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

/// Thinking-level ladder shared across providers.
///
/// Anthropic maps each level to a `thinking.budget_tokens` budget (and the new
/// `effort` parameter shipped under `effort-2025-11-24`). OpenAI maps each
/// level to `reasoning_effort` / `reasoning.effort`. `.max` collapses to
/// `xhigh` on OpenAI (no higher tier exists) while pushing Anthropic's budget
/// to its documented effective ceiling.
public enum BurnBarThinkingLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    /// Lower-case slug used to suffix a variant's wire id (`claude-opus-4-7-xhigh`).
    public var slug: String { rawValue }

    /// Human-friendly label used in the Settings editor and `displayName`.
    public var displayLabel: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        }
    }

    /// Anthropic `thinking.budget_tokens` value. Pinned to documented tiers.
    public var anthropicBudgetTokens: Int {
        switch self {
        case .low: return 2048
        case .medium: return 4096
        case .high: return 8192
        case .xhigh: return 16384
        case .max: return 32768
        }
    }

    /// OpenAI `reasoning_effort` / `reasoning.effort` value. `.max` collapses
    /// to `xhigh` since OpenAI does not expose a higher tier.
    public var openAIEffort: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh, .max: return "xhigh"
        }
    }

    /// Anthropic `effort` value sent on routes that include the `effort-2025-11-24`
    /// beta. `.max` collapses to `xhigh` because Anthropic only documents up to
    /// `xhigh`; the deeper budget is expressed via `thinking.budget_tokens`.
    public var anthropicEffort: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh, .max: return "xhigh"
        }
    }

    /// Sort order from lowest effort to highest.
    public var ladderIndex: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .xhigh: return 3
        case .max: return 4
        }
    }
}

/// A user-defined variant of an advertised model that pins a specific
/// `BurnBarThinkingLevel` (and optional `maxOutputTokens`). Variants are
/// surfaced as distinct rows in `/v1/models` and in every wired CLI's model
/// picker, with stable wire ids derived from the base model id + level slug.
public struct BurnBarModelVariant: Codable, Hashable, Identifiable, Sendable {
    public let variantID: String
    public var label: String
    public var baseModelID: String
    public var thinkingLevel: BurnBarThinkingLevel
    public var maxOutputTokens: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { variantID }

    public init(
        variantID: String,
        label: String,
        baseModelID: String,
        thinkingLevel: BurnBarThinkingLevel,
        maxOutputTokens: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.variantID = variantID
        self.label = label
        self.baseModelID = baseModelID
        self.thinkingLevel = thinkingLevel
        self.maxOutputTokens = maxOutputTokens
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Default wire id derived from the base model + level (`claude-opus-4-7-xhigh`).
    public static func defaultVariantID(baseModelID: String, level: BurnBarThinkingLevel) -> String {
        let trimmed = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed)-\(level.slug)"
    }

    /// Default label rendered alongside the variant ("XHigh").
    public static func defaultLabel(for level: BurnBarThinkingLevel) -> String {
        level.displayLabel
    }
}

public struct BurnBarProviderSettings: Codable, Hashable, Identifiable, Sendable {
    public let providerID: String
    public var isEnabled: Bool
    public var baseURL: String
    public var preferredModelIDs: [String]
    public var disabledAdvertisedModelIDs: [String]
    public var preferredCredentialSlotID: String?
    public var credentialSlots: [BurnBarProviderCredentialSlot]
    /// User-defined thinking-level variants. Each variant ships as its own
    /// row in `/v1/models` and in every wired CLI's picker, while still
    /// routing through `baseModelID`.
    public var modelVariants: [BurnBarModelVariant]

    public var id: String { providerID }

    public init(
        providerID: String,
        isEnabled: Bool = false,
        baseURL: String,
        preferredModelIDs: [String],
        disabledAdvertisedModelIDs: [String] = [],
        preferredCredentialSlotID: String? = nil,
        credentialSlots: [BurnBarProviderCredentialSlot] = [],
        modelVariants: [BurnBarModelVariant] = []
    ) {
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.preferredModelIDs = preferredModelIDs
        self.disabledAdvertisedModelIDs = Self.normalizedDisabledAdvertisedModelIDs(disabledAdvertisedModelIDs)
        self.preferredCredentialSlotID = preferredCredentialSlotID
        self.credentialSlots = credentialSlots
        self.modelVariants = Self.normalizedModelVariants(modelVariants)
    }

    public func isModelAdvertisementEnabled(_ modelID: String) -> Bool {
        let normalized = Self.normalizedAdvertisedModelID(modelID)
        guard !normalized.isEmpty else { return true }
        return !Set(disabledAdvertisedModelIDs.map(Self.normalizedAdvertisedModelID)).contains(normalized)
    }

    public mutating func setModelAdvertisement(modelID: String, isEnabled: Bool) {
        let normalized = Self.normalizedAdvertisedModelID(modelID)
        guard !normalized.isEmpty else { return }
        var disabled = Set(disabledAdvertisedModelIDs.map(Self.normalizedAdvertisedModelID))
        if isEnabled {
            disabled.remove(normalized)
        } else {
            disabled.insert(normalized)
        }
        disabledAdvertisedModelIDs = disabled.sorted()
    }

    /// Insert or update a variant, keyed by `variantID`. Touches `updatedAt`.
    public mutating func upsertModelVariant(_ variant: BurnBarModelVariant) {
        var working = modelVariants
        var inserted = variant
        inserted.updatedAt = Date()
        if let index = working.firstIndex(where: { $0.variantID == inserted.variantID }) {
            inserted.createdAt = working[index].createdAt
            working[index] = inserted
        } else {
            working.append(inserted)
        }
        modelVariants = Self.normalizedModelVariants(working)
    }

    /// Remove a variant by id. Returns `true` if a row was removed.
    @discardableResult
    public mutating func removeModelVariant(variantID: String) -> Bool {
        let trimmed = variantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let before = modelVariants.count
        modelVariants.removeAll { $0.variantID.caseInsensitiveCompare(trimmed) == .orderedSame }
        return modelVariants.count != before
    }

    /// Variants that target a specific base model id.
    public func variants(forBaseModelID baseModelID: String) -> [BurnBarModelVariant] {
        let normalized = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        return modelVariants.filter {
            $0.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case isEnabled
        case baseURL
        case preferredModelIDs
        case disabledAdvertisedModelIDs
        case preferredCredentialSlotID
        case credentialSlots
        case modelVariants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        preferredModelIDs = try container.decode([String].self, forKey: .preferredModelIDs)
        disabledAdvertisedModelIDs = Self.normalizedDisabledAdvertisedModelIDs(
            try container.decodeIfPresent([String].self, forKey: .disabledAdvertisedModelIDs) ?? []
        )
        preferredCredentialSlotID = try container.decodeIfPresent(String.self, forKey: .preferredCredentialSlotID)
        credentialSlots = try container.decodeIfPresent([BurnBarProviderCredentialSlot].self, forKey: .credentialSlots) ?? []
        modelVariants = Self.normalizedModelVariants(
            try container.decodeIfPresent([BurnBarModelVariant].self, forKey: .modelVariants) ?? []
        )
    }

    private static func normalizedDisabledAdvertisedModelIDs(_ modelIDs: [String]) -> [String] {
        var seen = Set<String>()
        return modelIDs.compactMap { raw in
            let normalized = normalizedAdvertisedModelID(raw)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func normalizedAdvertisedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedModelVariants(_ variants: [BurnBarModelVariant]) -> [BurnBarModelVariant] {
        var seen = Set<String>()
        return variants.compactMap { raw in
            let trimmedID = raw.variantID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBase = raw.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty,
                  !trimmedBase.isEmpty,
                  seen.insert(trimmedID.lowercased()).inserted else {
                return nil
            }
            let label = raw.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTokens: Int? = raw.maxOutputTokens.flatMap { tokens in
                tokens > 0 ? tokens : nil
            }
            return BurnBarModelVariant(
                variantID: trimmedID,
                label: label.isEmpty ? BurnBarModelVariant.defaultLabel(for: raw.thinkingLevel) : label,
                baseModelID: trimmedBase,
                thinkingLevel: raw.thinkingLevel,
                maxOutputTokens: normalizedTokens,
                createdAt: raw.createdAt,
                updatedAt: raw.updatedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.baseModelID.caseInsensitiveCompare(rhs.baseModelID) != .orderedSame {
                return lhs.baseModelID.localizedCaseInsensitiveCompare(rhs.baseModelID) == .orderedAscending
            }
            return lhs.thinkingLevel.ladderIndex < rhs.thinkingLevel.ladderIndex
        }
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

public struct BurnBarProviderModelVariantUpsertRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let variant: BurnBarModelVariant

    public init(providerID: String, variant: BurnBarModelVariant) {
        self.providerID = providerID
        self.variant = variant
    }
}

public struct BurnBarProviderModelVariantRemoveRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let variantID: String

    public init(providerID: String, variantID: String) {
        self.providerID = providerID
        self.variantID = variantID
    }
}

public struct BurnBarProviderModelVariantMutationResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot
    public let variant: BurnBarModelVariant?

    public init(
        snapshot: BurnBarProviderConfigurationSnapshot,
        variant: BurnBarModelVariant? = nil
    ) {
        self.snapshot = snapshot
        self.variant = variant
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
