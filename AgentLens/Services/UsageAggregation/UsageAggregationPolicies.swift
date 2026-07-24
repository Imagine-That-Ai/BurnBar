import Foundation
import OpenBurnBarLogParsers

enum SummaryEndpointCooldownPolicy {
    static let localEndpointFailureCooldown: TimeInterval = 5 * 60
}

/// Resource bounds for usage-refresh and conversation-indexing parse passes.
///
/// Sized for the 2026-07-16 incident corpus (21GB of Codex rollouts, 4.2GB of
/// Claude transcripts on one machine): a cold cache converges over a handful
/// of ticks instead of one unbounded 80-minute, 25GB pass, and steady-state
/// ticks (incremental tail scans) never come near the budget.
enum ParserResourcePolicy {
    /// Bytes of new (uncached) log content one usage-refresh pass may read.
    static let refreshFileByteBudget: Int64 = 256 * 1024 * 1024
    /// Bytes of new content one conversation-indexing pass may read — bodies
    /// re-read whole changed files, so this pass gets more headroom.
    static let indexingFileByteBudget: Int64 = 512 * 1024 * 1024
    /// Process physical footprint at which any governed pass hard-aborts.
    /// Generous versus the app's normal few-hundred-MB footprint, but far
    /// below the level that pushes a 64GB machine into swap death.
    static let memoryCeilingBytes: Int64 = 4 * 1024 * 1024 * 1024
    /// Footprint that logs a warning once per pass.
    static let memorySoftLimitBytes: Int64 = 1536 * 1024 * 1024

    static func makeRefreshGovernor() -> ParserResourceGovernor {
        makeGovernor(fileByteBudget: refreshFileByteBudget, label: "usage_refresh")
    }

    static func makeRefreshGovernor(fileByteBudget: Int64) -> ParserResourceGovernor {
        makeGovernor(fileByteBudget: fileByteBudget, label: "usage_refresh")
    }

    static func makeIndexingGovernor() -> ParserResourceGovernor {
        makeGovernor(fileByteBudget: indexingFileByteBudget, label: "conversation_indexing")
    }

    private static func makeGovernor(fileByteBudget: Int64, label: String) -> ParserResourceGovernor {
        ParserResourceGovernor(
            limits: ParserResourceLimits(
                fileByteBudget: fileByteBudget,
                memoryCeilingBytes: memoryCeilingBytes,
                memorySoftLimitBytes: memorySoftLimitBytes
            ),
            onSoftLimit: { footprint in
                AppLogger.parser.notice(
                    "parse_pass_memory_soft_limit",
                    metadata: [
                        "pass": label,
                        "footprint_mb": String(footprint / (1024 * 1024))
                    ]
                )
            }
        )
    }
}

enum ProjectionWorkerPolicy {
    /// Process indexing incrementally to keep UI work responsive. Normal
    /// refreshes stay small; once the queue crosses the stale-insight threshold,
    /// use a wider sweep so rebuild-sized queues drain during the same session.
    static let maxJobsPerPass = 4
    static let catchUpMaxJobsPerPass = ProjectionPipelineRuntimeTuning.defaultSweepMaxJobs * 4
    /// Brief pause between catch-up passes. `runSweep` yields internally while
    /// processing leased jobs, so backlog mode only needs a short handoff delay
    /// before claiming the next batch.
    static let backlogDelayNanoseconds: UInt64 = 20_000_000
    /// Hard cap on automatic consecutive backlog passes. New manual/periodic
    /// refreshes can request another pass, but one request can still drain a
    /// rebuild-sized local queue instead of leaving stale insights for days.
    static let maxContinuousBacklogPasses = 128
    /// Coalesce rapid-fire queue requests.
    static let coalesceDelayNanoseconds: UInt64 = 750_000_000
    /// Avoid rebuilding workflow insights on every tiny pass.
    static let insightRefreshCooldown: TimeInterval = 10
    /// Trim redundant queued conversation jobs when backlog explodes.
    static let backlogCompactionThreshold = 400

    /// Grace horizon before terminal (`completed`/`canceled`) projection jobs are reaped.
    /// The work queue never re-reads terminal rows, so they are pure dead weight that
    /// bloats the table and its indexes forever (the audit measured 99.9% dead rows).
    /// We keep one day so recently-finished rows stay inspectable for idempotency/debugging,
    /// then delete them on the next refresh tick.
    /// Settings can later expose this as a user-tunable retention window.
    static let terminalJobRetention: TimeInterval = 24 * 60 * 60

    static func shouldContinueBacklogProcessing(afterCompletedPasses completedPasses: Int) -> Bool {
        completedPasses < maxContinuousBacklogPasses
    }
}

enum AutoSummaryPolicy {
    /// Keep automatic summaries lightweight so background refreshes do not
    /// churn through entire historical backlogs or oversized prompts.
    static let maxPromptChars = 18_000
    static let maxOutputTokens = 220
    static let maxBatchSize = 8
    static let maxFirstLoadBatchSize = 16
    static let maxConcurrency = 2
    /// Pause summary churn while projection queue is already overloaded.
    static let pauseWhenProjectionQueueExceeds = 300
}
