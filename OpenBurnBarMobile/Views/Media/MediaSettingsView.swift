import SwiftUI
import OpenBurnBarCore

/// Settings → Media. Phase 2 brings the per-partner save preferences
/// link; Phase 6 adds the iPad back-camera toggle (only visible on
/// iPad Pro M-series); Phase 8 adds the Mercury pinned-tile toggle.
@MainActor
struct MediaSettingsView: View {
    @AppStorage("media.useBackCameraOnIPad") private var useBackCamera: Bool = false
    @AppStorage("media.statsOverlayEnabled") private var statsOverlayEnabled: Bool = false
    @AppStorage("mercury.autoKeyboardOnTextFocus") private var autoKeyboardOnTextFocus = false
    /// Mercury Phase 8 — controls the auto-pin of the "My Mac" tile in
    /// Hermes Square. Off → the tile disappears; on → it auto-pins on
    /// next detection. Persisted via `UserDefaults` (key matches
    /// `HermesSquareRoot`).
    @AppStorage("mercuryPinnedTileEnabled") private var mercuryPinnedTileEnabled: Bool = true
    @StateObject private var focusFollowPreference = AgentFocusFollowPreferenceStore.shared

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
                Toggle("Auto keyboard on text focus", isOn: $autoKeyboardOnTextFocus)
            } header: {
                Text("Calls & screen share")
            } footer: {
                Text("Auto keyboard opens the phone keyboard when your Mac focuses a text field. Smart Zoom still controls framing. Stats overlay also responds to a three-finger tap during a session.")
            }

            Section {
                Toggle("Show My Mac on Agents", isOn: $mercuryPinnedTileEnabled)
                    .accessibilityLabel("Show My Mac tile on Agents pinned grid")
                Picker("Agent mirror tracking", selection: $focusFollowPreference.mode) {
                    ForEach(AgentFocusFollowMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(focusFollowPreference.mode.settingsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Mercury")
            } footer: {
                Text("Your paired Mac can auto-pin to the Agents tab for mirror, call, or file actions. Tracking is reserved for Agent Watch views; regular Mac mirrors stay full display.")
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
