import Foundation

public enum HermesConnectionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case directURL
    case relayLink
}

public enum HermesConnectionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case online
    case offline
    case unauthorized
    case revoked
    case degraded
}

public struct HermesConnectionRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var mode: HermesConnectionMode
    public var status: HermesConnectionStatus
    public var profileName: String?
    public var endpointURL: String?
    public var advertisedModel: String?
    public var relayPublicKey: String?
    public var relayKeyVersion: Int?
    public var relayEncryption: String?
    public var realtimeRelayURL: String?
    public var realtimeRelayStatus: String?
    public var realtimeRelayLastSeenAt: Date?
    public var realtimeRelayProtocolVersion: Int?
    public var capabilities: [String]
    public var lastSeenAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: String,
        displayName: String,
        mode: HermesConnectionMode,
        status: HermesConnectionStatus,
        profileName: String? = nil,
        endpointURL: String? = nil,
        advertisedModel: String? = nil,
        relayPublicKey: String? = nil,
        relayKeyVersion: Int? = nil,
        relayEncryption: String? = nil,
        realtimeRelayURL: String? = nil,
        realtimeRelayStatus: String? = nil,
        realtimeRelayLastSeenAt: Date? = nil,
        realtimeRelayProtocolVersion: Int? = nil,
        capabilities: [String] = [],
        lastSeenAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.displayName = displayName
        self.mode = mode
        self.status = status
        self.profileName = profileName
        self.endpointURL = endpointURL
        self.advertisedModel = advertisedModel
        self.relayPublicKey = relayPublicKey
        self.relayKeyVersion = relayKeyVersion
        self.relayEncryption = relayEncryption
        self.realtimeRelayURL = realtimeRelayURL
        self.realtimeRelayStatus = realtimeRelayStatus
        self.realtimeRelayLastSeenAt = realtimeRelayLastSeenAt
        self.realtimeRelayProtocolVersion = realtimeRelayProtocolVersion
        self.capabilities = capabilities
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public static let localDefault = HermesConnectionRecord(
        id: "local-hermes",
        displayName: "Local Hermes",
        mode: .local,
        status: .offline,
        endpointURL: "http://localhost:8642",
        capabilities: ["chat_completions"]
    )
}

public struct HermesPairingSessionRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var code: String
    public var expiresAt: Date

    public init(id: String, code: String, expiresAt: Date) {
        self.id = id
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct HermesSessionSummary: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var preview: String?
    public var source: String?
    public var model: String?
    public var startedAt: Date?
    public var lastActiveAt: Date?
    public var endedAt: Date?
    public var isActive: Bool
    public var messageCount: Int
    public var toolCallCount: Int
    public var inputTokens: Int
    public var outputTokens: Int

    public init(
        id: String,
        title: String? = nil,
        preview: String? = nil,
        source: String? = nil,
        model: String? = nil,
        startedAt: Date? = nil,
        lastActiveAt: Date? = nil,
        endedAt: Date? = nil,
        isActive: Bool = false,
        messageCount: Int = 0,
        toolCallCount: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.source = source
        self.model = model
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.endedAt = endedAt
        self.isActive = isActive
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct HermesRuntimeProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var model: String?
    public var provider: String?
    public var skillCount: Int

    public init(name: String, model: String? = nil, provider: String? = nil, skillCount: Int = 0) {
        self.name = name
        self.model = model
        self.provider = provider
        self.skillCount = skillCount
    }
}

public struct HermesRuntimeModelOption: Codable, Identifiable, Sendable, Equatable {
    public var id: String { providerID + ":" + modelID }
    public var providerID: String
    public var providerName: String
    public var modelID: String
    public var displayName: String

    public init(providerID: String, providerName: String, modelID: String, displayName: String? = nil) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.displayName = displayName ?? modelID
    }
}

public struct HermesRuntimeJob: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var prompt: String
    public var scheduleDisplay: String?
    public var state: String
    public var enabled: Bool
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var lastError: String?

    public init(
        id: String,
        name: String? = nil,
        prompt: String,
        scheduleDisplay: String? = nil,
        state: String = "unknown",
        enabled: Bool = true,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.scheduleDisplay = scheduleDisplay
        self.state = state
        self.enabled = enabled
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.lastError = lastError
    }
}

public enum HermesRelayOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case chatCompletions
    case models
    case sessions
    case sessionDetail
    case profiles
    case jobs
}

public enum HermesRelayRequestStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case claimed
    case streaming
    case completed
    case failed
    case cancelled
    case expired
}

public enum HermesRelayChunkKind: String, Codable, Sendable, Equatable, CaseIterable {
    case sse
    case data
    case error
}

public struct HermesRelayRequestRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var connectionId: String
    public var operation: HermesRelayOperation
    public var status: HermesRelayRequestStatus
    public var method: String
    public var path: String?
    public var sessionId: String?
    public var body: String?
    public var payloadCiphertext: String?
    public var wrappedKey: String?
    public var relayEncryption: String?
    public var relayKeyVersion: Int?
    public var error: String?
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
        operation: HermesRelayOperation,
        status: HermesRelayRequestStatus = .pending,
        method: String,
        path: String? = nil,
        sessionId: String? = nil,
        body: String? = nil,
        payloadCiphertext: String? = nil,
        wrappedKey: String? = nil,
        relayEncryption: String? = nil,
        relayKeyVersion: Int? = nil,
        error: String? = nil,
        chunkCount: Int = 0,
        claimedAt: Date? = nil,
        claimedBy: String? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(90),
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.connectionId = connectionId
        self.operation = operation
        self.status = status
        self.method = method
        self.path = path
        self.sessionId = sessionId
        self.body = body
        self.payloadCiphertext = payloadCiphertext
        self.wrappedKey = wrappedKey
        self.relayEncryption = relayEncryption
        self.relayKeyVersion = relayKeyVersion
        self.error = error
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

public struct HermesRelayChunkRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var requestId: String
    public var sequence: Int
    public var kind: HermesRelayChunkKind
    public var data: String?
    public var text: String?
    public var error: String?
    public var ciphertext: String?
    public var createdAt: Date
    public var updatedAt: Date?
    public var schemaVersion: Int

    public init(
        id: String,
        requestId: String,
        sequence: Int,
        kind: HermesRelayChunkKind,
        data: String? = nil,
        text: String? = nil,
        error: String? = nil,
        ciphertext: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.requestId = requestId
        self.sequence = sequence
        self.kind = kind
        self.data = data
        self.text = text
        self.error = error
        self.ciphertext = ciphertext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}
