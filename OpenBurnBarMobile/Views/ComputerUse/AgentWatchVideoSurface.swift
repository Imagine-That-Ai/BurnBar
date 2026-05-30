#if canImport(SwiftUI) && canImport(UIKit)
import AVKit
import SwiftUI
import OpenBurnBarMedia

/// Decodes incoming `MediaFrame`s through `VideoReceivePipeline` and feeds
/// the resulting `CMSampleBuffer`s into a `AVSampleBufferDisplayLayer`.
///
/// The in-chat Agent Live Stage uses one coordinator owned by
/// `AgentWatchOverlaySingleton` so system PiP, dock, split, and maximize bind
/// to one canonical `AVSampleBufferDisplayLayer`. Standalone watch surfaces
/// may still create their own coordinator when they are not part of that stage
/// lifecycle.
@MainActor
final class AgentWatchVideoCoordinator: ObservableObject {
    let displayLayer: AVSampleBufferDisplayLayer
    @Published var displayAspectRatio: CGFloat?
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
