import SwiftUI
import AVKit
import OpenBurnBarMedia

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
    let sendTapIntent: (Double, Double) -> Void
    let sendTextIntent: (String) -> Void
    let sendShortcutIntent: (String, [String]) -> Void
    @State private var statsVisible: Bool = false
    @State private var viewport = ScreenShareViewportState()
    @State private var interactionMode: ScreenShareInteractionMode = .view
    @State private var isTyping = false
    @State private var textToType = ""
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @FocusState private var typingFocused: Bool

    init(
        coordinator: ScreenShareViewerCoordinator,
        resetToken: String?,
        controlStatus: ScreenSharePhoneControlStatus = .unavailable("Phone control is not connected."),
        sendTapIntent: @escaping (Double, Double) -> Void = { _, _ in },
        sendTextIntent: @escaping (String) -> Void = { _ in },
        sendShortcutIntent: @escaping (String, [String]) -> Void = { _, _ in }
    ) {
        self.coordinator = coordinator
        self.resetToken = resetToken
        self.controlStatus = controlStatus
        self.sendTapIntent = sendTapIntent
        self.sendTextIntent = sendTextIntent
        self.sendShortcutIntent = sendShortcutIntent
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
            }
            .ignoresSafeArea()

            controlChrome

            if statsVisible {
                StatsOverlay(stats: coordinator.lastStats)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(12)
            }

            if viewport.isZoomed {
                Button {
                    withAnimation(.snappy) {
                        viewport.reset()
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(radius: 8)
                }
                .padding(.trailing, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .accessibilityLabel("Reset mirror zoom")
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
            }
        }
        .onChange(of: controlStatus) { _, newValue in
            guard newValue.isLive == false, interactionMode == .control else { return }
            withAnimation(.snappy) {
                interactionMode = .view
                isTyping = false
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
                sendTapIntent(normalized.x, normalized.y)
            }
    }

    private var controlChrome: some View {
        VStack {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) {
                        interactionMode = .view
                        isTyping = false
                    }
                } label: {
                    Label("View", systemImage: "hand.draw")
                        .labelStyle(.iconOnly)
                        .frame(width: 42, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(interactionMode == .view ? .black : .white.opacity(0.78))
                .background(interactionMode == .view ? .white : .clear, in: Capsule())
                .accessibilityLabel("View mode")

                Button {
                    guard controlStatus.isLive else { return }
                    withAnimation(.snappy) {
                        interactionMode = .control
                    }
                } label: {
                    Label(controlStatus.label, systemImage: controlStatus.isLive ? "cursorarrow.click.2" : "lock")
                        .labelStyle(.iconOnly)
                        .frame(width: 42, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(interactionMode == .control ? .black : .white.opacity(controlStatus.isLive ? 0.86 : 0.42))
                .background(interactionMode == .control ? .white : .clear, in: Capsule())
                .disabled(controlStatus.isLive == false)
                .accessibilityLabel(controlStatus.label)
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 18)
            .padding(.trailing, 18)

            Spacer()

            if interactionMode == .control {
                Button {
                    guard controlStatus.isLive else { return }
                    withAnimation(.snappy) {
                        isTyping.toggle()
                    }
                    typingFocused = isTyping
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(radius: 8)
                }
                .disabled(controlStatus.isLive == false)
                .padding(.trailing, 18)
                .padding(.bottom, isTyping ? 6 : 24)
                .accessibilityLabel("Type on Mac")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(true)
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
}

private extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
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
