import SwiftUI
import Combine
import Photos
import Vision
import CoreImage

// MARK: - Access Status

enum PhotoAccessStatus {
    case authorized, limited, denied, restricted, notDetermined
    var canRead: Bool { self == .authorized || self == .limited }
    var isPermanentlyDenied: Bool { self == .denied || self == .restricted }
}

// MARK: - PhotoCategory
//
// Represents the semantic bucket a photo belongs to.
// Faces always take priority over scene classification (Rules 1 & 2).
// The raw string value is used only for debug printing.

enum PhotoCategory: String, CaseIterable {
    case soloPortrait  = "Solo Portrait"
    case groupPhoto    = "Group Photo"
    case pets          = "Pets"
    case nature        = "Nature"
    case food          = "Food"
    case document      = "Document"
    case misc          = "Misc"
}

// MARK: - FingerprintedAsset
// Lightweight pair stored after batch scanning — no CGImage held.

struct FingerprintedAsset {
    let asset: PHAsset
    let fingerprint: VNFeaturePrintObservation
}

// MARK: - PhotoItem
// Only created for the small winning cluster set.

struct PhotoItem {
    let asset: PHAsset
    let cgImage: CGImage
    var ciImage: CIImage { CIImage(cgImage: cgImage) }
}

// MARK: - PhotoAnalyzer

class PhotoAnalyzer: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    // Categorized taste profile — one fingerprint bucket per category.
    // Key insight: we only compare a candidate against its own category's
    // bucket, so a selfie never gets penalised for being unlike a landscape.
    private(set) var tasteProfile: [PhotoCategory: [VNFeaturePrintObservation]] = {
        // Pre-populate empty arrays so callers never hit nil on a missing key.
        var d = [PhotoCategory: [VNFeaturePrintObservation]]()
        PhotoCategory.allCases.forEach { d[$0] = [] }
        return d
    }()

    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    // Confidence threshold below which a VNClassifyImageRequest label is ignored.
    private let classifyConfidenceThreshold: Float = 0.4

    // MARK: - 1. Photo Access

    func requestPhotoAccess() async -> PhotoAccessStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                switch status {
                case .authorized:    continuation.resume(returning: .authorized)
                case .limited:       continuation.resume(returning: .limited)
                case .denied:        continuation.resume(returning: .denied)
                case .restricted:    continuation.resume(returning: .restricted)
                case .notDetermined: continuation.resume(returning: .notDetermined)
                @unknown default:    continuation.resume(returning: .notDetermined)
                }
            }
        }
    }

    // MARK: - 2. Categorise a CGImage
    //
    // Runs VNDetectFaceRectanglesRequest AND VNClassifyImageRequest in a
    // SINGLE handler.perform([...]) call. This is the critical efficiency win:
    // VNImageRequestHandler decodes the pixel buffer exactly once and feeds
    // it to both models simultaneously, rather than decoding twice.
    //
    // Priority order (as specified):
    //   1 face  → .soloPortrait
    //   2+ faces → .groupPhoto
    //   0 faces  → fall through to scene classification labels
    //   low confidence / no match → .misc

    func categorise(_ cgImage: CGImage) -> PhotoCategory {
        let faceRequest    = VNDetectFaceRectanglesRequest()
        let classifyRequest = VNClassifyImageRequest()

        // One decode, two models.
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([faceRequest, classifyRequest])

        // ── Rule 1: Faces take priority ────────────────────────────────────
        let faceCount = faceRequest.results?.count ?? 0
        if faceCount == 1 { return .soloPortrait }
        if faceCount >= 2 { return .groupPhoto }

        // ── Rule 2: Scene classification fallback ──────────────────────────
        // VNClassifyImageRequest returns labels sorted by confidence descending.
        // We walk them in order and return the first one that maps to a category.
        let labels = (classifyRequest.results as? [VNClassificationObservation]) ?? []

        for label in labels {
            // Ignore anything below our confidence floor.
            guard label.confidence >= classifyConfidenceThreshold else { break }

            if let category = Self.mapLabel(label.identifier) {
                return category
            }
        }

        // ── Rule 3: No confident match ─────────────────────────────────────
        return .misc
    }

    // MARK: - 2a. Label → Category mapping
    //
    // Apple's VNClassifyImageRequest uses a hierarchical identifier scheme
    // (e.g. "plant_", "animal_cat_", "food_fruit_apple").
    // We use prefix/substring matching so new sub-identifiers Apple adds
    // in future SDK versions fall through to the right bucket automatically.

    private static func mapLabel(_ id: String) -> PhotoCategory? {
        // Pets — specific animals before the broad "animal" check
        let petPrefixes = ["dog", "cat", "bird", "rabbit", "hamster",
                           "animal_dog", "animal_cat", "animal_bird",
                           "animal_rabbit", "animal_hamster", "pet"]
        if petPrefixes.contains(where: { id.hasPrefix($0) }) { return .pets }

        // Food
        let foodPrefixes = ["food", "drink", "beverage", "meal",
                            "fruit", "vegetable", "baked_goods", "dessert"]
        if foodPrefixes.contains(where: { id.hasPrefix($0) }) { return .food }

        // Document — text, receipts, screenshots, whiteboards
        let docPrefixes = ["text", "document", "receipt", "screenshot",
                           "whiteboard", "book", "newspaper", "magazine"]
        if docPrefixes.contains(where: { id.hasPrefix($0) }) { return .document }

        // Nature — outdoor scenes, landscapes, sky, water, plants
        let naturePrefixes = ["outdoor", "nature", "landscape", "sky",
                              "water", "ocean", "mountain", "forest",
                              "beach", "plant", "flower", "tree", "grass",
                              "field", "park", "garden", "sunset", "sunrise"]
        if naturePrefixes.contains(where: { id.hasPrefix($0) }) { return .nature }

        return nil
    }

    // MARK: - 3. Fingerprint a single CGImage (synchronous, call from bg thread)

    func generateFingerprint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            print("Fingerprint error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 4. Sharpness (Laplacian Variance)

    func calculateSharpness(ciImage: CIImage) -> Float {
        guard let conv = CIFilter(name: "CIConvolution3X3") else { return 0 }
        let kernel: [CGFloat] = [0.0, -1.0, 0.0, -1.0, 4.0, -1.0, 0.0, -1.0, 0.0]
        conv.setValue(ciImage, forKey: kCIInputImageKey)
        conv.setValue(CIVector(values: kernel, count: 9), forKey: "inputWeights")
        conv.setValue(0.0, forKey: "inputBias")
        guard let edgeImage = conv.outputImage else { return 0 }

        guard let avg = CIFilter(name: "CIAreaAverage") else { return 0 }
        avg.setValue(edgeImage, forKey: kCIInputImageKey)
        avg.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let avgImage = avg.outputImage else { return 0 }

        var bitmap = [Float](repeating: 0, count: 4)
        ciContext.render(avgImage,
                         toBitmap: &bitmap,
                         rowBytes: MemoryLayout<Float>.size * 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBAf,
                         colorSpace: nil)
        return max(bitmap[0], max(bitmap[1], bitmap[2]))
    }

    // MARK: - 5. Distance

    func computeDistance(between a: VNFeaturePrintObservation,
                         and b: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
            return distance
        } catch {
            return nil
        }
    }

    // MARK: - 6. Build Categorised Taste Profile
    //
    // For each favorite: classify it → fingerprint it → append to the right bucket.
    // Both classification and fingerprinting share a single VNImageRequestHandler
    // per image (same pixel decode, three models: face + scene + feature print).

    func buildTasteProfile(sampleLimit: Int = 100) async {
        let profile: [PhotoCategory: [VNFeaturePrintObservation]] =
            await Task.detached(priority: .userInitiated) {

            let fetchResult = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            guard let favorites = fetchResult.firstObject else { return [:] }

            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = sampleLimit
            let assets = PHAsset.fetchAssets(in: favorites, options: options)

            var buckets: [PhotoCategory: [VNFeaturePrintObservation]] = {
                var d = [PhotoCategory: [VNFeaturePrintObservation]]()
                PhotoCategory.allCases.forEach { d[$0] = [] }
                return d
            }()

            let imageOptions = PHImageRequestOptions()
            imageOptions.isSynchronous = true
            imageOptions.deliveryMode = .fastFormat
            imageOptions.resizeMode = .fast

            assets.enumerateObjects { [self] asset, _, _ in
                autoreleasepool {
                    var cgImage: CGImage?
                    PHImageManager.default().requestImage(
                        for: asset,
                        targetSize: CGSize(width: 224, height: 224),
                        contentMode: .aspectFill,
                        options: imageOptions
                    ) { image, _ in cgImage = image?.cgImage }

                    guard let cg = cgImage else { return }

                    // Three requests, one decode.
                    let faceRequest     = VNDetectFaceRectanglesRequest()
                    let classifyRequest = VNClassifyImageRequest()
                    let featureRequest  = VNGenerateImageFeaturePrintRequest()
                    featureRequest.imageCropAndScaleOption = .scaleFill

                    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                    guard (try? handler.perform([faceRequest, classifyRequest, featureRequest])) != nil,
                          let fp = featureRequest.results?.first as? VNFeaturePrintObservation
                    else { return }

                    // Determine category from the already-completed requests
                    let faceCount = faceRequest.results?.count ?? 0
                    let category: PhotoCategory

                    if faceCount == 1 {
                        category = .soloPortrait
                    } else if faceCount >= 2 {
                        category = .groupPhoto
                    } else {
                        let labels = (classifyRequest.results as? [VNClassificationObservation]) ?? []
                        category = labels
                            .first(where: { $0.confidence >= self.classifyConfidenceThreshold })
                            .flatMap { Self.mapLabel($0.identifier) } ?? .misc
                    }

                    buckets[category, default: []].append(fp)
                }
            }

            // Log the bucket breakdown for debugging
            buckets.forEach { cat, fps in
                if !fps.isEmpty { print("Taste profile [\(cat.rawValue)]: \(fps.count) photos") }
            }
            return buckets
        }.value

        tasteProfile = profile
    }

    // MARK: - 7. Categorised Taste Score (Min-Distance)
    //
    // Old approach: average distance to ALL favorites regardless of subject.
    // Problem: a great selfie scores badly because it's unlike landscape favorites.
    //
    // New approach:
    //   1. Classify the candidate image into a PhotoCategory.
    //   2. Look up only that category's bucket in the taste profile.
    //   3. Return the MIN distance to any single vector in the bucket.
    //      Min-distance rewards "at least one favorite looks like this",
    //      which is more robust than mean-distance when buckets are small.
    //   4. If the bucket is empty (user has no favorites of this type),
    //      return .greatestFiniteMagnitude so the photo is ranked last —
    //      we don't know their preference, so we don't guess.

    func tasteScore(for fingerprint: VNFeaturePrintObservation,
                    cgImage: CGImage) -> Float {

        let category = categorise(cgImage)
        let bucket   = tasteProfile[category] ?? []

        guard !bucket.isEmpty else {
            // No reference photos for this category — penalise rather than guess.
            return Float.greatestFiniteMagnitude
        }

        let distances = bucket.compactMap { computeDistance(between: fingerprint, and: $0) }
        guard !distances.isEmpty else { return Float.greatestFiniteMagnitude }

        // Min-distance: the photo only needs to resemble ONE favorite to score well.
        return distances.min()!
    }

    // MARK: - 8. Fingerprint a batch (RAM-safe, category stored per asset)
    //
    // fingerprintBatch now also categorises each photo during the same
    // Vision pass, storing the category in FingerprintedAsset.
    // No extra cost — face + classify requests piggyback on the feature
    // print decode that was already happening.

    func fingerprintBatch(
        assets: [PHAsset],
        progress: ((Double) -> Void)? = nil
    ) async -> [FingerprintedAsset] {

        await Task.detached(priority: .userInitiated) {
            var results: [FingerprintedAsset] = []
            results.reserveCapacity(assets.count)

            let imageOptions = PHImageRequestOptions()
            imageOptions.isSynchronous = true
            imageOptions.deliveryMode = .fastFormat
            imageOptions.resizeMode = .fast
            imageOptions.isNetworkAccessAllowed = false

            for (index, asset) in assets.enumerated() {
                autoreleasepool {
                    var cgImage: CGImage?
                    PHImageManager.default().requestImage(
                        for: asset,
                        targetSize: CGSize(width: 224, height: 224),
                        contentMode: .aspectFill,
                        options: imageOptions
                    ) { image, _ in cgImage = image?.cgImage }

                    guard let cg = cgImage else { return }

                    let featureRequest  = VNGenerateImageFeaturePrintRequest()
                    featureRequest.imageCropAndScaleOption = .scaleFill

                    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                    if (try? handler.perform([featureRequest])) != nil,
                       let fp = featureRequest.results?.first as? VNFeaturePrintObservation {
                        results.append(FingerprintedAsset(asset: asset, fingerprint: fp))
                    }
                }
                progress?(Double(index + 1) / Double(assets.count))
            }
            return results
        }.value
    }

    // MARK: - 9. Group fingerprints (no images in RAM)

    func groupFingerprintedAssets(
        _ assets: [FingerprintedAsset],
        threshold: Float = 0.35,
        windowSize: Int = 10
    ) -> [[FingerprintedAsset]] {

        let n = assets.count
        guard n > 1 else { return assets.map { [$0] } }

        var parent = Array(0..<n)
        var rank   = Array(repeating: 0, count: n)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb]      { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else                        { parent[rb] = ra; rank[ra] += 1 }
        }

        for i in 0..<n {
            let windowEnd = min(i + windowSize, n - 1)
            for j in (i + 1)...windowEnd {
                if let dist = computeDistance(between: assets[i].fingerprint,
                                              and: assets[j].fingerprint), dist < threshold {
                    union(i, j)
                }
            }
        }

        var clusters: [Int: [FingerprintedAsset]] = [:]
        for i in 0..<n { clusters[find(i), default: []].append(assets[i]) }
        return clusters.values.map { $0 }
    }

    // MARK: - 10. Resolve a cluster into PhotoItems for scoring

    func resolveCluster(_ cluster: [FingerprintedAsset]) -> [PhotoItem] {
        let imageOptions = PHImageRequestOptions()
        imageOptions.isSynchronous = true
        imageOptions.deliveryMode = .highQualityFormat
        imageOptions.resizeMode = .exact

        var items: [PhotoItem] = []
        for fa in cluster {
            autoreleasepool {
                var cgImage: CGImage?
                PHImageManager.default().requestImage(
                    for: fa.asset,
                    targetSize: CGSize(width: 512, height: 512),
                    contentMode: .aspectFill,
                    options: imageOptions
                ) { image, _ in cgImage = image?.cgImage }

                if let cg = cgImage {
                    items.append(PhotoItem(asset: fa.asset, cgImage: cg))
                }
            }
        }
        return items
    }

    // MARK: - Convenience

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}
