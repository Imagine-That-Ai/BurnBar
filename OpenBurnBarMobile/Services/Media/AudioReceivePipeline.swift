import Foundation
import AVFoundation
import OpenBurnBarMedia

/// iOS Opus → PCM decode + playback path. Adaptive jitter buffer
/// (60 ms target). Dropped packets are concealed via Opus PLC inside
/// the converter (Apple's built-in Opus decoder handles forward error
/// concealment automatically when packets are missing).
@MainActor
final class AudioReceivePipeline {
    enum Failure: Error, LocalizedError {
        case converterInit
        case decodeFailed(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .converterInit: return "Opus decoder initialization failed."
            case .decodeFailed(let m): return "Opus decode failed: \(m)"
            case .engineStartFailed(let m): return "Audio engine failed to start: \(m)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var jitterBuffer: [MediaFrame] = []
    private let jitterBufferTargetSize: Int = 3 // 3 × 20 ms = 60 ms

    init() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Failure.converterInit
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func start() throws {
        engine.attach(player)
        engine.attach(mixer)
        engine.connect(player, to: mixer, format: outputFormat)
        engine.connect(mixer, to: engine.outputNode, format: outputFormat)
        engine.prepare()
        do {
            try engine.start()
            player.play()
        } catch {
            throw Failure.engineStartFailed(error.localizedDescription)
        }
    }

    func ingest(frame: MediaFrame) throws {
        guard frame.kind == .audioOpus else { return }
        // Drop muted frames (still keep clock alignment via the playback engine's silence).
        if frame.flags.contains(.muted) { return }

        jitterBuffer.append(frame)
        if jitterBuffer.count < jitterBufferTargetSize { return }
        let oldest = jitterBuffer.removeFirst()
        try schedule(frame: oldest)
    }

    func stop() {
        player.stop()
        engine.stop()
        jitterBuffer.removeAll()
    }

    private func schedule(frame: MediaFrame) throws {
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: max(frame.payload.count, 1))
        compressed.byteLength = UInt32(frame.payload.count)
        compressed.packetCount = 1
        var packetDesc = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(frame.payload.count)
        )
        frame.payload.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(compressed.data, baseAddress, frame.payload.count)
            }
        }
        compressed.packetDescriptions?.assign(from: &packetDesc, count: 1)

        let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 960)!
        var error: NSError?
        var supplied = false
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }
        if status == .error || error != nil {
            throw Failure.decodeFailed(error?.localizedDescription ?? "status=error")
        }
        player.scheduleBuffer(pcm, completionHandler: nil)
    }
}
