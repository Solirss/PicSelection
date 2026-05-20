import SwiftUI
import Photos

// First-run gate: asks for photo-library permission and routes the user
// to the main browser once granted.

struct PermissionsView: View {
    @StateObject private var analyzer = PhotoAnalyzer()
    @State private var status: PhotoAccessStatus = .notDetermined
    @State private var isRequesting = false

    var body: some View {
        Group {
            switch status {
            case .authorized, .limited:
                SmartStackView(
                    viewModel: SmartStackViewModel(analyzer: analyzer)
                )

            case .denied, .restricted:
                DeniedView(isPermanent: status == .restricted) {
                    analyzer.openAppSettings()
                }

            case .notDetermined:
                RequestView(isLoading: isRequesting) {
                    await requestAccess()
                }
            }
        }
        .task {
            status = currentStatus()
        }
    }

    private func requestAccess() async {
        isRequesting = true
        status = await analyzer.requestPhotoAccess()
        isRequesting = false
    }

    private func currentStatus() -> PhotoAccessStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:    return .authorized
        case .limited:       return .limited
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }
}

// MARK: - RequestView

private struct RequestView: View {
    let isLoading: Bool
    let onRequest: () async -> Void

    var body: some View {
        ZStack {
            backgroundWash

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                heroIcon
                    .padding(.bottom, 28)

                VStack(spacing: 10) {
                    Text("Smart Picks")
                        .font(.largeTitle.weight(.bold))
                    Text("Clean up your camera roll with photos picked just for your taste.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 36)

                featureList
                    .padding(.horizontal, 24)

                Spacer()

                allowButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                privacyNote
                    .padding(.bottom, 24)
            }
        }
    }

    private var backgroundWash: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.purple.opacity(0.06),
                    Color.clear
                ],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.20), Color.purple.opacity(0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 120, height: 120)
                .blur(radius: 6)

            Circle()
                .fill(Color(.systemBackground))
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.08), radius: 18, y: 6)

            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .accentColor],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .symbolEffect(.pulse, options: .repeat(.continuous))
        }
    }

    private var featureList: some View {
        VStack(spacing: 12) {
            FeatureRow(icon: "heart.fill", tint: .pink,
                       title: "Learns your taste",
                       subtitle: "Uses your Favorites album to understand what you love.")
            FeatureRow(icon: "drop.triangle.fill", tint: .orange,
                       title: "Flags blurry shots",
                       subtitle: "Spots out-of-focus and low-quality photos.")
            FeatureRow(icon: "square.stack.3d.up.fill", tint: .accentColor,
                       title: "Groups similar photos",
                       subtitle: "Finds burst shots and near-duplicates.")
        }
    }

    private var allowButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await onRequest() }
        } label: {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("Allow Photo Access")
                    }
                    .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                        startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: Color.accentColor.opacity(0.35), radius: 18, y: 8)
        }
        .disabled(isLoading)
    }

    private var privacyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.caption2)
            Text("Everything stays on your device. Nothing is uploaded.")
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 32)
        .multilineTextAlignment(.center)
    }
}

// MARK: - DeniedView

private struct DeniedView: View {
    let isPermanent: Bool
    let openSettings: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.10))
                        .frame(width: 110, height: 110)
                    Image(systemName: isPermanent ? "lock.fill" : "lock.shield.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    Text(isPermanent ? "Access restricted" : "Photo access denied")
                        .font(.title2.weight(.bold))
                    Text(isPermanent
                         ? "Your device settings prevent Smart Picks from accessing photos."
                         : "Smart Picks needs access to your library to find duplicates and your best shots.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }

                if !isPermanent {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        openSettings()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gear")
                            Text("Open Settings")
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                                    startPoint: .top, endPoint: .bottom))
                        )
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 14, y: 6)
                    }
                    .padding(.horizontal, 32)
                }

                Spacer()
            }
        }
    }
}

// MARK: - FeatureRow

private struct FeatureRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

#Preview {
    PermissionsView()
}
