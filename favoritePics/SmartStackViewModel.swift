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
//
// `photos` is stable in AI-ranking order so the thumbnail tray and
// fullscreen swipe order never shuffle while the user is interacting.
// `selectedID` tracks the user's current pick separately — defaults to
// the AI's top pick on creation. Changing the selection no longer
// reorders the array.

struct SmartStack: Identifiable {
    let id = UUID()
    var photos: [RankedPhoto]
    var selectedID: String

    init(photos: [RankedPhoto]) {
        self.photos = photos
        self.selectedID = photos.first?.id ?? ""
    }

    var hero: RankedPhoto {
        photos.first(where: { $0.id == selectedID }) ?? photos[0]
    }

    var discardTray: [RankedPhoto] {
        photos.filter { $0.id != selectedID }
    }

    var discardCount: Int { photos.count - 1 }

    var aiPick: RankedPhoto? {
        photos.first(where: { $0.isTopPick })
    }

    mutating func promote(_ photo: RankedPhoto) {
        guard photos.contains(where: { $0.id == photo.id }) else { return }
        selectedID = photo.id
    }
}

// MARK: - PendingDeletion

struct PendingDeletion: Identifiable {
    let id: UUID = UUID()
    let stack: SmartStack
    let originalIndex: Int
    let scheduledAt: Date
    let undoWindow: TimeInterval

    var deadline: Date { scheduledAt.addingTimeInterval(undoWindow) }
    var photosCount: Int { stack.discardCount }
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

    // A deletion that's been requested but not yet committed to PhotoKit.
    // Shown as an undo toast; commits after `undoWindow` seconds unless cancelled.
    @Published var pendingDeletion: PendingDeletion? = nil

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
    private let undoWindow: TimeInterval = 5

    // All assets fetched once up front (cheap — metadata only)
    private var allAssets: [PHAsset] = []
    // Tracks which asset index the next batch starts from
    private var nextBatchOffset: Int = 0
    // Drives the undo timer; cancelling aborts the pending PhotoKit delete.
    private var undoTimerTask: Task<Void, Never>? = nil

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
            // FIX: resolveCluster uses PHImageManager internally, which must
            // not be called from Task.detached when using semaphore-based async.
            // Run it on a dedicated background queue instead of a detached Task
            // so the semaphore wait doesn't block the cooperative thread pool.
            let items: [PhotoItem] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [analyzer] in
                    continuation.resume(returning: analyzer.resolveCluster(cluster))
                }
            }

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

    // Removes the stack from the view immediately and shows an undo banner.
    // The actual PhotoKit deletion is delayed by `undoWindow` seconds so the
    // user has a chance to take it back. Requesting a new deletion while one
    // is pending commits the previous one straight away.
    func requestKeepHeroDeleteRest(in stack: SmartStack) {
        // Commit any in-flight pending deletion immediately so we never lose it.
        if let prev = pendingDeletion {
            undoTimerTask?.cancel()
            undoTimerTask = nil
            pendingDeletion = nil
            Task { await self.commit(stack: prev.stack) }
        }

        guard let idx = stacks.firstIndex(where: { $0.id == stack.id }) else { return }
        stacks.remove(at: idx)

        let pending = PendingDeletion(
            stack: stack,
            originalIndex: idx,
            scheduledAt: Date(),
            undoWindow: undoWindow
        )
        pendingDeletion = pending

        let id = pending.id
        undoTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.undoWindow ?? 5) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.commitPendingIfStillCurrent(id: id)
        }
    }

    func undoLastDeletion() {
        guard let pending = pendingDeletion else { return }
        undoTimerTask?.cancel()
        undoTimerTask = nil
        let insertIdx = min(pending.originalIndex, stacks.count)
        stacks.insert(pending.stack, at: insertIdx)
        pendingDeletion = nil
    }

    private func commitPendingIfStillCurrent(id: UUID) async {
        guard let current = pendingDeletion, current.id == id else { return }
        let stack = current.stack
        pendingDeletion = nil
        undoTimerTask = nil
        await commit(stack: stack)
    }

    private func commit(stack: SmartStack) async {
        let toDelete = stack.discardTray.map(\.asset)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }
        } catch {
            // PhotoKit refused the delete — log and move on. Re-inserting
            // the card here would be jarring after the user already moved past it.
            print("Delete failed: \(error.localizedDescription)")
        }
    }

    func skipStack(_ stack: SmartStack) {
        stacks.removeAll { $0.id == stack.id }
    }

    var hasMoreBatches: Bool { nextBatchOffset < allAssets.count }

    // MARK: - Helpers

    // FIX: switched from .opportunistic (multi-callback, data race on didResume)
    // to .highQualityFormat (single callback, no race possible).
    private func resolveDisplayImage(for asset: PHAsset) async -> UIImage {
        await withCheckedContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.isSynchronous = false
            opts.deliveryMode = .highQualityFormat  // single callback — no double-resume risk
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 800, height: 800),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                continuation.resume(returning: image ?? UIImage())
            }
        }
    }

    // Loads a higher-resolution image on demand for the full-screen viewer.
    // Bounded at 2400px on the long edge so pinch-zoom stays crisp without
    // exhausting RAM the way PHImageManagerMaximumSize would.
    func loadFullResolutionImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.isSynchronous = false
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .exact
            opts.isNetworkAccessAllowed = true

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 2400, height: 2400),
                contentMode: .aspectFit,
                options: opts
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
