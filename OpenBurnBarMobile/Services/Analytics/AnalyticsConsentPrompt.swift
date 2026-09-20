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
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    """
                    Share privacy-preserving product-usage events to help us improve OpenBurnBar. \
                    It’s off until you choose, and you can change it anytime in Settings.

                    We never collect your conversations, prompts, message text, keystrokes, \
                    API keys, secrets, file paths, or precise location — only which features are \
                    used, their outcomes, and coarse timing.
                    """
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                consentActions
            }
            .padding(24)
            .navigationTitle("Help improve OpenBurnBar")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(true) // a decision must be recorded, not swiped away
    }

    @ViewBuilder
    private var consentActions: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    Button {
                        decide(granted: true)
                    } label: {
                        Text("Allow analytics")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(MobileTheme.ember)
                    .controlSize(.large)
                    .accessibilityIdentifier("analytics.consent.allow")

                    Button {
                        decide(granted: false)
                    } label: {
                        Text("Not now")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .accessibilityIdentifier("analytics.consent.decline")
                }
            }
        } else {
            VStack(spacing: 12) {
                Button {
                    decide(granted: true)
                } label: {
                    Text("Allow analytics")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MobileTheme.ember)
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
        }
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
                if !consent.hasDecided && !AppStoreScreenshotMode.isEnabled { isPresented = true }
            }
            .sheet(isPresented: $isPresented) {
                AnalyticsConsentPrompt(isPresented: $isPresented)
            }
    }
}
