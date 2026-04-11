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

// MARK: - Photo Item

struct PhotoItem {
    let asset: PHAsset
    let cgImage: CGImage
    var ciImage: CIImage { CIImage(cgImage: cgImage) }
}

// MARK: - PhotoAnalyzer
// ObservableObject so it can be used with @StateObject in PermissionsView.
// All mutations happen before any UI reads them, so there are no data races.

class PhotoAnalyzer: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    // Written once on a background thread in buildTasteProfile(),
    // then only read afterward — safe in practice.
    private(set) var tasteProfile: [VNFeaturePrintObservation] = []

    // CIContext is thread-safe for concurrent rendering.
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

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

    // MARK: - 2. Fingerprint

    func generateFingerprint(for cgImage: CGImage) async -> VNFeaturePrintObservation? {
        await Task.detached(priority: .userInitiated) {
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
        }.value
    }

    // MARK: - 3. Sharpness (Laplacian Variance)
    // Returns a score where higher = sharper. Below ~0.015 is visibly blurry.

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

    // MARK: - 4. Distance
    // Lower = more similar. <0.15 duplicate, 0.15-0.40 similar, >0.40 different.

    func computeDistance(between a: VNFeaturePrintObservation,
                         and b: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
            return distance
        } catch {
            print("Distance error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 5. Taste Profile
    // No @MainActor here — we run fully on a detached background task.

    func buildTasteProfile(sampleLimit: Int = 100) async {
        let prints: [VNFeaturePrintObservation] = await Task.detached(priority: .userInitiated) {
            let fetchResult = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            guard let favorites = fetchResult.firstObject else { return [] }

            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = sampleLimit
            let assets = PHAsset.fetchAssets(in: favorites, options: options)

            var prints: [VNFeaturePrintObservation] = []
            let imageOptions = PHImageRequestOptions()
            imageOptions.isSynchronous = true
            imageOptions.deliveryMode = .fastFormat
            imageOptions.resizeMode = .fast

            assets.enumerateObjects { asset, _, _ in
                var cgImage: CGImage?
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 224, height: 224),
                    contentMode: .aspectFill,
                    options: imageOptions
                ) { image, _ in cgImage = image?.cgImage }

                guard let cg = cgImage else { return }
                let request = VNGenerateImageFeaturePrintRequest()
                request.imageCropAndScaleOption = .scaleFill
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                if (try? handler.perform([request])) != nil,
                   let fp = request.results?.first as? VNFeaturePrintObservation {
                    prints.append(fp)
                }
            }
            return prints
        }.value

        tasteProfile = prints
        print("Taste profile built: \(prints.count) favorites fingerprinted.")
    }

    // MARK: - 6. Taste Score
    // Lower = closer to the user's taste = better match.

    func tasteScore(for fingerprint: VNFeaturePrintObservation) -> Float {
        guard !tasteProfile.isEmpty else { return Float.greatestFiniteMagnitude }
        let distances = tasteProfile.compactMap { computeDistance(between: fingerprint, and: $0) }
        guard !distances.isEmpty else { return Float.greatestFiniteMagnitude }
        return distances.reduce(0, +) / Float(distances.count)
    }

    // MARK: - 7. Group Duplicates (Sliding Window + Union-Find)

    func groupDuplicates(
            items: [PhotoItem],
            threshold: Float = 0.35,
            windowSize: Int = 10,
            progress: ((Double) -> Void)? = nil
        ) async -> [[PhotoItem]] {

            let n = items.count
            guard n > 1 else { return items.map { [$0] } }

            var fingerprints: [VNFeaturePrintObservation?] = Array(repeating: nil, count: n)
            
            // FIX: Replaced withTaskGroup with a sequential loop
            // This stops the Vision framework from deadlocking!
            for (i, item) in items.enumerated() {
                // Process one at a time
                let fp = await self.generateFingerprint(for: item.cgImage)
                fingerprints[i] = fp
                
                // Update progress safely
                progress?(Double(i + 1) / Double(n))
            }

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

            for i in 0..<(n-1) {
                guard let fp1 = fingerprints[i] else { continue }
                let windowEnd = min(i + windowSize, n - 1)
                for j in (i + 1)...windowEnd {
                    guard let fp2 = fingerprints[j] else { continue }
                    if let dist = computeDistance(between: fp1, and: fp2), dist < threshold {
                        union(i, j)
                    }
                }
            }

            var clusters: [Int: [PhotoItem]] = [:]
            for i in 0..<n {
                clusters[find(i), default: []].append(items[i])
            }
            return clusters.values.map { $0 }
        }

    // MARK: - 8. Fetch Recent Photos

    func fetchRecentPhotoItems(limit: Int = 100) async -> [PhotoItem] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = limit
            options.predicate = NSPredicate(format: "mediaType == %d",
                                            PHAssetMediaType.image.rawValue)

            let assets = PHAsset.fetchAssets(with: options)
            var items: [PhotoItem] = []

            let imageOptions = PHImageRequestOptions()
            imageOptions.isSynchronous = true
            imageOptions.deliveryMode = .highQualityFormat
            imageOptions.resizeMode = .exact

            assets.enumerateObjects { asset, _, _ in
                var cgImage: CGImage?
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 512, height: 512),
                    contentMode: .aspectFill,
                    options: imageOptions
                ) { image, _ in cgImage = image?.cgImage }

                if let cg = cgImage {
                    items.append(PhotoItem(asset: asset, cgImage: cg))
                }
            }
            return items
        }.value
    }

    // MARK: - Convenience

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}
