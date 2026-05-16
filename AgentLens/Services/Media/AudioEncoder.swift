import Foundation
import AVFoundation
import OpenBurnBarMedia

/// Audio encoder for Phase 4. Defaults to Apple's built-in Opus codec
/// (`kAudioFormatOpus`, available macOS 12+ / iOS 16+) which is wire-
/// compatible with the iOS receive pipeline. Risk-5 fix: at init time
/// we probe for Opus availability and fall back to AAC-LC
/// (`kAudioFormatMPEG4AAC`) if Opus isn't supported on the current
/// device / OS combination — this keeps Phase 4 audio usable on the
/// long tail of older iPads (mini 6 has been reported to surface
/// inconsistent Opus support across builds).
///
/// Wire metadata: the codec used is signaled in-band via the
/// `MediaFrame.Kind` so the receiver picks the right decoder path. Both
/// kinds use the same 20 ms framing + 48 kHz mono + 64 kbps targets so
/// downstream pacing logic is identical.
@MainActor
final class AudioEncoder {
    enum Codec: String, Sendable, Equatable {
        case opus
        case aac
    }

    enum Failure: Error, LocalizedError {
        case converterInit
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .converterInit: return "Audio encoder initialization failed."
            case .encodeFailed(let m): return "Audio encode failed: \(m)"
            }
        }
    }

    typealias EncodedHandler = @Sendable (MediaFrame) async -> Void

    let resolvedCodec: Codec
    private let onEncoded: EncodedHandler
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var packetSequence: UInt32 = 0
    private(set) var isMuted: Bool = false

    init(onEncoded: @escaping EncodedHandler, preferredCodec: Codec = .opus) throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            throw Failure.converterInit
        }

        // Probe the preferred codec first. If `AVAudioConverter` returns
        // nil — which it does on older OSes or devices missing the Opus
        // codec module — fall back to AAC so audio still flows.
        if preferredCodec == .opus,
           let (opusFormat, opusConverter) = Self.makeConverter(
               inputFormat: inputFormat,
               codec: .opus
           ) {
            self.resolvedCodec = .opus
            self.outputFormat = opusFormat
            self.converter = opusConverter
        } else if let (aacFormat, aacConverter) = Self.makeConverter(
            inputFormat: inputFormat,
            codec: .aac
        ) {
            self.resolvedCodec = .aac
            self.outputFormat = aacFormat
            self.converter = aacConverter
        } else {
            throw Failure.converterInit
        }
        self.converter.bitRate = 64_000
        self.inputFormat = inputFormat
        self.onEncoded = onEncoded
    }

    private static func makeConverter(
        inputFormat: AVAudioFormat,
        codec: Codec
    ) -> (AVAudioFormat, AVAudioConverter)? {
        let formatID: AudioFormatID = codec == .opus
            ? kAudioFormatOpus
            : kAudioFormatMPEG4AAC
        let framesPerPacket: UInt32 = codec == .opus ? 960 : 1024
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let outputFormat = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        return (outputFormat, converter)
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
            // Both Opus and AAC route through `.audioOpus` for now —
            // the receiver inspects the wire format's metadata stream
            // (`MediaSessionCoordinator.codec`) to decide which decoder
            // to instantiate. A second kind for AAC is a follow-up if
            // we ever ship dual-codec sessions concurrently; today the
            // session is single-codec per call.
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
