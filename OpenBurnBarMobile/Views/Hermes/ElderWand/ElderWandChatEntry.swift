import SwiftUI
import OpenBurnBarCore

// MARK: - Elder Wand chat entry point (iOS)
//
// The discreet, Pro-gated entry to the Elder Wand configurator from the Hermes
// chat surface. Gating reuses the shared `gatedFeature(.elderWand, tier:)`
// modifier: when the user's resolved `HostedQuotaSubscriptionStore.cloudTier`
// satisfies `.pro` the tap opens the configurator; otherwise it presents the
// existing Pro paywall (`FeatureUnlockSheet`, which opens `CloudStoreView`).
//
// Two presentations:
//   • `ElderWandChatMenuButton` — a `Button` styled for a chat-options `Menu`
//     section. The `Menu` consumes its own tap, so the gate is handled inside
//     the button's action (read the tier, branch to configurator vs paywall)
//     rather than via the tap-intercepting `gatedFeature` modifier.
//   • `View.elderWandConfiguratorSheet(isPresented:service:)` — the sheet host,
//     attached once on the chat view.

// MARK: - Menu button

/// The Elder Wand row for the chat options `Menu`. Tapping it either opens the
/// configurator (Pro) or the Pro paywall (locked). Because a `Menu` swallows the
/// inner control's gesture, the gate is resolved explicitly here.
struct ElderWandChatMenuButton: View {
    /// Drives the configurator sheet on the host view.
    @Binding var showConfigurator: Bool
    /// Drives the Pro paywall sheet on the host view.
    @Binding var showPaywall: Bool

    @Environment(\.cloudSubscriptionStore) private var cloudStore

    private var isUnlocked: Bool {
        (cloudStore?.cloudTier ?? .none).satisfies(.pro)
    }

    var body: some View {
        Button {
            if isUnlocked {
                showConfigurator = true
            } else {
                Haptics.light()
                showPaywall = true
            }
        } label: {
            Label {
                Text("The Elder Wand")
            } icon: {
                Image(systemName: "wand.and.stars")
            }
            if !isUnlocked {
                Text("Cloud Pro")
            }
        }
        .accessibilityHint(isUnlocked
                           ? "Configure a model-fusion panel and judge"
                           : "Available on Cloud Pro")
    }
}

// MARK: - Sheet host modifier

private struct ElderWandConfiguratorSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let service: HermesService?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ElderWandConfiguratorView(service: service)
        }
    }
}

private struct ElderWandPaywallSheetModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            FeatureUnlockSheet(feature: GatedFeature.gatedFeature(.elderWand))
        }
    }
}

extension View {
    /// Hosts the Elder Wand configurator sheet. Attach once on the chat view
    /// and drive `isPresented` from the menu button (Pro-entitled path).
    func elderWandConfiguratorSheet(
        isPresented: Binding<Bool>,
        service: HermesService?
    ) -> some View {
        modifier(ElderWandConfiguratorSheetModifier(isPresented: isPresented, service: service))
    }

    /// Hosts the Pro paywall sheet for the locked Elder Wand entry path.
    func elderWandPaywallSheet(isPresented: Binding<Bool>) -> some View {
        modifier(ElderWandPaywallSheetModifier(isPresented: isPresented))
    }
}
