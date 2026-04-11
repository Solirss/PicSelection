import SwiftUI
import Photos

// MARK: - SmartStackView
// Displays one Smart Stack at a time. The hero fills most of the screen;
// the discard tray sits below as a horizontal scroll of thumbnails.

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

            case .fetchingPhotos:
                LoadingView(icon: "photo.on.rectangle.angled",
                            title: "Fetching your library",
                            subtitle: "This takes a moment…")

            case .analysing(let progress):
                LoadingView(icon: "sparkles",
                            title: "Finding similar photos",
                            subtitle: "Analysed \(Int(progress * 100))%",
                            progress: progress)

            case .error(let message):
                ErrorView(message: message) {
                    Task { await viewModel.run() }
                }

            case .ready:
                if viewModel.stacks.isEmpty {
                    ErrorView(message: "All done — your library is clean!",
                              systemImage: "checkmark.seal.fill") { }
                } else {
                    stackCarousel
                }
            }
        }
        .task { await viewModel.run() }
    }

    // MARK: - Stack Carousel

    @State private var currentIndex = 0

    private var stackCarousel: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack {
                Text("\(viewModel.stacks.count) groups to review")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)

            TabView(selection: $currentIndex) {
                ForEach(Array(viewModel.stacks.enumerated()), id: \.element.id) { index, stack in
                    StackCard(stack: stack, viewModel: viewModel)
                        .tag(index)
                        .padding(.horizontal, 16)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: currentIndex)
        }
    }
}

// MARK: - StackCard
// A single card showing the hero + tray for one SmartStack.

private struct StackCard: View {
    let stack: SmartStack
    @ObservedObject var viewModel: SmartStackViewModel

    @State private var showDeleteConfirm = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {

                // MARK: Hero Image
                ZStack(alignment: .topLeading) {
                    Image(uiImage: stack.hero.image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: heroHeight(in: geometry.size.height))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                        .animation(.spring(response: 0.35), value: stack.hero.id)

                    // Top Pick badge
                    Label("Top Pick", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                }

                // MARK: Sharpness + Taste indicators
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
                    Text("\(stack.discardCount) to remove")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                // MARK: Discard Tray
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(stack.discardTray) { photo in
                            TrayThumbnail(photo: photo) {
                                viewModel.promotePhoto(photo, in: stack)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(height: 90)

                // MARK: Action Buttons
                HStack(spacing: 12) {
                    // Skip
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

                    // Keep & Delete
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Label("Keep Best & Delete \(stack.discardCount)",
                              systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.red, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .confirmationDialog(
            "Delete \(stack.discardCount) photo\(stack.discardCount == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(stack.discardCount) photo\(stack.discardCount == 1 ? "" : "s")",
                   role: .destructive) {
                Task { await viewModel.keepHeroDeleteRest(in: stack) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The top pick will be kept. This cannot be undone.")
        }
    }

    private func heroHeight(in availableHeight: CGFloat) -> CGFloat {
        availableHeight * 0.42   // ~42% of available height leaves room for tray + buttons
    }
}

// MARK: - TrayThumbnail

private struct TrayThumbnail: View {
    let photo: RankedPhoto
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // Blur warning badge
                if photo.sharpness < 0.015 {
                    Image(systemName: "drop.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.orange, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - QualityPill

private struct QualityPill: View {
    let icon: String
    let label: String
    let value: Float      // 0–1, already normalised by caller
    let maxValue: Float

    private var normalised: Double { Double(min(value / maxValue, 1)) }
    private var color: Color {
        normalised > 0.6 ? .green : normalised > 0.3 ? .orange : .red
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

// MARK: - Loading View

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

            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let progress {
                ProgressView(value: progress)
                    .tint(.accentColor)
                    .frame(width: 200)
            } else {
                ProgressView()
            }
        }
        .padding(40)
    }
}

// MARK: - Error View

private struct ErrorView: View {
    let message: String
    var systemImage: String = "exclamationmark.triangle"
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if systemImage == "exclamationmark.triangle" {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
