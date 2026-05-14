import Foundation

/// One slice of a streaming Hermes Insights reply.
///
/// The adapter assembles these into the final `InsightAnalysisResult`:
/// `.delta` chunks grow the answer text incrementally; the optional
/// `.usage` chunk carries the canonical token+cost accounting from
/// Hermes (Hermes prices the underlying provider call and surfaces the
/// derived USD figure here so the audit log and Spend KPI can attribute
/// it without re-pricing on the client).
public enum HermesInsightChunk: Equatable, Sendable {
    /// Incremental answer text fragment. Concatenate in arrival order.
    case delta(String)
    /// Terminal token + cost accounting reported by Hermes. Always
    /// arrives at most once, immediately before `.completed`.
    case usage(HermesInsightTokenUsage)
    /// Stream finished cleanly. `fullAnswer` is the assembled text in
    /// case the consumer wants to short-circuit without manually
    /// accumulating `.delta` chunks.
    case completed(fullAnswer: String)
}

/// Hermes-flavoured token + cost report. Carries every dimension the
/// audit log + Spend KPI need; the adapter folds this into
/// `InsightTokenUsage` before persisting.
public struct HermesInsightTokenUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    /// USD figure Hermes derived from its own pricing table for the
    /// underlying provider call. The adapter prefers this over any
    /// catalog-based estimate so the audit log records the relay's
    /// truth, not a client-side approximation.
    public var estimatedCostUSD: Double

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        estimatedCostUSD: Double = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheCreationTokens + cacheReadTokens
    }
}

/// Pre-rendered chat-completion request the adapter hands to a
/// `HermesInsightTransport`. Carries the structured prompt + payload
/// the same way `OpenAIInsightAdapter` builds its body — the transport
/// only knows how to ship bytes to the user's Hermes session.
public struct HermesInsightChatRequest: Sendable {
    /// Hermes model id (e.g. `"hermes-default"`, `"hermes-claude"`).
    public var modelID: String
    /// System prompt assembled by `InsightAnalysisModelPrompt`.
    public var systemPrompt: String
    /// Encoded user payload (JSON-bytes from `InsightAnalysisModelPrompt.userPayload`).
    public var userPayload: Data
    /// Best supported response format for this turn — strict JSON schema,
    /// json_object, or narrative-only. Transports may downgrade if the
    /// underlying provider lacks support.
    public var capabilityTier: InsightCapabilityTier
    /// `true` when the user explicitly asked for a follow-up answer so
    /// the transport may pick a faster, answer-oriented model under the
    /// hood. Defaults to false (full editorial brief).
    public var prefersAnswerLatency: Bool
    /// Maximum output tokens — keeps the chat completion bounded so a
    /// runaway model can't push the meta strip into a four-figure cost.
    public var maxOutputTokens: Int

    public init(
        modelID: String,
        systemPrompt: String,
        userPayload: Data,
        capabilityTier: InsightCapabilityTier,
        prefersAnswerLatency: Bool = false,
        maxOutputTokens: Int = 1400
    ) {
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.userPayload = userPayload
        self.capabilityTier = capabilityTier
        self.prefersAnswerLatency = prefersAnswerLatency
        self.maxOutputTokens = maxOutputTokens
    }
}

/// One-shot chat completion result the transport returns when the
/// adapter asked for buffered analysis (the streaming path uses
/// `streamChatCompletion` instead). `responseJSON` is the raw OpenAI-
/// shaped payload the adapter hands to `InsightAnalysisModelDecoder`.
public struct HermesInsightChatResponse: Sendable {
    /// Raw response body from the Hermes relay. Expected to contain the
    /// structured JSON envelope at `choices[0].message.content`.
    public var responseJSON: Data
    /// Terminal token + cost accounting. Optional only because
    /// extremely old Hermes builds may not surface usage on every turn;
    /// when nil the adapter falls back to its own per-token estimate.
    public var usage: HermesInsightTokenUsage?

    public init(responseJSON: Data, usage: HermesInsightTokenUsage? = nil) {
        self.responseJSON = responseJSON
        self.usage = usage
    }
}
