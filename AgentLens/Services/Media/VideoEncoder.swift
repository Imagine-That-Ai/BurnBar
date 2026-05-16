import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import OpenBurnBarMedia

/// HEVC (H.265) video encoder for the Mac side of Phase 3 + 5.
/// `VTCompressionSession`-backed. Falls back to H.264 when HEVC hardware
/// encode isn't available (pre-Skylake Intel Macs).
///
/// Encoded NAL units are wrapped in `MediaFrame` envelopes via
/// `MediaPacketCodec` and emitted to the iroh stream as one stream per
/// GOP. Keyframe interval pinned at 2 s for fast recovery on stalled
/// streams.
@MainActor
final class VideoEncoder {
    enum Codec: String, Equatable, Sendable {
        case hevc
        case h264
    }

    enum Failure: Error, LocalizedError {
        case sessionCreate(OSStatus)
        case sessionConfigure(OSStatus)
        case encodeSubmit(OSStatus)

        var errorDescription: String? {
            switch self {
            case .sessionCreate(let status):
                return "Failed to create video encoder session (\(status))."
            case .sessionConfigure(let status):
                return "Failed to configure video encoder (\(status))."
            case .encodeSubmit(let status):
                return "Failed to submit frame to video encoder (\(status))."
            }
        }
    }

    struct Configuration: Sendable, Equatable {
        var width: Int32
        var height: Int32
        var targetBitsPerSecond: Int
        var keyframeIntervalSeconds: Double
        var preferredCodec: Codec
        var frameRate: Int32
    }

    typealias EncodedHandler = @Sendable (MediaFrame) async -> Void

    private let configuration: Configuration
    private let codec: MediaPacketCodec
    private let onEncoded: EncodedHandler
    private var session: VTCompressionSession?
    private var resolvedCodec: Codec
    private var currentGopID: UInt32 = 0
    private var currentFrameIndex: UInt32 = 0

    init(
        configuration: Configuration,
        codec: MediaPacketCodec = MediaPacketCodec(),
        onEncoded: @escaping EncodedHandler
    ) {
        self.configuration = configuration
        self.codec = codec
        self.onEncoded = onEncoded
        self.resolvedCodec = configuration.preferredCodec
    }

    func start() throws {
        let codecType = resolvedCodec == .hevc
            ? CMVideoCodecType(kCMVideoCodecType_HEVC)
            : CMVideoCodecType(kCMVideoCodecType_H264)

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: configuration.width,
            height: configuration.height,
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            // HEVC may not be available — fall back to H.264 once.
            if resolvedCodec == .hevc {
                resolvedCodec = .h264
                try start()
                return
            }
            throw Failure.sessionCreate(status)
        }
        self.session = session

        try setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue!)
        try setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse!)
        try setProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: configuration.targetBitsPerSecond)
        )
        try setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: configuration.keyframeIntervalSeconds)
        )
        try setProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: Int(configuration.frameRate))
        )
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func setTargetBitsPerSecond(_ bps: Int) throws {
        guard let session else { return }
        try setProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps))
    }

    func encode(sampleBuffer: CMSampleBuffer) async throws {
        guard let session, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        var infoFlags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: &infoFlags
        ) { [weak self] _, _, status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            Task.detached { [weak self] in
                await self?.handleEncodedSampleBuffer(sampleBuffer)
            }
        }
        if status != noErr {
            throw Failure.encodeSubmit(status)
        }
    }

    func stop() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    nonisolated private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else { return }
        let payload = Data(bytes: dataPointer, count: totalLength)
        let isKeyframe = await isKeyframe(sampleBuffer: sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMillis = UInt64(pts.seconds * 1000)

        let frameSnapshot = await Self.nextFrameIndices(forKeyframe: isKeyframe, on: self)
        let flags: MediaFrame.Flags = isKeyframe ? [.keyframe] : []
        let frame = MediaFrame(
            kind: .videoNAL,
            flags: flags,
            gopID: frameSnapshot.gopID,
            frameIndex: frameSnapshot.frameIndex,
            presentationTimestampMillis: ptsMillis,
            payload: payload
        )
        await onEncoded(frame)
    }

    private static func nextFrameIndices(
        forKeyframe isKeyframe: Bool,
        on encoder: VideoEncoder
    ) async -> (gopID: UInt32, frameIndex: UInt32) {
        await MainActor.run {
            if isKeyframe {
                encoder.currentGopID = encoder.currentGopID &+ 1
                encoder.currentFrameIndex = 0
            } else {
                encoder.currentFrameIndex = encoder.currentFrameIndex &+ 1
            }
            return (encoder.currentGopID, encoder.currentFrameIndex)
        }
    }

    nonisolated private func isKeyframe(sampleBuffer: CMSampleBuffer) async -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return false
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            throw Failure.sessionConfigure(status)
        }
    }
}
