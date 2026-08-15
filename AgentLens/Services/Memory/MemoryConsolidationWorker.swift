import Foundation
import OpenBurnBarCore

// MARK: - Stage-3 zero-LLM consolidation worker (PR8)
//
// One sleep-time consolidation tick over the shared `ControlPlaneStore`:
// salience decay recompute → decay/cap eviction → candidate TTL expiry →
// orphan repair/GC, in that order (recompute first so eviction judges FRESH
// salience; the orphan purge last so it also sweeps anything the earlier
// passes left behind). Every pass is deterministic SQL + Swift math — the
// Stage-3 LLM passes (promote / self-heal) are PR9 and are absent by design.
//
// Dormancy: the injected `isEnabled` gate (the same usage-extraction gate box
// PR6's Stage-1 ticker reads) is checked FIRST, so a disabled feature performs
// ZERO database work — proven by `UsageMemoryConsolidationTests`.
actor MemoryConsolidationWorker {
    /// What one tick did — per-pass counts for logs/tests.
    struct TickReport: Equatable, Sendable {
        /// `memory_salience` rows re-scored by the decay pass.
        var recomputed = 0
        /// Usage memories evicted (decayed + over-cap; approved rows never).
        var evicted = 0
        /// Stage-0 spool candidates deleted by the TTL sweep.
        var expired = 0
        /// Orphan sidecar rows removed by the repair/GC pass.
        var purged = 0
    }

    private let store: ControlPlaneStore
    private let isEnabled: @Sendable () -> Bool

    init(store: ControlPlaneStore, isEnabled: @escaping @Sendable () -> Bool) {
        self.store = store
        self.isEnabled = isEnabled
    }

    /// Run one consolidation tick. Pass failures are logged and swallowed
    /// independently (durable state means the next tick simply retries), so a
    /// single bad row can never wedge the whole cadence; the report carries
    /// the counts of what DID land.
    @discardableResult
    func consolidationTick(
        policy: UsageMemoryCurationPolicy = .defaults,
        now: Date = Date()
    ) async -> TickReport {
        var report = TickReport()
        guard isEnabled() else { return report }
        do {
            report.recomputed = try await store.recomputeMemorySalience(policy: policy, now: now)
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_recompute_failed", error: error)
        }
        do {
            report.evicted = try await store.evictDecayedUsageMemories(policy: policy, now: now).total
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_evict_failed", error: error)
        }
        do {
            report.expired = try await store.expireUsageCandidates(
                olderThan: policy.caps.candidateTTLDays,
                now: now
            )
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_ttl_expiry_failed", error: error)
        }
        do {
            report.purged = try await store.purgeOrphanConsolidationRows()
        } catch {
            AppLogger.dataStore.silentFailure("memory_consolidation_orphan_purge_failed", error: error)
        }
        return report
    }
}
