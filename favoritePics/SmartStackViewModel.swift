import SwiftUI
import Combine
import Photos

// MARK: - Ranked Photo

struct RankedPhoto: Identifiable {
    let id: String
    let asset: PHAsset
    let image: UIImage
    let sharpness: Float
    let tasteScore: Float
    var isTopPick: Bool
    var rankScore: Float { sharpness - tasteScore }
}

// MARK: - Smart Stack

struct SmartStack: Identifiable {
    let id = UUID()
    var photos: [RankedPhoto]

    var hero: RankedPhoto { photos[0] }
    var discardTray: [RankedPhoto] { Array(photos.dropFirst()) }
    var discardCount: Int { photos.count - 1 }

    mutating func promote(_ photo: RankedPhoto) {
        guard let idx = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        photos.swapAt(0, idx)
    }
}

// MARK: - SmartStackViewModel

@MainActor
class SmartStackViewModel: ObservableObject {

    // MARK: - Published state

    @Published var stacks: [SmartStack] = []
    @Published var phase: LoadingPhase = .idle

    // How many batches exist in total and which one we're on
    @Published var currentBatch: Int = 0
    @Published var totalBatches: Int = 0
    // True while the next batch is being processed in the background
    @Published var isLoadingNextBatch: Bool = false

    enum LoadingPhase: Equatable {
        case idle
        case buildingProfile
        case scanning(progress: Double)   // fingerprinting the current batch
        case clustering                   // grouping fingerprints
        case ranking                      // loading images for winners only
        case ready                        // showing results
        case finished                     // all batches done
        case error(String)
    }

    // MARK: - Private state

    private let analyzer: PhotoAnalyzer
    private let batchSize: Int = 250
    private let sharpnessThreshold: Float = 0.015

    // All assets fetched once up front (cheap — metadata only)
    private var allAssets: [PHAsset] = []
    // Tracks which asset index the next batch starts from
    private var nextBatchOffset: Int = 0

    init(analyzer: PhotoAnalyzer) {
        self.analyzer = analyzer
    }

    // MARK: - Entry point

    func run() async {
        // 1. Build taste profile
        phase = .buildingProfile
        await analyzer.buildTasteProfile(sampleLimit: 100)

        // 2. Fetch all asset metadata once — this is very cheap (~100 bytes/asset)
        allAssets = await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType == %d",
                                            PHAssetMediaType.image.rawValue)
            let result = PHAsset.fetchAssets(with: options)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            return assets
        }.value

        guard !allAssets.isEmpty else {
            phase = .error("No photos found in your library.")
            return
        }

        totalBatches = Int(ceil(Double(allAssets.count) / Double(batchSize)))
        nextBatchOffset = 0
        currentBatch = 0

        // 3. Load the first batch
        await processNextBatch()
    }

    // MARK: - Load next batch (called by the UI "Load More" button)

    func loadNextBatch() async {
        guard nextBatchOffset < allAssets.count, !isLoadingNextBatch else { return }
        isLoadingNextBatch = true
        await processNextBatch()
        isLoadingNextBatch = false
    }

    // MARK: - Core batch processor

    private func processNextBatch() async {
        let batchStart = nextBatchOffset
        let batchEnd   = min(batchStart + batchSize, allAssets.count)
        let batchAssets = Array(allAssets[batchStart..<batchEnd])

        currentBatch += 1
        nextBatchOffset = batchEnd

        // ── Step A: Fingerprint this batch only ───────────────────────────
        // CGImages live only inside fingerprintBatch and are freed per-photo.
        // After this call, RAM holds only ~250 × 2 KB = ~500 KB of fingerprints.

        phase = .scanning(progress: 0)

        let fingerprintedBatch = await analyzer.fingerprintBatch(
            assets: batchAssets,
            progress: { [weak self] p in
                Task { @MainActor [weak self] in
                    self?.phase = .scanning(progress: p)
                }
            }
        )

        guard !fingerprintedBatch.isEmpty else {
            // Nothing fingerprinted in this batch — skip silently
            if nextBatchOffset >= allAssets.count { phase = .finished }
            return
        }

        // ── Step B: Cluster fingerprints (no images in RAM) ───────────────

        phase = .clustering

        let clusters = await Task.detached(priority: .userInitiated) { [analyzer] in
            analyzer.groupFingerprintedAssets(
                fingerprintedBatch,
                threshold: 0.35,
                windowSize: 10
            )
        }.value

        let multiClusters = clusters.filter { $0.count > 1 }

        // ── Step C: Load images only for clustered photos ─────────────────

        phase = .ranking

        var newStacks: [SmartStack] = []

        for cluster in multiClusters {
            // resolveCluster loads CGImages at 512px for sharpness scoring,
            // then immediately releases them after scoring.
            let items: [PhotoItem] = await Task.detached(priority: .userInitiated) { [analyzer] in
                analyzer.resolveCluster(cluster)
            }.value

            var ranked: [RankedPhoto] = []

            for (item, fa) in zip(items, cluster) {
                let uiImage  = await resolveDisplayImage(for: item.asset)
                let sharpness = analyzer.calculateSharpness(ciImage: item.ciImage)
                let score     = analyzer.tasteScore(for: fa.fingerprint, cgImage: item.cgImage)

                ranked.append(RankedPhoto(
                    id: item.asset.localIdentifier,
                    asset: item.asset,
                    image: uiImage,
                    sharpness: sharpness,
                    tasteScore: score,
                    isTopPick: false
                ))
            }

            ranked.sort { a, b in
                let aBlurry = a.sharpness < sharpnessThreshold
                let bBlurry = b.sharpness < sharpnessThreshold
                if aBlurry != bBlurry { return bBlurry }
                return a.rankScore > b.rankScore
            }

            if !ranked.isEmpty { ranked[0].isTopPick = true }
            newStacks.append(SmartStack(photos: ranked))
        }

        // Append new stacks to any existing ones from previous batches
        stacks.append(contentsOf: newStacks.sorted { $0.photos.count > $1.photos.count })

        // Mark ready (or finished if this was the last batch)
        phase = nextBatchOffset >= allAssets.count ? .finished : .ready
    }

    // MARK: - User Actions

    func promotePhoto(_ photo: RankedPhoto, in stack: SmartStack) {
        guard let idx = stacks.firstIndex(where: { $0.id == stack.id }) else { return }
        stacks[idx].promote(photo)
    }

    func keepHeroDeleteRest(in stack: SmartStack) async {
        let toDelete = stack.discardTray.map(\.asset)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }
            stacks.removeAll { $0.id == stack.id }
        } catch {
            phase = .error("Could not delete photos: \(error.localizedDescription)")
        }
    }

    func skipStack(_ stack: SmartStack) {
        stacks.removeAll { $0.id == stack.id }
    }

    var hasMoreBatches: Bool { nextBatchOffset < allAssets.count }

    // MARK: - Helpers

    private func resolveDisplayImage(for asset: PHAsset) async -> UIImage {
        await withCheckedContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.isSynchronous = false
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast

            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 800, height: 800),
                contentMode: .aspectFill,
                options: opts
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded && !didResume {
                    didResume = true
                    continuation.resume(returning: image ?? UIImage())
                }
            }
        }
    }
}
