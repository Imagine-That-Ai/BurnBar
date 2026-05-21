import Foundation
import OpenBurnBarCore

/// Codec names used by Mercury's next-generation mirror streaming probes.
///
/// This is intentionally separate from `VideoDecoderConfigurationPayload.Codec`:
/// that existing v1 payload only supports the codecs already shipped on the
/// wire. AV1 remains a capability-probed experiment until a negotiated v2
/// envelope exists.
public enum MercuryVideoCodec: String, CaseIterable, Codable, Sendable, Equatable {
    case av1
    case hevc
    case h264
}

public struct MercuryVideoCodecCapability: Codable, Sendable, Equatable {
    public var codec: MercuryVideoCodec
    public var canEncode: Bool
    public var canDecode: Bool
    public var hardwareAccelerated: Bool
    public var lowLatencyEncode: Bool
    public var temporalLayering: Bool
    public var longTermReference: Bool
    public var screenContentCoding: Bool

    public init(
        codec: MercuryVideoCodec,
        canEncode: Bool,
        canDecode: Bool,
        hardwareAccelerated: Bool,
        lowLatencyEncode: Bool = false,
        temporalLayering: Bool = false,
        longTermReference: Bool = false,
        screenContentCoding: Bool = false
    ) {
        self.codec = codec
        self.canEncode = canEncode
        self.canDecode = canDecode
        self.hardwareAccelerated = hardwareAccelerated
        self.lowLatencyEncode = lowLatencyEncode
        self.temporalLayering = temporalLayering
        self.longTermReference = longTermReference
        self.screenContentCoding = screenContentCoding
    }
}

public struct MercuryMediaFrameVersionSupport: Codable, Sendable, Equatable {
    public var supportsV1: Bool
    public var supportsV2: Bool

    public init(supportsV1: Bool = true, supportsV2: Bool = false) {
        self.supportsV1 = supportsV1
        self.supportsV2 = supportsV2
    }

    public static let v1Only = MercuryMediaFrameVersionSupport(supportsV1: true, supportsV2: false)
    public static let v1AndV2 = MercuryMediaFrameVersionSupport(supportsV1: true, supportsV2: true)
}

public enum MercuryMediaFrameWireVersion: Int, Codable, Sendable, Equatable {
    case v1 = 1
    case v2 = 2
}

public struct MercuryDatagramCapability: Codable, Sendable, Equatable {
    /// `nil` means QUIC datagrams are disabled or unsupported by this peer/path.
    public var maxPayloadBytes: Int?

    public init(maxPayloadBytes: Int?) {
        self.maxPayloadBytes = maxPayloadBytes
    }

    public var isSupported: Bool {
        guard let maxPayloadBytes else { return false }
        return maxPayloadBytes > 0
    }

    public func payloadBudget(reserving overheadBytes: Int) -> Int? {
        guard let maxPayloadBytes, maxPayloadBytes > overheadBytes else { return nil }
        return maxPayloadBytes - overheadBytes
    }
}

public enum MercuryDatagramCapabilityProbe {
    public static func snapshot(maxDatagramSize: UInt32?) -> MercuryDatagramCapability {
        guard let maxDatagramSize, maxDatagramSize > 0 else {
            return MercuryDatagramCapability(maxPayloadBytes: nil)
        }
        return MercuryDatagramCapability(maxPayloadBytes: Int(maxDatagramSize))
    }

    public static func snapshot(_ readMaxDatagramSize: () throws -> UInt32?) -> MercuryDatagramCapability {
        do {
            return snapshot(maxDatagramSize: try readMaxDatagramSize())
        } catch {
            return MercuryDatagramCapability(maxPayloadBytes: nil)
        }
    }
}

public struct MercuryStreamingCapabilitySnapshot: Codable, Sendable, Equatable {
    public var codecCapabilities: [MercuryVideoCodecCapability]
    public var mediaFrameVersions: MercuryMediaFrameVersionSupport
    public var videoDatagrams: MercuryDatagramCapability
    public var source: String

    public init(
        codecCapabilities: [MercuryVideoCodecCapability],
        mediaFrameVersions: MercuryMediaFrameVersionSupport = .v1Only,
        videoDatagrams: MercuryDatagramCapability = MercuryDatagramCapability(maxPayloadBytes: nil),
        source: String
    ) {
        self.codecCapabilities = codecCapabilities
        self.mediaFrameVersions = mediaFrameVersions
        self.videoDatagrams = videoDatagrams
        self.source = source
    }

    public func capability(for codec: MercuryVideoCodec) -> MercuryVideoCodecCapability? {
        codecCapabilities.first { $0.codec == codec }
    }

    public func canEncode(_ codec: MercuryVideoCodec) -> Bool {
        capability(for: codec)?.canEncode == true
    }

    public func canDecode(_ codec: MercuryVideoCodec) -> Bool {
        capability(for: codec)?.canDecode == true
    }
}

public struct MercuryCodecPolicy: Sendable, Equatable {
    public var allowExperimentalAV1: Bool
    public var preferredCodecs: [MercuryVideoCodec]

    public init(
        allowExperimentalAV1: Bool = false,
        preferredCodecs: [MercuryVideoCodec] = [.av1, .hevc, .h264]
    ) {
        self.allowExperimentalAV1 = allowExperimentalAV1
        self.preferredCodecs = preferredCodecs
    }

    /// Production policy: do not select AV1 until both peers have proven
    /// runtime support and the rollout flag explicitly permits it.
    public static let production = MercuryCodecPolicy(
        allowExperimentalAV1: false,
        preferredCodecs: [.hevc, .h264]
    )

    public static let experimentalAV1 = MercuryCodecPolicy(
        allowExperimentalAV1: true,
        preferredCodecs: [.av1, .hevc, .h264]
    )
}

public enum MercuryCodecResolver {
    public static func resolveSendCodec(
        local: MercuryStreamingCapabilitySnapshot,
        remote: MercuryStreamingCapabilitySnapshot,
        policy: MercuryCodecPolicy = .production
    ) -> MercuryVideoCodec? {
        for codec in policy.preferredCodecs {
            if codec == .av1 && !policy.allowExperimentalAV1 {
                continue
            }
            guard local.canEncode(codec), remote.canDecode(codec) else {
                continue
            }
            return codec
        }
        return nil
    }
}

public enum MercuryWireVersionNegotiator {
    public static func resolve(
        local: MercuryMediaFrameVersionSupport,
        remote: MercuryMediaFrameVersionSupport
    ) -> MercuryMediaFrameWireVersion {
        if local.supportsV2 && remote.supportsV2 {
            return .v2
        }
        return .v1
    }

    public static func canSendMetadataV2(
        local: MercuryMediaFrameVersionSupport,
        remote: MercuryMediaFrameVersionSupport
    ) -> Bool {
        resolve(local: local, remote: remote) == .v2
    }
}

public extension MercuryVideoCodec {
    init?(wire: HermesRealtimeRelayVideoCodec) {
        switch wire {
        case .av1: self = .av1
        case .hevc: self = .hevc
        case .h264: self = .h264
        }
    }

    var wireValue: HermesRealtimeRelayVideoCodec {
        switch self {
        case .av1: return .av1
        case .hevc: return .hevc
        case .h264: return .h264
        }
    }
}

public extension MercuryVideoCodecCapability {
    init(wire: HermesRealtimeRelayVideoCodecCapability) {
        self.init(
            codec: MercuryVideoCodec(wire: wire.codec) ?? .h264,
            canEncode: wire.canEncode,
            canDecode: wire.canDecode,
            hardwareAccelerated: wire.hardwareAccelerated,
            lowLatencyEncode: wire.lowLatencyEncode,
            temporalLayering: wire.temporalLayering,
            longTermReference: wire.longTermReference,
            screenContentCoding: wire.screenContentCoding
        )
    }

    var wireValue: HermesRealtimeRelayVideoCodecCapability {
        HermesRealtimeRelayVideoCodecCapability(
            codec: codec.wireValue,
            canEncode: canEncode,
            canDecode: canDecode,
            hardwareAccelerated: hardwareAccelerated,
            lowLatencyEncode: lowLatencyEncode,
            temporalLayering: temporalLayering,
            longTermReference: longTermReference,
            screenContentCoding: screenContentCoding
        )
    }
}

public extension MercuryMediaFrameVersionSupport {
    init(wire: HermesRealtimeRelayMediaFrameVersionSupport) {
        self.init(supportsV1: wire.supportsV1, supportsV2: wire.supportsV2)
    }

    var wireValue: HermesRealtimeRelayMediaFrameVersionSupport {
        HermesRealtimeRelayMediaFrameVersionSupport(
            supportsV1: supportsV1,
            supportsV2: supportsV2
        )
    }
}

public extension MercuryDatagramCapability {
    init(wire: HermesRealtimeRelayDatagramCapability) {
        self.init(maxPayloadBytes: wire.maxPayloadBytes)
    }

    var wireValue: HermesRealtimeRelayDatagramCapability {
        HermesRealtimeRelayDatagramCapability(maxPayloadBytes: maxPayloadBytes)
    }
}

public extension MercuryStreamingCapabilitySnapshot {
    init(wire: HermesRealtimeRelayStreamingCapabilities) {
        self.init(
            codecCapabilities: wire.codecCapabilities.map(MercuryVideoCodecCapability.init(wire:)),
            mediaFrameVersions: MercuryMediaFrameVersionSupport(wire: wire.mediaFrameVersions),
            videoDatagrams: MercuryDatagramCapability(wire: wire.videoDatagrams),
            source: wire.source
        )
    }

    var wireValue: HermesRealtimeRelayStreamingCapabilities {
        HermesRealtimeRelayStreamingCapabilities(
            codecCapabilities: codecCapabilities.map(\.wireValue),
            mediaFrameVersions: mediaFrameVersions.wireValue,
            videoDatagrams: videoDatagrams.wireValue,
            source: source
        )
    }
}
