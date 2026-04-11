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

    @Published var stacks: [SmartStack] = []
    @Published var phase: LoadingPhase = .idle

    enum LoadingPhase: Equatable {
        case idle
        case buildingProfile
        case fetchingPhotos
        case analysing(progress: Double)
        case ready
        case error(String)
    }

    private let analyzer: PhotoAnalyzer
    private let sharpnessThreshold: Float = 0.015

    init(analyzer: PhotoAnalyzer) {
        self.analyzer = analyzer
    }

    // MARK: - Main Pipeline

    func run() async {
        phase = .buildingProfile
        await analyzer.buildTasteProfile(sampleLimit: 100)

        phase = .fetchingPhotos
        let items = await analyzer.fetchRecentPhotoItems(limit: 100)
        guard !items.isEmpty else {
            phase = .error("No photos found in your library.")
            return
        }

        phase = .analysing(progress: 0)
        let clusters = await analyzer.groupDuplicates(
            items: items,
            threshold: 0.35,
            windowSize: 10,
            progress: { [weak self] p in
                // progress callback is called from a background thread —
                // hop back to MainActor to update @Published state.
                Task { @MainActor [weak self] in
                    self?.phase = .analysing(progress: p)
                }
            }
        )
        

        let multiClusters = clusters.filter { $0.count > 1 }
        guard !multiClusters.isEmpty else {
            phase = .error("No similar photo groups found. Your library looks pretty clean!")
            return
        }

        // Resolve display images and rank — done cluster by cluster so we
        // avoid loading all 500 UIImages into memory simultaneously.
        var result: [SmartStack] = []
        for cluster in multiClusters {
            var ranked: [RankedPhoto] = []

            for item in cluster {
                // resolveDisplayImage uses a continuation so it must run
                // where async PHImageManager callbacks are safe — here on MainActor.
                let uiImage = await resolveDisplayImage(for: item.asset)
                let sharpness = analyzer.calculateSharpness(ciImage: item.ciImage)
                let fp = await analyzer.generateFingerprint(for: item.cgImage)
                let score = fp.map { analyzer.tasteScore(for: $0) } ?? Float.greatestFiniteMagnitude

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
            result.append(SmartStack(photos: ranked))
        }

        stacks = result.sorted { $0.photos.count > $1.photos.count }
        phase = .ready
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

    // MARK: - Helpers
    // Runs on MainActor so the PHImageManager callback and continuation
    // are always on the same actor — no cross-actor resume issues.

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
                // Resume on the final (non-degraded) delivery only,
                // and guard against double-resume if PHImageManager calls back twice.
                if !isDegraded && !didResume {
                    didResume = true
                    continuation.resume(returning: image ?? UIImage())
                }
            }
        }
    }
}
