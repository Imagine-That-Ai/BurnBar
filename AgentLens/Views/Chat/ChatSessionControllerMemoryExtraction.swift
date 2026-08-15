import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

@MainActor
extension ChatSessionController {
    /// Builds the extraction context for the current turn. v1 scopes by `appID`
    /// (same-device); `userID` is resolved at the backend rendezvous (PR-5), not
    /// trusted from this client. `threadLogicalID` is the device-local thread id
    /// for v1; a content-addressed cross-device id is a backend/F-3 refinement.
    func makeMemoryExtractionContext() -> MemoryExtractionContext {
        MemoryExtractionContext(
            scope: MemoryScope(appID: "openburnbar"),
            threadLogicalID: activeThreadID,
            promptVersion: Self.memoryPromptVersion
        )
    }

    var memoryServiceForExtraction: (any MemoryServing)? {
        settingsManager.memoryExtractionEnabled ? memoryService : nil
    }

    /// PR-D3 must-fix #4: kick the extraction drain after a terminal assistant commit has
    /// (atomically) enqueued an extraction job, so the job is processed THIS session instead
    /// of waiting for the next foreground/startup drain. A no-op when no engine is wired
    /// (tests, or pre-PR-5 builds) or when the kill switch is off — `launchDrain()` re-reads
    /// the live gate and returns immediately when extraction is disabled. Fire-and-forget;
    /// extraction must never block or fail the chat turn.
    func scheduleMemoryDrainAfterCommit() {
        // PR8 reinforce-on-use: the memories recalled into this turn's prompt
        // earned a hit — the turn committed, so the recall demonstrably fed a
        // kept exchange. Fire-and-forget (zero LLM, zero blocking) and cleared
        // here so an abandoned turn never reinforces.
        let recalledIDs = lastRecalledMemoryIDs
        lastRecalledMemoryIDs = []
        if recalledIDs.isEmpty == false {
            memoryExtractionEngine?.reinforceRecalledMemories(ids: recalledIDs)
        }
        memoryExtractionEngine?.launchDrain()
    }
}
