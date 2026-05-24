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

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .live: return "Control"
        case .connecting: return "Connecting"
        case .unavailable: return "Read only"
        }
    }

    var detail: String? {
        switch self {
        case .live:
            return nil
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
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let streamPhase: MediaControlStreamCoordinator.Phase
    let reconnectAttemptStartedAt: Date?
    let lastFailureReason: String?
    let lastLiveAt: Date?
    let onForceReconnect: () -> Void
    let onRetryRequest: () -> Void
    let sendTapIntent: (Double, Double, Int) -> Void
    let sendScrollIntent: (Double, Double, Double, Double, String?) -> Void
    let sendPointerMoveIntent: (Double, Double) -> Void
    let sendPointerClickIntent: (Int) -> Void
    let sendTextIntent: (String) -> Void
    let sendShortcutIntent: (String, [String]) -> Void
    let onSelectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let onClose: () -> Void
    let usePremiumSOTAUX: Bool
    @State private var statsVisible: Bool = false
    @State private var viewport = ScreenShareViewportState()
    @State private var interactionMode: ScreenShareInteractionMode = .view
    @State private var isTyping = false
    @State private var panelOffset = CGSize(width: -18, height: 18)
    @State private var panelDragBase = CGSize(width: -18, height: 18)
    @State private var showingDisplayPicker = false
    @State private var showingScrollTools = false
    @State private var edgeScrollEnabled = true
    @State private var hardwareScrollEnabled = false
    @State private var trackpadActive = false
    @State private var panelCollapsed = false
    @State private var controlPanTranslation: CGSize = .zero
    @State private var tapFeedbackPoint: CGPoint?
    @State private var lastControlClickPoint: CGPoint?
    @State private var controlPressStartedAt: Date?
    @State private var cursorPoint: CGPoint?
    @State private var cursorSize: CGFloat = 24
    @State private var cursorStyle: MirrorCursorStyle = .hidden
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var controlMagnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var typingFocusTask: Task<Void, Never>?

    init(
        coordinator: ScreenShareViewerCoordinator,
        resetToken: String?,
        controlStatus: ScreenSharePhoneControlStatus = .unavailable("Phone control is not connected."),
        controlInputEnabled: Bool? = nil,
        displays: [HermesRealtimeRelayDisplayDescriptor] = [],
        selectedDisplayId: String? = nil,
        streamPhase: MediaControlStreamCoordinator.Phase = .live,
        reconnectAttemptStartedAt: Date? = nil,
        lastFailureReason: String? = nil,
        lastLiveAt: Date? = nil,
        usePremiumSOTAUX: Bool = false,
        onForceReconnect: @escaping () -> Void = {},
        onRetryRequest: @escaping () -> Void = {},
        sendTapIntent: @escaping (Double, Double, Int) -> Void = { _, _, _ in },
        sendScrollIntent: @escaping (Double, Double, Double, Double, String?) -> Void = { _, _, _, _, _ in },
        sendPointerMoveIntent: @escaping (Double, Double) -> Void = { _, _ in },
        sendPointerClickIntent: @escaping (Int) -> Void = { _ in },
        sendTextIntent: @escaping (String) -> Void = { _ in },
        sendShortcutIntent: @escaping (String, [String]) -> Void = { _, _ in },
        onSelectDisplay: @escaping (String) -> Void = { _ in },
        onTrustControlDevice: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.resetToken = resetToken
        self.controlStatus = controlStatus
        self.controlInputEnabled = controlInputEnabled ?? controlStatus.isLive
        self.displays = displays
        self.selectedDisplayId = selectedDisplayId
        self.streamPhase = streamPhase
        self.reconnectAttemptStartedAt = reconnectAttemptStartedAt
        self.lastFailureReason = lastFailureReason
        self.lastLiveAt = lastLiveAt
        self.usePremiumSOTAUX = usePremiumSOTAUX
        self.onForceReconnect = onForceReconnect
        self.onRetryRequest = onRetryRequest
        self.sendTapIntent = sendTapIntent
        self.sendScrollIntent = sendScrollIntent
        self.sendPointerMoveIntent = sendPointerMoveIntent
        self.sendPointerClickIntent = sendPointerClickIntent
        self.sendTextIntent = sendTextIntent
        self.sendShortcutIntent = sendShortcutIntent
        self.onSelectDisplay = onSelectDisplay
        self.onTrustControlDevice = onTrustControlDevice
        self.onClose = onClose
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
                        withAnimation(.snappy) {
                            viewport.toggleQuickZoom(in: proxy.size)
                        }
                    }
                    .onAppear {
                        viewport.reclamp(in: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        viewport.reclamp(in: newSize)
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

                if interactionMode == .control, controlInputEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(controlSurfaceGesture(in: proxy.size, contentRect: contentRect, viewport: visibleViewport))
                        .simultaneousGesture(controlMagnifyGesture(in: proxy.size))
                        .accessibilityLabel("Mac screen control surface")
                }

                if interactionMode == .trackpad, controlInputEnabled {
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

                if controlInputEnabled,
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

                if hardwareScrollEnabled, controlInputEnabled {
                    VolumeButtonScrollBridge { direction in
                        let endY = min(max(0.5 + direction, 0), 1)
                        sendScrollIntent(0.5, 0.5, 0.5, endY, selectedDisplayId)
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                }

                MirrorControlPanel(
                    interactionMode: $interactionMode,
                    isCollapsed: $panelCollapsed,
                    isTyping: $isTyping,
                    showingDisplayPicker: $showingDisplayPicker,
                    showingScrollTools: $showingScrollTools,
                    edgeScrollEnabled: $edgeScrollEnabled,
                    hardwareScrollEnabled: $hardwareScrollEnabled,
                    statsVisible: $statsVisible,
                    cursorSize: $cursorSize,
                    cursorStyle: $cursorStyle,
                    stats: coordinator.lastStats,
                    controlStatus: controlStatus,
                    controlInputEnabled: controlInputEnabled,
                    displays: displays,
                    selectedDisplayId: selectedDisplayId,
                    isZoomed: viewport.isZoomed,
                    zoomIn: {
                        withAnimation(.snappy) { viewport.zoom(by: 1.25, in: proxy.size) }
                    },
                    zoomOut: {
                        withAnimation(.snappy) { viewport.zoom(by: 0.8, in: proxy.size) }
                    },
                    resetZoom: {
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
                    onClose: onClose
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .bottomLeading) {
            remoteKeyboardCapture
        }
        .onChange(of: resetToken) { _, _ in
            withAnimation(.snappy) {
                viewport.reset()
                interactionMode = .view
                isTyping = false
                controlPanTranslation = .zero
                tapFeedbackPoint = nil
                lastControlClickPoint = nil
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
            }
        }
        .onChange(of: isTyping) { _, newValue in
            if newValue {
                focusTypingBar()
            } else {
                typingFocusTask?.cancel()
                typingFocusTask = nil
            }
        }
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
                    viewport.applyMagnification(value.magnification, in: size)
                },
            DragGesture(minimumDistance: 2)
                .updating($dragTranslation) { value, state, _ in
                    guard interactionMode == .view else { return }
                    state = value.translation
                }
                .onEnded { value in
                    guard interactionMode == .view else { return }
                    viewport.applyTranslation(value.translation, in: size)
                }
        )
    }

    private func controlSurfaceGesture(in size: CGSize, contentRect: CGRect, viewport visibleViewport: ScreenShareViewportState) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if controlPressStartedAt == nil {
                    controlPressStartedAt = Date()
                }
                let distance = hypot(value.translation.width, value.translation.height)
                guard distance > controlPanStartDistance(in: size),
                      isEdgeScrollStart(value.startLocation, in: size) == false,
                      resolvedClickPoint(for: value, distance: distance, in: size) == nil else {
                    controlPanTranslation = .zero
                    return
                }
                controlPanTranslation = value.translation
            }
            .onEnded { value in
                defer { controlPanTranslation = .zero }
                let pressStartedAt = controlPressStartedAt
                controlPressStartedAt = nil

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
                    lastControlClickPoint = clickPoint
                    cursorPoint = clickPoint
                    showTapFeedback(at: clickPoint)
                    handleControlTap(
                        normalized: normalized,
                        at: clickPoint,
                        pressStartedAt: pressStartedAt
                    )
                    return
                }

                guard distance > controlPanStartDistance(in: size) else { return }
                viewport.applyTranslation(value.translation, in: size)
            }
    }

    private func handleControlTap(normalized: (x: Double, y: Double), at point: CGPoint, pressStartedAt: Date?) {
        let heldDuration = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sendTapIntent(
            normalized.x,
            normalized.y,
            ScreenShareControlInputPolicy.controlClickMouseButton(heldDuration: heldDuration)
        )
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
}

#if canImport(UIKit)
private struct RemoteKeyboardCaptureView: UIViewRepresentable {
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
private protocol RemoteKeyboardTextViewDelegate: AnyObject {
    func remoteKeyboardTextView(_ textView: RemoteKeyboardTextView, didInsert text: String)
    func remoteKeyboardTextViewDidDeleteBackward(_ textView: RemoteKeyboardTextView)
}

@MainActor
private final class RemoteKeyboardTextView: UITextView {
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

    static func clamp(offset proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        guard scale > minimumScale, size.width > 0, size.height > 0 else {
            return .zero
        }

        let horizontalLimit = size.width * (scale - 1) / 2
        let verticalLimit = size.height * (scale - 1) / 2

        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -verticalLimit), verticalLimit)
        )
    }
}

private enum ScreenShareInteractionMode {
    case view
    case control
    case trackpad
}

enum ScreenShareControlInputPolicy {
    static let rightClickHoldDuration: TimeInterval = 0.55
    static let trackpadTapTravelLimit: CGFloat = 8

    static func controlClickMouseButton(heldDuration: TimeInterval) -> Int {
        heldDuration >= rightClickHoldDuration ? 1 : 0
    }

    static func trackpadClickMouseButton(heldDuration: TimeInterval, travelDistance: CGFloat) -> Int? {
        if heldDuration >= rightClickHoldDuration {
            return 1
        }
        return travelDistance < trackpadTapTravelLimit ? 0 : nil
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

private struct MirrorControlPanel: View {
    @Binding var interactionMode: ScreenShareInteractionMode
    @Binding var isCollapsed: Bool
    @Binding var isTyping: Bool
    @Binding var showingDisplayPicker: Bool
    @Binding var showingScrollTools: Bool
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
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let focusTyping: () -> Void
    let selectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let sendScrollButton: (Double) -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if statsVisible {
                    compactStats
                }
                if let detail = controlStatus.detail {
                    compactControlStatus(detail)
                }
                panelButton("hand.draw", selected: interactionMode == .view, label: "View mode") {
                    withAnimation(.snappy) {
                        interactionMode = .view
                        isTyping = false
                    }
                }
                if controlInputEnabled, controlStatus.isLive == false {
                    panelButton("person.badge.key", selected: false, label: "Trust this iPhone for Mac control", action: onTrustControlDevice)
                }
                panelButton(controlInputEnabled ? "cursorarrow.click.2" : "lock", selected: interactionMode == .control, label: controlStatus.label, disabled: controlInputEnabled == false) {
                    guard controlInputEnabled else { return }
                    withAnimation(.snappy) {
                        interactionMode = .control
                        isTyping = false
                    }
                }
                panelButton("rectangle.and.hand.point.up.left", selected: interactionMode == .trackpad, label: "Trackpad mode", disabled: controlInputEnabled == false) {
                    guard controlInputEnabled else { return }
                    withAnimation(.snappy) {
                        interactionMode = .trackpad
                        isTyping = false
                    }
                }
                displayButton
                cursorMenu
                panelButton("magnifyingglass.plus", selected: false, label: "Zoom in", action: zoomIn)
                panelButton("magnifyingglass.minus", selected: false, label: "Zoom out", disabled: isZoomed == false, action: zoomOut)
                panelButton("chevron.up", selected: false, label: "Scroll up", disabled: controlInputEnabled == false) { sendScrollButton(-0.22) }
                panelButton("chevron.down", selected: false, label: "Scroll down", disabled: controlInputEnabled == false) { sendScrollButton(0.22) }
                panelButton("arrow.up.to.line", selected: false, label: "Page up", disabled: controlInputEnabled == false) { sendScrollButton(-0.45) }
                panelButton("arrow.down.to.line", selected: false, label: "Page down", disabled: controlInputEnabled == false) { sendScrollButton(0.45) }
                panelButton("keyboard", selected: isTyping, label: "Type on Mac", disabled: controlInputEnabled == false) {
                    guard controlInputEnabled else { return }
                    withAnimation(.snappy) {
                        interactionMode = .control
                        isTyping.toggle()
                    }
                    if isTyping { focusTyping() }
                }
                panelToggle("Edges", isOn: $edgeScrollEnabled, systemName: "arrow.left.and.right")
                panelToggle("Volume", isOn: $hardwareScrollEnabled, systemName: "speaker.wave.2")
                panelButton("waveform.path.ecg", selected: statsVisible, label: "Toggle performance stats") {
                    withAnimation(.snappy) { statsVisible.toggle() }
                }
                if isZoomed {
                    panelButton("arrow.counterclockwise", selected: false, label: "Reset zoom", action: resetZoom)
                }
                panelButton("xmark", selected: false, label: "Close mirror", action: onClose)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .mirrorGlassBackground(cornerRadius: 24)
        .shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mirror controls")
    }

    private var fallbackDisplays: [HermesRealtimeRelayDisplayDescriptor] {
        [HermesRealtimeRelayDisplayDescriptor(id: selectedDisplayId ?? "main", name: "Main Display", width: 0, height: 0, isPrimary: true)]
    }

    private var activeModeIcon: String {
        switch interactionMode {
        case .view:
            return "hand.draw"
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
        .accessibilityLabel("Cursor options")
    }

    private func cursorIcon(for style: MirrorCursorStyle) -> String {
        switch style {
        case .mercury, .ember, .aurora, .white: return "cursorarrow"
        case .hidden: return "cursorarrow.slash"
        }
    }

    private func panelButton(_ systemName: String, selected: Bool, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            railIcon(systemName, selected: selected, disabled: disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func panelToggle(_ label: String, isOn: Binding<Bool>, systemName: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            railIcon(systemName, selected: isOn.wrappedValue, disabled: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
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

@MainActor
final class ScreenShareViewerCoordinator: ObservableObject {
    struct Stats: Equatable, Sendable {
        var resolution: String = ""
        var codec: String = ""
        var bitsPerSecond: Int = 0
        var roundTripMillis: Int = 0
    }

    let displayLayer: AVSampleBufferDisplayLayer
    @Published var lastStats: Stats = Stats()
    @Published var displayAspectRatio: CGFloat?
    var longTermReferenceTokenHandler: ((MercuryLTRToken) async -> Void)?
    private var pipeline: VideoReceivePipeline?

    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer
        self.pipeline = VideoReceivePipeline { [weak self] sampleBuffer in
            await MainActor.run {
                self?.enqueue(sampleBuffer: sampleBuffer)
            }
        } onLongTermReferenceTokenDecoded: { [weak self] token in
            await self?.longTermReferenceTokenHandler?(token)
        }
    }

    func enqueue(sampleBuffer: CMSampleBuffer) {
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let width = CGFloat(dimensions.width)
            let height = CGFloat(dimensions.height)
            if width > 0, height > 0 {
                let aspectRatio = width / height
                if displayAspectRatio.map({ abs($0 - aspectRatio) > 0.0001 }) ?? true {
                    displayAspectRatio = aspectRatio
                }
            }
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func ingest(frame: MediaFrame) async {
        do {
            try await pipeline?.ingest(frame: frame)
        } catch {
            displayLayer.flush()
        }
    }

    func ingest(frameV2: MediaFrameV2) async {
        do {
            try await pipeline?.ingest(frameV2: frameV2)
        } catch {
            displayLayer.flush()
        }
    }

    func update(stats: Stats) {
        lastStats = stats
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
