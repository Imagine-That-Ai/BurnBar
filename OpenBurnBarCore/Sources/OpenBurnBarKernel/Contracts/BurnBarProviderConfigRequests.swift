import Foundation
import OpenBurnBarProviderModels

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
    public let endpointProfileID: String?
    public let region: ProviderEndpointRegion?
    public let tokenPlanTier: MimoTokenPlanTier?
    public let tokenPlanBillingCycle: MimoTokenPlanBillingCycle?
    public let authMethodID: String?

    public init(
        providerID: String,
        slotID: String? = nil,
        label: String,
        apiKey: String,
        isEnabled: Bool = true,
        endpointProfileID: String? = nil,
        region: ProviderEndpointRegion? = nil,
        tokenPlanTier: MimoTokenPlanTier? = nil,
        tokenPlanBillingCycle: MimoTokenPlanBillingCycle? = nil,
        authMethodID: String? = nil
    ) {
        self.providerID = providerID
        self.slotID = slotID
        self.label = label
        self.apiKey = apiKey
        self.isEnabled = isEnabled
        self.endpointProfileID = endpointProfileID
        self.region = region
        self.tokenPlanTier = tokenPlanTier
        self.tokenPlanBillingCycle = tokenPlanBillingCycle
        self.authMethodID = authMethodID
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

public struct BurnBarProviderModelAliasUpsertRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let alias: BurnBarModelAlias

    public init(providerID: String, alias: BurnBarModelAlias) {
        self.providerID = providerID
        self.alias = alias
    }
}

public struct BurnBarProviderModelAliasRemoveRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let aliasID: String

    public init(providerID: String, aliasID: String) {
        self.providerID = providerID
        self.aliasID = aliasID
    }
}

public struct BurnBarProviderModelAliasMutationResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot
    public let alias: BurnBarModelAlias?

    public init(
        snapshot: BurnBarProviderConfigurationSnapshot,
        alias: BurnBarModelAlias? = nil
    ) {
        self.snapshot = snapshot
        self.alias = alias
    }
}

public struct BurnBarProviderCustomModelUpsertRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let customModel: BurnBarCustomModel

    public init(providerID: String, customModel: BurnBarCustomModel) {
        self.providerID = providerID
        self.customModel = customModel
    }
}

public struct BurnBarProviderCustomModelRemoveRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct BurnBarProviderCustomModelMutationResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot
    public let customModel: BurnBarCustomModel?

    public init(
        snapshot: BurnBarProviderConfigurationSnapshot,
        customModel: BurnBarCustomModel? = nil
    ) {
        self.snapshot = snapshot
        self.customModel = customModel
    }
}

public struct BurnBarProviderModelDisplayNameSetRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let displayName: String

    public init(providerID: String, modelID: String, displayName: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
    }
}

public struct BurnBarProviderModelDisplayNameClearRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct BurnBarProviderModelDisplayNameMutationResponse: Codable, Hashable, Sendable {
    public let override: BurnBarModelDisplayOverride?
    public let snapshot: BurnBarProviderConfigurationSnapshot

    public init(override: BurnBarModelDisplayOverride?, snapshot: BurnBarProviderConfigurationSnapshot) {
        self.override = override
        self.snapshot = snapshot
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

/// Requests the daemon's durable all-time usage projection. The projection is
/// rebuilt from the append-only ledger whenever its content fingerprint is
/// stale, so clients never need to treat renderer-side arithmetic as authority.
public struct BurnBarUsageProjectionRequest: Codable, Hashable, Sendable {
    public init() {}
}

/// Requests an explicit authoritative recount of the daemon usage ledger.
/// Recount never mutates source events; it replaces only the derived projection.
public struct BurnBarUsageRecountRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarUsageProjectionTotals: Codable, Hashable, Sendable {
    public let eventCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let cost: Double

    public init(
        eventCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        reasoningTokens: Int,
        totalTokens: Int,
        cost: Double
    ) {
        self.eventCount = eventCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

/// One UTC-day/provider/model aggregate. Day boundaries are UTC by contract,
/// making the same ledger project identically on macOS and Linux regardless of
/// the host locale or current time zone.
public struct BurnBarUsageProjectionBucket: Codable, Hashable, Sendable {
    public let dayUTC: String
    public let providerID: String
    public let modelID: String
    public let totals: BurnBarUsageProjectionTotals
    public let exactEventCount: Int
    public let estimatedEventCount: Int
    public let unknownEventCount: Int
    public let firstRecordedAt: Date
    public let lastRecordedAt: Date

    public init(
        dayUTC: String,
        providerID: String,
        modelID: String,
        totals: BurnBarUsageProjectionTotals,
        exactEventCount: Int,
        estimatedEventCount: Int,
        unknownEventCount: Int,
        firstRecordedAt: Date,
        lastRecordedAt: Date
    ) {
        self.dayUTC = dayUTC
        self.providerID = providerID
        self.modelID = modelID
        self.totals = totals
        self.exactEventCount = exactEventCount
        self.estimatedEventCount = estimatedEventCount
        self.unknownEventCount = unknownEventCount
        self.firstRecordedAt = firstRecordedAt
        self.lastRecordedAt = lastRecordedAt
    }
}

public struct BurnBarUsageProjection: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generation: Int
    public let generatedAt: Date
    public let ledgerSHA256: String
    public let totals: BurnBarUsageProjectionTotals
    public let buckets: [BurnBarUsageProjectionBucket]

    public init(
        schemaVersion: Int = 1,
        generation: Int,
        generatedAt: Date,
        ledgerSHA256: String,
        totals: BurnBarUsageProjectionTotals,
        buckets: [BurnBarUsageProjectionBucket]
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.generatedAt = generatedAt
        self.ledgerSHA256 = ledgerSHA256
        self.totals = totals
        self.buckets = buckets
    }
}

public struct BurnBarUsageProjectionResponse: Codable, Hashable, Sendable {
    public let projection: BurnBarUsageProjection

    public init(projection: BurnBarUsageProjection) {
        self.projection = projection
    }
}

/// Requests a bounded, daemon-owned snapshot of the indexed conversation
/// history used by Activity export. Unlike `BurnBarRecentUsageRequest`, this
/// contract carries an explicit completeness proof and persisted session body.
public struct BurnBarActivityHistoryRequest: Codable, Hashable, Sendable {
    public let limit: Int

    public init(limit: Int = 500) {
        self.limit = limit
    }
}

public struct BurnBarActivityHistorySession: Codable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let model: String
    public let startedAt: String
    public let tokens: Int
    public let costUsd: Double
    public let title: String
    public let sourceID: String
    public let providerSessionID: String
    public let runID: String?
    public let projectName: String?
    public let bodyMD: String

    public init(
        id: String,
        provider: String,
        model: String,
        startedAt: String,
        tokens: Int,
        costUsd: Double,
        title: String,
        sourceID: String,
        providerSessionID: String,
        runID: String? = nil,
        projectName: String? = nil,
        bodyMD: String
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.startedAt = startedAt
        self.tokens = tokens
        self.costUsd = costUsd
        self.title = title
        self.sourceID = sourceID
        self.providerSessionID = providerSessionID
        self.runID = runID
        self.projectName = projectName
        self.bodyMD = bodyMD
    }
}

public struct BurnBarActivityHistoryResponse: Codable, Hashable, Sendable {
    public let sessions: [BurnBarActivityHistorySession]
    public let nextCursor: String?
    public let historyComplete: Bool
    public let historyLimit: Int
    public let totalCount: Int

    public init(
        sessions: [BurnBarActivityHistorySession],
        nextCursor: String?,
        historyComplete: Bool,
        historyLimit: Int,
        totalCount: Int
    ) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.historyComplete = historyComplete
        self.historyLimit = historyLimit
        self.totalCount = totalCount
    }
}

/// Requests a privacy-bounded, daemon-owned qualitative insight brief. The
/// daemon builds the digest from its usage ledger; the renderer never receives
/// raw transcripts or provider credentials.
public struct BurnBarUsageInsightsRequest: Codable, Hashable, Sendable {
    public let limit: Int
    public let windowSeconds: TimeInterval
    public let prompt: String

    public init(
        limit: Int = 200,
        windowSeconds: TimeInterval = 7 * 24 * 60 * 60,
        prompt: String = "Summarize the most important usage changes and actions."
    ) {
        self.limit = limit
        self.windowSeconds = windowSeconds
        self.prompt = prompt
    }
}

/// Fallback classifier for ledger rows that predate the stamped
/// `billingKind` field. Deliberately conservative: the daemon's provider
/// router only ever dials key-backed provider slots, so every provider it can
/// name is API-billed; anything unrecognized stays `unknown` instead of
/// guessing. Writers should stamp the kind at record time — this table exists
/// only so history remains classifiable.
public enum BurnBarBillingProvenance {
    /// Provider ids the daemon reaches with a configured API key. Kept as an
    /// explicit allowlist (not "everything") so a future subscription-bridged
    /// route cannot be silently misbilled as API spend.
    private static let apiKeyProviderIDs: Set<String> = [
        "deepseek", "openai", "anthropic", "openrouter", "meta", "metadev",
        "xai", "mistral", "gemini", "groq", "zai", "minimax", "moonshot",
        "fireworks", "together", "local-rules"
    ]

    public static func classify(providerID: String) -> BurnBarBillingKind {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return .unknown }
        // "local-rules" rows carry zero cost either way; classifying them as
        // api keeps the budget arithmetic exact without a special case.
        return apiKeyProviderIDs.contains(normalized) ? .api : .unknown
    }

    /// The effective kind for a ledger event: the stamped value when present,
    /// the classifier's answer for legacy rows otherwise.
    public static func effectiveKind(of event: BurnBarUsageEvent) -> BurnBarBillingKind {
        event.billingKind ?? classify(providerID: event.providerID)
    }

    /// Harnesses whose parsed sessions are overwhelmingly plan-billed. Kept in
    /// exact lockstep with the v60 `billingKindBackfillSQL` CASE — the Swift
    /// write path and the SQL backfill must never disagree about a row.
    private static let subscriptionFirstProviders: Set<AgentProvider> = [
        .claudeCode, .codex, .copilot, .cursor, .cursorAgent,
        .factory, .junie, .windsurf, .warp
    ]

    /// Bring-your-own-key harnesses: parsed sessions bill against the user's
    /// own API key. Mirror of the backfill's second CASE arm.
    private static let apiKeyFirstProviders: Set<AgentProvider> = [
        .aider, .hermes, .deepSeek, .openAI, .xAI
    ]

    /// Deterministic write-time classification for `token_usage` rows,
    /// mirroring the v60 backfill exactly:
    /// billing-API and daemon-gateway ingest are real dollars by construction;
    /// plan-first harness logs are subscription; BYO-key harness logs are api;
    /// everything else is `.unknown` — a wrong guess would corrupt the
    /// money/imputed split forever, an unknown can be reclassified later.
    public static func classify(
        provider: AgentProvider,
        usageSource: UsageSource
    ) -> BurnBarBillingKind {
        switch usageSource {
        case .billingAPI, .daemon:
            return .api
        case .providerLog:
            if subscriptionFirstProviders.contains(provider) { return .subscription }
            if apiKeyFirstProviders.contains(provider) { return .api }
            return .unknown
        case .inAppChat, .cursorBridge, .unknown:
            return .unknown
        }
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
