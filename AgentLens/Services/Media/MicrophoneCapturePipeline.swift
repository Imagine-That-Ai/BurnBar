import Foundation
import AVFoundation
import OpenBurnBarMedia

/// Mac mic capture for Phase 4 audio. AVAudioEngine + Voice-Processing
/// IO so Apple's tuned AEC handles speaker-into-mic feedback. Surfaces
/// 20 ms PCM frames to the Opus encoder.
@MainActor
final class MicrophoneCapturePipeline {
    enum Failure: Error, LocalizedError {
        case microphonePermissionDenied
        case configurationFailed(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "OpenBurnBar needs microphone access for calls."
            case .configurationFailed(let message):
                return "Microphone setup failed: \(message)"
            case .engineStartFailed(let message):
                return "Audio engine failed to start: \(message)"
            }
        }
    }

    typealias FrameHandler = @Sendable (AVAudioPCMBuffer) async -> Void

    private let engine = AVAudioEngine()
    private let onPCMFrame: FrameHandler
    /// Exactly 20 ms of mono 48 kHz Float32 = 960 samples.
    private static let samplesPerFrame: AVAudioFrameCount = 960
    private let frameTargetFormat: AVAudioFormat?

    init(onPCMFrame: @escaping FrameHandler) {
        self.onPCMFrame = onPCMFrame
        self.frameTargetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
    }

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            throw Failure.configurationFailed("voice processing: \(error.localizedDescription)")
        }

        guard let targetFormat = frameTargetFormat else {
            throw Failure.configurationFailed("invalid target format (48kHz mono float)")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw Failure.configurationFailed("converter init failed")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameTarget = AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / inputFormat.sampleRate)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(frameTarget, Self.samplesPerFrame)) else {
                return
            }
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
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
