import Foundation
import AVFoundation
import OpenBurnBarMedia

/// Mac webcam capture for Phase 5 video calls.
@MainActor
final class CameraCapturePipeline: NSObject {
    enum Failure: Error, LocalizedError {
        case cameraPermissionDenied
        case noCameraDevice
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .cameraPermissionDenied:
                return "OpenBurnBar needs camera access for calls."
            case .noCameraDevice:
                return "No camera available on this Mac."
            case .configurationFailed(let m):
                return "Camera configuration failed: \(m)"
            }
        }
    }

    typealias FrameHandler = @Sendable (CMSampleBuffer) async -> Void

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let onFrame: FrameHandler

    init(onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
    }

    func start() async throws {
        let granted = await Self.requestCameraAccess()
        guard granted else { throw Failure.cameraPermissionDenied }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ??
                AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            throw Failure.noCameraDevice
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            throw Failure.configurationFailed(error.localizedDescription)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "ai.openburnbar.media.camera"))
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()

        await Task.detached { [session] in session.startRunning() }.value
    }

    func stop() {
        session.stopRunning()
    }

    private static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }
}

extension CameraCapturePipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let snapshot = sampleBuffer
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.onFrame(snapshot)
        }
    }
}
