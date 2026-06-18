import SwiftUI
import OpenBurnBarAnalytics

/// The Settings toggle that lets the user turn opt-in analytics on or off at any
/// time. Reads/writes the shared tri-state consent store and notifies the recorder
/// (via `MobileAnalytics.setConsent`) so the Amplitude SDK starts on grant and
/// stops on revoke. Off by default; revoking stops all future sends at once and
/// flushes nothing. This is the same code path the first-run prompt uses, so the
/// two entry points can never diverge.
struct AnalyticsSettingsToggle: View {
    @ObservedObject private var consent = AnalyticsConsentStore.shared

    private var binding: Binding<Bool> {
        Binding(
            get: { consent.isGranted },
            set: { MobileAnalytics.setConsent(granted: $0) }
        )
    }

    var body: some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share Usage Analytics")
                    .font(.body)
                Text("Privacy-preserving product-usage events. Never your conversations, keystrokes, API keys, or location. Off by default — change it anytime.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("analytics.settings.toggle")
    }
}
