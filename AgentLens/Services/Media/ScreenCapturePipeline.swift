import Foundation
import AVFoundation
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
import OpenBurnBarMedia

/// Mac screen-capture pipeline driven by ScreenCaptureKit. Phase 3
/// (Mac → iOS one-way screen share) entry point. Captures the focused
/// window or display at 1920×1080@30 by default and surfaces
/// `CMSampleBuffer` frames to the encoder.
///
/// See `plans/2026-05-15-mercury-media-master-plan.md` § C.1.
@MainActor
final class ScreenCapturePipeline: NSObject {
    enum Failure: Error, LocalizedError {
        case screenRecordingPermissionDenied
        case noShareableContent
        case streamConfigurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .screenRecordingPermissionDenied:
                return "OpenBurnBar needs Screen Recording permission. Open System Settings → Privacy & Security → Screen Recording to enable."
            case .noShareableContent:
                return "No shareable display or window available."
            case .streamConfigurationFailed(let message):
                return "Screen capture stream failed: \(message)"
            }
        }
    }

    struct Configuration: Sendable, Equatable {
        var width: Int = 1920
        var height: Int = 1080
        var frameRate: Int = 30
        var captureFocusedWindowOnly: Bool = false
    }

    typealias FrameHandler = @Sendable (CMSampleBuffer) async -> Void

    private let configuration: Configuration
    private let frameHandler: FrameHandler
    #if canImport(ScreenCaptureKit)
    private var stream: SCStream?
    #endif

    init(configuration: Configuration = Configuration(), frameHandler: @escaping FrameHandler) {
        self.configuration = configuration
        self.frameHandler = frameHandler
    }

    func start() async throws {
        #if canImport(ScreenCaptureKit)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw Failure.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            throw Failure.noShareableContent
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = configuration.width
        cfg.height = configuration.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        cfg.queueDepth = 5
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true

        let newStream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await newStream.startCapture()
        self.stream = newStream
        #else
        throw Failure.streamConfigurationFailed("ScreenCaptureKit unavailable on this platform.")
        #endif
    }

    func stop() async {
        #if canImport(ScreenCaptureKit)
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        #endif
    }
}

#if canImport(ScreenCaptureKit)
extension ScreenCapturePipeline: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let frame = sampleBuffer
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.frameHandler(frame)
        }
    }
}
#endif
