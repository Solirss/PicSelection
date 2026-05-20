import SwiftUI
import Photos

// MARK: - SmartStackView (root)

struct SmartStackView: View {
    @ObservedObject var viewModel: SmartStackViewModel

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            switch viewModel.phase {
            case .idle:
                Color.clear

            case .buildingProfile:
                StatusView(icon: "heart.fill",
                           tint: .pink,
                           title: "Learning your taste",
                           subtitle: "Analyzing your Favorites album")

            case .scanning(let progress):
                StatusView(icon: "rectangle.stack",
                           tint: .accentColor,
                           title: "Scanning your library",
                           subtitle: "Batch \(viewModel.currentBatch) of \(viewModel.totalBatches) · \(Int(progress * 100))%",
                           progress: progress)

            case .clustering:
                StatusView(icon: "square.grid.3x3.square",
                           tint: .accentColor,
                           title: "Finding similar shots",
                           subtitle: "Comparing visual fingerprints")

            case .ranking:
                StatusView(icon: "sparkles",
                           tint: .accentColor,
                           title: "Ranking your best shots",
                           subtitle: "Loading the photos that matter")

            case .error(let message):
                ErrorView(message: message) {
                    Task { await viewModel.run() }
                }

            case .ready, .finished:
                StackBrowser(viewModel: viewModel)
            }
        }
        .task { await viewModel.run() }
    }
}

// MARK: - StackBrowser

private struct StackBrowser: View {
    @ObservedObject var viewModel: SmartStackViewModel
    @State private var currentStackID: AnyHashable? = nil
    @State private var fullScreenStack: SmartStack? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            if viewModel.stacks.isEmpty {
                emptyState
            } else {
                cardPager
            }
        }
        .fullScreenCover(item: $fullScreenStack) { snapshot in
            FullScreenPhotoViewer(
                stackID: snapshot.id,
                viewModel: viewModel
            )
        }
        .overlay(alignment: .bottom) {
            if let pending = viewModel.pendingDeletion {
                UndoToast(pending: pending) {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    viewModel.undoLastDeletion()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85),
                   value: viewModel.pendingDeletion?.id)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Picks")
                        .font(.title2.weight(.bold))
                    Text(headerSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusChip
            }

            progressBar
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var headerSubtitle: String {
        if viewModel.stacks.isEmpty { return "No groups in view" }
        let current = stackPosition
        return "Group \(current) of \(viewModel.stacks.count)"
    }

    private var stackPosition: Int {
        guard let id = currentStackID,
              let idx = viewModel.stacks.firstIndex(where: { AnyHashable($0.id) == id })
        else { return 1 }
        return idx + 1
    }

    @ViewBuilder
    private var statusChip: some View {
        if viewModel.phase == .finished {
            Label("Scan complete", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.green.opacity(0.12), in: Capsule())
        } else if viewModel.isLoadingNextBatch {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
        } else {
            Label("\(viewModel.totalBatches - viewModel.currentBatch) batches left",
                  systemImage: "rectangle.stack")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.7)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * scanProgress)
                    .animation(.easeInOut(duration: 0.4), value: scanProgress)
            }
        }
        .frame(height: 4)
    }

    private var scanProgress: Double {
        guard viewModel.totalBatches > 0 else { return 0 }
        return min(1, Double(viewModel.currentBatch) / Double(viewModel.totalBatches))
    }

    // MARK: Card pager

    private var cardPager: some View {
        GeometryReader { geo in
            ScrollViewReader { _ in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(viewModel.stacks) { stack in
                            StackCard(
                                stack: stack,
                                viewModel: viewModel,
                                onOpenViewer: { fullScreenStack = stack }
                            )
                            .frame(width: geo.size.width)
                            .id(AnyHashable(stack.id))
                        }

                        if viewModel.hasMoreBatches {
                            NextBatchCard(viewModel: viewModel)
                                .frame(width: geo.size.width)
                                .id(AnyHashable("next-batch"))
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $currentStackID)
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(.green.opacity(0.10))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.green)
            }
            VStack(spacing: 6) {
                Text(viewModel.hasMoreBatches ? "Nothing to clean here" : "Your library is tidy")
                    .font(.title3.weight(.semibold))
                Text(viewModel.hasMoreBatches
                     ? "No duplicate groups in this batch."
                     : "No more duplicate groups were found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            if viewModel.hasMoreBatches {
                NextBatchButton(viewModel: viewModel)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
            }
            Spacer()
        }
    }
}

// MARK: - StackCard

private struct StackCard: View {
    let stack: SmartStack
    @ObservedObject var viewModel: SmartStackViewModel
    let onOpenViewer: () -> Void

    @State private var showCompare = false

    var body: some View {
        VStack(spacing: 0) {
            heroSection
                .padding(.horizontal, 16)
                .padding(.top, 4)

            metaRow
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 12)

            thumbnailTray
                .padding(.bottom, 6)

            Spacer(minLength: 8)

            actionBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showCompare) {
            CompareGridSheet(stackID: stack.id, viewModel: viewModel)
        }
    }

    // MARK: Hero

    private var heroSection: some View {
        GeometryReader { geo in
            Button(action: onOpenViewer) {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: stack.hero.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    // Bottom gradient for badge legibility
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .center, endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .allowsHitTesting(false)

                    HStack {
                        pickBadge
                        Spacer()
                        tapHintBadge
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            heroFooterText
                            Spacer()
                            sizeBadge
                        }
                        .padding(14)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: stack.hero.id)
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 10)
        }
        .aspectRatio(3.0/4.0, contentMode: .fit)
    }

    @ViewBuilder
    private var pickBadge: some View {
        if stack.hero.isTopPick {
            Label("AI Pick", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [.purple, .accentColor],
                        startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .shadow(color: .accentColor.opacity(0.35), radius: 8, y: 3)
        } else {
            Label("Your pick", systemImage: "hand.tap.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
        }
    }

    private var tapHintBadge: some View {
        Label("Tap to view", systemImage: "arrow.up.left.and.arrow.down.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
    }

    @ViewBuilder
    private var heroFooterText: some View {
        if !stack.hero.isTopPick {
            Button {
                if let aiPick = stack.aiPick {
                    viewModel.promotePhoto(aiPick, in: stack)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } label: {
                Label("Restore AI Pick", systemImage: "arrow.uturn.backward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        } else if let reason = pickReason(for: stack.hero, in: stack) {
            Label(reason, systemImage: "lightbulb.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func pickReason(for hero: RankedPhoto, in stack: SmartStack) -> String? {
        guard hero.isTopPick, stack.photos.count > 1 else { return nil }
        let maxSharp = stack.photos.map(\.sharpness).max() ?? 0
        let minTaste = stack.photos.map(\.tasteScore).min() ?? 0
        let isSharpest = hero.sharpness == maxSharp
        let isBestTaste = hero.tasteScore == minTaste
        switch (isSharpest, isBestTaste) {
        case (true, true):   return "Sharpest and best taste match"
        case (true, false):  return "Sharpest in this group"
        case (false, true):  return "Closest to your taste"
        case (false, false): return "Best overall balance"
        }
    }

    private var sizeBadge: some View {
        Text("\(stack.photos.count) photos")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
    }

    // MARK: Meta row

    private var metaRow: some View {
        HStack(spacing: 10) {
            QualityChip(
                icon: "camera.aperture",
                label: "Sharpness",
                value: stack.hero.sharpness,
                maxValue: 0.15
            )
            QualityChip(
                icon: "heart.fill",
                label: "Your taste",
                value: max(0, 1 - stack.hero.tasteScore),
                maxValue: 1
            )
        }
    }

    // MARK: Thumbnail tray

    private var thumbnailTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All \(stack.photos.count) in this group")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showCompare = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.grid.2x2.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Compare")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(stack.photos) { photo in
                        TrayThumbnail(
                            photo: photo,
                            isSelected: photo.id == stack.hero.id
                        ) {
                            if photo.id != stack.hero.id {
                                viewModel.promotePhoto(photo, in: stack)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                viewModel.skipStack(stack)
            } label: {
                Label("Skip", systemImage: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            }

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                viewModel.requestKeepHeroDeleteRest(in: stack)
            } label: {
                Label("Keep best · Delete \(stack.discardCount)",
                      systemImage: "trash.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.red, Color.red.opacity(0.85)],
                                startPoint: .top, endPoint: .bottom))
                    )
                    .shadow(color: .red.opacity(0.35), radius: 14, y: 6)
            }
        }
    }
}

// MARK: - TrayThumbnail

private struct TrayThumbnail: View {
    let photo: RankedPhoto
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if photo.isTopPick {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "sparkles")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(
                                    LinearGradient(
                                        colors: [.purple, .accentColor],
                                        startPoint: .leading, endPoint: .trailing),
                                    in: Circle()
                                )
                                .offset(x: 4, y: -4)
                        }
                        Spacer()
                    }
                }

                if photo.sharpness < 0.015 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.orange, in: Circle())
                                .offset(x: 4, y: 4)
                        }
                    }
                }
            }
            .frame(width: 78, height: 78)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 3
                    )
            )
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .opacity(isSelected ? 1.0 : 0.7)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - QualityChip

private struct QualityChip: View {
    let icon: String
    let label: String
    let value: Float
    let maxValue: Float

    private var normalised: Double { Double(min(value / maxValue, 1)) }
    private var color: Color {
        normalised > 0.6 ? .green : normalised > 0.3 ? .orange : .red
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * normalised)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - NextBatchCard / NextBatchButton

private struct NextBatchCard: View {
    @ObservedObject var viewModel: SmartStackViewModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
            }
            VStack(spacing: 6) {
                Text("Batch reviewed")
                    .font(.title3.weight(.semibold))
                Text("Tap to scan the next 250 photos.\nWe load them in chunks to keep things smooth.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            NextBatchButton(viewModel: viewModel)
                .padding(.horizontal, 32)
                .padding(.top, 4)
            Spacer()
        }
    }
}

private struct NextBatchButton: View {
    @ObservedObject var viewModel: SmartStackViewModel

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await viewModel.loadNextBatch() }
        } label: {
            HStack {
                if viewModel.isLoadingNextBatch {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                    Text("Load next batch")
                        .monospacedDigit()
                    Text("\(viewModel.currentBatch)/\(viewModel.totalBatches)")
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.85)],
                        startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: .accentColor.opacity(0.35), radius: 14, y: 6)
        }
        .disabled(viewModel.isLoadingNextBatch)
    }
}

// MARK: - StatusView (loading)

private struct StatusView: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    var progress: Double? = nil

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 110, height: 110)
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let progress {
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                        .tint(tint)
                        .frame(width: 240)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(40)
    }
}

// MARK: - ErrorView

private struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.10))
                    .frame(width: 96, height: 96)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
            }
            Text("Something went wrong")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Try again", action: retry)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: 48)
                .background(.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - FullScreenPhotoViewer

private struct FullScreenPhotoViewer: View {
    let stackID: UUID
    @ObservedObject var viewModel: SmartStackViewModel
    @Environment(\.dismiss) private var dismiss

    // Track selection by photo ID so the user stays on the same photo
    // even if the stack changes underneath.
    @State private var currentPhotoID: String? = nil

    private var stack: SmartStack? {
        viewModel.stacks.first(where: { $0.id == stackID })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let stack {
                content(stack: stack)
            } else {
                // Stack vanished (deleted, skipped) — close politely.
                Color.clear.onAppear { dismiss() }
            }
        }
        .statusBarHidden()
    }

    private func content(stack: SmartStack) -> some View {
        let selectionBinding = Binding<Int>(
            get: {
                stack.photos.firstIndex(where: { $0.id == currentPhotoID })
                    ?? stack.photos.firstIndex(where: { $0.id == stack.hero.id })
                    ?? 0
            },
            set: { newIndex in
                if stack.photos.indices.contains(newIndex) {
                    currentPhotoID = stack.photos[newIndex].id
                }
            }
        )

        let currentPhoto = stack.photos.first(where: { $0.id == currentPhotoID }) ?? stack.hero

        return ZStack {
            TabView(selection: selectionBinding) {
                ForEach(Array(stack.photos.enumerated()), id: \.element.id) { index, photo in
                    ZoomablePhoto(photo: photo, viewModel: viewModel)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                topBar(stack: stack, selection: selectionBinding, currentPhoto: currentPhoto)
                Spacer()
                bottomBar(stack: stack, currentPhoto: currentPhoto)
            }
        }
        .onAppear {
            if currentPhotoID == nil {
                currentPhotoID = stack.hero.id
            }
        }
    }

    // MARK: Top bar

    private func topBar(stack: SmartStack,
                        selection: Binding<Int>,
                        currentPhoto: RankedPhoto) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            VStack(spacing: 4) {
                Text("\(selection.wrappedValue + 1) of \(stack.photos.count)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                if currentPhoto.isTopPick {
                    Label("AI Pick", systemImage: "sparkles")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            LinearGradient(
                                colors: [.purple, .accentColor],
                                startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                } else if currentPhoto.id == stack.hero.id {
                    Label("Your pick", systemImage: "hand.tap.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }

            Spacer()

            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Bottom bar

    private func bottomBar(stack: SmartStack, currentPhoto: RankedPhoto) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                DarkChip(
                    icon: "camera.aperture",
                    label: "Sharpness",
                    value: currentPhoto.sharpness,
                    maxValue: 0.15
                )
                DarkChip(
                    icon: "heart.fill",
                    label: "Your taste",
                    value: max(0, 1 - currentPhoto.tasteScore),
                    maxValue: 1
                )
            }

            if currentPhoto.id != stack.hero.id {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    viewModel.promotePhoto(currentPhoto, in: stack)
                } label: {
                    Label("Keep this one", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white)
                        )
                }
            } else {
                Label("This is the photo to keep", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

// MARK: - ZoomablePhoto (single zoomable page)

private struct ZoomablePhoto: View {
    let photo: RankedPhoto
    @ObservedObject var viewModel: SmartStackViewModel

    @State private var highRes: UIImage? = nil
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(uiImage: highRes ?? photo.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = max(1, min(lastScale * value, 5))
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    if scale <= 1 {
                                        withAnimation(.spring()) {
                                            scale = 1
                                            offset = .zero
                                            lastOffset = .zero
                                            lastScale = 1
                                        }
                                    }
                                },
                            DragGesture()
                                .onChanged { value in
                                    guard scale > 1 else { return }
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            if scale > 1 {
                                scale = 1
                                offset = .zero
                                lastOffset = .zero
                                lastScale = 1
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
            }
        }
        .task(id: photo.id) {
            let img = await viewModel.loadFullResolutionImage(for: photo.asset)
            if let img { highRes = img }
        }
    }
}

// MARK: - UndoToast

private struct UndoToast: View {
    let pending: PendingDeletion
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CountdownRing(deadline: pending.deadline, total: pending.undoWindow)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Deleting \(pending.photosCount) photo\(pending.photosCount == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Tap undo to keep them")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer(minLength: 8)

            Button(action: onUndo) {
                Text("Undo")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.88))
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

private struct CountdownRing: View {
    let deadline: Date
    let total: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let progress = total > 0 ? min(1, max(0, remaining / total)) : 0
            ZStack {
                Circle().stroke(.white.opacity(0.22), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

// MARK: - CompareGridSheet

private struct CompareGridSheet: View {
    let stackID: UUID
    @ObservedObject var viewModel: SmartStackViewModel
    @Environment(\.dismiss) private var dismiss

    private var stack: SmartStack? {
        viewModel.stacks.first(where: { $0.id == stackID })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if let stack {
                    content(stack: stack)
                } else {
                    Color.clear.onAppear { dismiss() }
                }
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    private func content(stack: SmartStack) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ]

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tap a photo to choose the one you'll keep.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(stack.photos) { photo in
                        CompareTile(
                            photo: photo,
                            isSelected: photo.id == stack.hero.id
                        ) {
                            viewModel.promotePhoto(photo, in: stack)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
            .padding(.top, 12)
        }
    }
}

private struct CompareTile: View {
    let photo: RankedPhoto
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .center, endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)

                HStack {
                    if photo.isTopPick {
                        Label("AI Pick", systemImage: "sparkles")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                LinearGradient(
                                    colors: [.purple, .accentColor],
                                    startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.4), radius: 4)
                    }
                }
                .padding(10)

                VStack {
                    Spacer()
                    HStack {
                        if photo.sharpness < 0.015 {
                            Label("Blurry", systemImage: "drop.triangle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.orange, in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .shadow(color: isSelected
                    ? Color.accentColor.opacity(0.30)
                    : Color.black.opacity(0.06),
                    radius: isSelected ? 14 : 6, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DarkChip (used inside the dark viewer)

private struct DarkChip: View {
    let icon: String
    let label: String
    let value: Float
    let maxValue: Float

    private var normalised: Double { Double(min(value / maxValue, 1)) }
    private var color: Color {
        normalised > 0.6 ? .green : normalised > 0.3 ? .orange : .red
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(color.opacity(0.20), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.15))
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * normalised)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
