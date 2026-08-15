import Foundation

// MARK: - Usage Memory Extraction Policy (PR6 Stage 1)
//
// Hard rails for the sleep-time Stage-1 batch-extraction loop, sibling of
// `MemoryExtractionPolicy` (the chat lane's rails). A value type (not an enum of
// statics) because the batch bounds are policy-tunable knobs the
// self-improvement loop may adjust later; the compiled-in `.default` mirrors
// the Stage-1 plan.
struct UsageMemoryExtractionPolicy: Equatable, Sendable {
    /// Minimum pending candidates (per source kind) before a fresh batch forms.
    /// Below this the spool keeps accumulating — unless the stale rule fires.
    var minBatch: Int
    /// Ceiling on candidates per batch job (top-salience first).
    var maxBatch: Int
    /// Upper bound on prompt characters per batch. Overflow drops the
    /// LOWEST-salience candidates (they wait for the next batch).
    var maxPromptChars: Int
    /// Upper bound on model output tokens per batch call.
    var maxOutputTokens: Int
    /// Ceiling on batch jobs enqueued per cadence tick (one per source kind,
    /// and there are exactly two usage kinds today).
    var maxJobsPerTick: Int
    /// Per-job wall clock for the extraction round-trip (local or cloud),
    /// strictly below the 15-min job lease.
    var perJobWallClock: TimeInterval
    /// Pending candidates older than this batch even below `minBatch`, so a
    /// trickle of candidates is never stranded in the spool.
    var staleBatchAge: TimeInterval

    static let `default` = UsageMemoryExtractionPolicy(
        minBatch: 10,
        maxBatch: 15,
        maxPromptChars: 12_000,
        maxOutputTokens: 512,
        maxJobsPerTick: 2,
        perJobWallClock: 60,
        staleBatchAge: 48 * 3600
    )
}
