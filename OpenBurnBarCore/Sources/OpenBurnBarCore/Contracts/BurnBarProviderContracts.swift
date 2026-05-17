import Foundation

public enum BurnBarProviderCredentialSlotStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case ready
    case coolingDown
    case exhausted
    case disabled
    case missingSecret
}

public struct BurnBarProviderCredentialSlot: Codable, Hashable, Identifiable, Sendable {
    public let slotID: String
    public var label: String
    public var isEnabled: Bool
    public var status: BurnBarProviderCredentialSlotStatus
    public var cooldownUntil: Date?
    public var lastSelectedAt: Date?
    public var lastQuotaRemainingPercent: Double?
    public var lastQuotaResetsAt: Date?
    public var lastStatusMessage: String?
    public var updatedAt: Date

    public var id: String { slotID }

    public init(
        slotID: String = UUID().uuidString,
        label: String,
        isEnabled: Bool = true,
        status: BurnBarProviderCredentialSlotStatus = .ready,
        cooldownUntil: Date? = nil,
        lastSelectedAt: Date? = nil,
        lastQuotaRemainingPercent: Double? = nil,
        lastQuotaResetsAt: Date? = nil,
        lastStatusMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.slotID = slotID
        self.label = label
        self.isEnabled = isEnabled
        self.status = status
        self.cooldownUntil = cooldownUntil
        self.lastSelectedAt = lastSelectedAt
        self.lastQuotaRemainingPercent = lastQuotaRemainingPercent
        self.lastQuotaResetsAt = lastQuotaResetsAt
        self.lastStatusMessage = lastStatusMessage
        self.updatedAt = updatedAt
    }
}

public struct BurnBarProviderSettings: Codable, Hashable, Identifiable, Sendable {
    public let providerID: String
    public var isEnabled: Bool
    public var baseURL: String
    public var preferredModelIDs: [String]
    public var preferredCredentialSlotID: String?
    public var credentialSlots: [BurnBarProviderCredentialSlot]

    public var id: String { providerID }

    public init(
        providerID: String,
        isEnabled: Bool = false,
        baseURL: String,
        preferredModelIDs: [String],
        preferredCredentialSlotID: String? = nil,
        credentialSlots: [BurnBarProviderCredentialSlot] = []
    ) {
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.preferredModelIDs = preferredModelIDs
        self.preferredCredentialSlotID = preferredCredentialSlotID
        self.credentialSlots = credentialSlots
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case isEnabled
        case baseURL
        case preferredModelIDs
        case preferredCredentialSlotID
        case credentialSlots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        preferredModelIDs = try container.decode([String].self, forKey: .preferredModelIDs)
        preferredCredentialSlotID = try container.decodeIfPresent(String.self, forKey: .preferredCredentialSlotID)
        credentialSlots = try container.decodeIfPresent([BurnBarProviderCredentialSlot].self, forKey: .credentialSlots) ?? []
    }
}

public struct BurnBarProviderConfigurationSnapshot: Codable, Hashable, Sendable {
    public var providers: [BurnBarProviderSettings]
    public var routerMode: ProviderRouterMode

    public init(
        providers: [BurnBarProviderSettings],
        routerMode: ProviderRouterMode = .providerFamilyFailover
    ) {
        self.providers = providers
        self.routerMode = routerMode
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case routerMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providers = try container.decode([BurnBarProviderSettings].self, forKey: .providers)
        self.routerMode = try container.decodeIfPresent(ProviderRouterMode.self, forKey: .routerMode)
            ?? .providerFamilyFailover
    }

    public func providerSettings(id: String) -> BurnBarProviderSettings? {
        providers.first(where: { $0.providerID == id })
    }
}

public struct BurnBarConfigGetRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarConfigUpdateRequest: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot

    public init(snapshot: BurnBarProviderConfigurationSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarConfigResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot

    public init(snapshot: BurnBarProviderConfigurationSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarProviderCredentialSlotUpsertRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let slotID: String?
    public let label: String
    public let apiKey: String
    public let isEnabled: Bool

    public init(
        providerID: String,
        slotID: String? = nil,
        label: String,
        apiKey: String,
        isEnabled: Bool = true
    ) {
        self.providerID = providerID
        self.slotID = slotID
        self.label = label
        self.apiKey = apiKey
        self.isEnabled = isEnabled
    }
}

public struct BurnBarProviderCredentialSlotRemoveRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let slotID: String

    public init(providerID: String, slotID: String) {
        self.providerID = providerID
        self.slotID = slotID
    }
}

public struct BurnBarProviderCredentialSlotMutationResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot
    public let slot: BurnBarProviderCredentialSlot?

    public init(
        snapshot: BurnBarProviderConfigurationSnapshot,
        slot: BurnBarProviderCredentialSlot? = nil
    ) {
        self.snapshot = snapshot
        self.slot = slot
    }
}

public struct BurnBarRecentUsageRequest: Codable, Hashable, Sendable {
    public let limit: Int

    public init(limit: Int = 20) {
        self.limit = limit
    }
}

public struct BurnBarRecentUsageResponse: Codable, Hashable, Sendable {
    public let usage: [BurnBarUsageEvent]

    public init(usage: [BurnBarUsageEvent]) {
        self.usage = usage
    }
}

/// Confidence level for a recorded `BurnBarUsageEvent`. Mirrors `UsageProvenanceConfidence`
/// at the contract layer so the daemon ledger can be written by Hermes/MCP/CLI clients
/// without depending on the app's `OpenBurnBarCore` runtime types.
public enum BurnBarUsageConfidence: String, Codable, Hashable, CaseIterable, Sendable {
    case exact
    case derivedExact = "derived_exact"
    case highConfidenceEstimate = "high_confidence_estimate"
    case lowConfidenceEstimate = "low_confidence_estimate"
    case unknown
}

public struct BurnBarUsageEvent: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID?
    public let providerID: String
    public let modelID: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let cost: Double
    public let recordedAt: Date
    /// Optional client-supplied session id for app/Hermes session attribution.
    public let sessionID: String?
    /// Optional client-supplied project name. Defaults to "OpenBurnBar Daemon" on import when nil.
    public let projectName: String?
    /// Confidence level for the recorded counts. Defaults to `.exact` for backwards compat
    /// (existing daemon-recorded rows are exact provider responses).
    public let confidence: BurnBarUsageConfidence

    private enum CodingKeys: String, CodingKey {
        case runID
        case providerID
        case modelID
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case reasoningTokens
        case cost
        case recordedAt
        case sessionID
        case projectName
        case confidence
    }

    public init(
        runID: BurnBarRunID? = nil,
        providerID: String,
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int,
        reasoningTokens: Int = 0,
        cost: Double,
        recordedAt: Date,
        sessionID: String? = nil,
        projectName: String? = nil,
        confidence: BurnBarUsageConfidence = .exact
    ) {
        self.runID = runID
        self.providerID = providerID
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.recordedAt = recordedAt
        self.sessionID = sessionID
        self.projectName = projectName
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decodeIfPresent(BurnBarRunID.self, forKey: .runID)
        providerID = try container.decode(String.self, forKey: .providerID)
        modelID = try container.decode(String.self, forKey: .modelID)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        cost = try container.decode(Double.self, forKey: .cost)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        confidence = try container.decodeIfPresent(BurnBarUsageConfidence.self, forKey: .confidence) ?? .exact
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(reasoningTokens, forKey: .reasoningTokens)
        try container.encode(cost, forKey: .cost)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(projectName, forKey: .projectName)
        try container.encode(confidence, forKey: .confidence)
    }
}

public struct BurnBarRecordUsageRequest: Codable, Hashable, Sendable {
    public let idempotencyKey: String
    public let event: BurnBarUsageEvent

    public init(idempotencyKey: String, event: BurnBarUsageEvent) {
        self.idempotencyKey = idempotencyKey
        self.event = event
    }
}

public struct BurnBarRecordUsageResponse: Codable, Hashable, Sendable {
    public let idempotencyKey: String
    public let inserted: Bool
    public let event: BurnBarUsageEvent

    public init(idempotencyKey: String, inserted: Bool, event: BurnBarUsageEvent) {
        self.idempotencyKey = idempotencyKey
        self.inserted = inserted
        self.event = event
    }
}

public struct BurnBarHealthRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarHealthResponse: Codable, Hashable, Sendable {
    public let ok: Bool
    public let daemonVersion: String
    public let protocolVersion: Int
    public let socketPath: String?
    public let gatewayEnabled: Bool
    public let gatewayHost: String?
    public let gatewayPort: Int?

    public init(ok: Bool, daemonVersion: String, protocolVersion: Int, socketPath: String? = nil, gatewayEnabled: Bool = false, gatewayHost: String? = nil, gatewayPort: Int? = nil) {
        self.ok = ok
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.socketPath = socketPath
        self.gatewayEnabled = gatewayEnabled
        self.gatewayHost = gatewayHost
        self.gatewayPort = gatewayPort
    }
}

public struct BurnBarCatalogRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarCatalogResponse: Codable, Hashable, Sendable {
    public let catalog: BurnBarCatalog

    public init(catalog: BurnBarCatalog) {
        self.catalog = catalog
    }
}
