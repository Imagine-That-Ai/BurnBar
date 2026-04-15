import Foundation

enum SummaryEndpointCooldownPolicy {
    static let localEndpointFailureCooldown: TimeInterval = 5 * 60
}

enum ProjectionWorkerPolicy {
    /// Process indexing incrementally to keep UI work responsive.
    static let maxJobsPerPass = 8
    static let catchUpMaxJobsPerPass = 64
    /// Small delay between backlog passes to reduce CPU pressure.
    static let backlogDelayNanoseconds: UInt64 = 100_000_000
    /// Coalesce rapid-fire queue requests.
    static let coalesceDelayNanoseconds: UInt64 = 750_000_000
    /// Avoid rebuilding workflow insights on every tiny pass.
    static let insightRefreshCooldown: TimeInterval = 10
    /// Trim redundant queued conversation jobs when backlog explodes.
    static let backlogCompactionThreshold = 400
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
