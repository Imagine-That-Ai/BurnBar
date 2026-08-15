import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

extension ChatSessionController {

    func buildInsightBriefSnapshot(refreshRollups: Bool = true) -> InsightBriefSnapshot {
        if let typed = typedSearchService {
            return InsightBriefSnapshot.build(
                from: dataStore,
                intelligenceService: typed,
                refreshRollups: refreshRollups
            )
        }
        return InsightBriefSnapshot.build(from: dataStore, refreshRollups: refreshRollups)
    }

    /// Off-main variant — the rollup GRDB I/O runs on a background task.
    /// See `InsightBriefSnapshot.buildAsync`.
    func buildInsightBriefSnapshotAsync(refreshRollups: Bool = true) async -> InsightBriefSnapshot {
        if let typed = typedSearchService {
            return await InsightBriefSnapshot.buildAsync(
                from: dataStore,
                intelligenceService: typed,
                refreshRollups: refreshRollups
            )
        }
        return await InsightBriefSnapshot.buildAsync(from: dataStore, refreshRollups: refreshRollups)
    }

    /// Fire-and-forget variant of `send()` — launches a Task not tied to any view lifecycle.
    func fireAndForgetSend() {
        Task { await send() }
    }

    /// F-2 (G8): recall memory snippets for the current turn and wrap each via
    /// `LLMSafeContent.wrapUntrusted` so they land in the evidence region only —
    /// never the trusted persona block. Returns "" when no service is wired or
    /// recall yields nothing.
    ///
    /// Memory text is ALWAYS untrusted regardless of the snippet's `trustTier`
    /// (defense-in-depth): the tier is server-resolved against the canonical chat
    /// row and carried on the snippet for provenance, but it is never a license
    /// to skip wrapping or to inject into persona voice. If the source row is
    /// missing/non-user/non-assistant the backend pins the tier to
    /// `.untrusted`/`.assistantDerived`; the frontend treats both as untrusted.
    func recallMemorySection(query: String, tokenBudget: Int) async -> String {
        // Gate recall by the same G4 kill switch as extraction so a fleet kill (or the
        // user toggle) immediately stops surfacing memories — even already-stored ones.
        guard settingsManager.memoryExtractionEnabled, let memoryService else { return "" }
        let scope = makeMemoryExtractionContext().scope
        let recallBudget = MemoryRecallBudget.forReply(
            arbiterBudget: max(tokenBudget, 1),
            highRecall: settingsManager.memoryHighRecallPerReply
        )
        let request = MemoryRecallRequest(
            query: query,
            scope: scope,
            tokenBudget: recallBudget.tokenBudget,
            limit: recallBudget.limit
        )
        let snippets: [MemorySnippet]
        do {
            snippets = try await memoryService.recallForPrompt(request)
        } catch {
            AppLogger.chat.silentFailure("memory recallForPrompt", error: error)
            self.lastRecalledMemoryCitations = []
            self.lastRecalledMemoryIDs = []
            return ""
        }
        self.lastRecalledMemoryCitations = snippets.flatMap(\.citations)
        // PR8 reinforce-on-use: remember WHICH memories entered the prompt so
        // the terminal-commit hook can bump their hit counts if the turn lands.
        self.lastRecalledMemoryIDs = snippets.map(\.memoryID)
        guard !snippets.isEmpty else { return "" }
        return snippets.map { snippet in
            let jumpID = snippet.citations.first?.messageID ?? snippet.citations.first?.crossDeviceHMAC
            let provenance = "memory:\(snippet.memoryID)@\(jumpID ?? "unresolved")"
            return LLMSafeContent.wrapUntrusted(snippet.text, provenance: provenance)
        }.joined(separator: "\n\n")
    }

}
