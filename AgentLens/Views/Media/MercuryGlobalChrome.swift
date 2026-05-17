import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia

/// App-scene-root overlay for Mercury's interruption-class UI:
///   • `.ringing` → present `IncomingCallSheet` so the user sees the
///     mirror request even when the menu-bar popover is closed.
///   • `.streaming` → render a floating `CallHUD` so the user can end
///     the mirror without re-opening the popover.
///
/// `MercuryGlobalChrome` is attached as a `WindowGroup` sibling in
/// `AgentLensApp` (or as a `.sheet` overlay on the main window). It
/// observes `MercuryRouter` directly so phase changes drive the
/// presentation without re-pumping state through the popover.
@MainActor
struct MercuryGlobalChrome: Scene {
    @ObservedObject var router: MercuryRouter
    @ObservedObject var peerSource: MercuryPeerSource
    @ObservedObject var hudState: CallHUDState

    var body: some Scene {
        // The chrome lives in its own window so it can present over the
        // menu bar popover, Settings, Dashboard, anything. The window is
        // hidden when `phase == .idle || .cooldown`.
        WindowGroup(id: "mercury.chrome") {
            MercuryChromeRoot(
                router: router,
                peerSource: peerSource,
                hudState: hudState
            )
        }
        .windowResizability(.contentSize)
    }
}

/// Inner SwiftUI root that consumes the published router phase and
/// shows either the incoming-call sheet, the call HUD, or nothing.
@MainActor
struct MercuryChromeRoot: View {
    @ObservedObject var router: MercuryRouter
    @ObservedObject var peerSource: MercuryPeerSource
    @ObservedObject var hudState: CallHUDState

    var body: some View {
        ZStack {
            switch router.phase {
            case .idle, .cooldown:
                EmptyView()
            case .ringing:
                if let request = router.pendingRequest {
                    IncomingCallSheet(
                        pairedDeviceName: request.requesterName,
                        initial: String(request.requesterName.prefix(1)).uppercased(),
                        onAccept: {
                            Task { await router.acceptMirror(request) }
                        },
                        onDecline: {
                            Task { await router.declineMirror(request) }
                        }
                    )
                }
            case .starting:
                ProgressView("Starting mirror…")
                    .progressViewStyle(.circular)
                    .padding(48)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.thickMaterial)
                    )
            case .streaming:
                CallHUD(
                    state: hudState,
                    onMuteMic: { hudState.isMicMuted.toggle() },
                    onMuteCamera: { hudState.isCameraMuted.toggle() },
                    onShareScreen: { hudState.isSharingScreen.toggle() },
                    onEnd: { Task { await router.stopMirror() } }
                )
                .frame(width: 260, height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.thickMaterial)
                )
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .padding(20)
    }
}
