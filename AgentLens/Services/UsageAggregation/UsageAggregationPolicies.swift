import Foundation

enum SummaryEndpointCooldownPolicy {
    static let localEndpointFailureCooldown: TimeInterval = 5 * 60
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
