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
    private let isPictureInPictureSupported: () -> Bool
    private(set) var didRequestAutomaticInlinePiP = false
    private(set) var isPictureInPictureActive = false
    var onDidStart: (() -> Void)?
    var onDidStop: (() -> Void)?

    #if canImport(AVKit)
    private var pipController: AVPictureInPictureController?
    #endif

    init(
        isPictureInPictureSupported: @escaping () -> Bool = {
            #if canImport(AVKit)
            AVPictureInPictureController.isPictureInPictureSupported()
            #else
            false
            #endif
        }
    ) {
        self.isPictureInPictureSupported = isPictureInPictureSupported
        super.init()
    }

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        #if canImport(AVKit)
        if self.displayLayer === displayLayer, pipController != nil { return }
        self.displayLayer = displayLayer
        guard isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        didRequestAutomaticInlinePiP = true
        controller.delegate = self
        self.pipController = controller
        #endif
    }

    func stop() {
        #if canImport(AVKit)
        pipController?.stopPictureInPicture()
        #endif
    }

    @discardableResult
    func start() -> Bool {
        #if canImport(AVKit)
        guard let pipController else { return false }
        guard !pipController.isPictureInPictureActive else { return true }
        guard pipController.isPictureInPicturePossible else { return false }
        pipController.startPictureInPicture()
        return true
        #else
        return false
        #endif
    }

    func handleDidStartPictureInPicture() {
        isPictureInPictureActive = true
        onDidStart?()
    }

    func handleDidStopPictureInPicture() {
        isPictureInPictureActive = false
        onDidStop?()
    }
}

#if canImport(AVKit)
extension ScreenSharePiPController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
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

extension ScreenSharePiPController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        handleDidStartPictureInPicture()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        handleDidStopPictureInPicture()
    }
}
#endif
