#if canImport(SwiftUI) && canImport(UIKit)
import AVKit
import SwiftUI
import OpenBurnBarMedia

/// Decodes incoming `MediaFrame`s through `VideoReceivePipeline` and feeds
/// the resulting `CMSampleBuffer`s into a `AVSampleBufferDisplayLayer`.
///
/// One coordinator per rendering view: the full-bleed Agent Watch screen and
/// the in-chat Agent Live Stage each own their own coordinator + display
/// layer so they can render concurrently without contending for a single
/// hosted layer. Both consume the same `AgentWatchState.currentFrame`
/// stream, which is gated by `displayLayer.isReadyForMoreMediaData`.
@MainActor
final class AgentWatchVideoCoordinator: ObservableObject {
    let displayLayer: AVSampleBufferDisplayLayer
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

    func ingest(frame: MediaFrame) async {
        do {
            try await pipeline?.ingest(frame: frame)
        } catch {
            displayLayer.flush()
        }
    }

    private func enqueue(sampleBuffer: CMSampleBuffer) {
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }
}

/// SwiftUI wrapper that hosts an `AgentWatchVideoCoordinator`'s display
/// layer inside a `UIView`. Reused by `AgentWatchView` (full-bleed) and
/// `AgentLiveStage` (in-chat windowed mirror).
struct AgentWatchVideoSurface: UIViewRepresentable {
    @ObservedObject var coordinator: AgentWatchVideoCoordinator
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> AgentWatchVideoSurfaceView {
        let view = AgentWatchVideoSurfaceView()
        view.attach(layer: coordinator.displayLayer, gravity: videoGravity)
        return view
    }

    func updateUIView(_ uiView: AgentWatchVideoSurfaceView, context: Context) {
        uiView.updateGravity(videoGravity)
    }
}

final class AgentWatchVideoSurfaceView: UIView {
    private weak var hostedLayer: AVSampleBufferDisplayLayer?

    func attach(layer: AVSampleBufferDisplayLayer, gravity: AVLayerVideoGravity) {
        hostedLayer?.removeFromSuperlayer()
        layer.frame = bounds
        layer.videoGravity = gravity
        self.layer.addSublayer(layer)
        hostedLayer = layer
    }

    func updateGravity(_ gravity: AVLayerVideoGravity) {
        hostedLayer?.videoGravity = gravity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedLayer?.frame = bounds
    }
}
#endif
