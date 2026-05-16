import SwiftUI

/// Settings → Media. Phase 2 brings the per-partner save preferences
/// link; Phase 6 adds the iPad back-camera toggle (only visible on
/// iPad Pro M-series).
@MainActor
struct MediaSettingsView: View {
    @AppStorage("media.useBackCameraOnIPad") private var useBackCamera: Bool = false
    @AppStorage("media.statsOverlayEnabled") private var statsOverlayEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                NavigationLink("Per-partner save preferences") {
                    PerPartnerSavePreferencesView()
                }
            } header: {
                Text("Attachments")
            }

            Section {
                #if canImport(UIKit)
                if isIPadProMSeries {
                    Toggle("Use back camera in calls", isOn: $useBackCamera)
                }
                #endif
                Toggle("Show session stats overlay", isOn: $statsOverlayEnabled)
            } header: {
                Text("Calls & screen share")
            } footer: {
                Text("Stats overlay also responds to a three-finger tap during a session.")
            }
        }
        .navigationTitle("Media")
    }

    private var isIPadProMSeries: Bool {
        #if canImport(UIKit)
        // Heuristic — real check happens at runtime in
        // `iPadMultiCamCaptureService` via `AVCaptureMultiCamSession.isMultiCamSupported`.
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        MediaSettingsView()
    }
}
#endif
