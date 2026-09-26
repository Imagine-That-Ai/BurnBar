import Foundation

/// Usage accounting primitives (3.2: extracted from provider contracts; usage models consume them, so they sit in ProviderModels below UsageModels).

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

/// Whether a usage event represents real per-token dollars leaving a wallet
/// (`api`) or the imputed list-price value of work that actually ran inside a
/// flat plan (`subscription`). `unknown` is the fail-honest default for rows
/// recorded before this dimension existed; consumers must surface it as its
/// own bucket rather than silently folding it into either side.
public enum BurnBarBillingKind: String, Codable, Hashable, Sendable, CaseIterable {
    case api
    case subscription
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
    /// Product surface that originated the request (for example Cursor or
    /// Grok Build). Optional for backward-compatible daemon ledger decoding.
    public let executionSourceID: String?
    public let executionSourceName: String?
    public let executionSourceKind: UsageExecutionSourceKind?
    public let executionSourceConfidence: BurnBarUsageConfidence?
    /// Confidence level for the recorded counts. Defaults to `.exact` for backwards compat
    /// (existing daemon-recorded rows are exact provider responses).
    public let confidence: BurnBarUsageConfidence
    /// Optional rollup key tying several sub-call usage events to one
    /// originating request. The Elder Wand model-fusion router stamps every
    /// panel/judge/synthesis sub-call with a shared `parentRequestID` so the N
    /// rows recorded for one fusion completion sum back to a single request
    /// (each sub-call still uses a DISTINCT idempotency key so they are not
    /// deduped). `nil` for ordinary single-route completions; additive and
    /// decode-optional so existing rows and call sites are unaffected.
    public let parentRequestID: String?
    /// Billing provenance of this event: real API dollars vs subscription-plan
    /// imputed value. Stamped by the writer that knows the route; `nil` on
    /// rows recorded before the field existed (resolve via
    /// `BurnBarBillingProvenance.effectiveKind(of:)`). Additive and
    /// decode-optional like `parentRequestID`.
    public let billingKind: BurnBarBillingKind?

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
        case executionSourceID
        case executionSourceName
        case executionSourceKind
        case executionSourceConfidence
        case confidence
        case parentRequestID
        case billingKind
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
        executionSourceID: String? = nil,
        executionSourceName: String? = nil,
        executionSourceKind: UsageExecutionSourceKind? = nil,
        executionSourceConfidence: BurnBarUsageConfidence? = nil,
        confidence: BurnBarUsageConfidence = .exact,
        parentRequestID: String? = nil,
        billingKind: BurnBarBillingKind? = nil
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
        self.executionSourceID = executionSourceID
        self.executionSourceName = executionSourceName
        self.executionSourceKind = executionSourceKind
        self.executionSourceConfidence = executionSourceConfidence
        self.confidence = confidence
        self.parentRequestID = parentRequestID
        self.billingKind = billingKind
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
        executionSourceID = try container.decodeIfPresent(String.self, forKey: .executionSourceID)
        executionSourceName = try container.decodeIfPresent(String.self, forKey: .executionSourceName)
        executionSourceKind = try container.decodeIfPresent(UsageExecutionSourceKind.self, forKey: .executionSourceKind)
        executionSourceConfidence = try container.decodeIfPresent(BurnBarUsageConfidence.self, forKey: .executionSourceConfidence)
        confidence = try container.decodeIfPresent(BurnBarUsageConfidence.self, forKey: .confidence) ?? .exact
        parentRequestID = try container.decodeIfPresent(String.self, forKey: .parentRequestID)
        billingKind = try container.decodeIfPresent(BurnBarBillingKind.self, forKey: .billingKind)
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
        try container.encodeIfPresent(executionSourceID, forKey: .executionSourceID)
        try container.encodeIfPresent(executionSourceName, forKey: .executionSourceName)
        try container.encodeIfPresent(executionSourceKind, forKey: .executionSourceKind)
        try container.encodeIfPresent(executionSourceConfidence, forKey: .executionSourceConfidence)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(parentRequestID, forKey: .parentRequestID)
        try container.encodeIfPresent(billingKind, forKey: .billingKind)
    }
}
