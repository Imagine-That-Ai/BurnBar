#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

/// Root overlay that renders the dock tile, the split mirror, and the
/// maximize layer (mirror + Chat Puck). Wired into `RootTabView` so a
/// single instance survives tab switches and the auto-open on
/// `AgentWatchState.sessionId` works regardless of the foreground tab.
///
/// Decisions (locked in spec):
///   • Auto-open on session start.
///   • Maximize is "drive-by-default" — taps/scrolls/typing on the mirror
///     pass through to the Mac with a "You are driving" pill that fades
///     in on first touch and after a 4-second lull.
///   • Chat is always reachable: dock leaves chat visible underneath;
///     split occupies the top half on compact / the left 60% on regular,
///     leaving the rest of the screen free; maximize collapses chat into
///     the draggable `ChatPuck`.
struct AgentLiveStage: View {
    @ObservedObject var singleton: AgentWatchOverlaySingleton
    @ObservedObject var presenter: AgentLiveStagePresenter
    @Bindable var hermesService: HermesService
    var onTapHermesTab: () -> Void

    @ObservedObject private var stateRef: AgentWatchState
    @StateObject private var video = AgentWatchVideoCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var lastInputAt: Date?
    @State private var dragPreview: (start: CGPoint, end: CGPoint)?

    init(
        singleton: AgentWatchOverlaySingleton,
        presenter: AgentLiveStagePresenter,
        hermesService: HermesService,
        onTapHermesTab: @escaping () -> Void
    ) {
        self.singleton = singleton
        self.presenter = presenter
        self.hermesService = hermesService
        self.onTapHermesTab = onTapHermesTab
        _stateRef = ObservedObject(wrappedValue: singleton.state)
    }

    var body: some View {
        ZStack {
            switch presenter.mode {
            case .hidden:
                EmptyView()
            case .dock:
                AgentLiveStageDockTile(
                    state: stateRef,
                    presenter: presenter,
                    horizontalSizeClass: horizontalSizeClass,
                    onApprove: { approveCurrent() },
                    onReject: { rejectCurrent(halt: false) },
                    onRejectHalt: { rejectCurrent(halt: true) },
                    onPanic: { panicHalt() }
                )
                .onTapGesture {
                    onTapHermesTab()
                }
                .transition(.scale(scale: 0.6, anchor: dockScaleAnchor)
                    .combined(with: .opacity))
            case .split:
                splitLayer
                    .transition(.move(edge: splitEdge).combined(with: .opacity))
            case .maximize:
                ZStack {
                    maximizeLayer
                    AgentLiveStageChatPuck(presenter: presenter, hermesService: hermesService)
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion
                   ? .easeInOut(duration: 0.18)
                   : .spring(response: 0.46, dampingFraction: 0.84),
                   value: presenter.mode)
        .onChange(of: presenter.mode) { _, mode in
            if mode == .maximize || mode == .split {
                NotificationCenter.default.post(
                    name: .cloudStoreChromeVisibilityChanged,
                    object: true
                )
            } else {
                NotificationCenter.default.post(
                    name: .cloudStoreChromeVisibilityChanged,
                    object: false
                )
            }
        }
    }

    private var dockScaleAnchor: UnitPoint {
        switch presenter.dockCorner {
        case .topLeading:     return .topLeading
        case .topTrailing:    return .topTrailing
        case .bottomLeading:  return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    private var splitEdge: Edge {
        horizontalSizeClass == .regular ? .leading : .top
    }

    // MARK: - Split layer

    @ViewBuilder
    private var splitLayer: some View {
        GeometryReader { proxy in
            let isRegular = horizontalSizeClass == .regular
            let stageWidth: CGFloat = isRegular ? proxy.size.width * 0.6 : proxy.size.width
            let stageHeight: CGFloat = isRegular ? proxy.size.height : proxy.size.height * 0.55

            mirrorStage(size: CGSize(width: stageWidth, height: stageHeight))
                .frame(width: stageWidth, height: stageHeight)
                .frame(width: proxy.size.width, height: proxy.size.height,
                       alignment: isRegular ? .leading : .top)
        }
        .ignoresSafeArea(.container, edges: horizontalSizeClass == .regular ? .leading : .top)
    }

    // MARK: - Maximize layer

    @ViewBuilder
    private var maximizeLayer: some View {
        GeometryReader { proxy in
            mirrorStage(size: proxy.size, isMaximized: true)
                .ignoresSafeArea()
        }
    }

    // MARK: - Mirror stage

    @ViewBuilder
    private func mirrorStage(size: CGSize, isMaximized: Bool = false) -> some View {
        ZStack(alignment: .top) {
            Color.black

            AgentWatchVideoSurface(coordinator: video)
                .opacity(stateRef.currentFrame == nil ? 0 : 1)

            if stateRef.currentFrame == nil {
                placeholder
            }

            passthroughSurface(size: size)

            cursorOverlay(size: size)

            dragOverlay

            VStack(spacing: 0) {
                topHairline
                Spacer(minLength: 0)
                bottomChrome
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 16)

            RoundedRectangle(cornerRadius: isMaximized ? 0 : 18, style: .continuous)
                .stroke(MobileTheme.mercuryGradient, lineWidth: isMaximized ? 0 : 1)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        HapticBus.sheetOpen()
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.18)
                                                   : .spring(response: 0.4, dampingFraction: 0.84)) {
                            presenter.requestCollapse(sessionActive: stateRef.sessionId != nil)
                        }
                    } label: {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse to dock")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: isMaximized ? 0 : 18, style: .continuous))
        .compositingGroup()
        .onChange(of: stateRef.currentFrame) { _, frame in
            guard let frame else { return }
            Task { await video.ingest(frame: frame) }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Text(stateRef.sessionId == nil
                 ? "Waiting for a Mac session…"
                 : "Live mirror ready")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    @ViewBuilder
    private var topHairline: some View {
        HStack(spacing: 10) {
            AgentLiveStageTelemetryCapsule(
                startedAt: stateRef.sessionStartedAt,
                actionsExecuted: stateRef.actionsExecuted,
                trustMode: stateRef.liveTrustMode
            )
            Spacer(minLength: 0)
            AgentLiveStageDrivingPill(isActive: isDrivingPillVisible)
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 10) {
            if let pending = stateRef.pendingApproval {
                AgentLiveStageApprovalStripe(
                    request: pending,
                    style: .expanded,
                    onApprove: { approveCurrent() },
                    onReject: { rejectCurrent(halt: false) },
                    onRejectHalt: { rejectCurrent(halt: true) }
                )
            }

            HStack(spacing: 8) {
                AgentLiveStageActionTicker(entry: stateRef.actionTimeline.last)
                Button {
                    panicHalt()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.octagon.fill")
                        Text("HALT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(MobileTheme.error)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Panic halt the agent")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
        }
    }

    @ViewBuilder
    private func cursorOverlay(size: CGSize) -> some View {
        if let cursor = stateRef.currentCursor {
            Image(systemName: "cursorarrow")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                .position(
                    x: cursorPosition(cursor, in: size).x,
                    y: cursorPosition(cursor, in: size).y
                )
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var dragOverlay: some View {
        if let dragPreview {
            Canvas { context, _ in
                var path = Path()
                path.move(to: dragPreview.start)
                path.addLine(to: dragPreview.end)
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.72)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5])
                )
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Passthrough surface

    @ViewBuilder
    private func passthroughSurface(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(passthroughGesture(in: size))
            .accessibilityLabel("Live mirror. Tap to drive, drag to scroll.")
    }

    private func passthroughGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if distance >= 10 {
                    dragPreview = (value.startLocation, value.location)
                } else {
                    dragPreview = nil
                }
                lastInputAt = .now
            }
            .onEnded { value in
                defer { dragPreview = nil }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 10 {
                    let point = normalized(value.location, in: size)
                    sendTap(x: point.x, y: point.y)
                } else {
                    let start = normalized(value.startLocation, in: size)
                    let end = normalized(value.location, in: size)
                    sendScrollDrag(x1: start.x, y1: start.y, x2: end.x, y2: end.y)
                }
                lastInputAt = .now
            }
    }

    private var isDrivingPillVisible: Bool {
        guard presenter.isInteractive else { return false }
        guard let lastInputAt else { return true }
        return Date().timeIntervalSince(lastInputAt) < 1.5
    }

    // MARK: - Receiver passthroughs

    private func sendTap(x: Double, y: Double) {
        let receiver = singleton.coordinator.receiver
        Task { try? await receiver?.tap(normalizedX: x, normalizedY: y) }
    }

    private func sendScrollDrag(x1: Double, y1: Double, x2: Double, y2: Double) {
        let receiver = singleton.coordinator.receiver
        Task {
            try? await receiver?.scrollDrag(
                startNormalizedX: x1,
                startNormalizedY: y1,
                endNormalizedX: x2,
                endNormalizedY: y2
            )
        }
    }

    private func approveCurrent() {
        guard let request = stateRef.pendingApproval else { return }
        Task { try? await singleton.coordinator.receiver?.approve(request) }
        HapticBus.primaryAction()
    }

    private func rejectCurrent(halt: Bool) {
        guard let request = stateRef.pendingApproval else { return }
        Task { try? await singleton.coordinator.receiver?.reject(request, halt: halt) }
        HapticBus.destructive()
    }

    private func panicHalt() {
        Task {
            try? await singleton.coordinator.receiver?.panicHalt()
            await singleton.stop()
            await MainActor.run {
                presenter.panicCollapse()
            }
        }
        HapticBus.destructive()
    }

    // MARK: - Geometry helpers

    private func normalized(_ point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        return (Double(x), Double(y))
    }

    private func cursorPosition(_ cursor: MediaFrame.CursorMetadata, in size: CGSize) -> CGPoint {
        let frameWidth: CGFloat = 1920
        let frameHeight: CGFloat = 1080
        let x = min(max(CGFloat(cursor.x) / frameWidth, 0), 1) * size.width
        let y = min(max(CGFloat(cursor.y) / frameHeight, 0), 1) * size.height
        return CGPoint(x: x, y: y)
    }
}
#endif
