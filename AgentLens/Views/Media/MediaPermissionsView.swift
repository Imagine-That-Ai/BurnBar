import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Settings → Privacy → Mercury permissions surface. Three rows —
/// Screen Recording / Camera / Microphone — with status pills + deep
/// links into System Settings.
@MainActor
struct MediaPermissionsView: View {
    @State private var screenRecordingStatus: PermissionStatus = .notRequested
    @State private var cameraStatus: PermissionStatus = .notRequested
    @State private var micStatus: PermissionStatus = .notRequested

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "Screen Recording",
                    rationale: "OpenBurnBar shares your screen with your paired iPhone or iPad during a pair-debug session.",
                    status: screenRecordingStatus,
                    deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
                permissionRow(
                    title: "Camera",
                    rationale: "OpenBurnBar uses your Mac's camera for one-on-one calls with your paired iPhone.",
                    status: cameraStatus,
                    deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
                )
                permissionRow(
                    title: "Microphone",
                    rationale: "OpenBurnBar uses the Mac microphone so you can speak with your paired iPhone during a call.",
                    status: micStatus,
                    deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
            } header: {
                Text("Mercury")
            } footer: {
                Text("OpenBurnBar uses these permissions only during sessions you initiate. Bytes flow peer-to-peer over iroh — never through our servers.")
            }
        }
        .task { await refreshAll() }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        rationale: String,
        status: PermissionStatus,
        deepLink: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.body)
                Spacer()
                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(status.tint.opacity(0.16), in: Capsule())
                    .foregroundStyle(status.tint)
            }
            Text(rationale).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Open System Settings") {
                    #if canImport(AppKit)
                    if let url = URL(string: deepLink) {
                        NSWorkspace.shared.open(url)
                    }
                    #endif
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func refreshAll() async {
        cameraStatus = await currentPermissionStatus(for: .video)
        micStatus = await currentPermissionStatus(for: .audio)
        // Screen Recording status isn't queryable cleanly outside macOS 14.5+
        // private API. Show "Check System Settings" instead.
        screenRecordingStatus = .notRequested
    }

    private func currentPermissionStatus(for mediaType: AVMediaType) async -> PermissionStatus {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .notRequested
        }
        #else
        return .notRequested
        #endif
    }
}

enum PermissionStatus: Sendable {
    case allowed
    case denied
    case notRequested

    var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .notRequested: return "Not requested"
        }
    }

    var tint: Color {
        switch self {
        case .allowed: return Color.green
        case .denied: return Color.red
        case .notRequested: return Color.secondary
        }
    }
}
