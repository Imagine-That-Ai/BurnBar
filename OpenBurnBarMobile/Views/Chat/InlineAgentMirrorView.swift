#if canImport(SwiftUI) && canImport(UIKit)
import AVKit
import AVFoundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import UIKit

/// Inline agent mirror that replaces the chat message list when the user
/// switches to CLI view. On appear, the controller asks the Mac to start
/// screen sharing via `MediaControlStreamCoordinator`, then renders the
/// incoming frames with Smart Zoom auto-framing the terminal / active
/// workspace. Keeps the chat input bar visible so the user can type while
/// watching the agent work.
struct InlineAgentMirrorView: View {
    @ObservedObject var singleton: AgentWatchOverlaySingleton
    let hermesService: HermesService
    @StateObject private var controller = InlineAgentMirrorController()

    @State private var viewport = ScreenShareViewportState()
    @AppStorage("mercurySmartZoomMode") private var smartZoomModeRaw: String = SmartZoomMode.smart.rawValue
    @State private var smartZoomManualOverrideUntil: Date?
    @State private var smartZoomAutoFollowing: Bool = false
    @State private var lastLayoutSize: CGSize = .zero

    init(singleton: AgentWatchOverlaySingleton,
         hermesService: HermesService = HermesService.shared) {
        self.singleton = singleton
        self.hermesService = hermesService
    }

    private var smartZoomMode: SmartZoomMode {
        get { SmartZoomMode(rawValue: smartZoomModeRaw) ?? .smart }
        nonmutating set { smartZoomModeRaw = newValue.rawValue }
    }

    /// When a Computer Use session is live, the singleton's pipeline is the
    /// authoritative source. Otherwise we fall back to the inline
    /// controller's mirror-request pipeline.
    private var usingSingleton: Bool {
        singleton.state.sessionId != nil
    }

    var body: some View {
        ZStack {
            Color.black
                .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))

            GeometryReader { proxy in
                ZStack {
                    if usingSingleton {
                        AgentWatchVideoSurface(coordinator: singleton.videoCoordinator)
                            .opacity(singleton.state.currentFrame == nil ? 0 : 1)
                            .scaleEffect(viewport.scale, anchor: .center)
                            .offset(viewport.offset)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } else {
                        InlineMirrorDisplayHost(coordinator: controller.viewer)
                            .opacity(controller.phase.canShowFrames ? 1 : 0)
                            .scaleEffect(viewport.scale, anchor: .center)
                            .offset(viewport.offset)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }

                    if !isShowingFrames {
                        placeholder
                    }

                    cursorOverlay(size: proxy.size)
                }
                .onAppear { lastLayoutSize = proxy.size }
                .onChange(of: proxy.size) { _, newSize in lastLayoutSize = newSize }
            }
            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))

            VStack {
                HStack {
                    smartZoomChip
                    Spacer()
                    statusChip
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                Spacer()
                if shouldShowFooter {
                    footer
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .strokeBorder(MobileTheme.mercuryGradient, lineWidth: 0.75)
        )
        .task {
            controller.start(hermesService: hermesService)
        }
        .onDisappear {
            controller.stop()
        }
        .onChange(of: singleton.state.currentFocus) { _, context in
            guard let context, smartZoomMode != .off, usingSingleton else { return }
            applySmartZoom(context: context)
        }
        .onChange(of: controller.latestFocusContext) { _, context in
            guard let context, smartZoomMode != .off, !usingSingleton else { return }
            applySmartZoomContext(context)
        }
        .onChange(of: singleton.state.currentFrame) { _, frame in
            guard let frame, usingSingleton else { return }
            Task { await singleton.videoCoordinator.ingest(frame: frame) }
            if let context = singleton.state.currentFocus, smartZoomMode != .off {
                applySmartZoom(context: context)
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    beginManualZoomOverride()
                    viewport.scale = max(1.0, min(value, 4.0))
                }
        )
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    beginManualZoomOverride()
                    viewport.offset = CGSize(
                        width: viewport.offset.width + value.translation.width * 0.5,
                        height: viewport.offset.height + value.translation.height * 0.5
                    )
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(MobileTheme.Animation.snappy) {
                viewport.reset()
                smartZoomManualOverrideUntil = nil
                smartZoomAutoFollowing = false
            }
        }
    }

    private var isShowingFrames: Bool {
        if usingSingleton {
            return singleton.state.currentFrame != nil
        }
        return controller.phase.isLive
    }

    private var shouldShowFooter: Bool {
        switch controller.phase {
        case .live, .idle, .error, .noRelay: return false
        default: return !usingSingleton
        }
    }

    // MARK: - Placeholders

    @ViewBuilder
    private var placeholder: some View {
        switch placeholderState {
        case .loading(let message):
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white.opacity(0.7))
                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .terminal(let message):
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message, let kind):
            errorPlaceholder(message: message, kind: kind)
        }
    }

    @ViewBuilder
    private func errorPlaceholder(message: String, kind: ErrorKind) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.warning)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind.headline)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(kind.explainer)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(message)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("TRY THIS")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.5))
                    ForEach(Array(kind.suggestions.enumerated()), id: \.offset) { index, hint in
                        HStack(alignment: .top, spacing: 10) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(MobileTheme.hermesAureate)
                                .frame(width: 22, alignment: .leading)
                            Text(hint)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )

                HStack(spacing: 8) {
                    Button {
                        controller.start(hermesService: hermesService)
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MobileTheme.hermesAureate)
                    .controlSize(.regular)

                    Button {
                        NotificationCenter.default.post(name: .init("ShowSettings"), object: nil)
                    } label: {
                        Label("Settings", systemImage: "gear")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 36)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    private enum ErrorKind {
        case noRelay
        case noFrames
        case generic

        var headline: String {
            switch self {
            case .noRelay: return "No Mac available"
            case .noFrames: return "Mac accepted but isn't sending frames"
            case .generic: return "Mirror error"
            }
        }

        var explainer: String {
            switch self {
            case .noRelay:
                return "CLI view mirrors your Mac's entire desktop \u{2014} not a separate terminal window. We need a paired Mac with Hermes Remote Relay turned on."
            case .noFrames:
                return "CLI view mirrors your Mac's whole desktop \u{2014} no terminal will pop open. Your Mac acknowledged the request but the screen-share pipeline hasn't produced a single frame yet."
            case .generic:
                return "The handshake didn't complete cleanly."
            }
        }

        var suggestions: [String] {
            switch self {
            case .noRelay:
                return [
                    "Open BurnBar on your Mac.",
                    "Sign in with the same OpenBurnBar account.",
                    "Enable Hermes Remote Relay in BurnBar's Hermes settings.",
                ]
            case .noFrames:
                return [
                    "Confirm BurnBar is still running on your Mac (menu bar icon visible).",
                    "Open System Settings \u{2192} Privacy & Security \u{2192} Screen Recording and make sure BurnBar is on. Toggle it off and back on if you just granted it.",
                    "Wake the Mac if it dozed. Locked / sleeping Macs produce no frames.",
                    "Quit and relaunch BurnBar on the Mac, then tap Try Again here.",
                ]
            case .generic:
                return [
                    "Tap Try Again to retry the handshake.",
                    "If it keeps failing, open Settings to confirm your Mac relay is online.",
                    "Switch back to Smart view (top toggle) to keep chatting in the meantime.",
                ]
            }
        }
    }

    private enum PlaceholderState {
        case loading(String)
        case terminal(String)
        case error(String, ErrorKind)
    }

    private var placeholderState: PlaceholderState {
        if usingSingleton {
            return .terminal("Computer Use session live\u{2026}")
        }
        switch controller.phase {
        case .idle:
            return .terminal("Waiting for Mac\u{2026}")
        case .connectingStream:
            return .loading("Connecting to Mac\u{2026}")
        case .askingMirror:
            return .loading("Asking Mac to share screen\u{2026}")
        case .waitingForApproval:
            return .loading("Tap Accept on your Mac to start\u{2026}")
        case .waitingForFrames:
            return .loading("Mac accepted \u{2014} loading first frame\u{2026}")
        case .live:
            return .terminal("Loading first frame\u{2026}")
        case .noRelay(let message):
            return .error(message, .noRelay)
        case .error(let message):
            let lower = message.lowercased()
            let kind: ErrorKind
            if lower.contains("no frames") || lower.contains("frame") || lower.contains("stall") {
                kind = .noFrames
            } else if lower.contains("no response") || lower.contains("mirror stream") || lower.contains("declined") {
                kind = .noRelay
            } else {
                kind = .generic
            }
            return .error(message, kind)
        }
    }

    // MARK: - Footer (compact diagnostic / retry)

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            switch controller.phase {
            case .connectingStream, .askingMirror, .waitingForApproval, .waitingForFrames:
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.white.opacity(0.7))
                Text(controller.phase.statusText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            case .noRelay(let message), .error(let message):
                Text(message)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }

    // MARK: - Cursor overlay (only valid for Computer Use)

    @ViewBuilder
    private func cursorOverlay(size: CGSize) -> some View {
        if usingSingleton, let cursor = singleton.state.currentCursor {
            let frameWidth: CGFloat = 1920
            let frameHeight: CGFloat = 1080
            let x = min(max(CGFloat(cursor.x) / frameWidth, 0), 1) * size.width
            let y = min(max(CGFloat(cursor.y) / frameHeight, 0), 1) * size.height
            Image(systemName: "cursorarrow")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                .position(x: x, y: y)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Chips

    @ViewBuilder
    private var smartZoomChip: some View {
        Menu {
            ForEach(SmartZoomMode.allCases) { mode in
                Button {
                    smartZoomMode = mode
                    smartZoomManualOverrideUntil = nil
                    if mode == .off {
                        withAnimation(MobileTheme.Animation.snappy) { viewport.reset() }
                        smartZoomAutoFollowing = false
                    }
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: smartZoomMode.systemImage)
                    .font(.system(size: 9, weight: .bold))
                Text(smartZoomMode.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(smartZoomAutoFollowing
                          ? MobileTheme.hermesAureate.opacity(0.85)
                          : Color.black.opacity(0.55))
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusChip: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 5, height: 5)
            Text(statusLabel)
                .font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }

    private var statusDotColor: Color {
        if usingSingleton { return MobileTheme.Colors.success }
        switch controller.phase {
        case .live: return MobileTheme.Colors.success
        case .waitingForFrames: return MobileTheme.Colors.success
        case .connectingStream, .askingMirror, .waitingForApproval: return MobileTheme.Colors.warning
        case .error, .noRelay: return MobileTheme.Colors.error
        case .idle: return MobileTheme.Colors.textMuted
        }
    }

    private var statusLabel: String {
        if usingSingleton { return "CU LIVE" }
        switch controller.phase {
        case .live: return "LIVE"
        case .waitingForFrames: return "LOADING"
        case .connectingStream: return "CONNECTING"
        case .askingMirror: return "ASKING"
        case .waitingForApproval: return "APPROVE ON MAC"
        case .error: return "ERROR"
        case .noRelay: return "NO RELAY"
        case .idle: return "OFFLINE"
        }
    }

    // MARK: - Smart Zoom logic

    private func applySmartZoom(context: HermesRealtimeRelayFocusContext) {
        guard let zoomContext = ScreenShareSmartZoomContext.from(context) else { return }
        applySmartZoomContext(zoomContext)
    }

    private func applySmartZoomContext(_ zoomContext: ScreenShareSmartZoomContext) {
        guard lastLayoutSize.width > 0, lastLayoutSize.height > 0 else { return }
        let contentRect = CGRect(origin: .zero, size: lastLayoutSize)
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: lastLayoutSize,
            contentRect: contentRect,
            currentState: viewport,
            context: zoomContext,
            mode: smartZoomMode,
            selectedDisplayId: nil,
            manualOverrideUntil: smartZoomManualOverrideUntil,
            now: Date()
        )
        if decision.isAutoFollowing {
            withAnimation(MobileTheme.Animation.snappy) {
                viewport.scale = decision.scale
                viewport.offset = decision.offset
            }
            if !smartZoomAutoFollowing { smartZoomAutoFollowing = true }
        }
    }

    private func beginManualZoomOverride() {
        smartZoomManualOverrideUntil = Date().addingTimeInterval(5)
        smartZoomAutoFollowing = false
    }
}

/// Hosts the `ScreenShareViewerCoordinator`'s display layer inside SwiftUI.
/// Duplicates the private `DisplayLayerHost` from `ScreenShareViewerView`
/// because that one isn't accessible cross-file.
private struct InlineMirrorDisplayHost: UIViewRepresentable {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator

    func makeUIView(context: Context) -> InlineMirrorDisplayLayerView {
        let view = InlineMirrorDisplayLayerView()
        view.attach(layer: coordinator.displayLayer)
        return view
    }

    func updateUIView(_ uiView: InlineMirrorDisplayLayerView, context: Context) {}
}

private final class InlineMirrorDisplayLayerView: UIView {
    private weak var hostedLayer: AVSampleBufferDisplayLayer?

    func attach(layer: AVSampleBufferDisplayLayer) {
        if let existing = hostedLayer {
            existing.removeFromSuperlayer()
        }
        layer.frame = bounds
        layer.videoGravity = .resizeAspect
        self.layer.addSublayer(layer)
        hostedLayer = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedLayer?.frame = bounds
    }
}
#endif
