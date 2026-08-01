import SwiftUI
@preconcurrency import AVKit
@preconcurrency import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

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
///
/// Split for size: the view's helpers live in
/// `ScreenShareViewerView+SmartZoom`, `+ControlInput`, and `+Layout`; supporting
/// subviews and pure policies live in sibling `ScreenShare*`,
/// `MirrorControlPanel`, and `TrackpadGlassSurface` files.
@MainActor
struct ScreenShareViewerView: View {
    static let smartTextFramingAnimation: Animation = .easeInOut(duration: 0.22)

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
    let remoteUnlockDiagnosticMessage: String?
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
    let requestRemoteUnlockSetup: () -> Void
    let onSelectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let onClose: () -> Void
    let usePremiumSOTAUX: Bool
    @State var statsVisible: Bool = false
    @State var viewport = ScreenShareViewportState()
    @AppStorage("mercurySmartZoomMode") var smartZoomModeRaw: String = SmartZoomMode.smart.rawValue
    @AppStorage("mercury.trackpadSensitivity") var trackpadSensitivity: Double = 1.0
    @AppStorage("mercury.smartTextDoubleTapLearned") var smartTextDoubleTapLearned = false
    @State var smartZoomManualOverrideUntil: Date?
    @State var smartZoomAutoFollowing: Bool = false
    @State var smartTextCoachVisible: Bool = false
    @State var keyboardHeight: CGFloat = 0
    @State var lastSmartTextNormalizedPoint: CGPoint?
    @State var lastSmartTextFocusedRect: HermesRealtimeRelayNormalizedRect?
    @State var lastSmartTextGestureStartedAt: Date?
    @State var deferredControlTapSmartZoomTask: Task<Void, Never>?
    @State var lastLayoutSize: CGSize?
    @State var interactionMode: ScreenShareInteractionMode = .view
    @State var isTyping = false
    @State var coPilotTarget: (normalizedX: Double, normalizedY: Double, viewPoint: CGPoint)?
    @State var coPilotInstruction: String = ""
    @State var coPilotRuntime: String = "hermes"
    @State var panelOffset = CGSize(width: -18, height: 18)
    @State var panelDragBase = CGSize(width: -18, height: 18)
    @State var edgeScrollEnabled = true
    @State var hardwareScrollEnabled = false
    @State var trackpadActive = false
    @State var panelCollapsed = true
    @State var controlPanTranslation: CGSize = .zero
    @State var tapFeedbackPoint: CGPoint?
    @State var lastControlClickPoint: CGPoint?
    @State var lastControlClickAt: Date?
    @State var controlPressStartedAt: Date?
    @State var pendingControlRightClickTask: Task<Void, Never>?
    @State var controlRightClickSentForCurrentPress = false
    @State var cursorPoint: CGPoint?
    @State var cursorSize: CGFloat = 24
    @State var cursorStyle: MirrorCursorStyle = .hidden
    @Binding var remoteUnlockPasswordDraft: String
    @GestureState var magnification: CGFloat = 1
    @GestureState var controlMagnification: CGFloat = 1
    @GestureState var dragTranslation: CGSize = .zero
    @State var typingFocusTask: Task<Void, Never>?

    var smartZoomMode: SmartZoomMode {
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
        remoteUnlockDiagnosticMessage: String? = nil,
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
        requestRemoteUnlockSetup: @escaping () -> Void = {},
        onSelectDisplay: @escaping (String) -> Void = { _ in },
        onTrustControlDevice: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        let resolvedControlInputEnabled = controlInputEnabled ?? controlStatus.isLive

        self.coordinator = coordinator
        self.resetToken = resetToken
        self.controlStatus = controlStatus
        self.controlInputEnabled = resolvedControlInputEnabled
        self._interactionMode = State(
            initialValue: ScreenShareInteractionModePolicy.defaultMode(
                controlInputEnabled: resolvedControlInputEnabled
            )
        )
        self.controlRoundTripMillis = controlRoundTripMillis
        self.displays = displays
        self.selectedDisplayId = selectedDisplayId
        self.streamPhase = streamPhase
        self.reconnectAttemptStartedAt = reconnectAttemptStartedAt
        self.lastFailureReason = lastFailureReason
        self.lastLiveAt = lastLiveAt
        self.remoteUnlockState = remoteUnlockState
        self.savedRemoteUnlockCredentialAvailable = savedRemoteUnlockCredentialAvailable
        self.remoteUnlockDiagnosticMessage = remoteUnlockDiagnosticMessage
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
        self.requestRemoteUnlockSetup = requestRemoteUnlockSetup
        self.onSelectDisplay = onSelectDisplay
        self.onTrustControlDevice = onTrustControlDevice
        self.onClose = onClose
    }

    var displayStats: ScreenShareViewerCoordinator.Stats {
        var stats = coordinator.lastStats
        if let controlRoundTripMillis {
            stats.roundTripMillis = controlRoundTripMillis
        }
        return stats
    }

    // remediation(1080p-hardcode): forward the selected display's real size from
    // the mirror handshake into the coordinator so the decoder's raw-payload
    // fallback no longer silently assumes 1080p. No-op when no descriptor matches.
    func forwardSelectedDisplayDimensions() {
        let descriptor = displays.first { $0.id == selectedDisplayId }
            ?? displays.first { $0.isPrimary }
            ?? displays.first
        guard let descriptor, descriptor.width > 0, descriptor.height > 0 else { return }
        coordinator.setExpectedSourceDimensions(width: descriptor.width, height: descriptor.height)
    }

    var activeRemoteUnlockState: HermesRealtimeRelayRemoteUnlockState? {
        guard let remoteUnlockState, remoteUnlockState.lockState != .unlocked else { return nil }
        return remoteUnlockState
    }

    var standardControlInputEnabled: Bool {
        controlInputEnabled
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
                let remoteUnlockActive = activeRemoteUnlockState != nil
                let streamIsLive = {
                    if case .live = streamPhase { return true }
                    return false
                }()

                DisplayLayerHost(coordinator: coordinator)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(visibleViewport.scale)
                    .offset(visibleViewport.offset)
                    .clipped()
                    .accessibilityElement()
                    .accessibilityIdentifier("mercury.screen.video")
                    .accessibilityLabel("Mac screen video")
                    .accessibilityValue(
                        coordinator.displayAspectRatio == nil
                            ? "Awaiting first frame"
                            : "Streaming"
                    )
                    .contentShape(Rectangle())
                    .gesture(viewportGesture(in: proxy.size))
                    .onTapGesture(count: 3) {
                        statsVisible.toggle()
                    }
                    .onTapGesture(count: 2) {
                        guard ScreenShareViewportGesturePolicy.allowsQuickZoom(interactionMode: interactionMode) else { return }
                        beginManualZoomOverride()
                        withAnimation(.snappy) {
                            viewport.toggleQuickZoom(in: proxy.size)
                        }
                    }
                    .onAppear {
                        viewport.reclamp(in: proxy.size)
                        lastLayoutSize = proxy.size
                        // remediation(1080p-hardcode): seed the decoder fallback
                        // dimensions from the handshake's selected display.
                        forwardSelectedDisplayDimensions()
                    }
                    .onChange(of: selectedDisplayId) { _, _ in
                        forwardSelectedDisplayDimensions()
                    }
                    .onChange(of: displays) { _, _ in
                        forwardSelectedDisplayDimensions()
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        viewport.reclamp(in: newSize)
                        lastLayoutSize = newSize
                        if isTyping || lastSmartTextNormalizedPoint != nil {
                            applyKeyboardAwareFraming()
                        } else {
                            applySmartZoomDecision(viewportSize: newSize, contentRect: renderedContentRect(in: newSize))
                        }
                    }
                    .animation(.snappy, value: viewport)

                if ScreenShareStreamStateOverlayPolicy.shouldShow(
                    displayAspectRatioKnown: coordinator.displayAspectRatio != nil,
                    streamIsLive: streamIsLive,
                    remoteUnlockActive: remoteUnlockActive
                ) {
                    StreamStateOverlay(
                        phase: streamPhase,
                        isAwaitingFrame: coordinator.displayAspectRatio == nil,
                        remoteUnlockActive: remoteUnlockActive,
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
                        sensitivity: $trackpadSensitivity,
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

                if !panelCollapsed {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                panelCollapsed = true
                            }
                        }
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
                    onClose: onClose,
                    screenSize: proxy.size
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                if let activeRemoteUnlockState {
                    RemoteUnlockStatusOverlay(
                        state: activeRemoteUnlockState,
                        password: $remoteUnlockPasswordDraft,
                        savedCredentialAvailable: savedRemoteUnlockCredentialAvailable,
                        diagnosticMessage: remoteUnlockDiagnosticMessage,
                        sendCredential: sendRemoteUnlockCredential,
                        saveCredential: saveRemoteUnlockCredential,
                        sendSavedCredential: sendSavedRemoteUnlockCredential,
                        deleteSavedCredential: deleteSavedRemoteUnlockCredential,
                        requestSetup: requestRemoteUnlockSetup,
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
                interactionMode = ScreenShareInteractionModePolicy.defaultMode(
                    controlInputEnabled: standardControlInputEnabled
                )
                isTyping = false
                controlPanTranslation = .zero
                tapFeedbackPoint = nil
                lastControlClickPoint = nil
                lastControlClickAt = nil
                lastSmartTextNormalizedPoint = nil
                lastSmartTextFocusedRect = nil
                lastSmartTextGestureStartedAt = nil
                deferredControlTapSmartZoomTask?.cancel()
                deferredControlTapSmartZoomTask = nil
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
                deferredControlTapSmartZoomTask?.cancel()
                deferredControlTapSmartZoomTask = nil
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
                lastSmartTextFocusedRect = nil
                lastSmartTextGestureStartedAt = nil
                deferredControlTapSmartZoomTask?.cancel()
                deferredControlTapSmartZoomTask = nil
            }
            recomputeSmartTextCoach()
        }
        .onChange(of: coordinator.latestFocusContext) { _, _ in
            if isTyping || lastSmartTextNormalizedPoint != nil {
                applyKeyboardAwareFraming()
            } else if ScreenShareSmartTextTargetPolicy.shouldDeferGenericSmartZoom(
                interactionMode: interactionMode,
                lastControlClickAt: lastControlClickAt,
                now: Date()
            ) {
                // A first tap may become a double-tap; keep the viewport still so the
                // second tap is measured against the same content geometry.
            } else {
                applySmartZoomDecisionUsingCurrentLayout()
            }
            recomputeSmartTextCoach()
        }
        .onChange(of: interactionMode) { _, newValue in
            if newValue != .control {
                deferredControlTapSmartZoomTask?.cancel()
                deferredControlTapSmartZoomTask = nil
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
            deferredControlTapSmartZoomTask?.cancel()
            deferredControlTapSmartZoomTask = nil
            typingFocusTask?.cancel()
            typingFocusTask = nil
        }
    }
}
