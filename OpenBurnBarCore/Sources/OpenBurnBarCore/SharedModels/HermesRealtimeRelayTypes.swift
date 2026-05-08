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
}

public struct HermesRealtimeRelayFrame: Codable, Sendable, Equatable {
    public var type: HermesRealtimeRelayFrameType
    public var uid: String
    public var connectionId: String
    public var requestId: String?
    public var protocolVersion: Int
    public var payload: HermesRealtimeRelayPayload?

    public init(
        type: HermesRealtimeRelayFrameType,
        uid: String,
        connectionId: String,
        requestId: String? = nil,
        protocolVersion: Int = HermesRealtimeRelayProtocol.version,
        payload: HermesRealtimeRelayPayload? = nil
    ) {
        self.type = type
        self.uid = uid
        self.connectionId = connectionId
        self.requestId = requestId
        self.protocolVersion = protocolVersion
        self.payload = payload
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
