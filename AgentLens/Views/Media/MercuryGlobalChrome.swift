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
                .frame(
                    width: hudState.isCollapsed ? 96 : 300,
                    height: hudState.isCollapsed ? 42 : 240
                )
                .background {
                    if !hudState.isCollapsed {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.thickMaterial)
                    }
                }
            }
        }
        .frame(
            minWidth: hudState.isCollapsed ? 112 : 320,
            minHeight: hudState.isCollapsed ? 58 : 240
        )
        .padding(hudState.isCollapsed ? 8 : 20)
        .background(Color.clear)
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
    private var lastStreamingRequestID: String?
    private var currentPhase: MercuryRouter.Phase = .idle

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

        hudState.$isCollapsed
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.resizePanelForCurrentState()
                }
            }
            .store(in: &cancellables)

        refresh(for: router.phase)
    }

    private func refresh(for phase: MercuryRouter.Phase) {
        currentPhase = phase
        switch phase {
        case .idle, .cooldown:
            lastStreamingRequestID = nil
            Self.log.info("mercury_panel_close phase=\(String(describing: phase), privacy: .public)")
            Self.debugTrace("mercury_panel_close phase=\(String(describing: phase))")
            closePanel()
        case .streaming(let requestID, let since):
            if lastStreamingRequestID != requestID {
                hudState.reset(startedAt: since)
                lastStreamingRequestID = requestID
            }
            Self.log.info("mercury_panel_show phase=\(String(describing: phase), privacy: .public)")
            Self.debugTrace("mercury_panel_show phase=\(String(describing: phase))")
            showPanel()
        case .ringing, .callRinging, .starting:
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
            resizePanelForCurrentState()
            panel.orderFrontRegardless()
            if shouldActivateApp {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: desiredPanelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Mercury Mirror"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shouldShowPanelShadow
        panel.contentView = NSHostingView(rootView: root)
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        if shouldActivateApp {
            NSApp.activate(ignoringOtherApps: true)
        }
        self.panel = panel
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private var shouldActivateApp: Bool {
        switch currentPhase {
        case .ringing, .callRinging, .starting:
            return true
        case .idle, .cooldown, .streaming:
            return false
        }
    }

    private var shouldShowPanelShadow: Bool {
        if case .streaming = currentPhase {
            return !hudState.isCollapsed
        }
        return true
    }

    private var desiredPanelSize: NSSize {
        switch currentPhase {
        case .streaming:
            return hudState.isCollapsed ? NSSize(width: 112, height: 58) : NSSize(width: 340, height: 280)
        case .ringing, .callRinging, .starting:
            return NSSize(width: 420, height: 360)
        case .idle, .cooldown:
            return NSSize(width: 0, height: 0)
        }
    }

    private func resizePanelForCurrentState() {
        guard let panel else { return }
        panel.hasShadow = shouldShowPanelShadow
        let currentTopRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let size = desiredPanelSize
        var frame = NSRect(
            x: currentTopRight.x - size.width,
            y: currentTopRight.y - size.height,
            width: size.width,
            height: size.height
        )

        if case .streaming = currentPhase, hudState.isCollapsed {
            frame = frameForCollapsedPill(size: size)
        }

        panel.setFrame(frame, display: true, animate: true)
    }

    private func positionPanel(_ panel: NSPanel) {
        let size = desiredPanelSize
        if case .streaming = currentPhase, hudState.isCollapsed {
            panel.setFrame(frameForCollapsedPill(size: size), display: true)
            return
        }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let frame = NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            panel.setFrame(frame, display: true)
        } else {
            panel.setContentSize(size)
            panel.center()
        }
    }

    private func frameForCollapsedPill(size: NSSize) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 18
        return NSRect(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin,
            width: size.width,
            height: size.height
        )
    }
}
