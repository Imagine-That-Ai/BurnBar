import Foundation
import AVFoundation
import OpenBurnBarMedia

/// Phase 6: iPad Pro M-series multicam capture (front primary + back
/// PiP). Falls back to single-cam on iPad mini and older iPads via
/// `AVCaptureMultiCamSession.isMultiCamSupported`.
@MainActor
final class iPadMultiCamCaptureService: NSObject {
    enum Failure: Error, LocalizedError {
        case unsupportedDevice
        case cameraPermissionDenied
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedDevice:
                return "Multi-cam isn't supported on this iPad."
            case .cameraPermissionDenied:
                return "OpenBurnBar needs camera access."
            case .configurationFailed(let m):
                return "Multi-cam configuration failed: \(m)"
            }
        }
    }

    typealias FrameHandler = @Sendable (AVCaptureDevice.Position, CMSampleBuffer) async -> Void

    private let session: AVCaptureSession
    private let frontOutput = AVCaptureVideoDataOutput()
    private let backOutput = AVCaptureVideoDataOutput()
    private let onFrame: FrameHandler
    private var isMultiCam: Bool = false

    init(onFrame: @escaping FrameHandler) {
        if AVCaptureMultiCamSession.isMultiCamSupported {
            session = AVCaptureMultiCamSession()
        } else {
            session = AVCaptureSession()
        }
        self.onFrame = onFrame
        self.isMultiCam = AVCaptureMultiCamSession.isMultiCamSupported
    }

    func start() async throws {
        let granted = await CameraCaptureService.requestCameraAccess()
        guard granted else { throw Failure.cameraPermissionDenied }

        session.beginConfiguration()

        guard let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            session.commitConfiguration()
            throw Failure.unsupportedDevice
        }
        try addInput(device: frontDevice)
        configure(output: frontOutput, position: .front)

        if isMultiCam, let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            do {
                try addInput(device: backDevice)
                configure(output: backOutput, position: .back)
            } catch {
                // If multi-cam pairing fails (legal on iPad mini in
                // edge cases), fall back to single-cam silently.
                isMultiCam = false
            }
        }

        session.commitConfiguration()
        await Task.detached { [session] in session.startRunning() }.value
    }

    func stop() {
        session.stopRunning()
    }

    var multiCamEnabled: Bool { isMultiCam }

    private func addInput(device: AVCaptureDevice) throws {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                throw Failure.configurationFailed("can't add input for \(device.localizedName)")
            }
        } catch {
            throw Failure.configurationFailed(error.localizedDescription)
        }
    }

    private func configure(output: AVCaptureVideoDataOutput, position: AVCaptureDevice.Position) {
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let queueLabel = position == .front
            ? "ai.openburnbar.media.camera.front"
            : "ai.openburnbar.media.camera.back"
        let context = SampleBufferContext(position: position, owner: self)
        output.setSampleBufferDelegate(context, queue: DispatchQueue(label: queueLabel))
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        // Hold the context strongly via objc_setAssociatedObject so the
        // delegate isn't deallocated while the session runs.
        objc_setAssociatedObject(output, "ai.openburnbar.media.camera.context", context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private final class SampleBufferContext: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let position: AVCaptureDevice.Position
    weak var owner: iPadMultiCamCaptureService?

    init(position: AVCaptureDevice.Position, owner: iPadMultiCamCaptureService) {
        self.position = position
        self.owner = owner
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let snapshot = sampleBuffer
        let pos = position
        Task.detached(priority: .userInitiated) { [weak owner] in
            await owner?.handle(position: pos, sampleBuffer: snapshot)
        }
    }
}

extension iPadMultiCamCaptureService {
    fileprivate func handle(position: AVCaptureDevice.Position, sampleBuffer: CMSampleBuffer) async {
        await onFrame(position, sampleBuffer)
    }
}

