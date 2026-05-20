import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import OpenBurnBarMedia

/// iOS-side decode pipeline for inbound video frames. Phase 3 (Mac
/// screen share, HEVC) and Phase 5 (Mac webcam, HEVC). Reads
/// `MediaFrame`s, decodes via `VTDecompressionSession`, and emits
/// `CMSampleBuffer`s for `AVSampleBufferDisplayLayer`.
@MainActor
final class VideoReceivePipeline {
    enum Codec: String, Sendable, Equatable {
        case hevc
        case h264
    }

    enum Failure: Error, LocalizedError {
        case sessionCreate(OSStatus)
        case formatDescription(OSStatus)
        case decodeSubmit(OSStatus)

        var errorDescription: String? {
            switch self {
            case .sessionCreate(let status):
                return "Failed to create video decoder session (\(status))."
            case .formatDescription(let status):
                return "Failed to build format description (\(status))."
            case .decodeSubmit(let status):
                return "Failed to submit frame to video decoder (\(status))."
            }
        }
    }

    typealias DecodedHandler = @Sendable (CMSampleBuffer) async -> Void

    private let codec: Codec
    private let onDecoded: DecodedHandler
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var activeCodec: Codec
    private var currentGopID: UInt32 = .max

    init(codec: Codec = .hevc, onDecoded: @escaping DecodedHandler) {
        self.codec = codec
        self.activeCodec = codec
        self.onDecoded = onDecoded
    }

    func ingest(frame: MediaFrame) async throws {
        let decoderPayload = try VideoDecoderConfigurationPayload.decodeIfPresent(frame.payload)
        let samplePayload = decoderPayload?.samplePayload ?? frame.payload
        if frame.flags.contains(.keyframe) || frame.gopID != currentGopID {
            currentGopID = frame.gopID
            if let decoderPayload {
                try buildFormatDescription(from: decoderPayload)
            } else {
                try buildFormatDescription(from: samplePayload)
            }
        }
        guard let formatDescription, let session else {
            // Cannot decode without a format description; drop until next keyframe.
            return
        }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: samplePayload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: samplePayload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else { return }

        try samplePayload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: rawBuffer.count
            )
            if copyStatus != noErr {
                throw Failure.decodeSubmit(copyStatus)
            }
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = samplePayload.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(frame.presentationTimestampMillis),
                timescale: 1_000
            ),
            decodeTimeStamp: .invalid
        )
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }
        markForImmediateDisplay(sampleBuffer)

        await onDecoded(sampleBuffer)

        var infoFlags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags,
            outputHandler: { (_: OSStatus, _: VTDecodeInfoFlags, _: CVImageBuffer?, _: CMTime, _: CMTime) in
                // No-op — the receiver's `AVSampleBufferDisplayLayer`
                // consumes the original sample buffer directly. The
                // VTDecompressionSession is held primarily to keep an
                // active hardware path warm.
            }
        )
        if decodeStatus != noErr {
            throw Failure.decodeSubmit(decodeStatus)
        }
    }

    func teardown() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    private func buildFormatDescription(from payload: Data) throws {
        let codecType = activeCodec == .hevc
            ? CMVideoCodecType(kCMVideoCodecType_HEVC)
            : CMVideoCodecType(kCMVideoCodecType_H264)

        var description: CMFormatDescription?
        let status = payload.withUnsafeBytes { rawBuffer -> OSStatus in
            guard rawBuffer.baseAddress != nil else { return -1 }
            return CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codecType,
                width: 1920,
                height: 1080,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw Failure.formatDescription(status)
        }
        self.formatDescription = description

        try recreateSession(with: description)
    }

    private func buildFormatDescription(from decoderPayload: VideoDecoderConfigurationPayload) throws {
        activeCodec = decoderPayload.codec == .hevc ? .hevc : .h264
        let parameterSets = decoderPayload.parameterSets
        var description: CMFormatDescription?
        let status: OSStatus

        switch decoderPayload.codec {
        case .hevc:
            status = withUnsafeParameterSetPointers(parameterSets) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            } ?? -1
        case .h264:
            status = withUnsafeParameterSetPointers(parameterSets) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            } ?? -1
        }

        guard status == noErr, let description else {
            throw Failure.formatDescription(status)
        }
        self.formatDescription = description
        try recreateSession(with: description)
    }

    private func withUnsafeParameterSetPointers<R>(
        _ parameterSets: [Data],
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R
    ) -> R? {
        guard !parameterSets.isEmpty else { return nil }

        var pointers: [UnsafePointer<UInt8>] = []
        pointers.reserveCapacity(parameterSets.count)
        let sizes = parameterSets.map(\.count)

        func recurse(_ index: Int) -> R? {
            if index == parameterSets.count {
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        guard let pointerBase = pointerBuffer.baseAddress,
                              let sizeBase = sizeBuffer.baseAddress else {
                            return nil
                        }
                        return body(pointerBase, sizeBase)
                    }
                }
            }

            return parameterSets[index].withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return nil
                }
                pointers.append(baseAddress)
                defer { _ = pointers.popLast() }
                return recurse(index + 1)
            }
        }

        return recurse(0)
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
              let attachment = attachments.first else {
            return
        }
        attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
    }

    private func recreateSession(with description: CMFormatDescription) throws {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        var session: VTDecompressionSession?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if createStatus != noErr {
            throw Failure.sessionCreate(createStatus)
        }
        self.session = session
    }
}
