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

// MARK: - FingerprintedAsset
// Lightweight pair — fingerprint (~2 KB) only, no CGImage.

struct FingerprintedAsset {
    let asset: PHAsset
    let fingerprint: VNFeaturePrintObservation
}

// MARK: - PhotoItem
// Only created for the small set of photos that won a cluster.

struct PhotoItem {
    let asset: PHAsset
    let cgImage: CGImage
    var ciImage: CIImage { CIImage(cgImage: cgImage) }
}

// MARK: - PhotoAnalyzer

class PhotoAnalyzer: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    private(set) var tasteProfile: [VNFeaturePrintObservation] = []
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

    // MARK: - 2. Fingerprint a single CGImage

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

    // MARK: - 3. Sharpness (Laplacian Variance)

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

    // MARK: - 5. Taste Profile

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

    func tasteScore(for fingerprint: VNFeaturePrintObservation) -> Float {
        guard !tasteProfile.isEmpty else { return Float.greatestFiniteMagnitude }
        let distances = tasteProfile.compactMap { computeDistance(between: fingerprint, and: $0) }
        guard !distances.isEmpty else { return Float.greatestFiniteMagnitude }
        return distances.reduce(0, +) / Float(distances.count)
    }

    // MARK: - 7. Fingerprint a specific batch of assets
    //
    // Each CGImage lives only inside its autoreleasepool iteration.
    // After this returns, RAM holds only the fingerprints (~2 KB each).
    // 250 photos × 2 KB = ~500 KB. The 250 CGImages (~1.5 GB) are all gone.

    func fingerprintBatch(
        assets: [PHAsset],
        progress: ((Double) -> Void)? = nil
    ) async -> [FingerprintedAsset] {

        await Task.detached(priority: .userInitiated) {
            var results: [FingerprintedAsset] = []
            results.reserveCapacity(assets.count)

            let imageOptions = PHImageRequestOptions()
            imageOptions.isSynchronous = true
            // fastFormat = lower-res thumbnail, fine for fingerprinting,
            // uses ~6x less RAM than highQualityFormat.
            imageOptions.deliveryMode = .fastFormat
            imageOptions.resizeMode = .fast
            // Don't trigger iCloud downloads — use local copy only.
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

                    let request = VNGenerateImageFeaturePrintRequest()
                    request.imageCropAndScaleOption = .scaleFill
                    let handler = VNImageRequestHandler(cgImage: cg, options: [:])

                    if (try? handler.perform([request])) != nil,
                       let fp = request.results?.first as? VNFeaturePrintObservation {
                        results.append(FingerprintedAsset(asset: asset, fingerprint: fp))
                    }
                    // cg released here — autoreleasepool boundary
                }
                progress?(Double(index + 1) / Double(assets.count))
            }
            return results
        }.value
    }

    // MARK: - 8. Group fingerprints (no images in RAM)

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
            for j in (i)...windowEnd {
                if let dist = computeDistance(between: assets[i].fingerprint,
                                              and: assets[j].fingerprint), dist < threshold {
                    union(i, j)
                }
            }
        }

        var clusters: [Int: [FingerprintedAsset]] = [:]
        for i in 0..<n {
            clusters[find(i), default: []].append(assets[i])
        }
        return clusters.values.map { $0 }
    }

    // MARK: - 9. Resolve a cluster into PhotoItems for scoring
    //
    // Only called for the small winner set inside each batch.

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
