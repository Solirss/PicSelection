import SwiftUI
import Photos

// Permission View is the page where the app asks from permssion to look at the gallery 

struct PermissionsView: View {
    // PhotoAnalyzer is ObservableObject so @StateObject keeps it alive
    // across view updates and passes the same instance into the ViewModel.
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
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.tint.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
            }

            VStack(spacing: 12) {
                Text("Clean up your camera roll")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("This app analyses your photos to find duplicates and surface your best shots — guided by your personal taste from your Favorites.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "heart.fill", color: .pink,
                           title: "Learns your taste",
                           subtitle: "Reads your Favorites to understand what you love")
                FeatureRow(icon: "eye.slash.fill", color: .orange,
                           title: "Flags blurry shots",
                           subtitle: "Automatically spots out-of-focus photos")
                FeatureRow(icon: "square.stack.3d.up.fill", color: .blue,
                           title: "Groups similar photos",
                           subtitle: "Finds burst shots and near-duplicates")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                Task { await onRequest() }
            } label: {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Allow Photo Access").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.tint, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .disabled(isLoading)

            Text("Photos are analysed entirely on-device. Nothing ever leaves your phone.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
        }
    }
}

// MARK: - DeniedView

private struct DeniedView: View {
    let isPermanent: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Text(isPermanent ? "Access restricted" : "Photo access denied")
                    .font(.title3.weight(.semibold))
                Text(isPermanent
                     ? "Your device policy prevents this app from accessing photos."
                     : "This app needs access to your photo library to work.\nYou can change this in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            if !isPermanent {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }
}

// MARK: - FeatureRow

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    PermissionsView()
}
