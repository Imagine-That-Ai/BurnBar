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
    @State private var statsVisible: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DisplayLayerHost(coordinator: coordinator)
                .ignoresSafeArea()
                .onTapGesture(count: 3) {
                    statsVisible.toggle()
                }

            if statsVisible {
                StatsOverlay(stats: coordinator.lastStats)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(12)
            }
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
