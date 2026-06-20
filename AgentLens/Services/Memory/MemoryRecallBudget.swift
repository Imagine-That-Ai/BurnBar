import Foundation

/// Maps the "High-recall (per reply)" toggle to concrete recall parameters.
///
/// Default values mirror the `MemoryRecallRequest` defaults (limit: 8, tokenBudget:
/// whatever `promptArbiter.memoryBudget` allocates — the caller passes the arbiter
/// value directly, so `tokenBudget` here is a *multiplier cap* on what high-recall
/// adds relative to the arbiter budget).
///
/// High-recall doubles both axes so the prompt receives roughly 2× the snippet
/// coverage without exceeding the arbiter's upper bound (the arbiter still truncates
/// if the assembled prompt would overflow). Specifically:
///   • limit 8 → 16   (more distinct memories can surface per reply)
///   • tokenBudget multiplier 1× → 2×  (caller multiplies arbiter budget by this)
///
/// These numbers are intentionally conservative: 16 snippets × ~40 tokens each ≈ 640
/// tokens at most, well inside a typical 2 k-token memory section ceiling.
enum MemoryRecallBudget {
    /// Default snippet limit used when high-recall is off.
    /// Must match `MemoryRecallRequest.init` default parameter.
    static let defaultLimit: Int = 8

    /// Multiplier applied to the arbiter's `memoryBudget` token count in default mode.
    static let defaultTokenBudgetMultiplier: Double = 1.0

    /// Snippet limit used when high-recall is on.
    static let highRecallLimit: Int = 16

    /// Multiplier applied to the arbiter's `memoryBudget` token count in high-recall mode.
    static let highRecallTokenBudgetMultiplier: Double = 2.0

    /// Returns `(limit, tokenBudget)` for a `MemoryRecallRequest`, given the arbiter's
    /// allocated budget and the toggle state.
    ///
    /// - Parameters:
    ///   - arbiterBudget: Token count from `PromptTokenArbiter.memoryBudget`.
    ///   - highRecall: Value of `settingsManager.memoryHighRecallPerReply`.
    /// - Returns: A tuple suitable for `MemoryRecallRequest(query:scope:tokenBudget:limit:)`.
    static func forReply(arbiterBudget: Int, highRecall: Bool) -> (limit: Int, tokenBudget: Int) {
        if highRecall {
            return (
                limit: highRecallLimit,
                tokenBudget: Int((Double(arbiterBudget) * highRecallTokenBudgetMultiplier).rounded())
            )
        }
        return (
            limit: defaultLimit,
            tokenBudget: arbiterBudget
        )
    }
}
