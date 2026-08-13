import Foundation
import OpenBurnBarCore
import OpenBurnBarLogParsers

enum SummaryEndpointCooldownPolicy {
    static let localEndpointFailureCooldown: TimeInterval = 5 * 60
}

/// Serializes live, catch-up, and single-provider persists so two lanes
/// cannot delete/insert the same session ids at once.
///
/// This is a real async mutex, not a Swift actor critical section.
/// `await` inside the body would otherwise re-enter the actor and let a
/// second persist start mid-transaction (SE-0306).
actor UsageIngestPersistGate {
    static let shared = UsageIngestPersistGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await body()
        release()
        return result
    }

    private func acquire() async {
        if isHeld {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } else {
            isHeld = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Two-lane usage ingest, Filebeat/Vector style.
///
/// Live ticks only read files touched inside `liveWindow` and run providers
/// in parallel. Historical unread bytes drain on an isolated catch-up lane
/// that cannot hold `isRefreshing` or steal the next live tick. Measurement
/// stays O(recent changes), not O(corpus).
enum UsageIngestionLane: Sendable, Equatable {
    /// Recent session files only. The UI waits for this lane.
    case live
    /// Historical unread bytes. Never blocks a live tick.
    case catchUp
}

enum UsageIngestionPolicy {
    /// Sessions idle longer than this are catch-up, not live measurement.
    static let liveWindow: TimeInterval = 12 * 60 * 60
    static let liveConcurrency = 8
    static let catchUpConcurrency = 3
    /// Tight live budget: today's tails, not a 3GB Claude backlog.
    static let liveFileByteBudget: Int64 = 16 * 1024 * 1024
    static let catchUpFileByteBudget: Int64 = 48 * 1024 * 1024
    /// After each live tick, drain this many catch-up slices then yield.
    static let maxCatchUpSlicesPerKick = 6
    static let catchUpSliceDelayNanoseconds: UInt64 = 25_000_000

    static func liveCutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(-liveWindow)
    }

    static func concurrency(for lane: UsageIngestionLane) -> Int {
        switch lane {
        case .live: return liveConcurrency
        case .catchUp: return catchUpConcurrency
        }
    }

    static func fileByteBudget(for lane: UsageIngestionLane) -> Int64 {
        switch lane {
        case .live: return liveFileByteBudget
        case .catchUp: return catchUpFileByteBudget
        }
    }

    static func isLiveUsage(_ usage: TokenUsage, cutoff: Date) -> Bool {
        usage.endTime >= cutoff || usage.startTime >= cutoff
    }

    /// Live ticks must not apply a parser invalidation unless this persist
    /// set also carries a replacement (exact id or `id#…` day bucket).
    /// Otherwise Codex can delete a lifetime row whose historical day
    /// replacements were filtered out of the live window.
    static func deletesSafeForLivePublish(
        _ deleteIDs: Set<String>,
        publishedSessionIDs: [String]
    ) -> Set<String> {
        guard !deleteIDs.isEmpty else { return [] }
        let published = Set(publishedSessionIDs)
        return Set(deleteIDs.filter { id in
            if published.contains(id) { return true }
            let prefix = id + "#"
            return publishedSessionIDs.contains { $0.hasPrefix(prefix) }
        })
    }
}

/// Resource bounds for usage-refresh and conversation-indexing parse passes.
///
/// The file-byte budget is **per provider**, not shared across the pass.
/// A shared 256MB budget plus alphabetical parse order lets one huge
/// Claude/Codex tail consume every tick, so Factory/Grok/etc. never ingest
/// today's burn. Memory ceilings stay process-wide.
enum ParserResourcePolicy {
    /// Bytes of new (uncached) log content one provider may read during a
    /// usage-refresh tick. Later providers keep their own slice even when
    /// Claude or Codex still has a multi-GB unread tail.
    static let refreshFileByteBudget: Int64 = 64 * 1024 * 1024
    /// Lower bound so a 30-provider catalog still makes progress on each
    /// parser when we derive a fair share from a global cap.
    static let refreshFileByteBudgetFloor: Int64 = 16 * 1024 * 1024
    /// Historical whole-pass cap kept as the derivation numerator and as
    /// the single-provider refresh budget.
    static let refreshPassFileByteBudget: Int64 = 256 * 1024 * 1024
    /// Bytes of new content one provider may read during conversation
    /// indexing — bodies re-read whole changed files, so this pass gets
    /// more headroom than usage refresh.
    static let indexingFileByteBudget: Int64 = 128 * 1024 * 1024
    /// Process physical footprint at which any governed pass hard-aborts.
    /// Generous versus the app's normal few-hundred-MB footprint, but far
    /// below the level that pushes a 64GB machine into swap death.
    static let memoryCeilingBytes: Int64 = 4 * 1024 * 1024 * 1024
    /// Footprint that logs a warning once per pass.
    static let memorySoftLimitBytes: Int64 = 1536 * 1024 * 1024

    /// Fair per-provider usage-refresh budget. One huge provider can still
    /// take `refreshFileByteBudget`, but it cannot zero out everyone else.
    static func perProviderRefreshFileByteBudget(providerCount: Int) -> Int64 {
        let count = Int64(max(providerCount, 1))
        if count == 1 {
            return refreshPassFileByteBudget
        }
        let fairShare = refreshPassFileByteBudget / count
        return min(refreshFileByteBudget, max(refreshFileByteBudgetFloor, fairShare))
    }

    static func makeRefreshGovernor(providerCount: Int = 1) -> ParserResourceGovernor {
        makeGovernor(
            fileByteBudget: perProviderRefreshFileByteBudget(providerCount: providerCount),
            label: "usage_refresh"
        )
    }

    static func makeIndexingGovernor() -> ParserResourceGovernor {
        makeGovernor(fileByteBudget: indexingFileByteBudget, label: "conversation_indexing")
    }

    static func makeGovernor(fileByteBudget: Int64, label: String) -> ParserResourceGovernor {
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
