import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// Data-lifecycle reaping for the projection work queue (WP2-DATALIFECYCLE).
///
/// The audit found `projection_jobs` was 99.9% dead rows because terminal
/// (`completed`/`canceled`) jobs were never reaped and the retention purge was a
/// no-op stub. These tests assert rows are actually removed.
@MainActor
final class ProjectionStoreLifecycleTests: XCTestCase {
    private func makeInMemoryDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeJob(
        id: String,
        status: ProjectionJobStatus,
        updatedAt: Date,
        completedAt: Date? = nil
    ) -> ProjectionJobRecord {
        ProjectionJobRecord(
            id: id,
            jobType: .reproject,
            sourceKind: .conversation,
            sourceID: "conv-\(id)",
            sourceVersionID: "v-\(id)",
            status: status,
            priority: 5,
            attempts: 0,
            maxAttempts: 5,
            scheduledAt: updatedAt,
            availableAt: updatedAt,
            completedAt: completedAt,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    private func makeOrchestrator(for store: DataStore) -> RefreshOrchestrator {
        RefreshOrchestrator(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            quotaService: ProviderQuotaService(
                appPaths: OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                homeDirectoryURL: FileManager.default.temporaryDirectory,
                refreshProviders: []
            )
        )
    }

    /// Enqueues `count` distinct queued conversation projection jobs that all share the
    /// same `(sourceID, jobType)`, so `compactConversationProjectionBacklog` keeps exactly
    /// one survivor and drops the rest.
    private func seedRedundantQueuedBacklog(
        in store: DataStore,
        count: Int,
        sourceID: String = "shared-conv",
        at instant: Date = Date(timeIntervalSince1970: 1_742_400_000)
    ) async throws {
        for index in 0..<count {
            try await store.enqueueProjectionJob(
                ProjectionJobRecord(
                    id: "backlog-\(index)",
                    jobType: .reproject,
                    sourceKind: .conversation,
                    sourceID: sourceID,
                    sourceVersionID: "v-\(index)",
                    status: .queued,
                    priority: 5,
                    attempts: 0,
                    maxAttempts: 5,
                    scheduledAt: instant,
                    availableAt: instant,
                    createdAt: instant,
                    updatedAt: instant
                )
            )
        }
    }

    // MARK: - L182: backlog compaction is observable, not swallowed

    /// Happy path: a runaway redundant backlog above the compaction threshold is drained
    /// during the post-persistence phase, and the returned `pendingProjectionJobs` reflects
    /// the post-compaction depth.
    func test_runPostPersistencePhase_compactsRunawayBacklog() async throws {
        let store = try makeInMemoryDataStore()
        let seeded = ProjectionWorkerPolicy.backlogCompactionThreshold + 5
        try await seedRedundantBacklogAndAssert(store: store, seeded: seeded)

        let result = await makeOrchestrator(for: store).runPostPersistencePhase(
            refreshStartedAt: Date(),
            allUsages: [],
            indexedConversationChanges: 0,
            parsePhaseDuration: 0,
            persistencePhaseDuration: 0
        )

        // Only the single newest entry per (sourceID, jobType) survives.
        let compactedJobCount = try await store.countProjectionJobs()
        XCTAssertEqual(compactedJobCount, 1)
        XCTAssertEqual(
            result.pendingProjectionJobs,
            1,
            "Reported pending depth must reflect the post-compaction count."
        )
    }

    /// Fail path (the L182 fix): a compaction write that throws must NOT crash the refresh
    /// nor be silently swallowed into a fabricated "drained" state. The backlog is left
    /// intact, the reported depth stays at the pre-compaction count, and the failure is
    /// surfaced via the logger (observable) rather than discarded.
    func test_runPostPersistencePhase_survivesCompactionWriteFailure() async throws {
        let store = try makeInMemoryDataStore()
        let seeded = ProjectionWorkerPolicy.backlogCompactionThreshold + 5
        try await seedRedundantBacklogAndAssert(store: store, seeded: seeded)

        // Force the compaction DELETE to throw while reads/COUNT keep working, so the
        // count gate at L180 still trips and we exercise the compaction branch itself.
        try await installDeleteTrap(on: store)

        let result = await makeOrchestrator(for: store).runPostPersistencePhase(
            refreshStartedAt: Date(),
            allUsages: [],
            indexedConversationChanges: 0,
            parsePhaseDuration: 0,
            persistencePhaseDuration: 0
        )

        // Graceful degradation: no crash, nothing deleted, and the runaway backlog is
        // still reported at full depth instead of a fabricated "compacted" value.
        let postFailureJobCount = try await store.countProjectionJobs()
        XCTAssertEqual(
            postFailureJobCount,
            seeded,
            "A failed compaction write must not remove any rows."
        )
        XCTAssertEqual(
            result.pendingProjectionJobs,
            seeded,
            "Reported pending depth must remain the pre-compaction count on failure."
        )
    }

    private func seedRedundantBacklogAndAssert(store: DataStore, seeded: Int) async throws {
        try await seedRedundantQueuedBacklog(in: store, count: seeded)
        let jobCount = try await store.countProjectionJobs()
        XCTAssertEqual(jobCount, seeded)
        XCTAssertGreaterThanOrEqual(seeded, ProjectionWorkerPolicy.backlogCompactionThreshold)
    }

    /// Installs a BEFORE DELETE trigger that aborts any delete on `projection_jobs`,
    /// leaving SELECT/COUNT fully functional.
    private func installDeleteTrap(on store: DataStore) async throws {
        try await store.actor.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER projection_jobs_delete_trap
                BEFORE DELETE ON projection_jobs
                BEGIN
                    SELECT RAISE(ABORT, 'projection_jobs delete trapped for test');
                END
                """)
        }
    }

    // MARK: - Finding 148: projection_jobs reaping

    func test_reapTerminalProjectionJobs_removesAgedTerminalRows() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date(timeIntervalSince1970: 1_742_200_000)
        let old = now.addingTimeInterval(-72 * 60 * 60) // 3 days ago
        let cutoff = now.addingTimeInterval(-24 * 60 * 60) // 1 day ago

        // Two aged terminal rows that should be reaped.
        try await store.enqueueProjectionJob(
            makeJob(id: "completed-old", status: .completed, updatedAt: old, completedAt: old)
        )
        try await store.enqueueProjectionJob(
            makeJob(id: "canceled-old", status: .canceled, updatedAt: old)
        )
        // A fresh completed row (inside the grace horizon) — must survive.
        try await store.enqueueProjectionJob(
            makeJob(id: "completed-fresh", status: .completed, updatedAt: now, completedAt: now)
        )
        // A queued row (still live work) — must survive regardless of age.
        try await store.enqueueProjectionJob(
            makeJob(id: "queued-old", status: .queued, updatedAt: old)
        )

        let initialJobCount = try await store.countProjectionJobs()
        XCTAssertEqual(initialJobCount, 4)

        let reaped = try await store.reapTerminalProjectionJobs(olderThan: cutoff, now: now)

        XCTAssertEqual(reaped, 2, "Both aged terminal rows should be deleted.")
        let remainingJobCount = try await store.countProjectionJobs()
        let completedJobCount = try await store.countProjectionJobs(statuses: [.completed])
        let queuedJobCount = try await store.countProjectionJobs(statuses: [.queued])
        XCTAssertEqual(remainingJobCount, 2)
        XCTAssertEqual(completedJobCount, 1)
        XCTAssertEqual(queuedJobCount, 1)

        let survivors = try await store.fetchProjectionJobs(
            statuses: ProjectionJobStatus.allCases,
            limit: 100
        ).map(\.id).sorted()
        XCTAssertEqual(survivors, ["completed-fresh", "queued-old"])
    }

    func test_reapTerminalProjectionJobs_keepsRunningAndFailedRows() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date(timeIntervalSince1970: 1_742_300_000)
        let old = now.addingTimeInterval(-100 * 60 * 60)
        let cutoff = now

        try await store.enqueueProjectionJob(makeJob(id: "running", status: .running, updatedAt: old))
        try await store.enqueueProjectionJob(makeJob(id: "failed", status: .failed, updatedAt: old))
        try await store.enqueueProjectionJob(makeJob(id: "leased", status: .leased, updatedAt: old))

        let reaped = try await store.reapTerminalProjectionJobs(olderThan: cutoff, now: now)

        XCTAssertEqual(reaped, 0, "Non-terminal rows must never be reaped.")
        let remainingJobCount = try await store.countProjectionJobs()
        XCTAssertEqual(remainingJobCount, 3)
    }

    // MARK: - Finding 186: retention purge stub replacement

    func test_runRetentionPurgeIfNeeded_reapsTerminalProjectionJobs() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date()
        // Aged well past the built-in terminal-job retention horizon.
        let stale = now.addingTimeInterval(-(ProjectionWorkerPolicy.terminalJobRetention + 60 * 60))

        try await store.enqueueProjectionJob(
            makeJob(id: "stale-completed", status: .completed, updatedAt: stale, completedAt: stale)
        )
        try await store.enqueueProjectionJob(
            makeJob(id: "fresh-completed", status: .completed, updatedAt: now, completedAt: now)
        )

        let initialJobCount = try await store.countProjectionJobs()
        XCTAssertEqual(initialJobCount, 2)

        let orchestrator = RefreshOrchestrator(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            quotaService: ProviderQuotaService(
                appPaths: OpenBurnBarAppPaths(applicationSupportRoot: FileManager.default.temporaryDirectory),
                homeDirectoryURL: FileManager.default.temporaryDirectory,
                refreshProviders: []
            )
        )

        await orchestrator.runRetentionPurgeIfNeeded()

        let remainingJobCount = try await store.countProjectionJobs()
        XCTAssertEqual(
            remainingJobCount,
            1,
            "Retention purge should reap the stale completed job and keep the fresh one."
        )
        let survivors = try await store.fetchProjectionJobs(
            statuses: ProjectionJobStatus.allCases,
            limit: 10
        ).map(\.id)
        XCTAssertEqual(survivors, ["fresh-completed"])
    }
}
