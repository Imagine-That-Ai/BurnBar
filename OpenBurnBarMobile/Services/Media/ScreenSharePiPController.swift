import Foundation
import AVFoundation
#if canImport(AVKit)
import AVKit
#endif

/// Phase 6 system-managed PiP controller for incoming Mac screen share.
/// On iOS 15+ `AVPictureInPictureController(contentSource:)` accepts an
/// `AVSampleBufferDisplayLayer` directly; the system handles the
/// floating window across app states.
@MainActor
final class ScreenSharePiPController: NSObject {
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    #if canImport(AVKit)
    private var pipController: AVPictureInPictureController?
    #endif

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        #if canImport(AVKit)
        self.displayLayer = displayLayer
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller
        #endif
    }

    func startIfPossible() {
        #if canImport(AVKit)
        if let pipController, pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        }
        #endif
    }

    func stop() {
        #if canImport(AVKit)
        pipController?.stopPictureInPicture()
        #endif
    }
}

#if canImport(AVKit)
extension ScreenSharePiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Frames flow continuously from `VideoReceivePipeline`; nothing
        // to do here beyond honoring system pause/resume.
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // Layer self-resizes via `videoGravity`; no manual work needed.
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
#endif
