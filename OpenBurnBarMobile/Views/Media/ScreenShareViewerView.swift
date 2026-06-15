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
@MainActor
struct ScreenShareViewerView: View {
    private static let smartTextFramingAnimation: Animation = .easeInOut(duration: 0.22)

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
    @State private var statsVisible: Bool = false
    @State private var viewport = ScreenShareViewportState()
    @AppStorage("mercurySmartZoomMode") private var smartZoomModeRaw: String = SmartZoomMode.smart.rawValue
    @AppStorage("mercury.trackpadSensitivity") private var trackpadSensitivity: Double = 1.0
    @AppStorage("mercury.smartTextDoubleTapLearned") private var smartTextDoubleTapLearned = false
    @State private var smartZoomManualOverrideUntil: Date?
    @State private var smartZoomAutoFollowing: Bool = false
    @State private var smartTextCoachVisible: Bool = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var lastSmartTextNormalizedPoint: CGPoint?
    @State private var lastSmartTextFocusedRect: HermesRealtimeRelayNormalizedRect?
    @State private var lastSmartTextGestureStartedAt: Date?
    @State private var deferredControlTapSmartZoomTask: Task<Void, Never>?
    @State private var lastLayoutSize: CGSize?
    @State private var interactionMode: ScreenShareInteractionMode = .view
    @State private var isTyping = false
    @State private var coPilotTarget: (normalizedX: Double, normalizedY: Double, viewPoint: CGPoint)?
    @State private var coPilotInstruction: String = ""
    @State private var coPilotRuntime: String = "hermes"
    @State private var panelOffset = CGSize(width: -18, height: 18)
    @State private var panelDragBase = CGSize(width: -18, height: 18)
    @State private var edgeScrollEnabled = true
    @State private var hardwareScrollEnabled = false
    @State private var trackpadActive = false
    @State private var panelCollapsed = true
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

    private var displayStats: ScreenShareViewerCoordinator.Stats {
        var stats = coordinator.lastStats
        if let controlRoundTripMillis {
            stats.roundTripMillis = controlRoundTripMillis
        }
        return stats
    }

    // remediation(1080p-hardcode): forward the selected display's real size from
    // the mirror handshake into the coordinator so the decoder's raw-payload
    // fallback no longer silently assumes 1080p. No-op when no descriptor matches.
    private func forwardSelectedDisplayDimensions() {
        let descriptor = displays.first { $0.id == selectedDisplayId }
            ?? displays.first { $0.isPrimary }
            ?? displays.first
        guard let descriptor, descriptor.width > 0, descriptor.height > 0 else { return }
        coordinator.setExpectedSourceDimensions(width: descriptor.width, height: descriptor.height)
    }

    private var activeRemoteUnlockState: HermesRealtimeRelayRemoteUnlockState? {
        guard let remoteUnlockState, remoteUnlockState.lockState != .unlocked else { return nil }
        return remoteUnlockState
    }

    private var standardControlInputEnabled: Bool {
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
        if let rect = activeTypingTargetRect() {
            lastSmartTextFocusedRect = rect
        }
        let target = ScreenShareSmartTextTargetPolicy.preferredTarget(
            focusedRect: lastSmartTextFocusedRect,
            tappedPoint: lastSmartTextNormalizedPoint
        )
        switch target {
        case .focusedRect(let rect):
            applyFocusedTextZoom(to: rect, in: size, contentRect: contentRect, bottomInset: inset)
        case .tappedPoint(let point):
            applyDoubleTapZoom(toNormalized: point, in: size, contentRect: contentRect, bottomInset: inset)
        case nil:
            guard isTyping else { return }
            // Keyboard opened without a specific target (e.g. the Type button): lift the
            // current framing above the keyboard so the top of the screen is used.
            withAnimation(Self.smartTextFramingAnimation) {
                viewport.offset = ScreenShareViewportState.clamp(
                    offset: CGSize(width: viewport.offset.width, height: -inset / 2),
                    scale: viewport.scale,
                    in: size,
                    bottomInset: inset
                )
            }
        }
    }

    private func applyFocusedTextZoom(to rect: HermesRealtimeRelayNormalizedRect, in size: CGSize, contentRect: CGRect, bottomInset: CGFloat) {
        guard size.width > 0, size.height > 0, contentRect.width > 0, contentRect.height > 0 else { return }
        let decision = ScreenShareSmartZoomReducer.fitRectDecision(
            normalizedRect: rect,
            viewportSize: size,
            contentRect: contentRect,
            fillRatio: ScreenShareSmartZoomReducer.textFillRatio,
            scaleRange: ScreenShareSmartZoomReducer.textScaleRange,
            bottomInset: bottomInset
        )
        applySmartTextDecision(decision)
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
        applySmartTextDecision(decision)
    }

    private func applySmartTextDecision(_ decision: ScreenShareSmartZoomReducer.Decision) {
        guard decision.isAutoFollowing else { return }
        guard ScreenShareSmartTextTargetPolicy.shouldApply(
            currentScale: viewport.scale,
            currentOffset: viewport.offset,
            nextScale: decision.scale,
            nextOffset: decision.offset
        ) else {
            smartZoomAutoFollowing = true
            return
        }
        withAnimation(Self.smartTextFramingAnimation) {
            viewport.scale = decision.scale
            viewport.offset = decision.offset
        }
        smartZoomAutoFollowing = true
    }

    private func activeTypingTargetRect(now: Date = Date()) -> HermesRealtimeRelayNormalizedRect? {
        guard isTyping,
              let rect = activeTextFocusRect(now: now, requireGestureFreshness: true) else {
            return nil
        }
        return rect
    }

    private func activeTextFocusRect(
        now: Date = Date(),
        requireGestureFreshness: Bool
    ) -> HermesRealtimeRelayNormalizedRect? {
        guard let context = coordinator.latestFocusContext,
              requireGestureFreshness == false ||
              ScreenShareSmartTextTargetPolicy.acceptsFocusContext(
                receivedAt: context.receivedAt,
                gestureStartedAt: lastSmartTextGestureStartedAt
              ),
              ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: context,
                selectedDisplayId: selectedDisplayId,
                now: now
              ),
              let rect = context.normalizedRect else {
            return nil
        }
        return rect
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
    private func triggerSmartTextDoubleTap(normalized target: CGPoint, in size: CGSize, contentRect: CGRect, gestureStartedAt: Date) {
        guard controlInputEnabled else { return }
        deferredControlTapSmartZoomTask?.cancel()
        deferredControlTapSmartZoomTask = nil
        smartTextDoubleTapLearned = true
        if smartTextCoachVisible {
            withAnimation(.snappy) { smartTextCoachVisible = false }
        }
        lastSmartTextGestureStartedAt = gestureStartedAt
        lastSmartTextFocusedRect = activeTextFocusRect(requireGestureFreshness: false)
        if size.width > 0, size.height > 0,
           contentRect.width > 0, contentRect.height > 0 {
            // The first frame uses the user's tapped point. The Mac's focused-element
            // rect then refines this to exact field geometry as soon as it arrives.
            lastSmartTextNormalizedPoint = target
        }
        interactionMode = .control
        isTyping = true
        applyKeyboardAwareFraming()
        focusTypingBar()
    }

    private func scheduleGenericSmartZoomAfterControlTap(_ tappedAt: Date) {
        deferredControlTapSmartZoomTask?.cancel()
        deferredControlTapSmartZoomTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ScreenShareSmartTextTargetPolicy.genericSmartZoomDelayNanoseconds)
            guard Task.isCancelled == false else { return }
            guard lastControlClickAt == tappedAt,
                  isTyping == false,
                  lastSmartTextNormalizedPoint == nil else {
                return
            }
            applySmartZoomDecisionUsingCurrentLayout()
        }
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
                        let doubleTapStartedAt = lastControlClickAt ?? tappedAt
                        deferredControlTapSmartZoomTask?.cancel()
                        deferredControlTapSmartZoomTask = nil
                        lastControlClickAt = nil
                        triggerSmartTextDoubleTap(
                            normalized: CGPoint(x: normalized.x, y: normalized.y),
                            in: size,
                            contentRect: contentRect,
                            gestureStartedAt: doubleTapStartedAt
                        )
                    } else {
                        lastControlClickAt = tappedAt
                        scheduleGenericSmartZoomAfterControlTap(tappedAt)
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
        interactionMode = .control
        if isTyping == false {
            isTyping = true
        }
        typingFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard Task.isCancelled == false else { return }
            interactionMode = .control
            if isTyping == false {
                isTyping = true
            }
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
                    // Material, not glass: this dismiss button is nested inside
                    // the coach-mark's own `.liquidGlassSurface` capsule below,
                    // and glass cannot sample other glass. Material-on-glass
                    // reads cleanly; a nested glass disc would punch through.
                    .background(.ultraThinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.vertical, 11)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .liquidGlassSurface(in: Capsule())
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
