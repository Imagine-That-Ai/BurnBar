import SwiftUI
import AVKit
import OpenBurnBarMedia

/// iOS Mercury screen-share viewer. Full-bleed video, optional stats
/// overlay (three-finger tap toggles). Wraps an
/// `AVSampleBufferDisplayLayer` via `UIViewRepresentable` so decoded
/// frames bypass UIKit's drawing path.
@MainActor
struct ScreenShareViewerView: View {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator
    let resetToken: String?
    @State private var statsVisible: Bool = false
    @State private var viewport = ScreenShareViewportState()
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

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
            }
            .ignoresSafeArea()

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
        .onChange(of: resetToken) { _, _ in
            withAnimation(.snappy) {
                viewport.reset()
            }
        }
    }

    private func viewportGesture(in size: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .updating($magnification) { value, state, _ in
                    state = value.magnification
                }
                .onEnded { value in
                    viewport.applyMagnification(value.magnification, in: size)
                },
            DragGesture(minimumDistance: 2)
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    viewport.applyTranslation(value.translation, in: size)
                }
        )
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
