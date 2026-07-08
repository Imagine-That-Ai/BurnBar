import Foundation
import OpenBurnBarCore

/// Maps the "High-recall (per reply)" toggle to concrete `MemoryRecallRequest`
/// parameters, and exposes the wrapper-envelope overhead the recall packer must charge.
///
/// High-recall's lever is the LIMIT — how many distinct approved facts are eligible to
/// surface — NOT a larger token slice. The prompt-token arbiter (`PromptTokenArbiter`)
/// caps the assembled, wrapped `.memory` section at its own `memoryBudget` regardless of
/// what recall asks for, so inflating `tokenBudget` here only forced the arbiter to
/// truncate a wrapped block — which severed the `</UNTRUSTED_CONTENT>` seal (M1/M2 audit
/// findings). The token budget therefore tracks the arbiter's allocation in both modes,
/// and the per-snippet wrapper envelope is charged in `recallChatMemorySnippets` so the
/// section fits the cap without truncation.
enum MemoryRecallBudget {
    /// Default snippet limit used when high-recall is off.
    /// Must match `MemoryRecallRequest.init` default parameter.
    static let defaultLimit: Int = 8

    /// Snippet limit when high-recall is on: a larger candidate pool under the SAME token
    /// cap (more distinct small facts can surface; the arbiter still bounds total size).
    static let highRecallLimit: Int = 16

    /// Per-snippet token cost of the `LLMSafeContent.wrapUntrusted` envelope (open tag +
    /// provenance + close tag + the multi-sentence CRITICAL RULE). The recall packer adds
    /// this to each snippet's body estimate so the budget reflects the WRAPPED size the
    /// arbiter actually sees — otherwise the assembled `.memory` section overflows the
    /// arbiter cap and is truncated. Estimated in the SAME units the `PromptTokenArbiter`
    /// uses for the `.memory` section (prose, ~3.5 chars/token) so recall and the arbiter
    /// agree on cost; using chars/4 here would under-count and re-introduce overflow.
    /// Derived from the real wrapper of an empty body so it tracks the template.
    static let wrapperTokenOverhead: Int = {
        // Price a WORST-CASE provenance: the real one assembled in
        // ChatSessionController+Search.recallMemorySection is "memory:<memoryID>@<jumpID>",
        // where memoryID is a UUID / "memory-<uuid>-<n>" and jumpID can be a message UUID
        // or a "v1-local:<sha256-hex>" cross-device tag — up to ~130 chars, far longer than
        // a short placeholder. Over-pricing the provenance (plus +1 token for the per-snippet
        // "\n\n" join) keeps the recall budget CONSERVATIVE vs the actual wrapped string, so
        // the assembled .memory section cannot overflow the arbiter cap and get truncated.
        let worstCaseProvenance = "memory:" + String(repeating: "x", count: 140)
        let envelope = LLMSafeContent.wrapUntrusted("", provenance: worstCaseProvenance)
        return PromptTokenArbiter.estimateProseTokens(envelope) + 1
    }()

    /// Returns `(limit, tokenBudget)` for a `MemoryRecallRequest`, given the arbiter's
    /// allocated budget and the toggle state.
    ///
    /// - Parameters:
    ///   - arbiterBudget: Token count from `PromptTokenArbiter.memoryBudget` (the cap the
    ///     assembled wrapped section must fit).
    ///   - highRecall: Value of `settingsManager.memoryHighRecallPerReply`.
    /// - Returns: A tuple suitable for `MemoryRecallRequest(query:scope:tokenBudget:limit:)`.
    static func forReply(arbiterBudget: Int, highRecall: Bool) -> (limit: Int, tokenBudget: Int) {
        (limit: highRecall ? highRecallLimit : defaultLimit, tokenBudget: max(arbiterBudget, 1))
    }
}
