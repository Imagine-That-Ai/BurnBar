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
    /// Runtime whose CLI the Mac launches interactively and pins the mirror to.
    let runtime: String
    @StateObject private var controller = InlineAgentMirrorController()

    @State private var viewport = ScreenShareViewportState()
    @AppStorage("mercurySmartZoomMode") private var smartZoomModeRaw: String = SmartZoomMode.smart.rawValue
    @State private var smartZoomManualOverrideUntil: Date?
    @State private var smartZoomAutoFollowing: Bool = false
    @State private var lastLayoutSize: CGSize = .zero
    /// Tracks whether the initial auto-zoom has been applied for this
    /// mirror session so we only zoom once on first frame.
    @State private var didApplyInitialZoom: Bool = false
    /// Drives the hidden keyboard capture that types into the live TUI.
    @State private var isTyping = false
    /// Keeps the special-key controls collapsed until the user asks for them.
    @State private var terminalControlsExpanded = false
    @State private var singletonDisplayAspectRatio: CGFloat?

    private static let fallbackTerminalAspectRatio: CGFloat = 16.0 / 9.0

    init(singleton: AgentWatchOverlaySingleton,
         hermesService: HermesService = HermesService.shared,
         runtime: String = AssistantRuntimeID.hermes.rawValue) {
        self.singleton = singleton
        self.hermesService = hermesService
        self.runtime = runtime
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

    private var activeDisplayAspectRatio: CGFloat? {
        if usingSingleton {
            return singletonDisplayAspectRatio
        }
        return controller.viewer.displayAspectRatio
    }

    private var liveTerminalAspectRatio: CGFloat? {
        guard isShowingFrames else { return nil }
        return activeDisplayAspectRatio ?? Self.fallbackTerminalAspectRatio
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
                if cliMissionBannerText != nil {
                    cliMissionBanner
                        .padding(.horizontal, 8)
                        .padding(.bottom, shouldShowFooter ? 4 : 8)
                }
                if shouldShowFooter {
                    footer
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
                if controller.phase.isLive && controller.controlInputReady {
                    terminalControlBar
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .strokeBorder(MobileTheme.mercuryGradient, lineWidth: 0.75)
        )
        .aspectRatio(liveTerminalAspectRatio, contentMode: .fit)
        .background(keyboardCaptureLayer)
        .task {
            if smartZoomMode == .off {
                smartZoomMode = .smart
            }
            controller.start(hermesService: hermesService, runtime: runtime)
        }
        .onDisappear {
            controller.stop()
            didApplyInitialZoom = false
            terminalControlsExpanded = false
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
        .onReceive(singleton.videoCoordinator.$displayAspectRatio) { aspectRatio in
            singletonDisplayAspectRatio = aspectRatio
            guard usingSingleton,
                  aspectRatio != nil,
                  !didApplyInitialZoom else { return }
            applyInitialZoomToFillWidth()
        }
        .onChange(of: controller.viewer.displayAspectRatio) { _, newAspect in
            guard newAspect != nil, !didApplyInitialZoom else { return }
            applyInitialZoomToFillWidth()
        }
        .onChange(of: controller.phase) { oldPhase, newPhase in
            // Reset the initial-zoom flag when the session ends or errors
            // so that a retry correctly re-zooms on the next first frame.
            if oldPhase.canShowFrames, !newPhase.canShowFrames {
                didApplyInitialZoom = false
            }
            if case .live = newPhase, !didApplyInitialZoom {
                applyInitialZoomToFillWidth()
            }
        }
        .onChange(of: controller.controlInputReady) { _, ready in
            guard ready, controller.phase.isLive else { return }
            isTyping = true
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
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    guard controller.controlInputReady else { return }
                    isTyping = true
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

    // MARK: - Live TUI keyboard

    /// Hidden 1×1 keyboard capture; each character/key is forwarded to the Mac
    /// terminal via the controller's phone-control sender.
    @ViewBuilder
    private var keyboardCaptureLayer: some View {
        #if canImport(UIKit)
        if controller.controlInputReady {
            RemoteKeyboardCaptureView(
                isActive: $isTyping,
                onText: { controller.sendText($0) },
                onKey: { controller.sendKey($0) },
                keepsFocus: true
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #else
        EmptyView()
        #endif
    }

    /// Floating command button over the live terminal. It stays collapsed by
    /// default so it does not cover the terminal prompt; tapping it opens the
    /// special keys upward.
    private var terminalControlBar: some View {
        // The expanded special-keys panel (.liquidGlassSurface) and the
        // toggle chip (.liquidGlassInteractive) are co-visible siblings, so on
        // iOS 26 they must share one GlassEffectContainer — glass cannot
        // sample other glass. LiquidGlassGroup passes content through unchanged
        // pre-26.
        LiquidGlassGroup(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                if terminalControlsExpanded {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            terminalKeyButton(systemImage: isTyping ? "keyboard.chevron.compact.down" : "keyboard") {
                                isTyping.toggle()
                            }
                            terminalKeyButton(label: "esc") { controller.sendKey("escape") }
                            terminalKeyButton(label: "tab") { controller.sendKey("tab") }
                            terminalKeyButton(label: "⌃C") { controller.sendKey("c", modifiers: ["control"]) }
                        }
                        HStack(spacing: 6) {
                            terminalKeyButton(systemImage: "arrow.up") { controller.sendKey("up") }
                            terminalKeyButton(systemImage: "arrow.down") { controller.sendKey("down") }
                            terminalKeyButton(systemImage: "arrow.left") { controller.sendKey("left") }
                            terminalKeyButton(systemImage: "arrow.right") { controller.sendKey("right") }
                            terminalKeyButton(systemImage: "return") { controller.sendKey("return") }
                        }
                    }
                    .padding(8)
                    .liquidGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.5)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Button {
                    withAnimation(MobileTheme.Animation.snappy) {
                        terminalControlsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: terminalControlsExpanded ? "chevron.down" : "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .frame(width: 44, height: 36)
                        .liquidGlassInteractive(in: Capsule())
                        .overlay(Capsule().strokeBorder(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(terminalControlsExpanded ? "Hide Terminal Controls" : "Show Terminal Controls")
            }
        }
    }

    private func terminalKeyButton(
        systemImage: String? = nil,
        label: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(label ?? "")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .frame(minWidth: 32, minHeight: 28)
            .background(MobileTheme.Colors.surfaceElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
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
                        controller.start(hermesService: hermesService, runtime: runtime)
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
                return "CLI view opens Hermes in Terminal on your paired Mac and mirrors that focused workspace here. We need a Mac with Hermes Remote Relay turned on."
            case .noFrames:
                return "The Mac accepted the mirror request, but the screen-share pipeline has not produced a frame yet. Hermes Terminal may be opening off-screen or Screen Recording may still be blocked."
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
                    "Enable Hermes Remote Relay in BurnBar's Hermes settings."
                ]
            case .noFrames:
                return [
                    "Confirm BurnBar is still running on your Mac (menu bar icon visible).",
                    "Open System Settings \u{2192} Privacy & Security \u{2192} Screen Recording and make sure BurnBar is on. Toggle it off and back on if you just granted it.",
                    "Wake the Mac if it dozed. Locked / sleeping Macs produce no frames.",
                    "Quit and relaunch BurnBar on the Mac, then tap Try Again here."
                ]
            case .generic:
                return [
                    "Tap Try Again to retry the handshake.",
                    "If it keeps failing, open Settings to confirm your Mac relay is online.",
                    "Switch back to Smart view (top toggle) to keep chatting in the meantime."
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

    @ViewBuilder
    private var cliMissionBanner: some View {
        if let text = cliMissionBannerText {
            missionBanner(text: text, isError: cliMissionBannerIsError)
        }
    }

    private var cliMissionBannerText: String? {
        if let error = hermesService.visibleCLIErrorText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        guard hermesService.isStreaming,
              let status = hermesService.visibleCLIStatusText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else { return nil }
        return status
    }

    private var cliMissionBannerIsError: Bool {
        let error = hermesService.visibleCLIErrorText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return error?.isEmpty == false
    }

    private func missionBanner(text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "terminal.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isError ? MobileTheme.Colors.warning : MobileTheme.hermesAureate)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(Color.black.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke((isError ? MobileTheme.Colors.warning : MobileTheme.hermesAureate).opacity(0.35), lineWidth: 0.6)
        )
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

    /// Computes the actual letterboxed rect where the video renders within
    /// the view, accounting for the Mac screen's aspect ratio. Without this,
    /// the zoom reducer thinks the video fills the entire view — causing
    /// misaligned framing on portrait phones.
    private func renderedContentRect(in size: CGSize) -> CGRect {
        guard let aspectRatio = activeDisplayAspectRatio,
              aspectRatio.isFinite,
              aspectRatio > 0,
              size.width > 0,
              size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }

        let containerAspect = size.width / size.height
        if containerAspect > aspectRatio {
            // Pillarboxed (unlikely on phone in portrait, but handles landscape)
            let width = size.height * aspectRatio
            return CGRect(
                x: (size.width - width) / 2,
                y: 0,
                width: width,
                height: size.height
            )
        }

        // Letterboxed: video is full-width, shorter than the view.
        let height = size.width / aspectRatio
        return CGRect(
            x: 0,
            y: (size.height - height) / 2,
            width: size.width,
            height: height
        )
    }

    /// On first frame, add a small readability nudge while preserving almost
    /// the full Terminal width. Height-fill zoom is too aggressive for
    /// landscape TUI windows inside a portrait phone viewport.
    private func applyInitialZoomToFillWidth() {
        guard lastLayoutSize.width > 0, lastLayoutSize.height > 0 else { return }
        let contentRect = renderedContentRect(in: lastLayoutSize)
        guard contentRect.width > 0, contentRect.height > 0 else { return }

        didApplyInitialZoom = true

        // If a focus context already exists, let the normal smart zoom
        // path handle it — it will produce a more precise framing.
        if let ctx = controller.latestFocusContext, smartZoomMode != .off {
            applySmartZoomContext(ctx)
            return
        }

        let scale = Self.terminalInitialZoomScale(
            viewportSize: lastLayoutSize,
            contentRect: contentRect
        )
        withAnimation(MobileTheme.Animation.snappy) {
            viewport.scale = scale
            viewport.offset = ScreenShareViewportState.clamp(
                offset: .zero,
                scale: scale,
                in: lastLayoutSize
            )
        }
        smartZoomAutoFollowing = false
    }

    private func applySmartZoom(context: HermesRealtimeRelayFocusContext) {
        guard let zoomContext = ScreenShareSmartZoomContext.from(context) else { return }
        applySmartZoomContext(zoomContext)
    }

    static func terminalInitialZoomScale(viewportSize: CGSize, contentRect: CGRect) -> CGFloat {
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              contentRect.width > 0,
              contentRect.height > 0 else {
            return ScreenShareViewportState.minimumScale
        }

        let heightFillScale = viewportSize.height / max(contentRect.height, 1)
        let readabilityLift = max(0, heightFillScale - 1) * 0.10
        let softenedScale = min(1.0 + readabilityLift, 1.18)
        return ScreenShareViewportState.clampScale(softenedScale)
    }

    private func applySmartZoomContext(_ zoomContext: ScreenShareSmartZoomContext) {
        guard lastLayoutSize.width > 0, lastLayoutSize.height > 0 else { return }
        let contentRect = renderedContentRect(in: lastLayoutSize)
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
            let targetScale = min(
                decision.scale,
                Self.terminalInitialZoomScale(viewportSize: lastLayoutSize, contentRect: contentRect)
            )
            let targetOffset = ScreenShareViewportState.clamp(
                offset: decision.offset,
                scale: targetScale,
                in: lastLayoutSize
            )
            withAnimation(MobileTheme.Animation.snappy) {
                viewport.scale = targetScale
                viewport.offset = targetOffset
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
