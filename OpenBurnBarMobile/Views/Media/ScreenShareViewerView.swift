import SwiftUI
import AVKit
import MediaPlayer
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
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let sendTapIntent: (Double, Double) -> Void
    let sendScrollIntent: (Double, Double, Double, Double, String?) -> Void
    let sendPointerMoveIntent: (Double, Double) -> Void
    let sendPointerClickIntent: () -> Void
    let sendTextIntent: (String) -> Void
    let sendShortcutIntent: (String, [String]) -> Void
    let onSelectDisplay: (String) -> Void
    let onClose: () -> Void
    @State private var statsVisible: Bool = false
    @State private var viewport = ScreenShareViewportState()
    @State private var interactionMode: ScreenShareInteractionMode = .view
    @State private var isTyping = false
    @State private var textToType = ""
    @State private var panelOffset = CGSize(width: -18, height: 18)
    @State private var panelDragBase = CGSize(width: -18, height: 18)
    @State private var showingDisplayPicker = false
    @State private var showingScrollTools = false
    @State private var edgeScrollEnabled = true
    @State private var hardwareScrollEnabled = false
    @State private var trackpadActive = false
    @State private var trackpadVisible = false
    @State private var cursorNormalized = CGPoint(x: 0.5, y: 0.5)
    @State private var cursorSize: CGFloat = 26
    @State private var cursorStyle: MirrorCursorStyle = .mercury
    @State private var tapFeedbackPoint: CGPoint?
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @FocusState private var typingFocused: Bool

    init(
        coordinator: ScreenShareViewerCoordinator,
        resetToken: String?,
        controlStatus: ScreenSharePhoneControlStatus = .unavailable("Phone control is not connected."),
        displays: [HermesRealtimeRelayDisplayDescriptor] = [],
        selectedDisplayId: String? = nil,
        sendTapIntent: @escaping (Double, Double) -> Void = { _, _ in },
        sendScrollIntent: @escaping (Double, Double, Double, Double, String?) -> Void = { _, _, _, _, _ in },
        sendPointerMoveIntent: @escaping (Double, Double) -> Void = { _, _ in },
        sendPointerClickIntent: @escaping () -> Void = {},
        sendTextIntent: @escaping (String) -> Void = { _ in },
        sendShortcutIntent: @escaping (String, [String]) -> Void = { _, _ in },
        onSelectDisplay: @escaping (String) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.resetToken = resetToken
        self.controlStatus = controlStatus
        self.displays = displays
        self.selectedDisplayId = selectedDisplayId
        self.sendTapIntent = sendTapIntent
        self.sendScrollIntent = sendScrollIntent
        self.sendPointerMoveIntent = sendPointerMoveIntent
        self.sendPointerClickIntent = sendPointerClickIntent
        self.sendTextIntent = sendTextIntent
        self.sendShortcutIntent = sendShortcutIntent
        self.onSelectDisplay = onSelectDisplay
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { proxy in
                let visibleViewport = viewport.preview(
                    magnification: magnification,
                    translation: dragTranslation,
                    in: proxy.size
                )

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
                        guard interactionMode == .view else { return }
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

                if interactionMode == .control, controlStatus.isLive {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(controlTapGesture(in: proxy.size, viewport: visibleViewport))
                        .accessibilityLabel("Mac screen control surface")
                }

                if interactionMode == .control, controlStatus.isLive, edgeScrollEnabled {
                    EdgeScrollOverlay { start, end in
                        sendScrollIntent(start.x, start.y, end.x, end.y, selectedDisplayId)
                    }
                }

                if interactionMode == .trackpad, controlStatus.isLive {
                    TrackpadGlassSurface(
                        isVisible: trackpadVisible || trackpadActive,
                        onActiveChange: { active in
                            withAnimation(.snappy) {
                                trackpadActive = active
                                trackpadVisible = active
                            }
                        },
                        onMove: { delta in
                            moveCursorByTrackpadDelta(delta, in: proxy.size, viewport: visibleViewport)
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

                if controlStatus.isLive, interactionMode == .trackpad {
                    MirrorPointerCursor(
                        normalizedPoint: cursorNormalized,
                        viewport: visibleViewport,
                        containerSize: proxy.size,
                        size: cursorSize,
                        style: cursorStyle
                    )
                    .allowsHitTesting(false)
                }

                if hardwareScrollEnabled, controlStatus.isLive {
                    VolumeButtonScrollBridge { direction in
                        let endY = min(max(0.5 + direction, 0), 1)
                        sendScrollIntent(0.5, 0.5, 0.5, endY, selectedDisplayId)
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                }

                MirrorControlPanel(
                    interactionMode: $interactionMode,
                    isTyping: $isTyping,
                    showingDisplayPicker: $showingDisplayPicker,
                    showingScrollTools: $showingScrollTools,
                    edgeScrollEnabled: $edgeScrollEnabled,
                    hardwareScrollEnabled: $hardwareScrollEnabled,
                    cursorSize: $cursorSize,
                    cursorStyle: $cursorStyle,
                    controlStatus: controlStatus,
                    displays: displays,
                    selectedDisplayId: selectedDisplayId,
                    isZoomed: viewport.isZoomed,
                    resetZoom: {
                        withAnimation(.snappy) { viewport.reset() }
                    },
                    focusTyping: {
                        focusTypingBar()
                    },
                    selectDisplay: onSelectDisplay,
                    sendScrollButton: { direction in
                        let endY = min(max(0.5 + direction, 0), 1)
                        sendScrollIntent(0.5, 0.5, 0.5, endY, selectedDisplayId)
                    },
                    onClose: onClose
                )
                .offset(panelOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .gesture(panelDragGesture(in: proxy.size))
                .onAppear { clampPanel(in: proxy.size) }
                .onChange(of: proxy.size) { _, newSize in clampPanel(in: newSize) }
            }
            .ignoresSafeArea()

            if statsVisible {
                StatsOverlay(stats: coordinator.lastStats)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(12)
            }

        }
        .safeAreaInset(edge: .bottom) {
            if interactionMode == .control, isTyping {
                typingBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: resetToken) { _, _ in
            withAnimation(.snappy) {
                viewport.reset()
                interactionMode = .view
                isTyping = false
                textToType = ""
                cursorNormalized = CGPoint(x: 0.5, y: 0.5)
                tapFeedbackPoint = nil
            }
        }
        .onChange(of: controlStatus) { _, newValue in
            guard newValue.isLive == false, interactionMode != .view else { return }
            withAnimation(.snappy) {
                interactionMode = .view
                isTyping = false
            }
        }
        .onChange(of: isTyping) { _, newValue in
            if newValue {
                focusTypingBar()
            } else {
                typingFocused = false
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

    private func controlTapGesture(in size: CGSize, viewport: ScreenShareViewportState) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onEnded { value in
                let distance = hypot(value.translation.width, value.translation.height)
                guard distance < 10 else { return }
                let normalized = viewport.normalizedPoint(for: value.location, in: size)
                showTapFeedback(at: value.location)
                sendTapIntent(normalized.x, normalized.y)
            }
    }

    private func moveCursorByTrackpadDelta(_ delta: CGSize, in size: CGSize, viewport: ScreenShareViewportState) {
        guard size.width > 0, size.height > 0 else { return }
        cursorNormalized.x = min(max(cursorNormalized.x + (delta.width / max(size.width * viewport.scale, 1)), 0), 1)
        cursorNormalized.y = min(max(cursorNormalized.y + (delta.height / max(size.height * viewport.scale, 1)), 0), 1)
        sendPointerMoveIntent(Double(delta.width), Double(delta.height))
    }

    private func focusTypingBar() {
        DispatchQueue.main.async {
            typingFocused = true
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
        let horizontalLimit = max(0, size.width - 112)
        let verticalLimit = max(0, size.height - 168)
        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), -8),
            height: min(max(proposed.height, 8), verticalLimit)
        )
    }

    private var typingBar: some View {
        HStack(spacing: 8) {
            TextField("Type on Mac", text: $textToType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typingFocused)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .submitLabel(.send)
                .onSubmit(sendTypedText)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(action: sendTypedText) {
                Image(systemName: "paperplane.fill")
                    .frame(width: 38, height: 38)
            }
            .disabled(textToType.isEmpty)
            .accessibilityLabel("Send text")

            Button {
                sendShortcutIntent("Return", [])
            } label: {
                Image(systemName: "return")
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Press Return on Mac")

            Button {
                sendShortcutIntent("Escape", [])
            } label: {
                Image(systemName: "escape")
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Press Escape on Mac")
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            focusTypingBar()
        }
    }

    private func sendTypedText() {
        guard textToType.isEmpty == false else { return }
        sendTextIntent(textToType)
        textToType = ""
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

    func normalizedPoint(for point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        let contentX = ((point.x - (size.width / 2) - offset.width) / scale) + (size.width / 2)
        let contentY = ((point.y - (size.height / 2) - offset.height) / scale) + (size.height / 2)
        let x = min(max(contentX / size.width, 0), 1)
        let y = min(max(contentY / size.height, 0), 1)
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

private struct MirrorControlPanel: View {
    @Binding var interactionMode: ScreenShareInteractionMode
    @Binding var isTyping: Bool
    @Binding var showingDisplayPicker: Bool
    @Binding var showingScrollTools: Bool
    @Binding var edgeScrollEnabled: Bool
    @Binding var hardwareScrollEnabled: Bool
    @Binding var cursorSize: CGFloat
    @Binding var cursorStyle: MirrorCursorStyle
    let controlStatus: ScreenSharePhoneControlStatus
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let isZoomed: Bool
    let resetZoom: () -> Void
    let focusTyping: () -> Void
    let selectDisplay: (String) -> Void
    let sendScrollButton: (Double) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                panelButton("hand.draw", selected: interactionMode == .view, label: "View mode") {
                    withAnimation(.snappy) {
                        interactionMode = .view
                        isTyping = false
                    }
                }
                panelButton(controlStatus.isLive ? "cursorarrow.click.2" : "lock", selected: interactionMode == .control, label: controlStatus.label, disabled: controlStatus.isLive == false) {
                    guard controlStatus.isLive else { return }
                    withAnimation(.snappy) { interactionMode = .control }
                }
                panelButton("rectangle.and.hand.point.up.left", selected: interactionMode == .trackpad, label: "Trackpad mode", disabled: controlStatus.isLive == false) {
                    guard controlStatus.isLive else { return }
                    withAnimation(.snappy) {
                        interactionMode = .trackpad
                        isTyping = false
                    }
                }
                panelButton("xmark", selected: false, label: "Close mirror", action: onClose)
            }

            HStack(spacing: 8) {
                panelButton("rectangle.connected.to.line.below", selected: showingDisplayPicker, label: "Displays") {
                    withAnimation(.snappy) {
                        showingDisplayPicker.toggle()
                        showingScrollTools = false
                    }
                }
                panelButton("arrow.up.and.down", selected: showingScrollTools, label: "Scroll controls") {
                    withAnimation(.snappy) {
                        showingScrollTools.toggle()
                        showingDisplayPicker = false
                    }
                }
                panelButton("keyboard", selected: isTyping, label: "Type on Mac", disabled: controlStatus.isLive == false) {
                    guard controlStatus.isLive else { return }
                    withAnimation(.snappy) {
                        interactionMode = .control
                        isTyping.toggle()
                    }
                    if isTyping { focusTyping() }
                }
                if isZoomed {
                    panelButton("arrow.counterclockwise", selected: false, label: "Reset zoom", action: resetZoom)
                }
            }

            if showingDisplayPicker {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(displays.isEmpty ? fallbackDisplays : displays) { display in
                        Button {
                            selectDisplay(display.id)
                            withAnimation(.snappy) { showingDisplayPicker = false }
                        } label: {
                            HStack(spacing: 8) {
                                Text(display.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                if display.id == selectedDisplayId || (selectedDisplayId == nil && display.isPrimary) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }

            if showingScrollTools {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        panelButton("chevron.up", selected: false, label: "Scroll up") { sendScrollButton(-0.22) }
                        panelButton("chevron.down", selected: false, label: "Scroll down") { sendScrollButton(0.22) }
                        panelButton("arrow.up.to.line", selected: false, label: "Page up") { sendScrollButton(-0.45) }
                        panelButton("arrow.down.to.line", selected: false, label: "Page down") { sendScrollButton(0.45) }
                    }
                    HStack(spacing: 8) {
                        Toggle("Edges", isOn: $edgeScrollEnabled)
                        Toggle("Volume", isOn: $hardwareScrollEnabled)
                    }
                    .toggleStyle(.button)
                    .font(.system(size: 11, weight: .semibold))
                    .tint(.white.opacity(0.2))
                    .foregroundStyle(.white)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }

            if interactionMode == .trackpad, controlStatus.isLive {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(MirrorCursorStyle.allCases) { style in
                            Button {
                                cursorStyle = style
                            } label: {
                                MirrorCursorSwatch(style: style, selected: cursorStyle == style)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(style.label) cursor")
                            .accessibilityAddTraits(cursorStyle == style ? .isSelected : [])
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                        Slider(value: $cursorSize, in: 18...48)
                            .frame(width: 132)
                    }
                    .tint(.white)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Cursor size")
                    .accessibilityValue("\(Int(cursorSize)) points")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .padding(8)
        .mirrorGlassBackground(cornerRadius: 28)
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mirror controls")
    }

    private var fallbackDisplays: [HermesRealtimeRelayDisplayDescriptor] {
        [HermesRealtimeRelayDisplayDescriptor(id: selectedDisplayId ?? "main", name: "Main Display", width: 0, height: 0, isPrimary: true)]
    }

    private func panelButton(_ systemName: String, selected: Bool, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected ? .black : .white.opacity(disabled ? 0.36 : 0.88))
                .frame(width: 44, height: 44)
                .background(selected ? Color.white : Color.white.opacity(disabled ? 0.05 : 0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

private enum MirrorCursorStyle: String, CaseIterable, Identifiable {
    case mercury
    case ember
    case aurora
    case white

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mercury: return "Mercury"
        case .ember: return "Ember"
        case .aurora: return "Aurora"
        case .white: return "White"
        }
    }
}

private struct MirrorPointerCursor: View {
    let normalizedPoint: CGPoint
    let viewport: ScreenShareViewportState
    let containerSize: CGSize
    let size: CGFloat
    let style: MirrorCursorStyle

    var body: some View {
        cursorGlyph
            .font(.system(size: size, weight: .black))
            .shadow(color: .black.opacity(0.45), radius: max(4, size * 0.18), x: 0, y: 3)
            .position(viewport.viewPoint(forNormalized: normalizedPoint, in: containerSize))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var cursorGlyph: some View {
        switch style {
        case .mercury:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.68, green: 0.84, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .ember:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.78, blue: 0.30), Color(red: 1.0, green: 0.24, blue: 0.32)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .aurora:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.30, green: 1.0, blue: 0.72), Color(red: 0.50, green: 0.46, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .white:
            Image(systemName: "cursorarrow")
                .foregroundStyle(.white)
        }
    }
}

private struct TapFeedbackMarker: View {
    let point: CGPoint

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.88), lineWidth: 2)
                .frame(width: 34, height: 34)
            Circle()
                .fill(.white.opacity(0.22))
                .frame(width: 12, height: 12)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
        .position(point)
        .transition(.scale(scale: 0.55).combined(with: .opacity))
        .accessibilityHidden(true)
    }
}

private struct MirrorCursorSwatch: View {
    let style: MirrorCursorStyle
    let selected: Bool

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 26, height: 26)
            .overlay(
                Circle()
                    .stroke(selected ? .white : .white.opacity(0.22), lineWidth: selected ? 2 : 1)
            )
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(style == .white ? .black : .white)
                }
            }
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .mercury:
            return AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.68, green: 0.84, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .ember:
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.30), Color(red: 1.0, green: 0.24, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .aurora:
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.30, green: 1.0, blue: 0.72), Color(red: 0.50, green: 0.46, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .white:
            return AnyShapeStyle(Color.white)
        }
    }
}

private struct EdgeScrollOverlay: View {
    let onScroll: (_ start: (x: Double, y: Double), _ end: (x: Double, y: Double)) -> Void

    var body: some View {
        GeometryReader { proxy in
            let margin = max(28, min(proxy.size.width, proxy.size.height) * 0.07)
            ZStack {
                edgeBand(width: proxy.size.width, height: margin, size: proxy.size)
                    .frame(maxHeight: .infinity, alignment: .top)
                edgeBand(width: proxy.size.width, height: margin, size: proxy.size)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                edgeBand(width: margin, height: proxy.size.height, size: proxy.size)
                    .frame(maxWidth: .infinity, alignment: .leading)
                edgeBand(width: margin, height: proxy.size.height, size: proxy.size)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .coordinateSpace(.named("mirrorEdgeScroll"))
        }
    }

    private func edgeBand(width: CGFloat, height: CGFloat, size: CGSize) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("mirrorEdgeScroll"))
                    .onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        guard distance > 12 else { return }
                        let start = normalized(value.startLocation, in: size)
                        let end = normalized(value.location, in: size)
                        onScroll(start, end)
                    }
            )
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (0.5, 0.5) }
        return (
            Double(min(max(point.x / size.width, 0), 1)),
            Double(min(max(point.y / size.height, 0), 1))
        )
    }
}

private struct TrackpadGlassSurface: View {
    let isVisible: Bool
    let onActiveChange: (Bool) -> Void
    let onMove: (CGSize) -> Void
    let onClick: () -> Void
    let onScroll: (Double) -> Void
    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.46, 360)
            let height = min(proxy.size.height * 0.40, 260)
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.clear)
                .mirrorGlassBackground(cornerRadius: 26)
                .overlay(alignment: .topLeading) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(16)
                }
                .opacity(isVisible ? 1 : 0.001)
                .frame(width: width, height: height)
                .position(x: proxy.size.width - width / 2 - 18, y: proxy.size.height - height / 2 - 34)
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            onActiveChange(true)
                            let delta = value.translation - lastTranslation
                            lastTranslation = value.translation
                            if abs(delta.width) > 0.5 || abs(delta.height) > 0.5 {
                                onMove(delta)
                            }
                        }
                        .onEnded { value in
                            let distance = hypot(value.translation.width, value.translation.height)
                            if distance < 8 {
                                onClick()
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
}

private struct VolumeButtonScrollBridge: UIViewRepresentable {
    let onVolumeStep: (Double) -> Void

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

    final class Coordinator: NSObject {
        var onVolumeStep: ((Double) -> Void)?
        private var observation: NSKeyValueObservation?
        private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume

        func start(onVolumeStep: @escaping (Double) -> Void) {
            self.onVolumeStep = onVolumeStep
            lastVolume = AVAudioSession.sharedInstance().outputVolume
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let self, let newValue = change.newValue else { return }
                let delta = newValue - self.lastVolume
                self.lastVolume = newValue
                guard abs(delta) > 0.001 else { return }
                DispatchQueue.main.async {
                    self.onVolumeStep?(delta > 0 ? -0.28 : 0.28)
                }
            }
        }
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
    private var pipeline: VideoReceivePipeline?

    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer
        self.pipeline = VideoReceivePipeline { [weak self] sampleBuffer in
            await MainActor.run {
                self?.enqueue(sampleBuffer: sampleBuffer)
            }
        }
    }

    func enqueue(sampleBuffer: CMSampleBuffer) {
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
