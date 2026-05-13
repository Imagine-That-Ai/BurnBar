import Foundation

/// Token + cost accounting produced by a single LLM investigation.
///
/// Each investigation logs one of these to the audit trail and (via
/// `BurnBarUsageEvent` on the daemon side) into the standard usage ledger
/// so the Insights tab's own cost shows up in the user's normal billing
/// rollups. This is the trust-by-design loop: the tool that measures cost
/// measures *itself*.
public struct InsightTokenUsage: Codable, Hashable, Sendable {
    public var providerKey: String
    public var modelID: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var estimatedCostUSD: Double
    public var startedAt: Date
    public var completedAt: Date

    public init(
        providerKey: String,
        modelID: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        estimatedCostUSD: Double = 0,
        startedAt: Date,
        completedAt: Date
    ) {
        self.providerKey = providerKey
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheCreationTokens + cacheReadTokens
    }

    public var durationSeconds: TimeInterval {
        max(0, completedAt.timeIntervalSince(startedAt))
    }
}
