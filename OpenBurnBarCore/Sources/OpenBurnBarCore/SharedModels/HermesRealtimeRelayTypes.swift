import Foundation

public enum HermesRealtimeRelayProtocol {
    public static let version = 1
    public static let capability = "realtime_relay"
    public static let defaultHostedRelayURLString = "wss://hermes-realtime-relay-cjrjb5ckqq-uc.a.run.app/v1/hermes/ws"
    public static let roleHeaderName = "X-OpenBurnBar-Relay-Role"
    public static let hostRoleHeaderValue = "host"
    public static let clientRoleHeaderValue = "client"
}

public enum HermesRealtimeRelayFrameType: String, Codable, Sendable, Equatable {
    case hostRegister = "host.register"
    case hostReady = "host.ready"
    case requestStart = "request.start"
    case requestCancel = "request.cancel"
    case responseChunk = "response.chunk"
    case responseComplete = "response.complete"
    case responseError = "response.error"
    case ping
    case pong
    // Mercury media rollout — see plans/2026-05-15-mercury-media-master-plan.md
    // and docs/HERMES_MEDIA_TRANSPORT.md. Older peers skip unknown frame types
    // on the chat stream so adding cases here is forward-compatible.
    case mediaClassify = "media.classify"
    case mediaBlobAdvertise = "media.blob.advertise"
    case mediaBlobAck = "media.blob.ack"
}

public struct HermesRealtimeRelayFrame: Codable, Sendable, Equatable {
    public var type: HermesRealtimeRelayFrameType
    public var uid: String
    public var connectionId: String
    public var requestId: String?
    public var protocolVersion: Int
    public var runtime: String?
    public var payload: HermesRealtimeRelayPayload?
    // Optional sibling to `payload`. Carries Mercury media metadata
    // (stream-class negotiation, blob advertisement, ack). Encoded only
    // when non-nil so chat-only traffic stays byte-identical to the
    // pre-rollout wire form.
    public var media: HermesRealtimeRelayMediaPayload?

    public init(
        type: HermesRealtimeRelayFrameType,
        uid: String,
        connectionId: String,
        requestId: String? = nil,
        protocolVersion: Int = HermesRealtimeRelayProtocol.version,
        runtime: String? = nil,
        payload: HermesRealtimeRelayPayload? = nil,
        media: HermesRealtimeRelayMediaPayload? = nil
    ) {
        self.type = type
        self.uid = uid
        self.connectionId = connectionId
        self.requestId = requestId
        self.protocolVersion = protocolVersion
        self.runtime = runtime
        self.payload = payload
        self.media = media
    }
}

public struct HermesRealtimeRelayMediaPayload: Codable, Sendable, Equatable {
    /// Identifier of the media stream class this frame addresses
    /// (`media.blob`, `media.screen.video`, `media.video.out`, etc.). Carried
    /// as a string rather than a closed enum so receivers route unknown
    /// classes to a no-op handler instead of failing to decode.
    public var streamClass: String?
    /// Attachment manifest carried on `media.blob.advertise`. Plaintext —
    /// metadata only, not content. Bytes flow over the iroh-blobs sub-stream.
    public var attachment: HermesRealtimeRelayAttachmentManifest?
    /// Base32-encoded iroh-blobs ticket. Receiver decodes and dials back to
    /// fetch the blob bytes.
    public var blobTicket: String?
    /// Acknowledgement carried on `media.blob.ack`.
    public var ack: HermesRealtimeRelayMediaAck?

    public init(
        streamClass: String? = nil,
        attachment: HermesRealtimeRelayAttachmentManifest? = nil,
        blobTicket: String? = nil,
        ack: HermesRealtimeRelayMediaAck? = nil
    ) {
        self.streamClass = streamClass
        self.attachment = attachment
        self.blobTicket = blobTicket
        self.ack = ack
    }
}

public struct HermesRealtimeRelayAttachmentManifest: Codable, Sendable, Equatable {
    public var manifestId: String
    public var blobHash: String
    public var filename: String
    public var mime: String
    public var size: Int64
    public var peerDeviceId: String?
    public var createdAt: Date

    public init(
        manifestId: String,
        blobHash: String,
        filename: String,
        mime: String,
        size: Int64,
        peerDeviceId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.manifestId = manifestId
        self.blobHash = blobHash
        self.filename = filename
        self.mime = mime
        self.size = size
        self.peerDeviceId = peerDeviceId
        self.createdAt = createdAt
    }
}

public struct HermesRealtimeRelayMediaAck: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case received
        case rejected
    }

    public var manifestId: String
    public var status: Status
    public var reason: String?

    public init(manifestId: String, status: Status, reason: String? = nil) {
        self.manifestId = manifestId
        self.status = status
        self.reason = reason
    }
}

public struct HermesRealtimeRelayPayload: Codable, Sendable, Equatable {
    public var operation: HermesRelayOperation?
    public var method: String?
    public var payloadCiphertext: String?
    public var wrappedKey: String?
    public var relayEncryption: String?
    public var relayKeyVersion: Int?
    public var sequence: Int?
    public var kind: HermesRelayChunkKind?
    public var ciphertext: String?
    public var error: String?
    public var chunkCount: Int?
    public var capabilities: [String]?

    public init(
        operation: HermesRelayOperation? = nil,
        method: String? = nil,
        payloadCiphertext: String? = nil,
        wrappedKey: String? = nil,
        relayEncryption: String? = nil,
        relayKeyVersion: Int? = nil,
        sequence: Int? = nil,
        kind: HermesRelayChunkKind? = nil,
        ciphertext: String? = nil,
        error: String? = nil,
        chunkCount: Int? = nil,
        capabilities: [String]? = nil
    ) {
        self.operation = operation
        self.method = method
        self.payloadCiphertext = payloadCiphertext
        self.wrappedKey = wrappedKey
        self.relayEncryption = relayEncryption
        self.relayKeyVersion = relayKeyVersion
        self.sequence = sequence
        self.kind = kind
        self.ciphertext = ciphertext
        self.error = error
        self.chunkCount = chunkCount
        self.capabilities = capabilities
    }
}
