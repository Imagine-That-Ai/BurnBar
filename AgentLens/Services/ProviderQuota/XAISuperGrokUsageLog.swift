import Foundation
import OpenBurnBarCore

// MARK: - SuperGrok Usage Log
//
// Per-prompt JSONL log used by `XAIQuotaAdapter` (SuperGrok pacing branch)
// to estimate prompts-in-rolling-2h-window for the consumer tiers.
//
// xAI does not publish a consumer-quota API for SuperGrok Lite / SuperGrok /
// SuperGrok Heavy; the adapter therefore computes a best-effort estimate by
// counting events in this log over the last 2 hours and comparing against
// the published cap for the active tier. Caps live on
// `XAIQuotaPlanTier.rollingTwoHourPromptCap` and may drift over time —
// downstream snapshots are flagged `confidence: .estimated`.
//
// Writers append one line every time the routing layer dispatches a prompt
// to xAI, regardless of which inference key actually services the call.

enum XAISuperGrokUsageLog {

    /// Append one event line to the SuperGrok usage log.
    static func recordPromptDispatched(
        plan: XAIQuotaPlanTier,
        model: String? = nil,
        source: String? = nil,
        at date: Date = Date(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        guard plan.isSuperGrokConsumer else { return }
        XAISuperGrokPacingLog.recordPromptDispatched(
            model: model,
            source: source,
            at: date,
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager,
            planTierRawValue: plan.rawValue
        )
    }
}
