import SwiftUI
import Photos

struct SmartStackView: View {
    @ObservedObject var viewModel: SmartStackViewModel

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            switch viewModel.phase {
            case .idle:
                EmptyView()

            case .buildingProfile:
                LoadingView(icon: "heart.fill",
                            title: "Learning your taste",
                            subtitle: "Analysing your Favorites album…")

            case .scanning(let progress):
                LoadingView(
                    icon: "photo.stack",
                    title: "Scanning batch \(viewModel.currentBatch) of \(viewModel.totalBatches)",
                    subtitle: "Reading photos… \(Int(progress * 100))%",
                    progress: progress
                )

            case .clustering:
                LoadingView(icon: "sparkles",
                            title: "Grouping similar photos",
                            subtitle: "Comparing fingerprints…")

            case .ranking:
                LoadingView(icon: "star",
                            title: "Ranking your best shots",
                            subtitle: "Loading only the grouped photos…")

            case .error(let message):
                ErrorView(message: message) {
                    Task { await viewModel.run() }
                }

            case .ready, .finished:
                stackBrowser
            }
        }
        .task { await viewModel.run() }
    }

    // MARK: - Stack Browser

    // BUG FIX 1 — Zoom bug
    // The old TabView(.page) recalculates its entire geometry whenever
    // new stacks are appended, causing a jarring scale/zoom animation.
    // Replaced with a ScrollViewReader + LazyHStack so new cards are
    // simply appended at the end without disturbing the existing layout.

    @State private var currentStackID: UUID? = nil

    private var stackBrowser: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.stacks.count) groups found")
                        .font(.subheadline.weight(.semibold))
                    Text("Batch \(viewModel.currentBatch) of \(viewModel.totalBatches)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.phase != .finished {
                    Text("\(viewModel.totalBatches - viewModel.currentBatch) batches left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if viewModel.stacks.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No duplicates in this batch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if viewModel.hasMoreBatches {
                        nextBatchButton
                    } else {
                        Text("Your library is clean!")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 0) {
                                ForEach(viewModel.stacks) { stack in
                                    StackCard(stack: stack, viewModel: viewModel)
                                        .frame(width: geo.size.width)
                                        .id(stack.id)
                                }

                                // "Load next batch" card — appended without
                                // touching existing cards at all.
                                if viewModel.hasMoreBatches {
                                    nextBatchCard
                                        .frame(width: geo.size.width)
                                        .id("next-batch")
                                }
                            }
                            // Snap card-by-card
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollPosition(id: $currentStackID)
                        // When a new batch loads, stay on the current card —
                        // do NOT jump anywhere. The new cards appear at the end
                        // and the user can swipe to them naturally.
                        .onChange(of: viewModel.stacks.count) { _, _ in
                            // Intentionally empty — we don't move the scroll
                            // position when new stacks arrive.
                        }
                    }
                }
            }
        }
    }

    // MARK: - Next Batch UI

    private var nextBatchCard: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("All done with this batch!")
                    .font(.title3.weight(.semibold))
                Text("Batches keep memory usage low.\nTap below to scan the next 250 photos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            nextBatchButton
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var nextBatchButton: some View {
        Button {
            Task { await viewModel.loadNextBatch() }
        } label: {
            Group {
                if viewModel.isLoadingNextBatch {
                    ProgressView().tint(.white)
                } else {
                    Label("Load Next Batch (\(viewModel.currentBatch)/\(viewModel.totalBatches))",
                          systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.tint, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 32)
        .disabled(viewModel.isLoadingNextBatch)
    }
}

// MARK: - StackCard

private struct StackCard: View {
    let stack: SmartStack
    @ObservedObject var viewModel: SmartStackViewModel
    @State private var showDeleteConfirm = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {

                // Hero image
                ZStack(alignment: .topLeading) {
                    Image(uiImage: stack.hero.image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: heroHeight(in: geometry.size.height))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                        // Animate smoothly when the hero changes — no zoom,
                        // just a cross-fade driven by the id change.
                        .animation(.easeInOut(duration: 0.25), value: stack.hero.id)

                    // Show "AI Pick" badge on hero only when it's the top pick,
                    // so the user always knows if they're viewing the AI's choice.
                    if stack.hero.isTopPick {
                        Label("AI Pick", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.tint.opacity(0.85), in: Capsule())
                            .padding(12)
                    } else {
                        Label("Viewing", systemImage: "eye")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(12)
                    }
                }

                // Quality indicators
                HStack(spacing: 16) {
                    QualityPill(icon: "camera.aperture",
                                label: "Sharpness",
                                value: stack.hero.sharpness,
                                maxValue: 0.15)
                    QualityPill(icon: "heart",
                                label: "Your taste",
                                value: max(0, 1 - stack.hero.tasteScore),
                                maxValue: 1)
                    Spacer()
                    // BUG FIX 2 — count label now reflects total stack size
                    Text("\(stack.photos.count) photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                // BUG FIX 2 — Tray now shows ALL photos including the hero.
                // BUG FIX 3 — Selected frame around the current hero thumbnail.
                // BUG FIX 4 — Persistent sparkle badge on the AI's top pick.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(stack.photos) { photo in
                            TrayThumbnail(
                                photo: photo,
                                isSelected: photo.id == stack.hero.id,   // fix 3
                                isAIPick: photo.isTopPick                 // fix 4
                            ) {
                                // Tapping the current hero is a no-op
                                if photo.id != stack.hero.id {
                                    viewModel.promotePhoto(photo, in: stack)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .frame(height: 96)

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        viewModel.skipStack(stack)
                    } label: {
                        Label("Skip", systemImage: "arrow.right")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .foregroundStyle(.primary)

                    Button { showDeleteConfirm = true } label: {
                        // "Delete X" now means everything except the hero
                        Label("Keep Best & Delete \(stack.photos.count - 1)", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.red, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .confirmationDialog(
            "Delete \(stack.photos.count - 1) photo\(stack.photos.count - 1 == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(stack.photos.count - 1) photo\(stack.photos.count - 1 == 1 ? "" : "s")",
                   role: .destructive) {
                Task { await viewModel.keepHeroDeleteRest(in: stack) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The top pick will be kept. This cannot be undone.")
        }
    }

    private func heroHeight(in h: CGFloat) -> CGFloat { h * 0.45 }
}

// MARK: - TrayThumbnail
//
// Three visual states communicated simultaneously:
//   isSelected  → blue border (you are here)
//   isAIPick    → sparkle badge (AI's recommendation, always visible)
//   blur warning → orange triangle (technical quality flag)
//
// A thumbnail can be both the AI pick AND selected (when the user
// hasn't changed the hero), in which case both indicators show.

private struct TrayThumbnail: View {
    let photo: RankedPhoto
    let isSelected: Bool   // currently shown as the hero
    let isAIPick: Bool     // AI's top pick, regardless of selection
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // Blur warning — bottom trailing
                if photo.sharpness < 0.015 {
                    Image(systemName: "drop.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.orange, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
            .overlay(alignment: .topTrailing) {
                // BUG FIX 4 — AI pick sparkle badge, top trailing, always visible
                if isAIPick {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.tint, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        // BUG FIX 3 — selected frame: blue border for the current hero,
        // subtle gray border for everything else.
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        // Dim thumbnails that aren't selected so the hero stands out in the tray
        .opacity(isSelected ? 1.0 : 0.75)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - QualityPill

private struct QualityPill: View {
    let icon: String
    let label: String
    let value: Float
    let maxValue: Float

    private var normalised: Double { Double(min(value / maxValue, 1)) }
    private var color: Color { normalised > 0.6 ? .green : normalised > 0.3 ? .orange : .red }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 4)
                        Capsule().fill(color)
                            .frame(width: geo.size.width * normalised, height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(width: 110)
    }
}

// MARK: - LoadingView

private struct LoadingView: View {
    let icon: String
    let title: String
    let subtitle: String
    var progress: Double? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let progress {
                ProgressView(value: progress)
                    .tint(.accentColor)
                    .frame(width: 220)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .padding(40)
    }
}

// MARK: - ErrorView

private struct ErrorView: View {
    let message: String
    var systemImage: String = "exclamationmark.triangle"
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            if systemImage == "exclamationmark.triangle" {
                Button("Try Again", action: retry).buttonStyle(.borderedProminent)
            }
        }
    }
}
