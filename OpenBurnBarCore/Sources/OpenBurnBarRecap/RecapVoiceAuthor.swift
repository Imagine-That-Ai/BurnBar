import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// One request to the editorial model.
public struct RecapVoiceRequest: Sendable {
    public let systemPrompt: String
    public let userPrompt: String

    public init(systemPrompt: String, userPrompt: String) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
    }

    /// The prompt for a second attempt after an unparsable reply — the same
    /// pattern `ChartInsightEngine` already uses, and the single retry that
    /// recovers most "here is your JSON:" preambles.
    public var jsonOnlyRetry: RecapVoiceRequest {
        RecapVoiceRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
                + "\n\nREMINDER: respond with ONLY the JSON object. No other text, no code fences."
        )
    }

    /// Builds the request for a payload.
    public static func forPayload(_ payload: RecapPromptPayload) -> RecapVoiceRequest {
        RecapVoiceRequest(
            systemPrompt: RecapVoiceSchema.systemPrompt,
            userPrompt: RecapVoiceSchema.userPrompt(payloadJSON: payload.json())
        )
    }
}

public struct RecapVoiceAuthorResult: Sendable {
    /// Raw model text. Fence tolerance and JSON extraction happen downstream.
    public let text: String
    public let modelTag: InsightModelTag

    public init(text: String, modelTag: InsightModelTag) {
        self.text = text
        self.modelTag = modelTag
    }
}

/// Supplies model-written prose for a recap.
///
/// Kept deliberately thin — one string in, one string out — so each platform can
/// route through whatever it already has (`CLIBridge` on macOS, the insight
/// adapters on iOS) without this layer knowing anything about transports,
/// credentials or streaming.
///
/// Returning nil means "no backend available", which is a normal outcome, not an
/// error: the deterministic recap is already complete.
public protocol RecapVoiceAuthor: Sendable {
    func author(_ request: RecapVoiceRequest) async throws -> RecapVoiceAuthorResult?
}

/// An author that never produces anything — the default when the editorial
/// layer is switched off.
public struct RecapVoiceAuthorUnavailable: RecapVoiceAuthor {
    public init() {}
    public func author(_ request: RecapVoiceRequest) async throws -> RecapVoiceAuthorResult? { nil }
}
