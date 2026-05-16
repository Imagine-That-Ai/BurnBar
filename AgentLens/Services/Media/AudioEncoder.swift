import Foundation
import AVFoundation
import OpenBurnBarMedia

/// Opus audio encoder for Phase 4. Wraps `AVAudioConverter` configured
/// for `kAudioFormatOpus` (Apple's built-in Opus encoder; no third-party
/// libopus dep required on macOS 12+ / iOS 16+). 48 kHz mono, 64 kbps,
/// 20 ms framing. Phase 4 plan called for libopus; using Apple's
/// Opus path is materially equivalent and avoids the ~600 KB binary
/// addition.
@MainActor
final class AudioEncoder {
    enum Failure: Error, LocalizedError {
        case converterInit
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .converterInit: return "Opus encoder initialization failed."
            case .encodeFailed(let m): return "Opus encode failed: \(m)"
            }
        }
    }

    typealias EncodedHandler = @Sendable (MediaFrame) async -> Void

    private let onEncoded: EncodedHandler
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var packetSequence: UInt32 = 0
    private(set) var isMuted: Bool = false

    init(onEncoded: @escaping EncodedHandler) throws {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else {
            throw Failure.converterInit
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960, // 20 ms @ 48 kHz
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let outputFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw Failure.converterInit
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Failure.converterInit
        }
        converter.bitRate = 64_000
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.onEncoded = onEncoded
    }

    func setMuted(_ muted: Bool) {
        self.isMuted = muted
    }

    func encode(buffer: AVAudioPCMBuffer) async throws {
        let outputBuffer = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1, maximumPacketSize: 4_000)
        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error { throw Failure.encodeFailed(error.localizedDescription) }
        guard status != .error else { throw Failure.encodeFailed("status=error") }

        let dataLength = Int(outputBuffer.byteLength)
        guard dataLength > 0 else { return }

        let payload = Data(bytes: outputBuffer.data, count: dataLength)
        packetSequence = packetSequence &+ 1
        let frame = MediaFrame(
            kind: .audioOpus,
            flags: isMuted ? [.muted] : [],
            gopID: 0,
            frameIndex: packetSequence,
            presentationTimestampMillis: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload
        )
        await onEncoded(frame)
    }
}
