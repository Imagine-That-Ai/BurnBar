import Foundation
import AVFoundation
import OpenBurnBarMedia

/// iOS-side mic capture for Phase 4. Same Voice-Processing IO path as
/// the Mac so AEC behavior is symmetric. Listens for
/// `AVAudioSession.routeChangeNotification` to handle AirPods connect
/// mid-call.
@MainActor
final class MicrophoneCaptureService {
    enum Failure: Error, LocalizedError {
        case microphonePermissionDenied
        case sessionConfigurationFailed(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "OpenBurnBar needs microphone access. Open Settings → OpenBurnBar to allow."
            case .sessionConfigurationFailed(let m):
                return "Audio session configuration failed: \(m)"
            case .engineStartFailed(let m):
                return "Audio engine failed to start: \(m)"
            }
        }
    }

    typealias FrameHandler = @Sendable (AVAudioPCMBuffer) async -> Void

    private let engine = AVAudioEngine()
    private let onPCMFrame: FrameHandler
    private let targetFormat: AVAudioFormat?
    private var routeChangeObserver: NSObjectProtocol?

    init(onPCMFrame: @escaping FrameHandler) {
        self.onPCMFrame = onPCMFrame
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
    }

    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw Failure.sessionConfigurationFailed(error.localizedDescription)
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw Failure.sessionConfigurationFailed("voice processing: \(error.localizedDescription)")
        }

        guard let targetFormat else { throw Failure.sessionConfigurationFailed("invalid target format") }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw Failure.sessionConfigurationFailed("converter init failed")
        }

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameTarget = AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / inputFormat.sampleRate)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(frameTarget, 960)) else { return }
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error || error != nil { return }
            let snapshot = converted
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.onPCMFrame(snapshot)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw Failure.engineStartFailed(error.localizedDescription)
        }

        observeRouteChanges()
    }

    func stop() {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Pause + reinit per the route-change resilience plan:
            // 200 ms grace, crossfade. For Phase 4 the simplest correct
            // behavior is to stop + restart the engine; AVAudioEngine
            // handles the rebind internally on next start.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.engine.pause()
                try? self.engine.start()
            }
        }
    }
}
