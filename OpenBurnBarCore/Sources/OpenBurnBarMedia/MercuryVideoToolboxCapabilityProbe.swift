#if canImport(CoreMedia) && canImport(VideoToolbox)
import CoreMedia
import Foundation
import VideoToolbox

public enum MercuryVideoToolboxCapabilityProbe {
    public static func snapshot(
        width: Int32 = 1920,
        height: Int32 = 1080,
        datagramMaxPayloadBytes: Int? = nil,
        mediaFrameVersions: MercuryMediaFrameVersionSupport = .v1Only
    ) -> MercuryStreamingCapabilitySnapshot {
        MercuryStreamingCapabilitySnapshot(
            codecCapabilities: MercuryVideoCodec.allCases.map {
                capability(for: $0, width: width, height: height)
            },
            mediaFrameVersions: mediaFrameVersions,
            videoDatagrams: MercuryDatagramCapability(maxPayloadBytes: datagramMaxPayloadBytes),
            source: "VideoToolbox"
        )
    }

    public static func capability(
        for codec: MercuryVideoCodec,
        width: Int32 = 1920,
        height: Int32 = 1080
    ) -> MercuryVideoCodecCapability {
        let codecType = cmCodecType(for: codec)
        let canEncode = canCreateEncoder(codecType: codecType, width: width, height: height)
        let lowLatencyEncode = canCreateEncoder(
            codecType: codecType,
            width: width,
            height: height,
            lowLatencyRateControl: true
        )
        return MercuryVideoCodecCapability(
            codec: codec,
            canEncode: canEncode,
            canDecode: VTIsHardwareDecodeSupported(codecType),
            hardwareAccelerated: encoderListReportsHardware(codecType: codecType),
            lowLatencyEncode: lowLatencyEncode,
            temporalLayering: false,
            longTermReference: canEncode && supportsLTR(codecType: codecType, width: width, height: height),
            screenContentCoding: false
        )
    }

    private static func canCreateEncoder(
        codecType: CMVideoCodecType,
        width: Int32,
        height: Int32,
        lowLatencyRateControl: Bool = false
    ) -> Bool {
        var session: VTCompressionSession?
        let encoderSpecification: CFDictionary?
        if lowLatencyRateControl {
            encoderSpecification = [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true as CFBoolean
            ] as CFDictionary
        } else {
            encoderSpecification = nil
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        return status == noErr && session != nil
    }

    private static func supportsLTR(codecType: CMVideoCodecType, width: Int32, height: Int32) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return false }
        return VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_EnableLTR,
            value: kCFBooleanTrue
        ) == noErr
    }

    private static func encoderListReportsHardware(codecType: CMVideoCodecType) -> Bool {
        var rawList: CFArray?
        guard VTCopyVideoEncoderList(nil, &rawList) == noErr,
              let encoders = rawList as? [[CFString: Any]] else {
            return false
        }

        return encoders.contains { encoder in
            guard let rawCodec = encoder[kVTVideoEncoderList_CodecType] as? NSNumber,
                  CMVideoCodecType(rawCodec.uint32Value) == codecType else {
                return false
            }
            return (encoder[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool) == true
        }
    }

    private static func cmCodecType(for codec: MercuryVideoCodec) -> CMVideoCodecType {
        switch codec {
        case .av1:
            return CMVideoCodecType(kCMVideoCodecType_AV1)
        case .hevc:
            return CMVideoCodecType(kCMVideoCodecType_HEVC)
        case .h264:
            return CMVideoCodecType(kCMVideoCodecType_H264)
        }
    }
}
#endif
