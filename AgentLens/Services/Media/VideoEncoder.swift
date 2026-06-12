import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import OpenBurnBarMedia

private final class SendableVideoSampleBuffer: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer

    init(_ sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

/// HEVC (H.265) video encoder for the Mac side of Phase 3 + 5.
/// `VTCompressionSession`-backed. Falls back to H.264 when HEVC hardware
/// encode isn't available (pre-Skylake Intel Macs).
///
/// Encoded NAL units are wrapped in `MediaFrame` envelopes via
/// `MediaPacketCodec` and emitted to the iroh stream as one stream per
/// GOP. Keyframe interval pinned at 2 s for fast recovery on stalled
/// streams.
@MainActor
protocol VideoEncoding: AnyObject {
    func start() throws
    func setTargetBitsPerSecond(_ bps: Int) throws
    func encode(sampleBuffer: CMSampleBuffer) async throws
    func requestLongTermReferenceRefresh()
    func acknowledgeLongTermReferenceToken(_ tokenValue: UInt64)
    func stop()
}

@MainActor
final class VideoEncoder: VideoEncoding {
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
        var enableLongTermReference: Bool = false
    }

    struct EncodedFrame: Sendable, Equatable {
        var frame: MediaFrame
        var longTermReferenceToken: MercuryLTRToken?
    }

    typealias EncodedHandler = @Sendable (EncodedFrame) async -> Void

    private let configuration: Configuration
    private let codec: MediaPacketCodec
    private let onEncoded: EncodedHandler
    private var session: VTCompressionSession?
    private var resolvedCodec: Codec
    private var currentGopID: UInt32 = 0
    private var currentFrameIndex: UInt32 = 0
    private var ltrState = MercuryLTRRecoveryState()

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
        if configuration.enableLongTermReference {
            try setProperty(session, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue!)
        }
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
        let frameProperties = framePropertiesForNextFrame()

        var infoFlags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: &infoFlags
        ) { [weak self] (status: OSStatus, _: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) in
            guard let self, status == noErr, let sampleBuffer else { return }
            let snapshot = SendableVideoSampleBuffer(sampleBuffer)
            Task.detached { [weak self, snapshot] in
                await self?.handleEncodedSampleBuffer(snapshot.sampleBuffer)
            }
        }
        if status != noErr {
            throw Failure.encodeSubmit(status)
        }
    }

    func requestLongTermReferenceRefresh() {
        ltrState.requestRefresh()
    }

    func acknowledgeLongTermReferenceToken(_ tokenValue: UInt64) {
        ltrState.acknowledgeDecodedToken(MercuryLTRToken(value: tokenValue))
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
        let isKeyframe = await isKeyframe(sampleBuffer: sampleBuffer)
        let samplePayload = Data(bytes: dataPointer, count: totalLength)
        let payload = await payloadForWire(samplePayload: samplePayload, sampleBuffer: sampleBuffer, isKeyframe: isKeyframe)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMillis = UInt64(pts.seconds * 1000)
        let ltrTokenValue = Self.longTermReferenceTokenValue(sampleBuffer: sampleBuffer)

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
        await Self.recordLongTermReferenceToken(ltrTokenValue, on: self)
        await onEncoded(EncodedFrame(
            frame: frame,
            longTermReferenceToken: ltrTokenValue.map(MercuryLTRToken.init(value:))
        ))
    }

    nonisolated private func payloadForWire(
        samplePayload: Data,
        sampleBuffer: CMSampleBuffer,
        isKeyframe: Bool
    ) async -> Data {
        guard isKeyframe,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let configuration = decoderConfigurationPayload(
                samplePayload: samplePayload,
                formatDescription: formatDescription
              )
        else {
            return samplePayload
        }
        return configuration
    }

    nonisolated private func decoderConfigurationPayload(
        samplePayload: Data,
        formatDescription: CMFormatDescription
    ) -> Data? {
        let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
        switch codecType {
        case CMVideoCodecType(kCMVideoCodecType_HEVC):
            return hevcConfigurationPayload(samplePayload: samplePayload, formatDescription: formatDescription)
        case CMVideoCodecType(kCMVideoCodecType_H264):
            return h264ConfigurationPayload(samplePayload: samplePayload, formatDescription: formatDescription)
        default:
            return nil
        }
    }

    nonisolated private func hevcConfigurationPayload(
        samplePayload: Data,
        formatDescription: CMFormatDescription
    ) -> Data? {
        var count = 0
        var nalHeaderLength: Int32 = 0
        let probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard probe == noErr, count > 0 else { return nil }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { continue }
            parameterSets.append(Data(bytes: pointer, count: size))
        }
        guard !parameterSets.isEmpty else { return nil }
        return try? VideoDecoderConfigurationPayload(
            codec: .hevc,
            parameterSets: parameterSets,
            samplePayload: samplePayload
        ).encoded()
    }

    nonisolated private func h264ConfigurationPayload(
        samplePayload: Data,
        formatDescription: CMFormatDescription
    ) -> Data? {
        var count = 0
        var nalHeaderLength: Int32 = 0
        let probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard probe == noErr, count > 0 else { return nil }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { continue }
            parameterSets.append(Data(bytes: pointer, count: size))
        }
        guard !parameterSets.isEmpty else { return nil }
        return try? VideoDecoderConfigurationPayload(
            codec: .h264,
            parameterSets: parameterSets,
            samplePayload: samplePayload
        ).encoded()
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

    private static func recordLongTermReferenceToken(
        _ tokenValue: UInt64?,
        on encoder: VideoEncoder
    ) async {
        await MainActor.run {
            guard encoder.configuration.enableLongTermReference,
                  tokenValue != nil || encoder.ltrState.refreshRequested else {
                return
            }
            _ = encoder.ltrState.recordEncodedRefreshToken(tokenValue)
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

    nonisolated private static func longTermReferenceTokenValue(sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first,
              let token = first[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber else {
            return nil
        }
        return token.uint64Value
    }

    private func framePropertiesForNextFrame() -> CFDictionary? {
        guard configuration.enableLongTermReference else { return nil }
        var properties: [CFString: Any] = [:]
        if ltrState.refreshRequested {
            properties[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true
        }
        let acknowledgedTokens = ltrState.acknowledgedTokenValuesForEncoder.map { NSNumber(value: $0) }
        if !acknowledgedTokens.isEmpty {
            properties[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acknowledgedTokens
        }
        return properties.isEmpty ? nil : properties as CFDictionary
    }

    private func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            throw Failure.sessionConfigure(status)
        }
    }
}
