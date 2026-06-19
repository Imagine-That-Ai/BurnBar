import SwiftUI
import OpenBurnBarAnalytics

/// First-run, opt-in analytics consent prompt for the iOS host.
///
/// Shown exactly once — only while consent is `.unset` (`hasDecided == false`).
/// Choosing "Allow" records `.granted` and notifies the recorder, which starts
/// the SDK and emits the single `consent.analytics.granted`. Choosing "Not Now"
/// records `.declined`, keeping analytics fully dark; it never re-prompts (decline
/// is a decision). Until the user taps one of the two, analytics stays dark
/// (`.unset`), and the SDK is never constructed.
///
/// This is presentation-only: it owns no analytics logic beyond calling
/// `MobileAnalytics.setConsent(granted:)`, which is the same path the Settings
/// toggle uses, so the behavior can't drift between the two entry points.
struct AnalyticsConsentPrompt: View {
    @ObservedObject private var consent = AnalyticsConsentStore.shared
    /// Bound to the host so the sheet dismisses once a decision is recorded.
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 8)
                .accessibilityHidden(true)

            Text("Help improve OpenBurnBar")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(
                """
                Share privacy-preserving product-usage events to help us improve OpenBurnBar. \
                It’s off until you choose, and you can change it anytime in Settings.

                We never collect your conversations, prompts, message text, keystrokes, \
                API keys, secrets, file paths, or precise location — only which features are \
                used, their outcomes, and coarse timing.
                """
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button {
                    decide(granted: true)
                } label: {
                    Text("Allow analytics")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("analytics.consent.allow")

                Button {
                    decide(granted: false)
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("analytics.consent.decline")
            }
            .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true) // a decision must be recorded, not swiped away
    }

    private func decide(granted: Bool) {
        MobileAnalytics.setConsent(granted: granted)
        if granted {
            MobileAnalytics.trackSessionSpineAfterFirstGrant()
        }
        isPresented = false
    }
}

extension View {
    /// Presents the first-run analytics consent prompt the first time the app is
    /// shown with consent still `.unset`. A no-op once the user has decided
    /// (granted or declined), so it never reappears.
    func analyticsConsentPrompt() -> some View {
        modifier(AnalyticsConsentPromptModifier())
    }
}

private struct AnalyticsConsentPromptModifier: ViewModifier {
    @ObservedObject private var consent = AnalyticsConsentStore.shared
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Present only when undecided. `hasDecided` is false only for `.unset`.
                if !consent.hasDecided { isPresented = true }
            }
            .sheet(isPresented: $isPresented) {
                AnalyticsConsentPrompt(isPresented: $isPresented)
            }
    }
}
