import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

struct HermesChatMessage: Identifiable, Equatable {
    /// Wall-clock generation windows shorter than this are treated as buffered
    /// SSE bursts (a relay or proxy delivered the whole answer at once). We
    /// suppress the rate in that case rather than print physically impossible
    /// numbers like "720 tok/s on a 31B local model".
    static let minimumTrustworthyWallClockDurationSeconds: TimeInterval = 0.1

    let id: String
    let role: HermesChatRole
    var text: String
    var toolCalls: [HermesToolCall]
    /// Hermes Square §6.6 — typed UI cards the agent emitted on this
    /// turn. Populated from SSE chunks that carry a `card` field (single
    /// envelope) or a `cards` field (array). Rendered inline by
    /// `HermesMessageBubble` via `CardEnvelopeView`. Empty for most
    /// turns; agents only emit cards when they want a structured
    /// surface (diff, approval, chart, mini-program).
    var cards: [CardEnvelope] = []
    /// Files the user attached to this message. Persisted with the chat so
    /// attachments stay visible after a session is reopened.
    var attachments: [HermesAttachment]
    /// What the user (or selected favourite) asked Hermes to use. Stays stable
    /// for the lifetime of the message so we can show "Asked: …" honestly even
    /// when the server picked a different model.
    var requestedModelID: String?
    /// What the server told us it actually ran, parsed from streamed
    /// `"model"` fields. `nil` until the first SSE chunk that includes it
    /// arrives; some servers never emit it.
    var responseModelID: String?
    /// Display-friendly model name (`responseModelID` when present, otherwise
    /// `requestedModelID`-derived). Kept for backwards compatibility with
    /// existing UI code that already reads `modelName`.
    var modelName: String?
    let timestamp: Date
    var isStreaming: Bool
    var isError: Bool
    var responseStartedAt: Date?
    var firstResponseChunkAt: Date?
    var responseCompletedAt: Date?
    var outputTokenCount: Int?
    var totalTokenCount: Int?
    var tokenCountSource: HermesTokenCountSource?
    /// Provider-reported generation duration in seconds (Ollama
    /// `eval_duration`, OpenAI-style `generation_time`, etc.). When present
    /// we use this for `tokensPerSecond` instead of wall-clock.
    var providerGenerationDurationSeconds: TimeInterval?
    /// Provider-reported total wall-clock duration in seconds, surfaced for
    /// diagnostics and accessibility text.
    var providerTotalDurationSeconds: TimeInterval?
    /// For `role == .tool` messages, the upstream `tool_calls[].id` this
    /// reply answers. Always non-nil for tool messages, always nil for
    /// other roles. The encoder uses this to emit
    /// `{role: "tool", tool_call_id: "..."}` on the wire.
    var toolCallID: String?
    /// Transient SSE state — accumulated `delta.refusal` text for this
    /// turn. When the model declines, OpenAI-compatible servers emit the
    /// reason on this channel instead of `content`. We hoist it into
    /// `text` at finalize so the user actually sees what happened.
    var streamedRefusal: String = ""
    /// Transient SSE state — accumulated reasoning channel text
    /// (`reasoning_content`, `reasoning`, `thinking`). Some thinking
    /// models (DeepSeek R1, Qwen3 thinking, certain MiniMax routes)
    /// emit the entire answer on the reasoning channel without ever
    /// flushing to `content`. We hoist it into `text` at finalize so
    /// the bubble renders the model's actual response instead of an
    /// empty error.
    var streamedReasoning: String = ""
    /// Last `choices[].finish_reason` observed for this turn. Used to
    /// pick a more honest empty-text fallback (length cap vs. content
    /// filter vs. truncated stream).
    var lastFinishReason: String?
    /// First-class outcome for this assistant turn. Drives the bubble
    /// chrome (badge, border, retry affordance) so the UI doesn't have
    /// to sniff the prose to know whether the model actually answered,
    /// declined, only emitted reasoning, or finished without text.
    /// Always `.normal` for user/system/tool messages.
    var outcome: HermesChatMessageOutcome = .normal

    init(
        id: String = UUID().uuidString,
        role: HermesChatRole,
        text: String,
        toolCalls: [HermesToolCall] = [],
        attachments: [HermesAttachment] = [],
        requestedModelID: String? = nil,
        responseModelID: String? = nil,
        modelName: String? = nil,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isError: Bool = false,
        responseStartedAt: Date? = nil,
        firstResponseChunkAt: Date? = nil,
        responseCompletedAt: Date? = nil,
        outputTokenCount: Int? = nil,
        totalTokenCount: Int? = nil,
        tokenCountSource: HermesTokenCountSource? = nil,
        providerGenerationDurationSeconds: TimeInterval? = nil,
        providerTotalDurationSeconds: TimeInterval? = nil,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.requestedModelID = requestedModelID
        self.responseModelID = responseModelID
        self.modelName = modelName
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isError = isError
        self.responseStartedAt = responseStartedAt
        self.firstResponseChunkAt = firstResponseChunkAt
        self.responseCompletedAt = responseCompletedAt
        self.outputTokenCount = outputTokenCount
        self.totalTokenCount = totalTokenCount
        self.tokenCountSource = tokenCountSource
        self.providerGenerationDurationSeconds = providerGenerationDurationSeconds
        self.providerTotalDurationSeconds = providerTotalDurationSeconds
        self.toolCallID = toolCallID
    }

    /// Wall-clock generation duration: time from the first received chunk to
    /// completion. Only safe when the stream wasn't proxy-buffered.
    var wallClockGenerationDurationSeconds: TimeInterval? {
        guard role == .assistant else { return nil }
        let start = firstResponseChunkAt ?? responseStartedAt
        let end = responseCompletedAt ?? (isStreaming ? Date() : nil)
        guard let start, let end else { return nil }
        let duration = end.timeIntervalSince(start)
        return duration > 0 ? duration : nil
    }

    /// Best available generation duration. Prefers the provider-reported
    /// number (truthful, measured server-side); falls back to wall-clock when
    /// no provider value is available.
    var generationDurationSeconds: TimeInterval? {
        if let providerGenerationDurationSeconds, providerGenerationDurationSeconds > 0 {
            return providerGenerationDurationSeconds
        }
        return wallClockGenerationDurationSeconds
    }

    var totalResponseDurationSeconds: TimeInterval? {
        if let providerTotalDurationSeconds, providerTotalDurationSeconds > 0 {
            return providerTotalDurationSeconds
        }
        guard role == .assistant,
              let start = responseStartedAt,
              let end = responseCompletedAt ?? (isStreaming ? Date() : nil) else {
            return nil
        }
        let duration = end.timeIntervalSince(start)
        return duration > 0 ? duration : nil
    }

    /// Where the generation duration we'd publish actually came from. When
    /// the wall-clock window is implausibly short for the reported token
    /// count, we mark it `bufferedWallClock` and suppress the rate.
    var generationDurationSource: HermesGenerationDurationSource? {
        guard role == .assistant else { return nil }
        if let providerGenerationDurationSeconds, providerGenerationDurationSeconds > 0 {
            return .providerEvalDuration
        }
        guard let wall = wallClockGenerationDurationSeconds else { return nil }
        if wall < Self.minimumTrustworthyWallClockDurationSeconds {
            return .bufferedWallClock
        }
        return .wallClock
    }

    var tokensPerSecond: Double? {
        guard role == .assistant,
              !isError,
              let outputTokenCount,
              outputTokenCount > 0,
              let source = generationDurationSource else {
            return nil
        }
        switch source {
        case .providerEvalDuration:
            guard let providerGenerationDurationSeconds,
                  providerGenerationDurationSeconds > 0 else { return nil }
            return Double(outputTokenCount) / providerGenerationDurationSeconds
        case .wallClock:
            guard let wall = wallClockGenerationDurationSeconds, wall > 0 else { return nil }
            return Double(outputTokenCount) / wall
        case .bufferedWallClock:
            // Stream was proxy-buffered. Refusing to publish a rate is the
            // honest answer — better silent than 720 tok/s on a 31B model.
            return nil
        }
    }

    var isTokensPerSecondEstimated: Bool {
        // Honest definition: a published rate counts as "estimated" unless
        // *both* the token count and the generation duration came from the
        // provider. The `~` prefix is the user-visible signal that
        // something in the rate computation isn't fully trustworthy.
        //   provider usage  + provider eval duration → exact (no `~`)
        //   provider usage  + wall-clock             → estimated (`~`)
        //   text estimate   + anything               → estimated (`~`)
        if tokenCountSource == .estimatedText { return true }
        if generationDurationSource == .wallClock { return true }
        return false
    }

    var tokensPerSecondDisplayText: String? {
        guard let tokensPerSecond else { return nil }
        let value: String
        if tokensPerSecond >= 100 {
            value = String(format: "%.0f", tokensPerSecond)
        } else if tokensPerSecond >= 10 {
            value = String(format: "%.1f", tokensPerSecond)
        } else {
            value = String(format: "%.2f", tokensPerSecond)
        }
        let prefix = isTokensPerSecondEstimated ? "~" : ""
        return "\(prefix)\(value) tok/s"
    }

    /// `true` once the server has echoed any `"model"` field. `false` for
    /// servers that silently swallow the model param — useful for surfacing a
    /// "server didn't confirm model" affordance in the UI.
    var serverConfirmedModel: Bool {
        responseModelID?.nilIfBlank != nil
    }

    /// `true` when the server explicitly told us it ran a different model than
    /// what the client requested. Comparison ignores casing/whitespace.
    var serverRoutedToDifferentModel: Bool {
        guard let requested = requestedModelID?.nilIfBlank?.lowercased(),
              let response = responseModelID?.nilIfBlank?.lowercased(),
              requested != response else {
            return false
        }
        return true
    }

    mutating func markResponseStarted(at date: Date = Date()) {
        if responseStartedAt == nil {
            responseStartedAt = date
        }
    }

    mutating func markFirstResponseChunk(at date: Date = Date()) {
        markResponseStarted(at: date)
        if firstResponseChunkAt == nil {
            firstResponseChunkAt = date
        }
    }

    mutating func applyTokenUsage(_ usage: HermesTokenUsageStats) {
        if let totalTokens = usage.totalTokens, totalTokens > 0 {
            self.totalTokenCount = totalTokens
        }
        if let outputTokens = usage.outputTokens, outputTokens > 0 {
            self.outputTokenCount = outputTokens
            self.tokenCountSource = .providerUsage
        }
        if let provided = usage.generationDurationSeconds, provided > 0 {
            self.providerGenerationDurationSeconds = provided
        }
        if let totalProvided = usage.totalDurationSeconds, totalProvided > 0 {
            self.providerTotalDurationSeconds = totalProvided
        }
    }

    /// Records the model id the server tells us it ran. Stable: only the
    /// first non-blank value sticks per turn so a downstream chunk that
    /// echoes a different alias can't quietly overwrite it.
    mutating func applyResponseModelID(_ rawValue: String?) {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return }
        if responseModelID?.nilIfBlank == nil {
            responseModelID = trimmed
        }
        // Always reflect the most recent confirmed value in `modelName` so
        // existing UI bindings update without extra code.
        modelName = trimmed
    }

    mutating func finalizeResponseMetrics(at date: Date = Date()) {
        guard role == .assistant else { return }
        markResponseStarted(at: timestamp)
        responseCompletedAt = date

        guard !isError,
              outputTokenCount == nil,
              let estimated = Self.estimatedOutputTokens(for: text) else {
            return
        }
        outputTokenCount = estimated
        tokenCountSource = .estimatedText
    }

    static func estimatedOutputTokens(for text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let characterEstimate = Int((Double(trimmed.count) / 4.0).rounded(.up))
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let wordEstimate = Int((Double(wordCount) * 1.3).rounded(.up))
        return max(1, max(characterEstimate, wordEstimate))
    }

    /// Body + error styling + first-class outcome to use when the
    /// upstream stream finished without producing any visible
    /// `content` or executable `tool_calls`. Three rescue paths in
    /// priority order:
    ///   1. **Refusal**: model declined; we surface the refusal reason
    ///      so the user knows the model intentionally responded.
    ///   2. **Reasoning-only**: thinking models occasionally emit the
    ///      whole answer on the reasoning channel and never flush to
    ///      `content`. Hoisting the reasoning text gives the user a
    ///      real reply instead of an empty error.
    ///   3. **Hard empty**: nothing usable — we surface a more
    ///      informative message keyed off `lastFinishReason` so the
    ///      user knows whether to retry, shorten the prompt, or switch
    ///      models.
    ///
    /// The returned `outcome` lets the bubble UI render a tag/icon
    /// without sniffing prose ("does this contain 'declined'?" — bad).
    static func emptyResponseFallback(
        refusal: String,
        reasoning: String,
        finishReason: String?
    ) -> (text: String, isError: Bool, outcome: HermesChatMessageOutcome) {
        let trimmedRefusal = refusal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRefusal.isEmpty {
            return (trimmedRefusal, false, .refusal)
        }
        let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReasoning.isEmpty {
            // Hoist verbatim — the bubble chrome (`.reasoningFallback`
            // outcome) tells the user this is the raw reasoning channel
            // and that the model never produced a polished reply. No
            // prose marker needed.
            return (trimmedReasoning, false, .reasoningFallback)
        }
        switch finishReason?.lowercased() {
        case "length":
            return (
                "Hermes hit its reply length cap before finishing. Try a shorter prompt or switch to a model with a larger reply ceiling.",
                true,
                .lengthCap
            )
        case "content_filter":
            return (
                "Hermes blocked this reply for content safety. Try rewording the prompt or switch models.",
                true,
                .contentFilter
            )
        case "tool_calls":
            return (
                "Hermes asked to use a tool but didn't follow up with a reply. Try again or switch models.",
                true,
                .toolCallNoFollowUp
            )
        default:
            return (
                "Hermes returned no text. Try again or switch models.",
                true,
                .empty
            )
        }
    }
}

/// One tool the model decided to invoke in the current assistant turn.
///
/// `name` lands first (the OpenAI streaming protocol sends it on the *first*
/// tool-call delta). `arguments` is accumulated across subsequent deltas — each
/// streamed fragment is appended in order, since they are partial JSON strings
/// that only parse correctly once concatenated. `detail` is a human-readable
/// preview derived from `arguments` (e.g. the file path passed to `read_file`)
/// so the mobile pill can show *what the model is doing*, not just *that it is
/// using a tool*.
struct HermesToolCall: Identifiable, Equatable {
    let id: String
    var name: String
    var status: String
    /// Raw concatenated JSON arguments string. Streamed incrementally.
    var arguments: String
    /// Short human-readable preview of the arguments (path, command, query…).
    /// Computed once the model emits enough fragments to parse usefully.
    var detail: String?

    init(
        id: String,
        name: String,
        status: String,
        arguments: String = "",
        detail: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.arguments = arguments
        self.detail = detail
    }
}

// `nilIfBlank` lives in Models/StringNilIfBlank.swift (shared across the
// mobile target).
