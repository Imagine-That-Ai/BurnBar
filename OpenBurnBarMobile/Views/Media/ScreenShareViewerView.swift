import SwiftUI
@preconcurrency import AVKit
@preconcurrency import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore

enum ScreenSharePhoneControlStatus: Equatable {
    case unavailable(String)
    case connecting
    case live
    case liveNotice(String)

    var isLive: Bool {
        switch self {
        case .live, .liveNotice: return true
        case .connecting, .unavailable: return false
        }
    }

    var label: String {
        switch self {
        case .live, .liveNotice: return "Control"
        case .connecting: return "Connecting"
        case .unavailable: return "Read only"
        }
    }

    var detail: String? {
        switch self {
        case .live:
            return nil
        case .liveNotice(let message):
            return message
        case .connecting:
            return "Preparing Mac control"
        case .unavailable(let reason):
            return reason
        }
    }
}

/// iOS Mercury screen-share viewer. Full-bleed video, optional stats
/// overlay (three-finger tap toggles). Wraps an
/// `AVSampleBufferDisplayLayer` via `UIViewRepresentable` so decoded
/// frames bypass UIKit's drawing path.
@MainActor
struct ScreenShareViewerView: View {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator
    let resetToken: String?
    let controlStatus: ScreenSharePhoneControlStatus
    let controlInputEnabled: Bool
    let controlRoundTripMillis: Int?
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let streamPhase: MediaControlStreamCoordinator.Phase
    let reconnectAttemptStartedAt: Date?
    let lastFailureReason: String?
    let lastLiveAt: Date?
    let remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
    let savedRemoteUnlockCredentialAvailable: Bool
    let onForceReconnect: () -> Void
    let onRetryRequest: () -> Void
    let sendTapIntent: (Double, Double, Int) -> Void
    let sendScrollIntent: (Double, Double, Double, Double, String?) -> Void
    let sendPointerMoveIntent: (Double, Double) -> Void
    let sendPointerClickIntent: (Int) -> Void
    let sendTextIntent: (String) -> Void
    let sendShortcutIntent: (String, [String]) -> Void
    let sendAgentContextTargetIntent: (Double, Double, String, String, String?) -> Void
    let pasteClipboardToMac: () -> Void
    let grabClipboardFromMac: () -> Void
    let sendRemoteUnlockCredential: (String) -> Void
    let saveRemoteUnlockCredential: (String) -> Void
    let sendSavedRemoteUnlockCredential: () -> Void
    let deleteSavedRemoteUnlockCredential: () -> Void
    let onSelectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let onClose: () -> Void
    let usePremiumSOTAUX: Bool
    @State private var statsVisible: Bool = false
    @State private var viewport = ScreenShareViewportState()
    @AppStorage("mercurySmartZoomMode") private var smartZoomModeRaw: String = SmartZoomMode.smart.rawValue
    @AppStorage("mercury.smartTextDoubleTapLearned") private var smartTextDoubleTapLearned = false
    @State private var smartZoomManualOverrideUntil: Date?
    @State private var smartZoomAutoFollowing: Bool = false
    @State private var smartTextCoachVisible: Bool = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var lastSmartTextNormalizedPoint: CGPoint?
    @State private var lastLayoutSize: CGSize?
    @State private var interactionMode: ScreenShareInteractionMode = .view
    @State private var isTyping = false
    @State private var coPilotTarget: (normalizedX: Double, normalizedY: Double, viewPoint: CGPoint)? = nil
    @State private var coPilotInstruction: String = ""
    @State private var coPilotRuntime: String = "hermes"
    @State private var panelOffset = CGSize(width: -18, height: 18)
    @State private var panelDragBase = CGSize(width: -18, height: 18)
    @State private var edgeScrollEnabled = true
    @State private var hardwareScrollEnabled = false
    @State private var trackpadActive = false
    @State private var panelCollapsed = false
    @State private var controlPanTranslation: CGSize = .zero
    @State private var tapFeedbackPoint: CGPoint?
    @State private var lastControlClickPoint: CGPoint?
    @State private var lastControlClickAt: Date?
    @State private var controlPressStartedAt: Date?
    @State private var pendingControlRightClickTask: Task<Void, Never>?
    @State private var controlRightClickSentForCurrentPress = false
    @State private var cursorPoint: CGPoint?
    @State private var cursorSize: CGFloat = 24
    @State private var cursorStyle: MirrorCursorStyle = .hidden
    @Binding var remoteUnlockPasswordDraft: String
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var controlMagnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var typingFocusTask: Task<Void, Never>?

    private var smartZoomMode: SmartZoomMode {
        get { SmartZoomMode(rawValue: smartZoomModeRaw) ?? .smart }
        nonmutating set { smartZoomModeRaw = newValue.rawValue }
    }

    init(
        coordinator: ScreenShareViewerCoordinator,
        resetToken: String?,
        controlStatus: ScreenSharePhoneControlStatus = .unavailable("Phone control is not connected."),
        controlInputEnabled: Bool? = nil,
        controlRoundTripMillis: Int? = nil,
        displays: [HermesRealtimeRelayDisplayDescriptor] = [],
        selectedDisplayId: String? = nil,
        streamPhase: MediaControlStreamCoordinator.Phase = .live,
        reconnectAttemptStartedAt: Date? = nil,
        lastFailureReason: String? = nil,
        lastLiveAt: Date? = nil,
        remoteUnlockState: HermesRealtimeRelayRemoteUnlockState? = nil,
        savedRemoteUnlockCredentialAvailable: Bool = false,
        remoteUnlockPasswordDraft: Binding<String> = .constant(""),
        usePremiumSOTAUX: Bool = false,
        onForceReconnect: @escaping () -> Void = {},
        onRetryRequest: @escaping () -> Void = {},
        sendTapIntent: @escaping (Double, Double, Int) -> Void = { _, _, _ in },
        sendScrollIntent: @escaping (Double, Double, Double, Double, String?) -> Void = { _, _, _, _, _ in },
        sendPointerMoveIntent: @escaping (Double, Double) -> Void = { _, _ in },
        sendPointerClickIntent: @escaping (Int) -> Void = { _ in },
        sendTextIntent: @escaping (String) -> Void = { _ in },
        sendShortcutIntent: @escaping (String, [String]) -> Void = { _, _ in },
        sendAgentContextTargetIntent: @escaping (Double, Double, String, String, String?) -> Void = { _, _, _, _, _ in },
        pasteClipboardToMac: @escaping () -> Void = {},
        grabClipboardFromMac: @escaping () -> Void = {},
        sendRemoteUnlockCredential: @escaping (String) -> Void = { _ in },
        saveRemoteUnlockCredential: @escaping (String) -> Void = { _ in },
        sendSavedRemoteUnlockCredential: @escaping () -> Void = {},
        deleteSavedRemoteUnlockCredential: @escaping () -> Void = {},
        onSelectDisplay: @escaping (String) -> Void = { _ in },
        onTrustControlDevice: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.resetToken = resetToken
        self.controlStatus = controlStatus
        self.controlInputEnabled = controlInputEnabled ?? controlStatus.isLive
        self.controlRoundTripMillis = controlRoundTripMillis
        self.displays = displays
        self.selectedDisplayId = selectedDisplayId
        self.streamPhase = streamPhase
        self.reconnectAttemptStartedAt = reconnectAttemptStartedAt
        self.lastFailureReason = lastFailureReason
        self.lastLiveAt = lastLiveAt
        self.remoteUnlockState = remoteUnlockState
        self.savedRemoteUnlockCredentialAvailable = savedRemoteUnlockCredentialAvailable
        self._remoteUnlockPasswordDraft = remoteUnlockPasswordDraft
        self.usePremiumSOTAUX = usePremiumSOTAUX
        self.onForceReconnect = onForceReconnect
        self.onRetryRequest = onRetryRequest
        self.sendTapIntent = sendTapIntent
        self.sendScrollIntent = sendScrollIntent
        self.sendPointerMoveIntent = sendPointerMoveIntent
        self.sendPointerClickIntent = sendPointerClickIntent
        self.sendTextIntent = sendTextIntent
        self.sendShortcutIntent = sendShortcutIntent
        self.sendAgentContextTargetIntent = sendAgentContextTargetIntent
        self.pasteClipboardToMac = pasteClipboardToMac
        self.grabClipboardFromMac = grabClipboardFromMac
        self.sendRemoteUnlockCredential = sendRemoteUnlockCredential
        self.saveRemoteUnlockCredential = saveRemoteUnlockCredential
        self.sendSavedRemoteUnlockCredential = sendSavedRemoteUnlockCredential
        self.deleteSavedRemoteUnlockCredential = deleteSavedRemoteUnlockCredential
        self.onSelectDisplay = onSelectDisplay
        self.onTrustControlDevice = onTrustControlDevice
        self.onClose = onClose
    }

    private var displayStats: ScreenShareViewerCoordinator.Stats {
        var stats = coordinator.lastStats
        if let controlRoundTripMillis {
            stats.roundTripMillis = controlRoundTripMillis
        }
        return stats
    }

    private var activeRemoteUnlockState: HermesRealtimeRelayRemoteUnlockState? {
        guard let remoteUnlockState, remoteUnlockState.lockState != .unlocked else { return nil }
        return remoteUnlockState
    }

    private var standardControlInputEnabled: Bool {
        controlInputEnabled && activeRemoteUnlockState == nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { proxy in
                let visibleViewport = viewport.preview(
                    magnification: magnification * controlMagnification,
                    translation: dragTranslation + controlPanTranslation,
                    in: proxy.size
                )
                let contentRect = renderedContentRect(in: proxy.size)

                DisplayLayerHost(coordinator: coordinator)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(visibleViewport.scale)
                    .offset(visibleViewport.offset)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(viewportGesture(in: proxy.size))
                    .onTapGesture(count: 3) {
                        statsVisible.toggle()
                    }
                    .onTapGesture(count: 2) {
                        guard interactionMode != .trackpad else { return }
                        beginManualZoomOverride()
                        withAnimation(.snappy) {
                            viewport.toggleQuickZoom(in: proxy.size)
                        }
                    }
                    .onAppear {
                        viewport.reclamp(in: proxy.size)
                        lastLayoutSize = proxy.size
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        viewport.reclamp(in: newSize)
                        lastLayoutSize = newSize
                        applySmartZoomDecision(viewportSize: newSize, contentRect: renderedContentRect(in: newSize))
                    }
                    .animation(.snappy, value: viewport)

                if coordinator.displayAspectRatio == nil || streamPhase != .live {
                    StreamStateOverlay(
                        phase: streamPhase,
                        isAwaitingFrame: coordinator.displayAspectRatio == nil,
                        usePremiumSOTAUX: usePremiumSOTAUX,
                        reconnectAttemptStartedAt: reconnectAttemptStartedAt,
                        lastFailureReason: lastFailureReason,
                        lastLiveAt: lastLiveAt,
                        onForceReconnect: onForceReconnect,
                        onRetryRequest: onRetryRequest,
                        onClose: onClose
                    )
                    .transition(.opacity)
                }

                if interactionMode == .control, standardControlInputEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(controlSurfaceGesture(in: proxy.size, contentRect: contentRect, viewport: visibleViewport))
                        .simultaneousGesture(controlMagnifyGesture(in: proxy.size))
                        .accessibilityLabel("Mac screen control surface")
                }

                if interactionMode == .trackpad, standardControlInputEnabled {
                    TrackpadGlassSurface(
                        isVisible: true,
                        usePremiumSOTAUX: usePremiumSOTAUX,
                        onActiveChange: { active in
                            withAnimation(.snappy) {
                                trackpadActive = active
                            }
                        },
                        onMove: { delta in
                            moveLocalCursorByTrackpadDelta(delta, in: contentRect)
                            sendTrackpadPointerDelta(delta)
                        },
                        onClick: sendPointerClickIntent,
                        onScroll: { dy in
                            sendScrollIntent(0.5, 0.5, 0.5, min(max(0.5 - dy, 0), 1), selectedDisplayId)
                        }
                    )
                }

                if interactionMode == .control, let tapFeedbackPoint {
                    TapFeedbackMarker(point: tapFeedbackPoint)
                        .allowsHitTesting(false)
                }

                if interactionMode == .coPilot {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onEnded { value in
                                    let normalized = visibleViewport.normalizedPoint(for: value.location, in: proxy.size, contentRect: contentRect)
                                    withAnimation(.snappy) {
                                        coPilotTarget = (normalizedX: normalized.x, normalizedY: normalized.y, viewPoint: value.location)
                                    }
                                }
                        )
                        .accessibilityLabel("Co-Pilot target selection area")
                }

                if interactionMode == .coPilot, let target = coPilotTarget {
                    CoPilotTargetRing(point: target.viewPoint)
                        .allowsHitTesting(false)
                }

                if standardControlInputEnabled,
                   interactionMode != .view,
                   let visibleCursorPoint = cursorPoint ?? ScreenShareControlInputPolicy.initialCursorPoint(in: contentRect),
                   cursorStyle != .hidden {
                    MirrorPointerCursor(
                        point: visibleCursorPoint,
                        size: cursorSize,
                        style: cursorStyle,
                        usePremiumSOTAUX: usePremiumSOTAUX
                    )
                    .allowsHitTesting(false)
                }

                if hardwareScrollEnabled, standardControlInputEnabled {
                    VolumeButtonScrollBridge { direction in
                        let endY = min(max(0.5 + direction, 0), 1)
                        sendScrollIntent(0.5, 0.5, 0.5, endY, selectedDisplayId)
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                }

                if interactionMode == .coPilot, coPilotTarget != nil {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "dot.circle.and.hand.point.up.left")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.red)
                            Text("Agent Co-Pilot Target Locked")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                            Button {
                                withAnimation(.snappy) {
                                    coPilotTarget = nil
                                    coPilotInstruction = ""
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                        }

                        // Segmented Picker for Agent Runtime
                        Picker("Agent", selection: $coPilotRuntime) {
                            Text("Hermes").tag("hermes")
                            Text("Pi").tag("pi")
                            Text("Codex").tag("codex")
                            Text("Claude").tag("claude")
                            Text("OpenClaw").tag("openclaw")
                        }
                        .pickerStyle(.segmented)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                        // TextField for instruction
                        HStack(spacing: 8) {
                            TextField("Enter instruction (e.g. 'click this button')", text: $coPilotInstruction)
                                .font(.system(size: 14))
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                                .onSubmit {
                                    submitCoPilotIntent()
                                }

                            Button(action: submitCoPilotIntent) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(coPilotInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.3) : .red)
                            }
                            .buttonStyle(.plain)
                            .disabled(coPilotInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(18)
                    .mirrorGlassBackground(cornerRadius: 24)
                    .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 80) // Stay above the control panel
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }

                MirrorControlPanel(
                    interactionMode: $interactionMode,
                    isCollapsed: $panelCollapsed,
                    isTyping: $isTyping,
                    coPilotTarget: $coPilotTarget,
                    edgeScrollEnabled: $edgeScrollEnabled,
                    hardwareScrollEnabled: $hardwareScrollEnabled,
                    statsVisible: $statsVisible,
                    cursorSize: $cursorSize,
                    cursorStyle: $cursorStyle,
                    stats: displayStats,
                    controlStatus: controlStatus,
                    controlInputEnabled: standardControlInputEnabled,
                    displays: displays,
                    selectedDisplayId: selectedDisplayId,
                    isZoomed: viewport.isZoomed,
                    smartZoomMode: smartZoomMode,
                    smartZoomAutoFollowing: smartZoomAutoFollowing,
                    setSmartZoomMode: { newMode in
                        smartZoomMode = newMode
                        smartZoomManualOverrideUntil = nil
                        if newMode == .off {
                            withAnimation(.snappy) { viewport.reset() }
                            smartZoomAutoFollowing = false
                        } else {
                            applySmartZoomDecision(viewportSize: proxy.size, contentRect: contentRect)
                        }
                    },
                    zoomIn: {
                        beginManualZoomOverride()
                        withAnimation(.snappy) { viewport.zoom(by: 1.25, in: proxy.size) }
                    },
                    zoomOut: {
                        beginManualZoomOverride()
                        withAnimation(.snappy) { viewport.zoom(by: 0.8, in: proxy.size) }
                    },
                    resetZoom: {
                        beginManualZoomOverride()
                        withAnimation(.snappy) { viewport.reset() }
                    },
                    focusTyping: {
                        focusTypingBar()
                    },
                    selectDisplay: onSelectDisplay,
                    onTrustControlDevice: onTrustControlDevice,
                    sendScrollButton: { direction in
                        let endY = min(max(0.5 + direction, 0), 1)
                        sendScrollIntent(0.5, 0.5, 0.5, endY, selectedDisplayId)
                    },
                    pasteClipboardToMac: pasteClipboardToMac,
                    grabClipboardFromMac: grabClipboardFromMac,
                    onClose: onClose
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                if let activeRemoteUnlockState {
                    RemoteUnlockStatusOverlay(
                        state: activeRemoteUnlockState,
                        password: $remoteUnlockPasswordDraft,
                        savedCredentialAvailable: savedRemoteUnlockCredentialAvailable,
                        sendCredential: sendRemoteUnlockCredential,
                        saveCredential: saveRemoteUnlockCredential,
                        sendSavedCredential: sendSavedRemoteUnlockCredential,
                        deleteSavedCredential: deleteSavedRemoteUnlockCredential,
                        onReconnect: onForceReconnect,
                        onClose: onClose
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            remoteKeyboardCapture
        }
        .overlay(alignment: .bottom) {
            if smartTextCoachVisible {
                smartTextCoachMark
                    .padding(.horizontal, 20)
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(KeyboardHeightReader(height: $keyboardHeight))
        .onChange(of: resetToken) { _, _ in
            withAnimation(.snappy) {
                viewport.reset()
                interactionMode = .view
                isTyping = false
                controlPanTranslation = .zero
                tapFeedbackPoint = nil
                lastControlClickPoint = nil
                lastControlClickAt = nil
                lastSmartTextNormalizedPoint = nil
                smartTextCoachVisible = false
                cancelPendingControlRightClick()
                controlRightClickSentForCurrentPress = false
                cursorPoint = nil
                typingFocusTask?.cancel()
                typingFocusTask = nil
            }
        }
        .onChange(of: controlStatus) { _, newValue in
            guard controlInputEnabled == false,
                  newValue.isLive == false,
                  interactionMode != .view else { return }
            withAnimation(.snappy) {
                interactionMode = .view
                isTyping = false
                controlPanTranslation = .zero
                cancelPendingControlRightClick()
                controlRightClickSentForCurrentPress = false
            }
        }
        .onChange(of: isTyping) { _, newValue in
            if newValue {
                focusTypingBar()
            } else {
                typingFocusTask?.cancel()
                typingFocusTask = nil
                lastSmartTextNormalizedPoint = nil
            }
            recomputeSmartTextCoach()
        }
        .onChange(of: coordinator.latestFocusContext) { _, _ in
            if isTyping, lastSmartTextNormalizedPoint != nil {
                applyKeyboardAwareFraming()
            } else {
                applySmartZoomDecisionUsingCurrentLayout()
            }
            recomputeSmartTextCoach()
        }
        .onChange(of: interactionMode) { _, newValue in
            if newValue != .control {
                cancelPendingControlRightClick()
                controlRightClickSentForCurrentPress = false
            }
            recomputeSmartTextCoach()
        }
        .onChange(of: activeRemoteUnlockState?.lockState) { _, newValue in
            if standardControlInputEnabled == false {
                isTyping = false
            }
            recomputeSmartTextCoach()
            if newValue == nil || newValue == .unlocked {
                remoteUnlockPasswordDraft = ""
            }
        }
        .onChange(of: keyboardHeight) { _, _ in
            applyKeyboardAwareFraming()
        }
        .onDisappear {
            cancelPendingControlRightClick()
            typingFocusTask?.cancel()
            typingFocusTask = nil
        }
    }

    private func beginManualZoomOverride() {
        smartZoomManualOverrideUntil = Date().addingTimeInterval(ScreenShareSmartZoomReducer.manualOverrideHold)
        smartZoomAutoFollowing = false
    }

    /// Height of the on-screen keyboard that overlaps the viewport, capped so the
    /// remaining visible area can never collapse to nothing.
    private func keyboardInset(in size: CGSize) -> CGFloat {
        ScreenShareKeyboardFramePolicy.cappedInset(rawOverlap: keyboardHeight, viewportHeight: size.height)
    }

    /// Re-frames the smart-text target whenever the keyboard appears, resizes, or
    /// dismisses — lifting the focused field into the visible area above the keyboard
    /// (and back to center when it goes away).
    private func applyKeyboardAwareFraming() {
        guard let size = lastLayoutSize, size.width > 0, size.height > 0 else { return }
        let contentRect = renderedContentRect(in: size)
        let inset = keyboardInset(in: size)
        if let point = activeTypingTargetNormalizedPoint() ?? lastSmartTextNormalizedPoint {
            applyDoubleTapZoom(toNormalized: point, in: size, contentRect: contentRect, bottomInset: inset)
        } else if isTyping {
            // Keyboard opened without a specific target (e.g. the Type button): lift the
            // current framing above the keyboard so the top of the screen is used.
            withAnimation(.snappy) {
                viewport.offset = ScreenShareViewportState.clamp(
                    offset: CGSize(width: viewport.offset.width, height: -inset / 2),
                    scale: viewport.scale,
                    in: size,
                    bottomInset: inset
                )
            }
        }
    }

    private func applyDoubleTapZoom(toNormalized point: CGPoint, in size: CGSize, contentRect: CGRect, bottomInset: CGFloat) {
        guard size.width > 0, size.height > 0, contentRect.width > 0, contentRect.height > 0 else { return }
        let decision = ScreenShareSmartZoomReducer.centerPointDecision(
            normalizedPoint: HermesRealtimeRelayNormalizedPoint(x: Double(point.x), y: Double(point.y)),
            viewportSize: size,
            contentRect: contentRect,
            scale: max(viewport.scale, ScreenShareSmartZoomReducer.doubleTapEntryScale),
            bottomInset: bottomInset
        )
        withAnimation(.snappy) {
            viewport.scale = decision.scale
            viewport.offset = decision.offset
        }
        smartZoomAutoFollowing = true
    }

    private func activeTypingTargetNormalizedPoint(now: Date = Date()) -> CGPoint? {
        guard isTyping,
              let context = coordinator.latestFocusContext,
              ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: context,
                selectedDisplayId: selectedDisplayId,
                now: now
              ),
              let rect = context.normalizedRect else {
            return nil
        }
        return ScreenShareSmartZoomReducer.normalizedCenter(of: rect)
    }

    private func applySmartZoomDecisionUsingCurrentLayout() {
        guard let layoutSize = lastLayoutSize else { return }
        let contentRect = renderedContentRect(in: layoutSize)
        applySmartZoomDecision(viewportSize: layoutSize, contentRect: contentRect)
    }

    @MainActor
    private func applySmartZoomDecision(viewportSize: CGSize, contentRect: CGRect) {
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewportSize,
            contentRect: contentRect,
            currentState: viewport,
            context: coordinator.latestFocusContext,
            mode: smartZoomMode,
            selectedDisplayId: selectedDisplayId,
            manualOverrideUntil: smartZoomManualOverrideUntil,
            now: Date(),
            bottomInset: keyboardInset(in: viewportSize)
        )
        if decision.isAutoFollowing {
            withAnimation(.snappy) {
                viewport.scale = decision.scale
                viewport.offset = decision.offset
            }
            if !smartZoomAutoFollowing { smartZoomAutoFollowing = true }
        } else if smartZoomAutoFollowing {
            smartZoomAutoFollowing = false
        }
    }

    @MainActor
    private func triggerSmartTextDoubleTap(at point: CGPoint, in size: CGSize, contentRect: CGRect) {
        guard controlInputEnabled else { return }
        smartTextDoubleTapLearned = true
        if smartTextCoachVisible {
            withAnimation(.snappy) { smartTextCoachVisible = false }
        }
        if size.width > 0, size.height > 0,
           contentRect.width > 0, contentRect.height > 0 {
            // Zoom straight to the tapped point — this is an explicit gesture, so it
            // zooms even when Smart Zoom mode is off. Remember the target so the framing
            // can re-center above the keyboard once it animates up.
            let normalized = viewport.normalizedPoint(for: point, in: size, contentRect: contentRect)
            let target = CGPoint(x: normalized.x, y: normalized.y)
            lastSmartTextNormalizedPoint = target
            applyDoubleTapZoom(toNormalized: target, in: size, contentRect: contentRect, bottomInset: keyboardInset(in: size))
        }
        focusTypingBar()
    }

    private func recomputeSmartTextCoach() {
        let hasActiveTextFocus: Bool = {
            guard let context = coordinator.latestFocusContext else { return false }
            return ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: context,
                selectedDisplayId: selectedDisplayId,
                now: Date()
            )
        }()
        let shouldShow = ScreenShareSmartTextActivationPolicy.shouldShowDoubleTapCoach(
            learned: smartTextDoubleTapLearned,
            controlInputEnabled: standardControlInputEnabled,
            isTyping: isTyping,
            isCoPilotMode: interactionMode == .coPilot,
            hasActiveTextFocus: hasActiveTextFocus
        )
        guard shouldShow != smartTextCoachVisible else { return }
        withAnimation(.snappy) { smartTextCoachVisible = shouldShow }
    }

    private func viewportGesture(in size: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .updating($magnification) { value, state, _ in
                    guard interactionMode == .view else { return }
                    state = value.magnification
                }
                .onEnded { value in
                    guard interactionMode == .view else { return }
                    beginManualZoomOverride()
                    viewport.applyMagnification(value.magnification, in: size)
                },
            DragGesture(minimumDistance: 2)
                .updating($dragTranslation) { value, state, _ in
                    guard interactionMode == .view else { return }
                    state = value.translation
                }
                .onEnded { value in
                    guard interactionMode == .view else { return }
                    beginManualZoomOverride()
                    viewport.applyTranslation(value.translation, in: size)
                }
        )
    }

    private func controlSurfaceGesture(in size: CGSize, contentRect: CGRect, viewport visibleViewport: ScreenShareViewportState) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if controlPressStartedAt == nil {
                    controlPressStartedAt = Date()
                    let normalized = visibleViewport.normalizedPoint(for: value.startLocation, in: size, contentRect: contentRect)
                    scheduleControlRightClick(
                        at: value.startLocation,
                        normalized: normalized
                    )
                }
                let distance = hypot(value.translation.width, value.translation.height)
                guard controlRightClickSentForCurrentPress == false else {
                    controlPanTranslation = .zero
                    return
                }
                let edgeScrollGesture = edgeScrollEnabled
                    && distance > 14
                    && isEdgeScrollStart(value.startLocation, in: size)
                let resolvedClickPoint = resolvedClickPoint(for: value, distance: distance, in: size)
                let shouldCancelRightClick = ScreenShareControlInputPolicy.shouldCancelPendingControlRightClick(
                    distance: distance,
                    panStartDistance: controlPanStartDistance(in: size),
                    isEdgeScrollGesture: edgeScrollGesture,
                    hasResolvedClickPoint: resolvedClickPoint != nil
                )
                if shouldCancelRightClick {
                    cancelPendingControlRightClick()
                }
                guard distance > controlPanStartDistance(in: size),
                      edgeScrollGesture == false,
                      resolvedClickPoint == nil else {
                    controlPanTranslation = .zero
                    return
                }
                controlPanTranslation = value.translation
            }
            .onEnded { value in
                defer {
                    controlPanTranslation = .zero
                    cancelPendingControlRightClick()
                    controlRightClickSentForCurrentPress = false
                }
                let pressStartedAt = controlPressStartedAt
                controlPressStartedAt = nil

                guard controlRightClickSentForCurrentPress == false else { return }

                let distance = hypot(value.translation.width, value.translation.height)
                if edgeScrollEnabled,
                   distance > 14,
                   isEdgeScrollStart(value.startLocation, in: size) {
                    let start = visibleViewport.normalizedPoint(for: value.startLocation, in: size, contentRect: contentRect)
                    let end = visibleViewport.normalizedPoint(for: value.location, in: size, contentRect: contentRect)
                    sendScrollIntent(start.x, start.y, end.x, end.y, selectedDisplayId)
                    return
                }

                if let clickPoint = resolvedClickPoint(for: value, distance: distance, in: size) {
                    let normalized = visibleViewport.normalizedPoint(for: clickPoint, in: size, contentRect: contentRect)
                    let tappedAt = Date()
                    let isDoubleTap = ScreenShareControlInputPolicy.isDoubleTap(
                        previousAt: lastControlClickAt,
                        previousPoint: lastControlClickPoint,
                        currentPoint: clickPoint,
                        now: tappedAt,
                        maxDistance: clickRadii(in: size).repeated
                    )
                    lastControlClickPoint = clickPoint
                    cursorPoint = clickPoint
                    showTapFeedback(at: clickPoint)
                    handleControlTap(
                        normalized: normalized,
                        at: clickPoint,
                        pressStartedAt: pressStartedAt
                    )
                    if isDoubleTap {
                        // Second tap of a double-tap: jump straight into the field now,
                        // instead of waiting for the Mac's focus context to round-trip.
                        // Reset the timestamp so a third tap starts a fresh pair.
                        lastControlClickAt = nil
                        triggerSmartTextDoubleTap(at: clickPoint, in: size, contentRect: contentRect)
                    } else {
                        lastControlClickAt = tappedAt
                    }
                    return
                }

                guard distance > controlPanStartDistance(in: size) else { return }
                viewport.applyTranslation(value.translation, in: size)
            }
    }

    private func scheduleControlRightClick(at point: CGPoint, normalized: (x: Double, y: Double)) {
        cancelPendingControlRightClick()
        controlRightClickSentForCurrentPress = false
        pendingControlRightClickTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ScreenShareControlInputPolicy.rightClickHoldDelayNanoseconds)
            guard Task.isCancelled == false else { return }
            controlRightClickSentForCurrentPress = true
            controlPanTranslation = .zero
            lastControlClickPoint = point
            cursorPoint = point
            showTapFeedback(at: point)
            triggerControlRightClickHaptic()
            sendTapIntent(normalized.x, normalized.y, 1)
        }
    }

    private func cancelPendingControlRightClick() {
        pendingControlRightClickTask?.cancel()
        pendingControlRightClickTask = nil
    }

    private func triggerControlRightClickHaptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func handleControlTap(normalized: (x: Double, y: Double), at point: CGPoint, pressStartedAt: Date?) {
        let heldDuration = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sendTapIntent(
            normalized.x,
            normalized.y,
            ScreenShareControlInputPolicy.controlClickMouseButton(heldDuration: heldDuration)
        )
    }

    private func submitCoPilotIntent() {
        guard let target = coPilotTarget else { return }
        let instruction = coPilotInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }

        sendAgentContextTargetIntent(
            target.normalizedX,
            target.normalizedY,
            instruction,
            coPilotRuntime,
            nil
        )

        withAnimation(.snappy) {
            coPilotTarget = nil
            coPilotInstruction = ""
        }
    }

    private func controlMagnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($controlMagnification) { value, state, _ in
                guard interactionMode == .control else { return }
                state = value.magnification
            }
            .onEnded { value in
                guard interactionMode == .control else { return }
                viewport.applyMagnification(value.magnification, in: size)
            }
    }

    private func resolvedClickPoint(for value: DragGesture.Value, distance: CGFloat, in size: CGSize) -> CGPoint? {
        let radii = clickRadii(in: size)
        if distance <= radii.precise {
            return value.location
        }
        if distance <= radii.forgiving {
            return value.location
        }
        if let lastControlClickPoint,
           distance <= radii.repeated,
           min(
                hypot(value.startLocation.x - lastControlClickPoint.x, value.startLocation.y - lastControlClickPoint.y),
                hypot(value.location.x - lastControlClickPoint.x, value.location.y - lastControlClickPoint.y)
           ) <= radii.repeated {
            return value.location
        }
        return nil
    }

    private func clickRadii(in size: CGSize) -> (precise: CGFloat, forgiving: CGFloat, repeated: CGFloat) {
        let diagonal = max(1, hypot(size.width, size.height))
        return (
            precise: min(max(diagonal * 0.014, 12), 22),
            forgiving: min(max(diagonal * 0.026, 26), 48),
            repeated: min(max(diagonal * 0.034, 32), 64)
        )
    }

    private func controlPanStartDistance(in size: CGSize) -> CGFloat {
        clickRadii(in: size).forgiving + 2
    }

    private func isEdgeScrollStart(_ point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let margin = max(28, min(size.width, size.height) * 0.07)
        return point.x <= margin
            || point.x >= size.width - margin
            || point.y <= margin
            || point.y >= size.height - margin
    }

    private func sendTrackpadPointerDelta(_ delta: CGSize) {
        sendPointerMoveIntent(Double(delta.width), Double(delta.height))
    }

    private func moveLocalCursorByTrackpadDelta(_ delta: CGSize, in bounds: CGRect) {
        cursorPoint = ScreenShareControlInputPolicy.movedCursorPoint(
            current: cursorPoint,
            delta: delta,
            bounds: bounds
        )
    }

    private func renderedContentRect(in size: CGSize) -> CGRect {
        guard let aspectRatio = coordinator.displayAspectRatio,
              aspectRatio.isFinite,
              aspectRatio > 0,
              size.width > 0,
              size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }

        let containerAspect = size.width / size.height
        if containerAspect > aspectRatio {
            let width = size.height * aspectRatio
            return CGRect(
                x: (size.width - width) / 2,
                y: 0,
                width: width,
                height: size.height
            )
        }

        let height = size.width / aspectRatio
        return CGRect(
            x: 0,
            y: (size.height - height) / 2,
            width: size.width,
            height: height
        )
    }

    private func focusTypingBar() {
        guard controlInputEnabled else { return }
        typingFocusTask?.cancel()
        typingFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard Task.isCancelled == false else { return }
            interactionMode = .control
            isTyping = true
        }
    }

    private func showTapFeedback(at point: CGPoint) {
        withAnimation(.snappy) {
            tapFeedbackPoint = point
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            withAnimation(.easeOut(duration: 0.18)) {
                tapFeedbackPoint = nil
            }
        }
    }

    private func panelDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                panelOffset = clampPanelOffset(
                    panelDragBase + value.translation,
                    in: size
                )
            }
            .onEnded { _ in
                panelDragBase = panelOffset
            }
    }

    private func clampPanel(in size: CGSize) {
        panelOffset = clampPanelOffset(panelOffset, in: size)
        panelDragBase = panelOffset
    }

    private func clampPanelOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let horizontalLimit = max(0, size.width - (panelCollapsed ? 72 : 112))
        let verticalLimit = max(0, size.height - (panelCollapsed ? 72 : 168))
        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), -8),
            height: min(max(proposed.height, 8), verticalLimit)
        )
    }

    @ViewBuilder
    private var remoteKeyboardCapture: some View {
        #if canImport(UIKit)
        RemoteKeyboardCaptureView(
            isActive: $isTyping,
            onText: sendTextIntent,
            onKey: { key in
                sendShortcutIntent(key, [])
            }
        )
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #else
        EmptyView()
        #endif
    }

    private var smartTextCoachMark: some View {
        HStack(spacing: 11) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.17, green: 0.79, blue: 0.75))
            VStack(alignment: .leading, spacing: 1) {
                Text("Double-tap to type")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Zoom into the focused field and open the keyboard instantly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.snappy) {
                    smartTextDoubleTapLearned = true
                    smartTextCoachVisible = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(7)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.vertical, 11)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .frame(maxWidth: 440)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tip: double-tap a text field to zoom in and type")
    }
}

#if canImport(UIKit)
/// Hidden UITextView that captures hardware/soft-keyboard input and reports it
/// as discrete text + key events. Reused by the focused interactive-CLI
/// terminal (`InlineAgentMirrorView`) so typing flows into the live TUI.
struct RemoteKeyboardCaptureView: UIViewRepresentable {
    @Binding var isActive: Bool
    let onText: (String) -> Void
    let onKey: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> RemoteKeyboardTextView {
        let textView = RemoteKeyboardTextView(frame: .zero)
        textView.remoteKeyboardDelegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = .clear
        textView.tintColor = .clear
        textView.isScrollEnabled = false
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardDismissMode = .interactive
        textView.inputAccessoryView = context.coordinator.makeAccessoryToolbar()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ uiView: RemoteKeyboardTextView, context: Context) {
        context.coordinator.parent = self
        if isActive {
            if uiView.isFirstResponder == false {
                DispatchQueue.main.async {
                    guard self.isActive else { return }
                    uiView.becomeFirstResponder()
                }
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
            uiView.text = ""
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, RemoteKeyboardTextViewDelegate {
        var parent: RemoteKeyboardCaptureView
        weak var textView: RemoteKeyboardTextView?

        init(parent: RemoteKeyboardCaptureView) {
            self.parent = parent
        }

        func makeAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.items = [
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(
                    title: "Done",
                    style: .done,
                    target: self,
                    action: #selector(donePressed)
                )
            ]
            toolbar.sizeToFit()
            return toolbar
        }

        @objc private func donePressed() {
            parent.isActive = false
            textView?.resignFirstResponder()
            textView?.text = ""
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            textView.text = ""
            if parent.isActive {
                parent.isActive = false
            }
        }

        func remoteKeyboardTextView(_ textView: RemoteKeyboardTextView, didInsert text: String) {
            textView.text = ""
            switch text {
            case "\n", "\r":
                parent.onKey("Return")
            case "\t":
                parent.onKey("Tab")
            default:
                parent.onText(text)
            }
        }

        func remoteKeyboardTextViewDidDeleteBackward(_ textView: RemoteKeyboardTextView) {
            textView.text = ""
            parent.onKey("Delete")
        }
    }
}

@MainActor
protocol RemoteKeyboardTextViewDelegate: AnyObject {
    func remoteKeyboardTextView(_ textView: RemoteKeyboardTextView, didInsert text: String)
    func remoteKeyboardTextViewDidDeleteBackward(_ textView: RemoteKeyboardTextView)
}

@MainActor
final class RemoteKeyboardTextView: UITextView {
    weak var remoteKeyboardDelegate: RemoteKeyboardTextViewDelegate?

    override var canBecomeFirstResponder: Bool { true }

    override func insertText(_ text: String) {
        remoteKeyboardDelegate?.remoteKeyboardTextView(self, didInsert: text)
    }

    override func deleteBackward() {
        remoteKeyboardDelegate?.remoteKeyboardTextViewDidDeleteBackward(self)
    }
}
#endif

private struct KeyboardHeightReader: View {
    @Binding var height: CGFloat

    var body: some View {
        #if canImport(UIKit)
        GeometryReader { proxy in
            Color.clear
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    height = ScreenShareKeyboardOverlapPolicy.overlap(keyboardFrame: frame, viewFrame: proxy.frame(in: .global))
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    height = ScreenShareKeyboardOverlapPolicy.overlap(keyboardFrame: frame, viewFrame: proxy.frame(in: .global))
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    height = 0
                }
        }
        #else
        Color.clear
        #endif
    }
}

enum ScreenShareKeyboardFramePolicy {
    static func cappedInset(rawOverlap: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        return min(max(rawOverlap, 0), viewportHeight * 0.6)
    }
}

#if canImport(UIKit)
enum ScreenShareKeyboardOverlapPolicy {
    static func overlap(keyboardFrame: CGRect, viewFrame: CGRect) -> CGFloat {
        guard keyboardFrame.width > 0, keyboardFrame.height > 0, viewFrame.width > 0, viewFrame.height > 0 else {
            return 0
        }
        return max(0, min(viewFrame.intersection(keyboardFrame).height, viewFrame.height))
    }
}
#endif

enum SmartZoomMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case smart
    case text
    case window
    case cursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .smart: return "Smart"
        case .text: return "Text"
        case .window: return "Window"
        case .cursor: return "Cursor"
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "rectangle.dashed"
        case .smart: return "sparkles.rectangle.stack"
        case .text: return "text.cursor"
        case .window: return "rectangle.inset.filled"
        case .cursor: return "cursorarrow"
        }
    }
}

struct ScreenShareSmartZoomContext: Equatable {
    var targetKind: HermesRealtimeRelayFocusTargetKind
    var displayId: String?
    var normalizedRect: HermesRealtimeRelayNormalizedRect?
    var normalizedPoint: HermesRealtimeRelayNormalizedPoint?
    var confidence: Double?
    var receivedAt: Date

    static func from(
        _ relay: HermesRealtimeRelayFocusContext,
        receivedAt: Date = Date()
    ) -> ScreenShareSmartZoomContext? {
        guard let targetKind = relay.targetKind else { return nil }
        return ScreenShareSmartZoomContext(
            targetKind: targetKind,
            displayId: relay.displayId,
            normalizedRect: relay.normalizedRect,
            normalizedPoint: relay.normalizedPoint,
            confidence: relay.confidence,
            receivedAt: receivedAt
        )
    }
}

enum ScreenShareSmartZoomReducer {
    static let staleAfter: TimeInterval = 1.5
    static let manualOverrideHold: TimeInterval = 5.0
    static let textFillRatio: CGFloat = 0.62
    static let windowFillRatio: CGFloat = 0.86
    static let agentFillRatio: CGFloat = 0.72
    static let textScaleRange: ClosedRange<CGFloat> = 1.4...4.0
    static let windowScaleRange: ClosedRange<CGFloat> = 1.0...2.4
    static let cursorEntryScale: CGFloat = 1.8
    static let agentScaleRange: ClosedRange<CGFloat> = 1.0...3.0
    /// Scale used when a double-tap optimistically zooms toward the tapped point,
    /// before the Mac's focused-element rect arrives to refine the framing.
    static let doubleTapEntryScale: CGFloat = 2.4

    struct Decision: Equatable {
        var scale: CGFloat
        var offset: CGSize
        var isAutoFollowing: Bool
    }

    static func reduce(
        viewportSize: CGSize,
        contentRect: CGRect,
        currentState: ScreenShareViewportState,
        context: ScreenShareSmartZoomContext?,
        mode: SmartZoomMode,
        selectedDisplayId: String?,
        manualOverrideUntil: Date?,
        now: Date,
        bottomInset: CGFloat = 0
    ) -> Decision {
        let idleDecision = Decision(
            scale: currentState.scale,
            offset: currentState.offset,
            isAutoFollowing: false
        )

        guard mode != .off else { return idleDecision }
        guard viewportSize.width > 0, viewportSize.height > 0 else { return idleDecision }
        guard contentRect.width > 0, contentRect.height > 0 else { return idleDecision }
        if let manualOverrideUntil, manualOverrideUntil > now { return idleDecision }
        guard let context else { return idleDecision }
        if now.timeIntervalSince(context.receivedAt) > staleAfter { return idleDecision }
        if let target = context.displayId,
           let selected = selectedDisplayId,
           target != selected {
            return idleDecision
        }
        guard targetMatches(mode: mode, kind: context.targetKind) else { return idleDecision }

        switch context.targetKind {
        case .focusedElement:
            guard let rect = context.normalizedRect else { return idleDecision }
            return fitRectDecision(
                normalizedRect: rect,
                viewportSize: viewportSize,
                contentRect: contentRect,
                fillRatio: textFillRatio,
                scaleRange: textScaleRange,
                bottomInset: bottomInset
            )
        case .focusedWindow:
            guard let rect = context.normalizedRect else { return idleDecision }
            return fitRectDecision(
                normalizedRect: rect,
                viewportSize: viewportSize,
                contentRect: contentRect,
                fillRatio: windowFillRatio,
                scaleRange: windowScaleRange,
                bottomInset: bottomInset
            )
        case .agentWorkspace:
            guard let rect = context.normalizedRect else { return idleDecision }
            return fitRectDecision(
                normalizedRect: rect,
                viewportSize: viewportSize,
                contentRect: contentRect,
                fillRatio: agentFillRatio,
                scaleRange: agentScaleRange,
                bottomInset: bottomInset
            )
        case .cursor:
            guard let point = context.normalizedPoint else { return idleDecision }
            let targetScale: CGFloat
            if currentState.isZoomed {
                targetScale = currentState.scale
            } else {
                targetScale = min(max(cursorEntryScale, ScreenShareViewportState.minimumScale), ScreenShareViewportState.maximumScale)
            }
            return centerPointDecision(
                normalizedPoint: point,
                viewportSize: viewportSize,
                contentRect: contentRect,
                scale: targetScale,
                bottomInset: bottomInset
            )
        }
    }

    static func targetMatches(mode: SmartZoomMode, kind: HermesRealtimeRelayFocusTargetKind) -> Bool {
        switch mode {
        case .off: return false
        case .smart: return true
        case .text: return kind == .focusedElement
        case .window: return kind == .focusedWindow
        case .cursor: return kind == .cursor
        }
    }

    static func fitRectDecision(
        normalizedRect rect: HermesRealtimeRelayNormalizedRect,
        viewportSize: CGSize,
        contentRect: CGRect,
        fillRatio: CGFloat,
        scaleRange: ClosedRange<CGFloat>,
        bottomInset: CGFloat = 0
    ) -> Decision {
        let rectWidthInContent = max(0.0001, CGFloat(rect.width)) * contentRect.width
        let rectHeightInContent = max(0.0001, CGFloat(rect.height)) * contentRect.height
        let shortRectAxis = min(rectWidthInContent, rectHeightInContent)
        let shortViewportAxis = min(viewportSize.width, max(1, viewportSize.height - bottomInset))
        let targetShortAxis = shortViewportAxis * fillRatio
        let rawScale = targetShortAxis / max(shortRectAxis, 0.0001)
        let scale = clamp(rawScale, range: scaleRange)
        let centerX = contentRect.minX + CGFloat(rect.x + rect.width / 2) * contentRect.width
        let centerY = contentRect.minY + CGFloat(rect.y + rect.height / 2) * contentRect.height
        let offset = offsetForCenter(
            centerInContent: CGPoint(x: centerX, y: centerY),
            scale: scale,
            viewportSize: viewportSize,
            bottomInset: bottomInset
        )
        return Decision(scale: scale, offset: offset, isAutoFollowing: true)
    }

    static func centerPointDecision(
        normalizedPoint point: HermesRealtimeRelayNormalizedPoint,
        viewportSize: CGSize,
        contentRect: CGRect,
        scale: CGFloat,
        bottomInset: CGFloat = 0
    ) -> Decision {
        let clampedScale = ScreenShareViewportState.clampScale(scale)
        let centerX = contentRect.minX + CGFloat(point.x) * contentRect.width
        let centerY = contentRect.minY + CGFloat(point.y) * contentRect.height
        let offset = offsetForCenter(
            centerInContent: CGPoint(x: centerX, y: centerY),
            scale: clampedScale,
            viewportSize: viewportSize,
            bottomInset: bottomInset
        )
        return Decision(scale: clampedScale, offset: offset, isAutoFollowing: true)
    }

    static func normalizedCenter(of rect: HermesRealtimeRelayNormalizedRect) -> CGPoint {
        CGPoint(
            x: CGFloat(rect.x + rect.width / 2),
            y: CGFloat(rect.y + rect.height / 2)
        )
    }

    /// Offset that puts `centerInContent` at the visual center of the
    /// viewport when the content is scaled by `scale`. Inverse of
    /// `ScreenShareViewportState.viewPoint(forNormalized:in:)`:
    ///
    ///   viewX = (cx - W/2) * scale + W/2 + offsetWidth
    ///   put viewX = W/2 ⇒ offsetWidth = (W/2 - cx) * scale.
    static func offsetForCenter(
        centerInContent: CGPoint,
        scale: CGFloat,
        viewportSize: CGSize,
        bottomInset: CGFloat = 0
    ) -> CGSize {
        let halfWidth = viewportSize.width / 2
        let halfHeight = viewportSize.height / 2
        // Aim for the center of the *visible* area (above any keyboard) so the target
        // lands in view and the content uses the top of the screen.
        let lift = max(0, bottomInset) / 2
        let proposedX = (halfWidth - centerInContent.x) * scale
        let proposedY = (halfHeight - centerInContent.y) * scale - lift
        return ScreenShareViewportState.clamp(
            offset: CGSize(width: proposedX, height: proposedY),
            scale: scale,
            in: viewportSize,
            bottomInset: bottomInset
        )
    }

    static func clamp(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        if value.isNaN { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

struct ScreenShareViewportState: Equatable {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 4
    static let quickZoomScale: CGFloat = 2

    var scale: CGFloat = minimumScale
    var offset: CGSize = .zero

    var isZoomed: Bool {
        scale > Self.minimumScale + 0.001
    }

    mutating func applyMagnification(_ magnification: CGFloat, in size: CGSize) {
        scale = Self.clampScale(scale * magnification)
        offset = Self.clamp(offset: offset, scale: scale, in: size)
    }

    mutating func zoom(by multiplier: CGFloat, in size: CGSize) {
        scale = Self.clampScale(scale * multiplier)
        offset = Self.clamp(offset: offset, scale: scale, in: size)
    }

    mutating func applyTranslation(_ translation: CGSize, in size: CGSize) {
        offset = Self.clamp(offset: offset + translation, scale: scale, in: size)
    }

    mutating func toggleQuickZoom(in size: CGSize) {
        if isZoomed {
            reset()
        } else {
            scale = Self.quickZoomScale
            offset = Self.clamp(offset: .zero, scale: scale, in: size)
        }
    }

    mutating func reclamp(in size: CGSize) {
        scale = Self.clampScale(scale)
        offset = Self.clamp(offset: offset, scale: scale, in: size)
    }

    mutating func reset() {
        scale = Self.minimumScale
        offset = .zero
    }

    func preview(magnification: CGFloat, translation: CGSize, in size: CGSize) -> ScreenShareViewportState {
        let previewScale = Self.clampScale(scale * magnification)
        return ScreenShareViewportState(
            scale: previewScale,
            offset: Self.clamp(offset: offset + translation, scale: previewScale, in: size)
        )
    }

    func normalizedPoint(for point: CGPoint, in size: CGSize, contentRect: CGRect? = nil) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        let baseX = ((point.x - (size.width / 2) - offset.width) / scale) + (size.width / 2)
        let baseY = ((point.y - (size.height / 2) - offset.height) / scale) + (size.height / 2)
        let rect = contentRect ?? CGRect(origin: .zero, size: size)
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let x = min(max((baseX - rect.minX) / rect.width, 0), 1)
        let y = min(max((baseY - rect.minY) / rect.height, 0), 1)
        return (Double(x), Double(y))
    }

    func viewPoint(forNormalized normalized: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let contentX = min(max(normalized.x, 0), 1) * size.width
        let contentY = min(max(normalized.y, 0), 1) * size.height
        let viewX = ((contentX - (size.width / 2)) * scale) + (size.width / 2) + offset.width
        let viewY = ((contentY - (size.height / 2)) * scale) + (size.height / 2) + offset.height
        return CGPoint(x: min(max(viewX, 0), size.width), y: min(max(viewY, 0), size.height))
    }

    static func clampScale(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, minimumScale), maximumScale)
    }

    static func clamp(offset proposed: CGSize, scale: CGFloat, in size: CGSize, bottomInset: CGFloat = 0) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }

        let horizontalLimit = max(0, size.width * (scale - 1) / 2)
        let verticalLimit = max(0, size.height * (scale - 1) / 2)
        // When a keyboard covers the bottom, allow the content to ride up by half the
        // covered height so the focused region sits in the visible area instead of
        // being centered behind the keyboard (and leaving the top of the screen black).
        let lift = max(0, bottomInset) / 2

        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -(verticalLimit + lift)), verticalLimit)
        )
    }
}

enum ScreenShareInteractionMode: Equatable {
    case view
    case control
    case trackpad
    case coPilot
}

enum ScreenShareSmartTextActivationPolicy {
    /// Decides whether to surface the "double-tap to type" coaching hint. The hint
    /// teaches the fast path at the exact moment it pays off: a text field is focused
    /// on the Mac, control is live, and the keyboard is still down. It retires once the
    /// user has performed the gesture (`learned`) or starts typing.
    static func shouldShowDoubleTapCoach(
        learned: Bool,
        controlInputEnabled: Bool,
        isTyping: Bool,
        isCoPilotMode: Bool,
        hasActiveTextFocus: Bool
    ) -> Bool {
        guard learned == false else { return false }
        guard controlInputEnabled else { return false }
        guard isCoPilotMode == false else { return false }
        guard isTyping == false else { return false }
        return hasActiveTextFocus
    }
}

enum ScreenShareControlInputPolicy {
    static let rightClickHoldDuration: TimeInterval = 0.55
    static let trackpadTapTravelLimit: CGFloat = 8
    static let doubleTapMaxInterval: TimeInterval = 0.4
    static var rightClickHoldDelayNanoseconds: UInt64 {
        UInt64((rightClickHoldDuration * 1_000_000_000).rounded())
    }

    static func controlClickMouseButton(heldDuration: TimeInterval) -> Int {
        heldDuration >= rightClickHoldDuration ? 1 : 0
    }

    static func shouldCancelPendingControlRightClick(
        distance: CGFloat,
        panStartDistance: CGFloat,
        isEdgeScrollGesture: Bool,
        hasResolvedClickPoint: Bool
    ) -> Bool {
        isEdgeScrollGesture || (distance > panStartDistance && hasResolvedClickPoint == false)
    }

    static func trackpadClickMouseButton(heldDuration: TimeInterval, travelDistance: CGFloat) -> Int? {
        if heldDuration >= rightClickHoldDuration {
            return 1
        }
        return travelDistance < trackpadTapTravelLimit ? 0 : nil
    }

    /// Detects whether the current control-surface tap completes a double-tap relative
    /// to the previously resolved tap. The double-tap is the gesture that jumps the
    /// viewer straight into a text field — zooming in and raising the keyboard
    /// immediately, rather than waiting for the Mac's focus context to round-trip back.
    static func isDoubleTap(
        previousAt: Date?,
        previousPoint: CGPoint?,
        currentPoint: CGPoint,
        now: Date,
        maxDistance: CGFloat,
        maxInterval: TimeInterval = doubleTapMaxInterval
    ) -> Bool {
        guard let previousAt, let previousPoint else { return false }
        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed >= 0, elapsed <= maxInterval else { return false }
        return hypot(currentPoint.x - previousPoint.x, currentPoint.y - previousPoint.y) <= maxDistance
    }

    static func initialCursorPoint(in bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    static func movedCursorPoint(current: CGPoint?, delta: CGSize, bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let base = current ?? CGPoint(x: bounds.midX, y: bounds.midY)
        return CGPoint(
            x: min(max(base.x + delta.width, bounds.minX), bounds.maxX),
            y: min(max(base.y + delta.height, bounds.minY), bounds.maxY)
        )
    }
}

private enum MirrorCursorStyle: String, CaseIterable, Identifiable {
    case mercury
    case ember
    case aurora
    case white
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mercury: return "Mercury cursor"
        case .ember: return "Ember cursor"
        case .aurora: return "Aurora cursor"
        case .white: return "White cursor"
        case .hidden: return "Hide cursor"
        }
    }
}

private struct RemoteUnlockStatusOverlay: View {
    let state: HermesRealtimeRelayRemoteUnlockState
    @Binding var password: String
    let savedCredentialAvailable: Bool
    let sendCredential: (String) -> Void
    let saveCredential: (String) -> Void
    let sendSavedCredential: () -> Void
    let deleteSavedCredential: () -> Void
    let onReconnect: () -> Void
    let onClose: () -> Void
    @State private var isSending = false
    @State private var isSaving = false
    @State private var isSendingSaved = false

    private var canSendCredential: Bool {
        state.capabilities.enabled && state.capabilities.allowsCredentialPaste
    }

    private var canUseSavedCredential: Bool {
        state.capabilities.enabled && state.capabilities.allowsSavedCredentialUnlock
    }

    private var title: String {
        switch state.lockState {
        case .loginWindow, .rebootLoginWindow: return "Mac Login Window"
        case .securityAgent: return "Mac Authentication Prompt"
        case .screenSaver, .screenLocked: return "Mac Locked"
        case .displaySleeping: return "Mac Display Sleeping"
        case .fastUserSwitching: return "Fast User Switching"
        case .fileVaultPreboot: return "FileVault Preboot"
        case .remoteDesktopCurtain: return "Remote Desktop Curtain"
        case .unknown: return "Mac Lock State Unknown"
        case .unlocked: return "Mac Unlocked"
        }
    }

    private var detail: String {
        if canSendCredential {
            if state.capabilities.certificationStatus == .certified {
                return "Remote Unlock is certified on this Mac. Credential entry uses the dedicated remote-unlock lane; normal Mac control is paused while locked."
            }
            return "Remote Unlock is ready on this Mac. The first successful locked unlock records hardware certification; normal Mac control is paused while locked."
        }
        let firstBlocker = state.capabilities.blockers.first ?? "remote_unlock_not_certified"
        return "Remote Unlock is unavailable on this Mac: \(firstBlocker). Normal Mac control is paused while locked."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: canSendCredential ? "lock.open.display" : "lock.display")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(canSendCredential ? .green : .yellow)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(state.backend.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer()

                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.10), in: Circle())

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.10), in: Circle())
            }

            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            if canSendCredential {
                VStack(alignment: .leading, spacing: 10) {
                    if savedCredentialAvailable, canUseSavedCredential {
                        HStack(spacing: 10) {
                            Button {
                                isSendingSaved = true
                                sendSavedCredential()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    isSendingSaved = false
                                }
                            } label: {
                                Label(isSendingSaved ? "Sending" : "One-tap unlock", systemImage: isSendingSaved ? "checkmark" : "faceid")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.black)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .disabled(isSendingSaved)
                            .accessibilityLabel("Unlock Mac with saved credential")

                            Button(role: .destructive) {
                                deleteSavedCredential()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel("Delete saved Remote Unlock credential")
                        }
                    }

                    HStack(spacing: 10) {
                        SecureField("Mac password", text: $password)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )

                        Button {
                            let credential = password
                            password = ""
                            isSending = true
                            sendCredential(credential)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                isSending = false
                            }
                        } label: {
                            Image(systemName: isSending ? "checkmark" : "lock.open")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.black)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(password.isEmpty || isSending ? 0.55 : 1)
                        .disabled(password.isEmpty || isSending)
                        .accessibilityLabel("Send Mac password")
                    }

                    if canUseSavedCredential {
                        Button {
                            isSaving = true
                            saveCredential(password)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                isSaving = false
                            }
                        } label: {
                            Label(isSaving ? "Saving" : "Save for one-tap unlock", systemImage: isSaving ? "checkmark.shield" : "key.fill")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(password.isEmpty || isSaving ? 0.55 : 1)
                        .disabled(password.isEmpty || isSaving)
                        .accessibilityLabel("Save Mac password for one-tap Remote Unlock")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(16)
        .mirrorGlassBackground(cornerRadius: 18)
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
    }
}

#if DEBUG
struct RemoteUnlockSimulatorHarnessView: View {
    @State private var password = "test-mac-password"
    @State private var savedCredentialAvailable = true
    @State private var status = "Locked Mac Remote Unlock ready"

    private var state: HermesRealtimeRelayRemoteUnlockState {
        HermesRealtimeRelayRemoteUnlockState(
            sessionId: "sim-remote-unlock-session",
            lockState: .loginWindow,
            backend: .appleScreenSharingLoopback,
            capabilities: HermesRealtimeRelayRemoteUnlockCapabilities(
                enabled: true,
                certificationStatus: .certified,
                activeBackend: .appleScreenSharingLoopback,
                supportedBackends: [.appleScreenSharingLoopback],
                supportedLockStates: [.loginWindow, .securityAgent, .screenLocked],
                allowsCredentialPaste: true,
                allowsSavedCredentialUnlock: true,
                credentialRecipientKeyId: "sim-mac-recipient-key",
                credentialRecipientPublicKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                credentialEnvelopeAlgorithm: "HPKE-X25519-SHA256-CHACHAPOLY"
            ),
            controlOwnerViewerId: "sim-viewer",
            observedAt: Date()
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.09, blue: 0.12), Color(red: 0.18, green: 0.20, blue: 0.23)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("MacBook Pro", systemImage: "display")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    Label("loginwindow", systemImage: "lock.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.74))

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 92, height: 92)
                        .overlay(
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 58))
                                .foregroundStyle(.white.opacity(0.70))
                        )
                    Text("Alberto")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Password required")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.60))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 18)

                RemoteUnlockStatusOverlay(
                    state: state,
                    password: $password,
                    savedCredentialAvailable: savedCredentialAvailable,
                    sendCredential: { credential in
                        status = credential.isEmpty ? "Password missing" : "Typed password queued for loginwindow"
                    },
                    saveCredential: { credential in
                        savedCredentialAvailable = !credential.isEmpty
                        status = credential.isEmpty ? "Password missing" : "One-tap credential available"
                    },
                    sendSavedCredential: {
                        status = "Saved credential queued for loginwindow"
                    },
                    deleteSavedCredential: {
                        savedCredentialAvailable = false
                        status = "Saved credential removed"
                    },
                    onReconnect: {
                        status = "Remote Unlock session refreshed"
                    },
                    onClose: {
                        status = "Remote Unlock viewer closed"
                    }
                )

                Text(status)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
                    .accessibilityIdentifier("remoteUnlockHarness.status")
            }
            .padding(18)
        }
        .accessibilityIdentifier("remoteUnlockHarness.root")
    }
}
#endif

private struct MirrorControlPanel: View {
    @Binding var interactionMode: ScreenShareInteractionMode
    @Binding var isCollapsed: Bool
    @Binding var isTyping: Bool
    @Binding var coPilotTarget: (normalizedX: Double, normalizedY: Double, viewPoint: CGPoint)?
    @Binding var edgeScrollEnabled: Bool
    @Binding var hardwareScrollEnabled: Bool
    @Binding var statsVisible: Bool
    @Binding var cursorSize: CGFloat
    @Binding var cursorStyle: MirrorCursorStyle
    let stats: ScreenShareViewerCoordinator.Stats
    let controlStatus: ScreenSharePhoneControlStatus
    let controlInputEnabled: Bool
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let isZoomed: Bool
    let smartZoomMode: SmartZoomMode
    let smartZoomAutoFollowing: Bool
    let setSmartZoomMode: (SmartZoomMode) -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let focusTyping: () -> Void
    let selectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let sendScrollButton: (Double) -> Void
    let pasteClipboardToMac: () -> Void
    let grabClipboardFromMac: () -> Void
    let onClose: () -> Void

    @State private var openGroup: MirrorControlGroup?
    @State private var tooltip: String?

    // Related controls are shelved behind one primary button each, so the
    // always-visible dock stays compact instead of showing every action at once.
    private enum MirrorControlGroup: String, CaseIterable, Identifiable {
        case mode, zoom, scroll, keyboard, screen
        var id: String { rawValue }

        var title: String {
            switch self {
            case .mode: return "Mode"
            case .zoom: return "Zoom"
            case .scroll: return "Scroll"
            case .keyboard: return "Keys"
            case .screen: return "Screen"
            }
        }

        var hint: String {
            switch self {
            case .mode: return "Interaction mode — view, control, trackpad, Co-Pilot"
            case .zoom: return "Zoom and Smart Zoom"
            case .scroll: return "Scroll and paging"
            case .keyboard: return "Keyboard and clipboard"
            case .screen: return "Display, cursor and stats"
            }
        }

        var icon: String {
            switch self {
            case .mode: return "hand.draw"
            case .zoom: return "arrow.up.left.and.down.right.magnifyingglass"
            case .scroll: return "arrow.up.arrow.down"
            case .keyboard: return "keyboard"
            case .screen: return "macwindow"
            }
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            statusStrip
            if let group = openGroup {
                shelf(for: group)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            primaryDock
        }
        .overlay(alignment: .top) { tooltipBubble }
        .animation(.snappy(duration: 0.26), value: openGroup)
        .onChange(of: openGroup) { _, newValue in
            isCollapsed = (newValue == nil)
        }
        .onAppear { isCollapsed = (openGroup == nil) }
        .task(id: tooltip) {
            guard tooltip != nil else { return }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(.easeOut(duration: 0.2)) { tooltip = nil }
        }
    }

    // MARK: - Primary dock

    private var primaryDock: some View {
        HStack(spacing: 10) {
            ForEach(MirrorControlGroup.allCases) { group in
                groupButton(group)
            }
            Spacer(minLength: 6)
            Button(action: onClose) {
                railIcon("xmark", selected: false, disabled: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close mirror")
            .accessibilityHint("Disconnect and close the mirror")
            .help("Close mirror")
            .simultaneousGesture(longPress("Close mirror and disconnect"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .mirrorGlassBackground(cornerRadius: 24)
        .shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mirror controls")
    }

    private func groupButton(_ group: MirrorControlGroup) -> some View {
        let isOpen = openGroup == group
        return Button {
            withAnimation(.snappy(duration: 0.26)) {
                openGroup = isOpen ? nil : group
            }
        } label: {
            railIcon(
                group == .mode ? activeModeIcon : group.icon,
                selected: isOpen || groupActive(group),
                disabled: false
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.title)
        .accessibilityHint(group.hint)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .help(group.hint)
        .simultaneousGesture(longPress(group.hint))
    }

    private func groupActive(_ group: MirrorControlGroup) -> Bool {
        switch group {
        case .mode: return interactionMode != .view
        case .zoom: return isZoomed || smartZoomMode != .off
        case .scroll: return edgeScrollEnabled || hardwareScrollEnabled
        case .keyboard: return isTyping
        case .screen: return statsVisible || cursorStyle == .hidden
        }
    }

    // MARK: - Shelf (cascading group contents)

    private func shelf(for group: MirrorControlGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                shelfTitle(group.title)
                shelfContent(for: group)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .mirrorGlassBackground(cornerRadius: 22)
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title) options")
    }

    @ViewBuilder
    private func shelfContent(for group: MirrorControlGroup) -> some View {
        switch group {
        case .mode: modeShelf
        case .zoom: zoomShelf
        case .scroll: scrollShelf
        case .keyboard: keyboardShelf
        case .screen: screenShelf
        }
    }

    @ViewBuilder
    private var modeShelf: some View {
        leafButton(
            "hand.draw", label: "View mode",
            hint: "View only — pan and zoom without controlling the Mac",
            selected: interactionMode == .view, collapsesShelf: true
        ) {
            withAnimation(.snappy) {
                interactionMode = .view
                isTyping = false
            }
        }
        leafButton(
            "target", label: "Agent Co-Pilot",
            hint: "Tap a target and the agent acts on it for you",
            selected: interactionMode == .coPilot,
            disabled: controlInputEnabled == false, collapsesShelf: true
        ) {
            guard controlInputEnabled else { return }
            withAnimation(.snappy) {
                interactionMode = .coPilot
                isTyping = false
                coPilotTarget = nil
            }
        }
        if controlInputEnabled, controlStatus.isLive == false {
            leafButton(
                "person.badge.key", label: "Trust this iPhone",
                hint: "Authorize this iPhone to control the Mac",
                collapsesShelf: true, action: onTrustControlDevice
            )
        }
        leafButton(
            controlInputEnabled ? "cursorarrow.click.2" : "lock",
            label: controlStatus.label,
            hint: "Direct control — tap and drag controls the Mac pointer",
            selected: interactionMode == .control,
            disabled: controlInputEnabled == false, collapsesShelf: true
        ) {
            guard controlInputEnabled else { return }
            withAnimation(.snappy) {
                interactionMode = .control
                isTyping = false
            }
        }
        leafButton(
            "rectangle.and.hand.point.up.left", label: "Trackpad mode",
            hint: "Trackpad — relative pointer movement like a laptop",
            selected: interactionMode == .trackpad,
            disabled: controlInputEnabled == false, collapsesShelf: true
        ) {
            guard controlInputEnabled else { return }
            withAnimation(.snappy) {
                interactionMode = .trackpad
                isTyping = false
            }
        }
    }

    @ViewBuilder
    private var zoomShelf: some View {
        leafButton(
            "plus.magnifyingglass", label: "Zoom in",
            hint: "Zoom into the mirrored screen", action: zoomIn
        )
        leafButton(
            "minus.magnifyingglass", label: "Zoom out",
            hint: "Zoom back out", disabled: isZoomed == false, action: zoomOut
        )
        if isZoomed {
            leafButton(
                "arrow.counterclockwise", label: "Reset zoom",
                hint: "Return to fit-to-screen", action: resetZoom
            )
        }
        smartZoomMenu
    }

    @ViewBuilder
    private var scrollShelf: some View {
        leafButton(
            "chevron.up", label: "Scroll up", hint: "Scroll up a little",
            disabled: controlInputEnabled == false
        ) { sendScrollButton(-0.22) }
        leafButton(
            "chevron.down", label: "Scroll down", hint: "Scroll down a little",
            disabled: controlInputEnabled == false
        ) { sendScrollButton(0.22) }
        leafButton(
            "arrow.up.to.line", label: "Page up", hint: "Scroll up a full page",
            disabled: controlInputEnabled == false
        ) { sendScrollButton(-0.45) }
        leafButton(
            "arrow.down.to.line", label: "Page down", hint: "Scroll down a full page",
            disabled: controlInputEnabled == false
        ) { sendScrollButton(0.45) }
        leafToggle(
            "arrow.left.and.right", label: "Edge scroll",
            hint: "Scroll by dragging near the screen edges", isOn: $edgeScrollEnabled
        )
        leafToggle(
            "speaker.wave.2", label: "Volume scroll",
            hint: "Use the hardware volume buttons to scroll", isOn: $hardwareScrollEnabled
        )
    }

    @ViewBuilder
    private var keyboardShelf: some View {
        leafButton(
            "keyboard", label: "Type on Mac",
            hint: "Open the keyboard and type on the Mac",
            selected: isTyping, disabled: controlInputEnabled == false
        ) {
            guard controlInputEnabled else { return }
            withAnimation(.snappy) {
                interactionMode = .control
                isTyping.toggle()
            }
            if isTyping { focusTyping() }
        }
        leafButton(
            "doc.on.clipboard", label: "To Mac",
            hint: "Send this iPhone's clipboard to the Mac",
            disabled: controlInputEnabled == false, action: pasteClipboardToMac
        )
        leafButton(
            "arrow.down.doc", label: "From Mac",
            hint: "Copy the Mac's clipboard to this iPhone",
            disabled: controlInputEnabled == false, action: grabClipboardFromMac
        )
    }

    @ViewBuilder
    private var screenShelf: some View {
        displayButton
        cursorMenu
        leafToggle(
            "waveform.path.ecg", label: "Performance stats",
            hint: "Show the bitrate and latency overlay", isOn: $statsVisible
        )
    }

    // MARK: - Status strip

    @ViewBuilder
    private var statusStrip: some View {
        if statsVisible || controlStatus.detail != nil {
            HStack(spacing: 8) {
                if statsVisible {
                    compactStats
                }
                if let detail = controlStatus.detail {
                    compactControlStatus(detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    // MARK: - Tooltip (tap and hold)

    @ViewBuilder
    private var tooltipBubble: some View {
        if let tooltip {
            Text(tooltip)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: -54)
                .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func longPress(_ text: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            presentTooltip(text)
        }
    }

    private func presentTooltip(_ text: String) {
        withAnimation(.snappy(duration: 0.2)) { tooltip = text }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // MARK: - Leaf controls

    private func leafButton(
        _ systemName: String,
        label: String,
        hint: String,
        selected: Bool = false,
        disabled: Bool = false,
        collapsesShelf: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            if collapsesShelf {
                withAnimation(.snappy(duration: 0.26)) { openGroup = nil }
            }
        } label: {
            railIcon(systemName, selected: selected, disabled: disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .help(hint)
        .simultaneousGesture(longPress(hint))
    }

    private func leafToggle(
        _ systemName: String,
        label: String,
        hint: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            railIcon(systemName, selected: isOn.wrappedValue, disabled: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityHint(hint)
        .help(hint)
        .simultaneousGesture(longPress(hint))
    }

    private func shelfTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 10)
            .frame(height: 42)
            .accessibilityHidden(true)
    }

    private var fallbackDisplays: [HermesRealtimeRelayDisplayDescriptor] {
        [HermesRealtimeRelayDisplayDescriptor(id: selectedDisplayId ?? "main", name: "Main Display", width: 0, height: 0, isPrimary: true)]
    }

    private var activeModeIcon: String {
        switch interactionMode {
        case .view:
            return "hand.draw"
        case .coPilot:
            return "target"
        case .control:
            return controlInputEnabled ? "cursorarrow.click.2" : "lock"
        case .trackpad:
            return "rectangle.and.hand.point.up.left"
        }
    }

    private var compactStats: some View {
        let mbps = Double(stats.bitsPerSecond) / 1_000_000.0
        return HStack(spacing: 8) {
            Text(String(format: "%.2f Mbps", mbps))
            Text("RTT \(stats.roundTripMillis) ms")
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.white.opacity(0.10), in: Capsule())
        .accessibilityLabel("Performance \(String(format: "%.2f megabits per second", mbps)), round trip \(stats.roundTripMillis) milliseconds")
    }

    private func compactControlStatus(_ message: String) -> some View {
        Text(shortControlMessage(message))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.white.opacity(0.10), in: Capsule())
            .accessibilityLabel(message)
    }

    private func shortControlMessage(_ message: String) -> String {
        guard message.count > 72 else { return message }
        return String(message.prefix(69)) + "..."
    }

    private var displayOptions: [HermesRealtimeRelayDisplayDescriptor] {
        displays.isEmpty ? fallbackDisplays : displays
    }

    private var selectedDisplayIndex: Int {
        displayOptions.firstIndex {
            $0.id == selectedDisplayId || (selectedDisplayId == nil && $0.isPrimary)
        } ?? 0
    }

    private var displayButton: some View {
        let isDisabled = displayOptions.count <= 1
        return Button {
            guard !isDisabled else { return }
            let nextIndex = (selectedDisplayIndex + 1) % displayOptions.count
            selectDisplay(displayOptions[nextIndex].id)
        } label: {
            railIcon("rectangle.connected.to.line.below", selected: displayOptions.count > 1, disabled: isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contextMenu {
            ForEach(displayOptions) { display in
                Button {
                    selectDisplay(display.id)
                } label: {
                    Label(display.name, systemImage: display.id == selectedDisplayId || (selectedDisplayId == nil && display.isPrimary) ? "checkmark.display" : "display")
                }
            }
        }
        .help(isDisabled ? "One display available" : "Switch display — long-press to choose")
        .accessibilityLabel(isDisabled ? "One display available" : "Switch display")
    }

    private var cursorMenu: some View {
        Menu {
            ForEach(MirrorCursorStyle.allCases) { style in
                Button {
                    cursorStyle = style
                } label: {
                    Label(style.label, systemImage: cursorIcon(for: style))
                }
            }
            Button {
                cursorSize = max(18, cursorSize - 4)
            } label: {
                Label("Smaller cursor", systemImage: "minus.magnifyingglass")
            }
            Button {
                cursorSize = min(42, cursorSize + 4)
            } label: {
                Label("Larger cursor", systemImage: "plus.magnifyingglass")
            }
        } label: {
            railIcon(cursorIcon(for: cursorStyle), selected: interactionMode != .view && cursorStyle != .hidden, disabled: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Cursor style and size")
        .accessibilityLabel("Cursor options")
    }

    private func cursorIcon(for style: MirrorCursorStyle) -> String {
        switch style {
        case .mercury, .ember, .aurora, .white: return "cursorarrow"
        case .hidden: return "cursorarrow.slash"
        }
    }

    private var smartZoomMenu: some View {
        Menu {
            ForEach(SmartZoomMode.allCases) { mode in
                Button {
                    setSmartZoomMode(mode)
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                railIcon(
                    smartZoomMode.systemImage,
                    selected: smartZoomMode != .off,
                    disabled: false
                )
                if smartZoomAutoFollowing {
                    Text("Smart")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.17, green: 0.79, blue: 0.75),
                                            Color(red: 0.56, green: 0.50, blue: 0.85)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .offset(x: -2, y: -2)
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Smart Zoom: \(smartZoomMode.label)")
        .accessibilityLabel("Smart Zoom: \(smartZoomMode.label)")
        .accessibilityValue(smartZoomAutoFollowing ? "Auto-following" : "Idle")
    }

    private func railIcon(_ systemName: String, selected: Bool, disabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(selected ? .white : .white.opacity(disabled ? 0.35 : 0.85))
            .frame(width: 42, height: 42)
            .background(
                ZStack {
                    if selected {
                        // High-end active glass keycap
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)

                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .shadow(color: Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.5), radius: 6)
                    } else {
                        // Subtle standard glass keycap
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(disabled ? 0.03 : 0.08))

                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                }
            )
            .shadow(color: selected ? Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.15) : Color.black.opacity(0.1), radius: 4)
    }
}

private struct TapFeedbackMarker: View {
    let point: CGPoint
    @State private var bloomAngle: Double = 0
    @State private var animScale: CGFloat = 0.5
    @State private var animOpacity: Double = 1.0

    var body: some View {
        ZStack {
            // Concentric ring 1
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.17, green: 0.79, blue: 0.75), .white],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 44, height: 44)
                .scaleEffect(animScale)
                .opacity(animOpacity)

            // Concentric ring 2
            Circle()
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                .frame(width: 24, height: 24)
                .scaleEffect(animScale * 0.7)
                .opacity(animOpacity * 0.8)

            // Center dot
            Circle()
                .fill(Color(red: 0.17, green: 0.79, blue: 0.75))
                .frame(width: 8, height: 8)
                .shadow(color: Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.6), radius: 4)
        }
        .position(point)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                animScale = 1.2
                animOpacity = 0.0
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CoPilotTargetRing: View {
    let point: CGPoint
    @State private var animScale: CGFloat = 0.6
    @State private var animPulse: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Outermost target ring
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.red, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 48, height: 48)
                .scaleEffect(animScale)

            // Reticle lines (crosshairs)
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: 16)
                .offset(y: -16)

            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: 16)
                .offset(y: 16)

            Rectangle()
                .fill(Color.red)
                .frame(width: 16, height: 2)
                .offset(x: -16)

            Rectangle()
                .fill(Color.red)
                .frame(width: 16, height: 2)
                .offset(x: 16)

            // Inner pulsing ring
            Circle()
                .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
                .frame(width: 28, height: 28)
                .scaleEffect(animPulse)

            // Center core dot
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .shadow(color: .red.opacity(0.8), radius: 4)
        }
        .position(point)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                animScale = 1.0
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                animPulse = 1.25
            }
        }
        .accessibilityHidden(true)
    }
}

struct CyberCursorArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scaleX = rect.width / 24.0
        let scaleY = rect.height / 24.0

        path.move(to: CGPoint(x: 0 * scaleX, y: 0 * scaleY))
        path.addLine(to: CGPoint(x: 18 * scaleX, y: 13 * scaleY))
        path.addLine(to: CGPoint(x: 10 * scaleX, y: 14 * scaleY))
        path.addLine(to: CGPoint(x: 15 * scaleX, y: 23 * scaleY))
        path.addLine(to: CGPoint(x: 12 * scaleX, y: 24 * scaleY))
        path.addLine(to: CGPoint(x: 7 * scaleX, y: 15 * scaleY))
        path.addLine(to: CGPoint(x: 0 * scaleX, y: 19 * scaleY))
        path.closeSubpath()

        return path
    }
}

private struct MirrorPointerCursor: View {
    let point: CGPoint
    let size: CGFloat
    let style: MirrorCursorStyle
    let usePremiumSOTAUX: Bool
    @State private var haloScale: CGFloat = 1.0

    var body: some View {
        Group {
            if usePremiumSOTAUX {
                ZStack(alignment: .topLeading) {
                    Circle()
                        .stroke(glowColor, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                        .scaleEffect(haloScale)
                        .opacity(Double(2.0 - haloScale))
                        .offset(x: -4, y: -4)

                    Circle()
                        .fill(glowColor)
                        .frame(width: 3, height: 3)
                        .offset(x: -1.5, y: -1.5)

                    CyberCursorArrow()
                        .fill(
                            LinearGradient(
                                colors: [.white, glowColor.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: size, height: size)
                        .overlay(
                            CyberCursorArrow()
                                .stroke(Color.white, lineWidth: 1.0)
                        )
                        .shadow(color: glowColor.opacity(0.5), radius: 6, x: 2, y: 2)
                }
                .frame(width: size, height: size)
                .offset(x: size / 2, y: size / 2)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                        haloScale = 2.0
                    }
                }
            } else {
                cursorGlyph
                    .font(.system(size: size, weight: .bold))
                    .shadow(color: glowColor.opacity(0.65), radius: 8, x: 0, y: 0)
                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
            }
        }
        .position(point)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.78, blendDuration: 0), value: point)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityHidden(true)
    }

    private var glowColor: Color {
        switch style {
        case .mercury: return Color(red: 0.17, green: 0.79, blue: 0.75) // neon teal glow
        case .ember: return Color(red: 0.91, green: 0.44, blue: 0.38)   // neon coral/ember glow
        case .aurora: return Color(red: 0.56, green: 0.50, blue: 0.85)  // neon purple glow
        case .white: return .white
        case .hidden: return .clear
        }
    }

    @ViewBuilder
    private var cursorGlyph: some View {
        switch style {
        case .mercury:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.17, green: 0.79, blue: 0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .ember:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.91, green: 0.44, blue: 0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .aurora:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.56, green: 0.50, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .white:
            Image(systemName: "cursorarrow")
                .foregroundStyle(.white)
        case .hidden:
            EmptyView()
        }
    }
}

private struct TrackpadGlassSurface: View {
    let isVisible: Bool
    let usePremiumSOTAUX: Bool
    let onActiveChange: (Bool) -> Void
    let onMove: (CGSize) -> Void
    let onClick: (Int) -> Void
    let onScroll: (Double) -> Void
    @State private var lastTranslation: CGSize = .zero
    @State private var pressStartedAt: Date?
    @State private var touchLocation: CGPoint? = nil
    @State private var touchHistory: [CGPoint] = []

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.46, 360)
            let height = min(proxy.size.height * 0.40, 260)

            ZStack {
                // Fine grid crosshairs in background
                trackpadGridPattern(width: width, height: height)

                // Trail ring representing current touch location
                if usePremiumSOTAUX {
                    ForEach(Array(touchHistory.enumerated()), id: \.offset) { index, point in
                        let age = CGFloat(touchHistory.count - 1 - index)
                        let opacity = 0.8 * (1.0 - age * 0.22)
                        let scale = 1.0 - age * 0.15
                        let frameSize = 24.0 * scale
                        if frameSize > 2 {
                            Circle()
                                .stroke(Color(red: 0.17, green: 0.79, blue: 0.75).opacity(Double(opacity)), lineWidth: max(0.5, 1.5 - age * 0.2))
                                .frame(width: frameSize, height: frameSize)
                                .position(point)
                        }
                    }
                } else {
                    if let touchLocation {
                        Circle()
                            .stroke(Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.8), lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                            .position(touchLocation)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(width: width, height: height)
            .mirrorGlassBackground(cornerRadius: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: touchLocation != nil ? [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)] : [.white.opacity(0.15), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .animation(.easeInOut(duration: 0.25), value: touchLocation != nil)
            )
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Glass Trackpad")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(16)
            }
            .opacity(isVisible ? 1 : 0.001)
            .position(x: proxy.size.width - width / 2 - 18, y: proxy.size.height - height / 2 - 34)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if pressStartedAt == nil {
                            pressStartedAt = Date()
                        }
                        touchLocation = value.location
                        if usePremiumSOTAUX {
                            touchHistory.append(value.location)
                            if touchHistory.count > 4 {
                                touchHistory.removeFirst()
                            }
                        }
                        onActiveChange(true)
                        let delta = value.translation - lastTranslation
                        lastTranslation = value.translation
                        if abs(delta.width) > 0.5 || abs(delta.height) > 0.5 {
                            onMove(delta)
                        }
                    }
                    .onEnded { value in
                        touchLocation = nil
                        touchHistory.removeAll()
                        let heldDuration = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                        pressStartedAt = nil
                        let distance = hypot(value.translation.width, value.translation.height)
                        if let mouseButton = ScreenShareControlInputPolicy.trackpadClickMouseButton(
                            heldDuration: heldDuration,
                            travelDistance: distance
                        ) {
                            if mouseButton == 1 {
                                triggerLightHaptic()
                            } else {
                                triggerMediumHaptic()
                            }
                            onClick(mouseButton)
                        } else if abs(value.translation.height) > abs(value.translation.width) * 1.5 {
                            onScroll(Double(value.translation.height / max(proxy.size.height, 1)))
                        }
                        lastTranslation = .zero
                        onActiveChange(false)
                    }
            )
        }
        .ignoresSafeArea()
    }

    private func triggerLightHaptic() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    private func triggerMediumHaptic() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    @ViewBuilder
    private func trackpadGridPattern(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // Thin horizontal lines
            VStack(spacing: height / 6) {
                ForEach(0..<5) { _ in
                    Divider()
                        .background(Color.white.opacity(0.04))
                }
            }
            .frame(width: width, height: height)

            // Thin vertical lines
            HStack(spacing: width / 6) {
                ForEach(0..<5) { _ in
                    Divider()
                        .background(Color.white.opacity(0.04))
                }
            }
            .frame(width: width, height: height)
        }
    }
}

private struct StreamStateOverlay: View {
    let phase: MediaControlStreamCoordinator.Phase
    let isAwaitingFrame: Bool
    let usePremiumSOTAUX: Bool
    let reconnectAttemptStartedAt: Date?
    let lastFailureReason: String?
    let lastLiveAt: Date?
    let onForceReconnect: () -> Void
    let onRetryRequest: () -> Void
    let onClose: () -> Void

    /// Wall-clock anchor for the "Awaiting first video frame" stretch.
    /// Set the first time the overlay observes `.live + isAwaitingFrame`;
    /// after `Self.awaitingFrameWatchdog` seconds elapse, the overlay
    /// shows the recoverable "Mac isn't sending frames" state, fires one
    /// automatic restart, and leaves manual recovery controls available.
    @State private var awaitingFrameSince: Date?
    @State private var automaticRetryTask: Task<Void, Never>?

    @State private var spinAngle: Double = 0
    @State private var textIndex = 0
    @State private var pulseScale: CGFloat = 1.0
    private static let awaitingFrameWatchdog: TimeInterval = 8.0
    private let statusTexts = [
        "Connecting to paired Mac control stream...",
        "Negotiating VideoToolbox hardware codecs...",
        "Synchronizing GOP keyframes...",
        "Awaiting first video frame..."
    ]

    var body: some View {
        ZStack {
            // Blurred dark overlay behind
            Color.black.opacity(0.6)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                switch phase {
                case .idle, .dialing:
                    connectingContent(title: "Mercury Link", detail: statusTexts[textIndex])

                case .live:
                    if isAwaitingFrame {
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            if let since = awaitingFrameSince,
                               context.date.timeIntervalSince(since) >= Self.awaitingFrameWatchdog {
                                stuckFrameContent(stuckSince: since, now: context.date)
                            } else {
                                connectingContent(title: "Mercury Live", detail: "Awaiting first video frame...")
                            }
                        }
                    } else {
                        EmptyView()
                    }

                case .reconnecting(let nextAttemptIn):
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        reconnectingContent(
                            nextAttemptIn: nextAttemptIn,
                            now: context.date
                        )
                    }

                case .failed(let reason):
                    failedContent(reason: reason)

                case .stopped:
                    stoppedContent()
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 380)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .white.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
            )
            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
        .onAppear {
            startTextRotation()
            if isAwaitingLiveFrame {
                startAwaitingFrameWatchdog()
            }
        }
        .onChange(of: isAwaitingLiveFrame) { _, awaiting in
            if awaiting {
                startAwaitingFrameWatchdog()
            } else {
                stopAwaitingFrameWatchdog()
            }
        }
        .onDisappear {
            stopAwaitingFrameWatchdog()
        }
    }

    private var isAwaitingLiveFrame: Bool {
        if case .live = phase, isAwaitingFrame { return true }
        return false
    }

    // MARK: - Connecting State
    @ViewBuilder
    private func connectingContent(title: String, detail: String) -> some View {
        VStack(spacing: 20) {
            if usePremiumSOTAUX {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 1.5)
                        .frame(width: 76, height: 76)
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [15, 8])
                        )
                        .frame(width: 76, height: 76)
                        .rotationEffect(.degrees(spinAngle))

                    Circle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 1.5)
                        .frame(width: 52, height: 52)
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color(red: 0.56, green: 0.50, blue: 0.85), Color(red: 0.91, green: 0.44, blue: 0.38)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [10, 6])
                        )
                        .frame(width: 52, height: 52)
                        .rotationEffect(.degrees(-spinAngle * 1.3))

                    Circle()
                        .fill(Color(red: 0.17, green: 0.79, blue: 0.75))
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulseScale)
                        .opacity(Double(2.0 - pulseScale))
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                pulseScale = 1.6
                            }
                        }

                    Circle()
                        .fill(Color(red: 0.17, green: 0.79, blue: 0.75))
                        .frame(width: 10, height: 10)
                }
                .onAppear {
                    withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) {
                        spinAngle = 360
                    }
                }
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 4)
                        .frame(width: 64, height: 64)

                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(spinAngle))
                        .onAppear {
                            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                                spinAngle = 360
                            }
                        }
                }
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(detail)
            }
        }
    }

    // MARK: - Reconnecting State
    @ViewBuilder
    private func reconnectingContent(nextAttemptIn: TimeInterval, now: Date) -> some View {
        let elapsed = reconnectAttemptStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let remaining = max(0, nextAttemptIn - elapsed)
        let lastSeenSeconds = lastLiveAt.map { Int(now.timeIntervalSince($0)) }

        VStack(spacing: 20) {
            Image(systemName: "wifi.router.dashed")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .yellow],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating)
                .shadow(color: .orange.opacity(0.3), radius: 8)

            VStack(spacing: 8) {
                Text("Connection Lost")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(remaining > 0.2
                     ? "Mercury lost contact with the Mac.\nRetrying automatically in \(String(format: "%.1f", remaining))s..."
                     : "Mercury lost contact with the Mac.\nRetrying now...")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)

                if let reason = lastFailureReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.top, 2)
                }

                if let secs = lastSeenSeconds, secs > 0 {
                    Text("Last seen \(formattedRelative(seconds: secs)) ago")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 2)
                }
            }

            VStack(spacing: 12) {
                Button(action: onForceReconnect) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Force Reconnect Now")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        }
                    )
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Text("Close Mirror")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func stuckFrameContent(stuckSince: Date, now: Date) -> some View {
        let stuckSeconds = Int(now.timeIntervalSince(stuckSince))
        VStack(spacing: 20) {
            Image(systemName: "tv.slash")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating)
                .shadow(color: .yellow.opacity(0.3), radius: 8)

            VStack(spacing: 8) {
                Text("Mac isn't sending frames")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("The control stream is live, but no video has arrived in \(stuckSeconds)s. Mercury is restarting the mirror automatically.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button(action: onRetryRequest) {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("Restart Mirror")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        }
                    )
                }
                .buttonStyle(.plain)

                Button(action: onForceReconnect) {
                    Text("Force Reconnect")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Text("Close Mirror")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
    }

    private func formattedRelative(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    // MARK: - Failed State
    @ViewBuilder
    private func failedContent(reason: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.red, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating)
                .shadow(color: .red.opacity(0.3), radius: 8)

            VStack(spacing: 8) {
                Text("Connection Failed")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(reason)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button(action: onRetryRequest) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry Mirror Request")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.red, .orange],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        }
                    )
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Text("Close Mirror")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Stopped State
    @ViewBuilder
    private func stoppedContent() -> some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))

            VStack(spacing: 8) {
                Text("Session Terminated")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("The Mac screen sharing session has ended or is unavailable.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            Button(action: onClose) {
                Text("Close Mirror")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }

    private func startTextRotation() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard phase == .idle || phase == .dialing || (phase == .live && isAwaitingFrame) else { continue }
                withAnimation(.easeInOut(duration: 0.5)) {
                    textIndex = (textIndex + 1) % statusTexts.count
                }
            }
        }
    }

    private func startAwaitingFrameWatchdog() {
        awaitingFrameSince = Date()
        automaticRetryTask?.cancel()
        automaticRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.awaitingFrameWatchdog * 1_000_000_000))
            guard !Task.isCancelled, isAwaitingLiveFrame else { return }
            onRetryRequest()
        }
    }

    private func stopAwaitingFrameWatchdog() {
        awaitingFrameSince = nil
        automaticRetryTask?.cancel()
        automaticRetryTask = nil
    }
}

private struct VolumeButtonScrollBridge: UIViewRepresentable {
    let onVolumeStep: @MainActor (Double) -> Void

    func makeUIView(context: Context) -> MPVolumeView {
        try? AVAudioSession.sharedInstance().setActive(true)
        let view = MPVolumeView(frame: .zero)
        view.isHidden = true
        context.coordinator.start(onVolumeStep: onVolumeStep)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        context.coordinator.onVolumeStep = onVolumeStep
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, @unchecked Sendable {
        var onVolumeStep: (@MainActor (Double) -> Void)?
        private var observation: NSKeyValueObservation?
        private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume

        func start(onVolumeStep: @escaping @MainActor (Double) -> Void) {
            self.onVolumeStep = onVolumeStep
            lastVolume = AVAudioSession.sharedInstance().outputVolume
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let self, let newValue = change.newValue else { return }
                let delta = newValue - self.lastVolume
                self.lastVolume = newValue
                guard abs(delta) > 0.001 else { return }
                let callback = SendableVolumeStepCallback(self.onVolumeStep)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        callback.call(delta > 0 ? -0.28 : 0.28)
                    }
                }
            }
        }
    }
}

private struct SendableVolumeStepCallback: @unchecked Sendable {
    private let callback: (@MainActor (Double) -> Void)?

    init(_ callback: (@MainActor (Double) -> Void)?) {
        self.callback = callback
    }

    @MainActor
    func call(_ value: Double) {
        callback?(value)
    }
}

private extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }

    static func - (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width - rhs.width, height: lhs.height - rhs.height)
    }
}

private extension View {
    @ViewBuilder
    func mirrorGlassBackground(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background(.clear)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
        }
    }
}

struct ScreenShareViewerPerformanceStats: Equatable, Sendable {
    var resolution: String = ""
    var codec: String = ""
    var bitsPerSecond: Int = 0
    var roundTripMillis: Int = 0
}

struct ScreenShareViewerStatsMeter: Sendable {
    private var windowStartedAt: Date?
    private var bytesInWindow: Int = 0
    private var lastStats = ScreenShareViewerPerformanceStats()
    private let minimumSampleInterval: TimeInterval

    init(minimumSampleInterval: TimeInterval = 0.5) {
        self.minimumSampleInterval = minimumSampleInterval
    }

    mutating func recordFrame(
        byteCount: Int,
        now: Date = Date(),
        codec: String? = nil,
        resolution: String? = nil
    ) -> ScreenShareViewerPerformanceStats {
        if windowStartedAt == nil {
            windowStartedAt = now
        }
        bytesInWindow += max(byteCount, 0)

        var next = lastStats
        if let codec, !codec.isEmpty {
            next.codec = codec
        }
        if let resolution, !resolution.isEmpty {
            next.resolution = resolution
        }

        let elapsed = max(0, now.timeIntervalSince(windowStartedAt ?? now))
        if elapsed >= minimumSampleInterval {
            next.bitsPerSecond = Int((Double(bytesInWindow) * 8.0 / elapsed).rounded())
            windowStartedAt = now
            bytesInWindow = 0
        }

        lastStats = next
        return next
    }

    mutating func updateRoundTripMillis(_ roundTripMillis: Int) -> ScreenShareViewerPerformanceStats {
        lastStats.roundTripMillis = max(0, roundTripMillis)
        return lastStats
    }
}

@MainActor
final class ScreenShareViewerCoordinator: ObservableObject {
    typealias Stats = ScreenShareViewerPerformanceStats

    let displayLayer: AVSampleBufferDisplayLayer
    @Published var lastStats: Stats = Stats()
    @Published var displayAspectRatio: CGFloat?
    @Published var latestFocusContext: ScreenShareSmartZoomContext?
    var longTermReferenceTokenHandler: ((MercuryLTRToken) async -> Void)?
    private var pipeline: VideoReceivePipeline?
    private var statsMeter = ScreenShareViewerStatsMeter()

    func ingest(focusContext: HermesRealtimeRelayFocusContext) {
        guard let context = ScreenShareSmartZoomContext.from(focusContext) else { return }
        latestFocusContext = context
    }

    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer
        self.pipeline = makePipeline()
    }

    func resetForNewMirror() {
        displayLayer.flushAndRemoveImage()
        lastStats = Stats()
        displayAspectRatio = nil
        latestFocusContext = nil
        statsMeter = ScreenShareViewerStatsMeter()
        pipeline = makePipeline()
    }

    private func makePipeline() -> VideoReceivePipeline {
        VideoReceivePipeline { [weak self] sampleBuffer in
            await MainActor.run {
                self?.enqueue(sampleBuffer: sampleBuffer)
            }
        } onLongTermReferenceTokenDecoded: { [weak self] token in
            await self?.longTermReferenceTokenHandler?(token)
        }
    }

    func enqueue(sampleBuffer: CMSampleBuffer) {
        var resolution: String?
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let width = CGFloat(dimensions.width)
            let height = CGFloat(dimensions.height)
            if width > 0, height > 0 {
                resolution = "\(Int(width))x\(Int(height))"
                let aspectRatio = width / height
                if displayAspectRatio.map({ abs($0 - aspectRatio) > 0.0001 }) ?? true {
                    displayAspectRatio = aspectRatio
                }
            }
        }
        if let resolution, lastStats.resolution != resolution {
            var stats = lastStats
            stats.resolution = resolution
            lastStats = stats
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func ingest(frame: MediaFrame) async {
        recordIncomingFrame(byteCount: Self.estimatedWireByteCount(for: frame), codec: "HEVC")
        do {
            try await pipeline?.ingest(frame: frame)
        } catch {
            displayLayer.flush()
        }
    }

    func ingest(frameV2: MediaFrameV2) async {
        recordIncomingFrame(
            byteCount: Self.estimatedWireByteCount(for: frameV2),
            codec: Self.codecLabel(for: frameV2)
        )
        do {
            try await pipeline?.ingest(frameV2: frameV2)
        } catch {
            displayLayer.flush()
        }
    }

    func update(stats: Stats) {
        lastStats = stats
    }

    func update(roundTripMillis: Int) {
        lastStats = statsMeter.updateRoundTripMillis(roundTripMillis)
    }

    private func recordIncomingFrame(byteCount: Int, codec: String?) {
        lastStats = statsMeter.recordFrame(
            byteCount: byteCount,
            codec: codec,
            resolution: lastStats.resolution
        )
    }

    private static func estimatedWireByteCount(for frame: MediaFrame) -> Int {
        MediaFrame.headerByteCount
            + (frame.flags.contains(.hasCursorMetadata) ? MediaFrame.cursorMetadataByteCount : 0)
            + frame.payload.count
    }

    private static func estimatedWireByteCount(for frame: MediaFrameV2) -> Int {
        MediaFrameV2Codec.fixedHeaderByteCount + frame.metadata.count + frame.payload.count
    }

    private static func codecLabel(for frame: MediaFrameV2) -> String? {
        guard let metadata = try? MediaFrameV2Metadata.decode(frame.metadata),
              let codec = metadata.codec
        else { return nil }

        switch codec {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .av1: return "AV1"
        }
    }
}

private struct DisplayLayerHost: UIViewRepresentable {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator

    func makeUIView(context: Context) -> DisplayLayerView {
        let view = DisplayLayerView()
        view.attach(layer: coordinator.displayLayer)
        return view
    }

    func updateUIView(_ uiView: DisplayLayerView, context: Context) {
        // Layer reattachment handled internally; nothing to do per update.
    }
}

private final class DisplayLayerView: UIView {
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

private struct StatsOverlay: View {
    let stats: ScreenShareViewerCoordinator.Stats

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(stats.resolution).font(.system(size: 13, weight: .medium, design: .monospaced))
            Text("\(stats.codec) · \(formattedBitrate)").font(.system(size: 13, weight: .medium, design: .monospaced))
            Text("RTT \(stats.roundTripMillis) ms").font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.primary.opacity(0.85))
    }

    private var formattedBitrate: String {
        let mbps = Double(stats.bitsPerSecond) / 1_000_000.0
        return String(format: "%.2f Mbps", mbps)
    }
}
