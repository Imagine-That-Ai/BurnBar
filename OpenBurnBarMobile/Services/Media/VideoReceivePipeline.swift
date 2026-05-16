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
    private var currentGopID: UInt32 = .max

    init(codec: Codec = .hevc, onDecoded: @escaping DecodedHandler) {
        self.codec = codec
        self.onDecoded = onDecoded
    }

    func ingest(frame: MediaFrame) async throws {
        if frame.flags.contains(.keyframe) || frame.gopID != currentGopID {
            currentGopID = frame.gopID
            try buildFormatDescription(from: frame.payload)
        }
        guard let formatDescription, let session else {
            // Cannot decode without a format description; drop until next keyframe.
            return
        }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.payload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else { return }

        try frame.payload.withUnsafeBytes { rawBuffer in
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
        var sampleSize = frame.payload.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        await onDecoded(sampleBuffer)

        var infoFlags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags,
            outputHandler: { _, _, _, _ in
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
        let codecType = codec == .hevc
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
