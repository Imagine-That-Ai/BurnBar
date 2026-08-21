import SwiftUI
import AVFoundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// Hermes chat routing, mobile setup-wizard steps/state/gates, chat preferences, and the setup wizard view.
// Extracted from HermesTabView.swift (god-file decomposition) — same module, verbatim.

//
// Hermes is now a two-level flow:
//   1. `HermesConversationListView` — the tab landing. Lists every Hermes
//      session exposed by the connected host and provides a mercury FAB for
//      starting a new chat.
//   2. `HermesChatView` — the thread UI (welcome block, runtime rail, prompt
//      carousel, streaming bubbles, input bar). Pushed from the list via the
//      enclosing `NavigationStack`.
//
// `HermesChatRoute` is the value-typed destination both surfaces use, so push
// works on iPhone and iPad with system navigation chrome.
enum HermesChatRoute: Hashable {
    /// Resume a previously persisted Hermes session.
    case existing(sessionID: String)
    /// Start a fresh chat (clears `service.messages` and `selectedSessionID`).
    case new
}

struct PresentedHermesChatRoute: Identifiable {
    let route: HermesChatRoute

    var id: String {
        switch route {
        case .new:
            return "new"
        case .existing(let sessionID):
            return "existing:\(sessionID)"
        }
    }
}

enum HermesMobileSetupStep: Int, CaseIterable, Identifiable {
    case keepMacReady
    case chooseHost
    case syncProjects
    case startChat

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .keepMacReady: return "Keep your Mac ready"
        case .chooseHost: return "Pick a Hermes host"
        case .syncProjects: return "Sync projects"
        case .startChat: return "Start chatting"
        }
    }

    var detail: String {
        switch self {
        case .keepMacReady:
            return "OpenBurnBar on macOS should be signed in, running, and set to allow Hermes Remote Relay."
        case .chooseHost:
            return "Use Remote Relay away from home; use a direct LAN/VPN URL only when your device can reach the Mac."
        case .syncProjects:
            return "The Mac shares recent BurnBar projects so Mission Control can offer selectable targets instead of a blank path."
        case .startChat:
            return "Ask about spend, sessions, quota pressure, or anything your connected Hermes runtime can answer."
        }
    }

    var systemImage: String {
        switch self {
        case .keepMacReady: return "macbook.and.iphone"
        case .chooseHost: return "antenna.radiowaves.left.and.right"
        case .syncProjects: return "folder.badge.gearshape"
        case .startChat: return "bubble.left.and.bubble.right.fill"
        }
    }
}

enum HermesMobileSetupWizardState {
    static let completionKey = "com.openburnbar.mobile.hermesSetupWizardCompleted"
}

enum HermesMobileSetupWizardGate {
    static func hasUsableSetup(
        isReachable: Bool,
        selectedConnection: HermesConnectionRecord,
        suggestedRelayConnection: HermesConnectionRecord?
    ) -> Bool {
        if isReachable { return true }
        if selectedConnection.mode == .relayLink && selectedConnection.status == .online {
            return true
        }
        return suggestedRelayConnection != nil
    }

    static func shouldAutoPresent(
        isScreenshotMode: Bool,
        hasCompletedSetup: Bool,
        didAutoPresent: Bool,
        hasUsableSetup: Bool
    ) -> Bool {
        !isScreenshotMode && !hasCompletedSetup && !didAutoPresent && !hasUsableSetup
    }
}

enum HermesMobileChatPreferences {
    /// `@AppStorage` key for the opt-in tokens-per-second footer on assistant
    /// bubbles. Defaults to `false` so existing chat surfaces stay unchanged
    /// until the user explicitly enables it.
    static let showMessageTPSKey = "hermesShowMessageTPS"
    /// `@AppStorage` key for opting into pretext-powered rich text rendering
    /// in assistant bubbles. Defaults to `true` — pretext degrades gracefully
    /// to native `Text` while measurement is in flight, and adds visible
    /// chips for `@mentions` and `` `code spans` `` when ready.
    static let usePretextRenderingKey = "hermesUsePretextRendering"
    /// `@AppStorage` key for opting into the interactive SwarmCanvasView live background
    /// in the Agents (formerly Hermes Square) root scene. Defaults to `false`.
    static let agentsLiveBackgroundEnabledKey = "agentsLiveBackgroundEnabled"
}

enum HermesChatLayout {
    static let composerBottomPadding: CGFloat = 8
}

extension Notification.Name {
    /// Posted by `HermesChatView` when its text input focus changes so that
    /// `RootTabView` can hide the floating `AuroraNavigationTray` while the
    /// user is typing.
    static let hermesKeyboardFocusChanged = Notification.Name("hermesKeyboardFocusChanged")
}

struct HermesMobileSetupWizardView: View {
    @Binding var isPresented: Bool
    @Binding var hasCompletedSetup: Bool
    let onOpenConnections: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    header

                    VStack(spacing: 10) {
                        ForEach(HermesMobileSetupStep.allCases) { step in
                            setupStepRow(step)
                        }
                    }

                    Button {
                        complete()
                    } label: {
                        Text("Start Chatting")
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.aurora(.hermes, fullWidth: true))

                    Button {
                        onOpenConnections()
                    } label: {
                        Label("Open Connections", systemImage: "network")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .frame(maxWidth: .infinity)
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop())
            .navigationTitle("Hermes Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 12) {
                    HermesLiveGlyph(size: 44, isLive: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hermes in 1-2-3-4")
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("One Mac host. One connection. Selectable projects. One chat.")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Text("For iPhone and iPad, Hermes works through BurnBar Cloud Gateway, your Mac Remote Relay, or a direct LAN/VPN Hermes URL.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setupStepRow(_ step: HermesMobileSetupStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(AuroraDesign.Gradients.mercuryFoil)
                    .frame(width: 34, height: 34)
                Text("\(step.number)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: step.systemImage)
                        .font(.system(size: 12, weight: .bold))
                    Text(step.title)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text(step.detail)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MobileTheme.hermesAureate.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.number): \(step.title). \(step.detail)")
    }

    private func complete() {
        hasCompletedSetup = true
        isPresented = false
    }
}
