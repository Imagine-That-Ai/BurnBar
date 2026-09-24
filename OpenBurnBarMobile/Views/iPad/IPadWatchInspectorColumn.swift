import SwiftUI
import OpenBurnBarInboxModels
import OpenBurnBarKernel
import OpenBurnBarQuota
import OpenBurnBarUI
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

/// Persistent iPad Watch column: Agent Watch control plus desktop pixels.
///
/// Two pointers: iPadOS hover/magnetism hit Halt, approvals, and Ask to
/// Mirror. The Mac arrow lives on the HEVC canvas only when a live frame
/// and cursor sample exist. `.hoverEffectDisabled` applies to that pane
/// alone so local chrome does not grow a host cursor.
struct IPadWatchInspectorColumn: View {
    let authUID: String?
    let hermesService: HermesService
    @ObservedObject var singleton: AgentWatchOverlaySingleton
    @ObservedObject var hostReachability: HostReachabilityClient

    @StateObject private var mercuryPeerSource: MercuryPeerSource
    @State private var mercuryBootError: String?
    @State private var isBootingMercury = false
    @State private var showTimeline = false
    @State private var isDriving = false
    @State private var lastDriveInputAt: Date?

    @ObservedObject private var watchState: AgentWatchState

    init(
        authUID: String?,
        hermesService: HermesService,
        singleton: AgentWatchOverlaySingleton,
        hostReachability: HostReachabilityClient = .shared
    ) {
        self.authUID = authUID
        self.hermesService = hermesService
        self.singleton = singleton
        self.hostReachability = hostReachability
        _watchState = ObservedObject(wrappedValue: singleton.state)
        _mercuryPeerSource = StateObject(wrappedValue: MercuryPeerSource(
            relayConnectionProvider: { hermesService.mercuryRelayConnection }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            localChrome
            Rectangle()
                .fill(MobileTheme.Colors.borderSubtle)
                .frame(height: 1)
            mercuryPane
            hostFooter
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onChange(of: watchState.currentFrame != nil) { _, hasFrame in
            if !hasFrame {
                isDriving = false
                lastDriveInputAt = nil
            }
        }
        .task {
            await hermesService.refreshConnections(refreshSelectedConnection: false)
            mercuryPeerSource.start()
        }
        .onDisappear {
            mercuryPeerSource.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.approve)) { _ in
            approvePending()
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.halt)) { _ in
            panicHalt()
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.askToMirror)) { _ in
            Task { await bootMercury() }
        }
        .sheet(isPresented: $showTimeline) {
            AgentActionTimelineSheet(entries: watchState.actionTimeline)
        }
        .accessibilityIdentifier("ipad.watch.inspector")
    }

    // MARK: - Local chrome (iPadOS pointer)

    /// Halt, approvals, and Ask-to-Mirror sit here. Magnetism / highlight
    /// apply. The HEVC pane below disables hover so a Mac cursor is not
    /// painted on this chrome.
    private var localChrome: some View {
        LiquidGlassGroup(spacing: 0) {
            VStack(spacing: 0) {
                haltBar
                controlPane
            }
        }
        .modifier(IPadWatchChromeMagnetism())
    }

    // MARK: - Halt (always visible)

    private var haltBar: some View {
        HStack(spacing: 10) {
            Button(role: .destructive, action: panicHalt) {
                Label("Halt", systemImage: "exclamationmark.octagon.fill")
                    .frame(minWidth: 88, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(MobileTheme.error)
            .padding(12)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityLabel("Panic halt the agent")
            .accessibilityIdentifier(IPadAwayDeskNavigation.haltAccessibilityID)

            Spacer(minLength: 0)

            Text(phaseLabel)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(phaseColor)
                .tracking(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .liquidGlassSurface(in: Rectangle(), fallback: .ultraThinMaterial)
        .contentShape(Rectangle())
    }

    // MARK: - Control (Watch)

    private var controlPane: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Watch")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)

            Text("Approvals and the action log.")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let pending = watchState.pendingApproval {
                AgentLiveStageApprovalStripe(
                    request: pending,
                    style: .expanded,
                    onApprove: approvePending,
                    onReject: { rejectPending(halt: false) },
                    onRejectHalt: { rejectPending(halt: true) }
                )
                .hoverEffect(.highlight)
                .overlay(alignment: .bottomTrailing) {
                    Button("Approve") { approvePending() }
                        .keyboardShortcut(.defaultAction)
                        .opacity(0.001)
                        .accessibilityHidden(true)
                }
            }

            if let latest = watchState.actionTimeline.last {
                Button {
                    showTimeline = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.clipboard")
                            .foregroundStyle(MobileTheme.ember)
                        Text(latest.summary)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated)
                    )
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            } else {
                ContentUnavailableView(
                    "No Computer Use actions",
                    systemImage: "clock",
                    description: Text("When the Mac agent needs a decision, the approval lands here.")
                )
                .frame(maxHeight: 160)
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pixels (Mercury)

    @ViewBuilder
    private var mercuryPane: some View {
        if watchState.currentFrame != nil {
            IPadWatchPixelPane(
                singleton: singleton,
                watchState: watchState,
                isDriving: $isDriving,
                lastDriveInputAt: $lastDriveInputAt,
                panicHalt: panicHalt
            )
        } else if let connectionID = mercuryConnectionID {
            MercuryLiveDetailView(
                connectionID: connectionID,
                peer: mercuryPeerSource.peer,
                bootError: mercuryBootError,
                isBooting: isBootingMercury,
                ensureMercuryLive: { id in
                    await bootMercury(requestedID: id)
                },
                embedStyle: .deskInspector
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(IPadAwayDeskNavigation.mercuryAccessibilityID)
        } else {
            ContentUnavailableView {
                Label("Mac desktop", systemImage: "display")
            } description: {
                Text("Ask to Mirror when you want the picture. Halt stays on the bar.")
            } actions: {
                Button("Ask to Mirror") {
                    Task { await bootMercury() }
                }
                .buttonStyle(.bordered)
                .hoverEffect(.highlight)
                .accessibilityIdentifier(IPadAwayDeskNavigation.askToMirrorAccessibilityID)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(IPadAwayDeskNavigation.mercuryEmptyAccessibilityID)
        }
    }

    private var hostFooter: some View {
        HostReachabilityStatusLine(status: hostReachability.status)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .liquidGlassSurface(in: Rectangle(), fallback: .ultraThinMaterial)
            .accessibilityIdentifier("ipad.watch.hostFooter")
    }

    private var mercuryConnectionID: String? {
        if let peer = mercuryPeerSource.peer, peer.isOnline {
            return peer.connectionID
        }
        return hermesService.mercuryRelayConnection?.id
    }

    private var phaseLabel: String {
        switch singleton.phase {
        case .idle, .stopped: return "STANDBY"
        case .dialing: return "DIALING"
        case .reconnecting: return "RECONNECTING"
        case .live: return "LIVE"
        case .failed: return "ERROR"
        }
    }

    private var phaseColor: Color {
        switch singleton.phase {
        case .live: return MobileTheme.success
        case .dialing, .reconnecting: return MobileTheme.warning
        case .failed: return MobileTheme.error
        case .idle, .stopped: return MobileTheme.Colors.textMuted
        }
    }

    private func approvePending() {
        guard let request = watchState.pendingApproval else { return }
        Task { try? await singleton.coordinator.receiver?.approve(request) }
        HapticBus.primaryAction()
    }

    private func rejectPending(halt: Bool) {
        guard let request = watchState.pendingApproval else { return }
        Task { try? await singleton.coordinator.receiver?.reject(request, halt: halt) }
        HapticBus.destructive()
    }

    private func panicHalt() {
        Task {
            try? await singleton.coordinator.receiver?.panicHalt()
            await singleton.stop()
        }
        HapticBus.destructive()
    }

    private func bootMercury(requestedID: String? = nil) async {
        guard let resolved = requestedID ?? mercuryConnectionID else {
            mercuryBootError = "No online Mac relay found. Open BurnBar on the Mac, enable Remote Relay, then retry."
            return
        }
        guard !isBootingMercury else { return }
        isBootingMercury = true
        mercuryBootError = nil
        defer { isBootingMercury = false }

        mercuryBootError = await hermesService.ensureMercuryMediaControlStream(connectionID: resolved)
    }
}

/// Highlight + magnetism on Halt / approvals. Not applied to the stream.
///
/// `.hoverEffectGroup()` is unavailable on iOS (macOS / visionOS only),
/// even when gated with `#available(iOS 18, *)`. iPadOS chrome uses
/// `.defaultHoverEffect(.highlight)` plus per-control `.hoverEffect`.
private struct IPadWatchChromeMagnetism: ViewModifier {
    func body(content: Content) -> some View {
        content.defaultHoverEffect(.highlight)
    }
}

/// Live HEVC canvas. iPadOS hover is disabled; the Mac arrow draws only
/// when the coordinator has a cursor sample. Drive mode is Space /
/// double-click in, Esc out — Halt stays on the chrome above.
private struct IPadWatchPixelPane: View {
    @ObservedObject var singleton: AgentWatchOverlaySingleton
    @ObservedObject var watchState: AgentWatchState
    @Binding var isDriving: Bool
    @Binding var lastDriveInputAt: Date?
    let panicHalt: () -> Void

    @FocusState private var pixelFocused: Bool
    @State private var dragPreview: (start: CGPoint, end: CGPoint)?

    private var presentation: IPadAwayDeskNavigation.PixelPresentation {
        IPadAwayDeskNavigation.pixelPresentation(
            hasLiveFrame: watchState.currentFrame != nil,
            isLabeledStill: false
        )
    }

    private var drawsHostCursor: Bool {
        IPadAwayDeskNavigation.shouldDrawHostCursor(
            presentation: presentation,
            hasCursorSample: watchState.currentCursor != nil
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                AgentWatchVideoSurface(coordinator: singleton.videoCoordinator)
                if drawsHostCursor, let cursor = watchState.currentCursor {
                    hostCursor(cursor, in: proxy.size)
                }
                if isDriving {
                    passthroughSurface(in: proxy.size)
                    if let dragPreview {
                        driveDragPreview(dragPreview)
                    }
                }
                driveChrome
                ThreeFingerLongPressCapture(onRecognized: panicHalt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hoverEffectDisabled(
            IPadAwayDeskNavigation.disablesHover(.hostPixels, presentation: presentation)
        )
        .focusable()
        .focusEffectDisabled(true)
        .focused($pixelFocused)
        .modifier(IPadWatchEnterDriveTap(isDriving: isDriving) {
            applyDriveChord(.doubleClick)
        })
        .onKeyPress(.space) {
            applyDriveChord(.space)
            return .handled
        }
        .onKeyPress(.escape) {
            applyDriveChord(.escape)
            return .handled
        }
        .accessibilityIdentifier(IPadAwayDeskNavigation.pixelsAccessibilityID)
        .accessibilityLabel(
            isDriving
                ? "Live Mac desktop. Driving. Escape releases."
                : "Live Mac desktop. Double-tap or Space to drive."
        )
    }

    @ViewBuilder
    private var driveChrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                AgentLiveStageDrivingPill(
                    isActive: IPadAwayDeskNavigation.isDrivingPillVisible(
                        isDriving: isDriving,
                        lastInputAt: lastDriveInputAt
                    )
                )
                .accessibilityIdentifier(IPadAwayDeskNavigation.drivePillAccessibilityID)
            }
            if let copy = IPadAwayDeskNavigation.mouseLockedCopy(isDriving: isDriving) {
                HStack {
                    Spacer(minLength: 0)
                    Text(copy)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .accessibilityIdentifier(IPadAwayDeskNavigation.mouseLockedAccessibilityID)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func hostCursor(_ cursor: MediaFrame.CursorMetadata, in size: CGSize) -> some View {
        let point = IPadAwayDeskNavigation.hostCursorPoint(x: cursor.x, y: cursor.y, in: size)
        return Image(systemName: "cursorarrow")
            .resizable()
            .scaledToFit()
            .frame(width: 26, height: 26)
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityIdentifier(IPadAwayDeskNavigation.hostCursorAccessibilityID)
            .accessibilityHidden(true)
    }

    private func passthroughSurface(in size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(passthroughGesture(in: size))
            .accessibilityLabel("Live mirror. Tap to drive, drag to scroll.")
    }

    private func passthroughGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                dragPreview = distance >= 10 ? (value.startLocation, value.location) : nil
                lastDriveInputAt = .now
            }
            .onEnded { value in
                defer { dragPreview = nil }
                lastDriveInputAt = .now
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 10 {
                    let point = AgentPointerMapping.normalized(value.location, in: size)
                    sendTap(x: point.x, y: point.y)
                } else {
                    let start = AgentPointerMapping.normalized(value.startLocation, in: size)
                    let end = AgentPointerMapping.normalized(value.location, in: size)
                    sendScroll(x1: start.x, y1: start.y, x2: end.x, y2: end.y)
                }
            }
    }

    private func driveDragPreview(_ drag: (start: CGPoint, end: CGPoint)) -> some View {
        Path { path in
            path.move(to: drag.start)
            path.addLine(to: drag.end)
        }
        .stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
        .allowsHitTesting(false)
    }

    private func applyDriveChord(_ chord: IPadAwayDeskNavigation.DriveChord) {
        let next = IPadAwayDeskNavigation.driveMode(
            current: isDriving,
            chord: chord,
            hasLiveFrame: watchState.currentFrame != nil
        )
        if next != isDriving {
            isDriving = next
            if next {
                lastDriveInputAt = nil
            }
        }
    }

    private func sendTap(x: Double, y: Double) {
        let receiver = singleton.coordinator.receiver
        Task { try? await receiver?.tap(normalizedX: x, normalizedY: y) }
    }

    private func sendScroll(x1: Double, y1: Double, x2: Double, y2: Double) {
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

}

private struct IPadWatchEnterDriveTap: ViewModifier {
    let isDriving: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isDriving {
            content
        } else {
            content.onTapGesture(count: 2, perform: action)
        }
    }
}
