import Foundation

// MARK: - Pi Connection Types
//
// Sibling of `HermesConnectionTypes.swift`. Keeps the same shape so the
// shared `AssistantSettingsView` and `AssistantConnectionSheet` can render
// both runtimes from one code path without runtime-specific branching beyond
// the accent gradient.

public enum PiConnectionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case directURL
    case relayLink
}

public enum PiConnectionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case online
    case offline
    case unauthorized
    case revoked
    case degraded
}

public struct PiConnectionRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var mode: PiConnectionMode
    public var status: PiConnectionStatus
    public var endpointURL: String?
    public var advertisedModel: String?
    /// Active Pi gateway instance (when Redis discovery is wired).
    public var instanceID: String?
    /// Optional Redis registry URL — only used when the host has multi-instance Pi.
    public var redisURL: String?
    public var relayPublicKey: String?
    public var relayKeyVersion: Int?
    public var relayEncryption: String?
    public var realtimeRelayURL: String?
    public var realtimeRelayStatus: String?
    public var realtimeRelayLastSeenAt: Date?
    public var realtimeRelayProtocolVersion: Int?
    public var capabilities: [String]
    public var instances: [PiAgentInstanceRecord]
    public var models: [PiAgentRuntimeModelOption]
    public var lastSeenAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case mode
        case status
        case endpointURL
        case advertisedModel
        case instanceID = "selectedInstanceID"
        case redisURL
        case relayPublicKey
        case relayKeyVersion
        case relayEncryption
        case realtimeRelayURL
        case realtimeRelayStatus
        case realtimeRelayLastSeenAt
        case realtimeRelayProtocolVersion
        case capabilities
        case instances
        case models
        case lastSeenAt
        case createdAt
        case updatedAt
        case schemaVersion
    }

    public init(
        id: String,
        displayName: String,
        mode: PiConnectionMode,
        status: PiConnectionStatus,
        endpointURL: String? = nil,
        advertisedModel: String? = nil,
        instanceID: String? = nil,
        redisURL: String? = nil,
        relayPublicKey: String? = nil,
        relayKeyVersion: Int? = nil,
        relayEncryption: String? = nil,
        realtimeRelayURL: String? = nil,
        realtimeRelayStatus: String? = nil,
        realtimeRelayLastSeenAt: Date? = nil,
        realtimeRelayProtocolVersion: Int? = nil,
        capabilities: [String] = [],
        instances: [PiAgentInstanceRecord] = [],
        models: [PiAgentRuntimeModelOption] = [],
        lastSeenAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.displayName = displayName
        self.mode = mode
        self.status = status
        self.endpointURL = endpointURL
        self.advertisedModel = advertisedModel
        self.instanceID = instanceID
        self.redisURL = redisURL
        self.relayPublicKey = relayPublicKey
        self.relayKeyVersion = relayKeyVersion
        self.relayEncryption = relayEncryption
        self.realtimeRelayURL = realtimeRelayURL
        self.realtimeRelayStatus = realtimeRelayStatus
        self.realtimeRelayLastSeenAt = realtimeRelayLastSeenAt
        self.realtimeRelayProtocolVersion = realtimeRelayProtocolVersion
        self.capabilities = capabilities
        self.instances = instances
        self.models = models
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public static let localDefault = PiConnectionRecord(
        id: "local-pi",
        displayName: "Local Pi",
        mode: .local,
        status: .offline,
        endpointURL: "http://127.0.0.1:8765",
        capabilities: ["chat_completions"]
    )
}

// MARK: - Pi Pairing Session

public struct PiPairingSessionRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var code: String
    public var expiresAt: Date

    public init(id: String, code: String, expiresAt: Date) {
        self.id = id
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct PiAgentInstanceRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var endpointURL: String?
    public var status: PiConnectionStatus
    public var modelName: String?
    public var capabilities: [String]
    public var lastSeenAt: Date?
    public var schemaVersion: Int

    public init(
        id: String,
        displayName: String,
        endpointURL: String? = nil,
        status: PiConnectionStatus = .offline,
        modelName: String? = nil,
        capabilities: [String] = [],
        lastSeenAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.displayName = displayName
        self.endpointURL = endpointURL
        self.status = status
        self.modelName = modelName
        self.capabilities = capabilities
        self.lastSeenAt = lastSeenAt
        self.schemaVersion = schemaVersion
    }
}

public struct PiAgentRuntimeModelOption: Codable, Identifiable, Sendable, Equatable {
    public var id: String { providerID + ":" + modelID }
    public var providerID: String
    public var providerName: String
    public var modelID: String
    public var displayName: String
    public var instanceID: String?
    public var schemaVersion: Int

    public init(
        providerID: String,
        providerName: String,
        modelID: String,
        displayName: String? = nil,
        instanceID: String? = nil,
        schemaVersion: Int = 1
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.displayName = displayName ?? modelID
        self.instanceID = instanceID
        self.schemaVersion = schemaVersion
    }
}

public struct PiAgentSessionSummary: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var preview: String?
    public var source: String?
    public var model: String?
    public var instanceID: String?
    public var startedAt: Date?
    public var lastActiveAt: Date?
    public var endedAt: Date?
    public var isActive: Bool
    public var messageCount: Int
    public var toolCallCount: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var schemaVersion: Int

    public init(
        id: String,
        title: String? = nil,
        preview: String? = nil,
        source: String? = nil,
        model: String? = nil,
        instanceID: String? = nil,
        startedAt: Date? = nil,
        lastActiveAt: Date? = nil,
        endedAt: Date? = nil,
        isActive: Bool = false,
        messageCount: Int = 0,
        toolCallCount: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.source = source
        self.model = model
        self.instanceID = instanceID
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.endedAt = endedAt
        self.isActive = isActive
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.schemaVersion = schemaVersion
    }
}

public enum PiAgentRelayOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case chatCompletions
    case models
    case sessions
    case sessionDetail
}

public enum PiAgentRelayRequestStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case claimed
    case streaming
    case completed
    case failed
    case cancelled
    case expired
}

public enum PiAgentRelayChunkKind: String, Codable, Sendable, Equatable, CaseIterable {
    case sse
    case data
    case error
}

public struct PiAgentRelayRequestRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var connectionId: String
    public var operation: PiAgentRelayOperation
    public var status: PiAgentRelayRequestStatus
    public var method: String
    public var payloadCiphertext: String
    public var wrappedKey: String
    public var relayEncryption: String
    public var relayKeyVersion: Int
    public var chunkCount: Int
    public var claimedAt: Date?
    public var claimedBy: String?
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date
    public var schemaVersion: Int

    public init(
        id: String,
        connectionId: String,
        operation: PiAgentRelayOperation,
        status: PiAgentRelayRequestStatus = .pending,
        method: String,
        payloadCiphertext: String,
        wrappedKey: String,
        relayEncryption: String = PiAgentRelayCrypto.algorithm,
        relayKeyVersion: Int = PiAgentRelayCrypto.keyVersion,
        chunkCount: Int = 0,
        claimedAt: Date? = nil,
        claimedBy: String? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(90),
        schemaVersion: Int = 2
    ) {
        self.id = id
        self.connectionId = connectionId
        self.operation = operation
        self.status = status
        self.method = method
        self.payloadCiphertext = payloadCiphertext
        self.wrappedKey = wrappedKey
        self.relayEncryption = relayEncryption
        self.relayKeyVersion = relayKeyVersion
        self.chunkCount = chunkCount
        self.claimedAt = claimedAt
        self.claimedBy = claimedBy
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.schemaVersion = schemaVersion
    }
}

public struct PiAgentRelayChunkRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var requestId: String
    public var sequence: Int
    public var kind: PiAgentRelayChunkKind
    public var ciphertext: String
    public var createdAt: Date
    public var updatedAt: Date?
    public var schemaVersion: Int

    public init(
        id: String,
        requestId: String,
        sequence: Int,
        kind: PiAgentRelayChunkKind,
        ciphertext: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        schemaVersion: Int = 2
    ) {
        self.id = id
        self.requestId = requestId
        self.sequence = sequence
        self.kind = kind
        self.ciphertext = ciphertext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}
