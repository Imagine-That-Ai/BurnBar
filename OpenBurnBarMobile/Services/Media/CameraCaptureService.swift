import Foundation
import AVFoundation
import OpenBurnBarMedia

/// iOS front-camera capture for Phase 5 video calls. iPhone single-cam.
/// iPad multicam (front + back PiP) lives in
/// `iPadMultiCamCaptureService` (Phase 6).
@MainActor
final class CameraCaptureService: NSObject {
    enum Failure: Error, LocalizedError {
        case cameraPermissionDenied
        case noCameraDevice
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .cameraPermissionDenied:
                return "OpenBurnBar needs camera access. Open Settings → OpenBurnBar to allow."
            case .noCameraDevice:
                return "No camera available on this device."
            case .configurationFailed(let m):
                return "Camera configuration failed: \(m)"
            }
        }
    }

    typealias FrameHandler = @Sendable (CMSampleBuffer) async -> Void

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let onFrame: FrameHandler

    init(onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
    }

    func start() async throws {
        let granted = await Self.requestCameraAccess()
        guard granted else { throw Failure.cameraPermissionDenied }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
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
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "ai.openburnbar.media.camera.ios"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        await Task.detached { [session] in session.startRunning() }.value
    }

    func stop() {
        session.stopRunning()
    }

    static func requestCameraAccess() async -> Bool {
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

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
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
