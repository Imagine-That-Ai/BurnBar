import AppKit
import Combine
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import OSLog

/// App-scene-root overlay for Mercury's interruption-class UI:
///   • `.ringing` → present `IncomingCallSheet` so the user sees the
///     mirror request even when the menu-bar popover is closed.
///   • `.streaming` → render a floating `CallHUD` so the user can end
///     the mirror without re-opening the popover.
///
/// Instantiated as a raw `WindowGroup(id: "mercury.chrome")` sibling
/// in `AgentLensApp.body` so phase changes drive the presentation
/// without re-pumping state through the popover.
///
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
                        subtitle: "Screen mirror request",
                        actionNoun: "mirror request",
                        onAccept: {
                            Task { await router.acceptMirror(request) }
                        },
                        onDecline: {
                            Task { await router.declineMirror(request) }
                        }
                    )
                }
            case .callRinging:
                if let request = router.pendingCall {
                    IncomingCallSheet(
                        pairedDeviceName: request.requesterName,
                        initial: String(request.requesterName.prefix(1)).uppercased(),
                        subtitle: "Mercury call invite",
                        actionNoun: "call invite",
                        onAccept: {
                            Task { await router.acceptCall(request) }
                        },
                        onDecline: {
                            Task { await router.declineCall(request) }
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

/// AppKit presenter for Mercury's interruption UI.
///
/// `WindowGroup(id: "mercury.chrome")` is useful once a SwiftUI window is
/// already open, but phase changes in `MercuryRouter` do not open that window
/// by themselves. This presenter is retained by `OpenBurnBarRuntimeContext`
/// and owns a real `NSPanel`, so an incoming phone mirror request appears even
/// when the menu-bar popover is closed.
@MainActor
final class MercuryIncomingPanelPresenter {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")
    private static func debugTrace(_ message: String) {
        #if DEBUG
        NSLog("OpenBurnBarMercury \(message)")
        #endif
    }

    private let router: MercuryRouter
    private let peerSource: MercuryPeerSource
    private let hudState: CallHUDState
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(
        router: MercuryRouter,
        peerSource: MercuryPeerSource,
        hudState: CallHUDState
    ) {
        self.router = router
        self.peerSource = peerSource
        self.hudState = hudState

        router.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                Task { @MainActor in
                    self?.refresh(for: phase)
                }
            }
            .store(in: &cancellables)

        refresh(for: router.phase)
    }

    private func refresh(for phase: MercuryRouter.Phase) {
        switch phase {
        case .idle, .cooldown:
            Self.log.info("mercury_panel_close phase=\(String(describing: phase), privacy: .public)")
            Self.debugTrace("mercury_panel_close phase=\(String(describing: phase))")
            closePanel()
        case .ringing, .callRinging, .starting, .streaming:
            Self.log.info("mercury_panel_show phase=\(String(describing: phase), privacy: .public)")
            Self.debugTrace("mercury_panel_show phase=\(String(describing: phase))")
            showPanel()
        }
    }

    private func showPanel() {
        let root = MercuryChromeRoot(
            router: router,
            peerSource: peerSource,
            hudState: hudState
        )

        if let panel {
            panel.contentView = NSHostingView(rootView: root)
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Mercury Mirror"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: root)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}
