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

    // MARK: - Finding 148: projection_jobs reaping

    func test_reapTerminalProjectionJobs_removesAgedTerminalRows() throws {
        let store = try makeInMemoryDataStore()
        let now = Date(timeIntervalSince1970: 1_742_200_000)
        let old = now.addingTimeInterval(-72 * 60 * 60) // 3 days ago
        let cutoff = now.addingTimeInterval(-24 * 60 * 60) // 1 day ago

        // Two aged terminal rows that should be reaped.
        try store.enqueueProjectionJob(
            makeJob(id: "completed-old", status: .completed, updatedAt: old, completedAt: old)
        )
        try store.enqueueProjectionJob(
            makeJob(id: "canceled-old", status: .canceled, updatedAt: old)
        )
        // A fresh completed row (inside the grace horizon) — must survive.
        try store.enqueueProjectionJob(
            makeJob(id: "completed-fresh", status: .completed, updatedAt: now, completedAt: now)
        )
        // A queued row (still live work) — must survive regardless of age.
        try store.enqueueProjectionJob(
            makeJob(id: "queued-old", status: .queued, updatedAt: old)
        )

        XCTAssertEqual(try store.countProjectionJobs(), 4)

        let reaped = try store.reapTerminalProjectionJobs(olderThan: cutoff, now: now)

        XCTAssertEqual(reaped, 2, "Both aged terminal rows should be deleted.")
        XCTAssertEqual(try store.countProjectionJobs(), 2)
        XCTAssertEqual(try store.countProjectionJobs(statuses: [.completed]), 1)
        XCTAssertEqual(try store.countProjectionJobs(statuses: [.queued]), 1)

        let survivors = try store.fetchProjectionJobs(
            statuses: ProjectionJobStatus.allCases,
            limit: 100
        ).map(\.id).sorted()
        XCTAssertEqual(survivors, ["completed-fresh", "queued-old"])
    }

    func test_reapTerminalProjectionJobs_keepsRunningAndFailedRows() throws {
        let store = try makeInMemoryDataStore()
        let now = Date(timeIntervalSince1970: 1_742_300_000)
        let old = now.addingTimeInterval(-100 * 60 * 60)
        let cutoff = now

        try store.enqueueProjectionJob(makeJob(id: "running", status: .running, updatedAt: old))
        try store.enqueueProjectionJob(makeJob(id: "failed", status: .failed, updatedAt: old))
        try store.enqueueProjectionJob(makeJob(id: "leased", status: .leased, updatedAt: old))

        let reaped = try store.reapTerminalProjectionJobs(olderThan: cutoff, now: now)

        XCTAssertEqual(reaped, 0, "Non-terminal rows must never be reaped.")
        XCTAssertEqual(try store.countProjectionJobs(), 3)
    }

    // MARK: - Finding 186: retention purge stub replacement

    func test_runRetentionPurgeIfNeeded_reapsTerminalProjectionJobs() async throws {
        let store = try makeInMemoryDataStore()
        let now = Date()
        // Aged well past the built-in terminal-job retention horizon.
        let stale = now.addingTimeInterval(-(ProjectionWorkerPolicy.terminalJobRetention + 60 * 60))

        try store.enqueueProjectionJob(
            makeJob(id: "stale-completed", status: .completed, updatedAt: stale, completedAt: stale)
        )
        try store.enqueueProjectionJob(
            makeJob(id: "fresh-completed", status: .completed, updatedAt: now, completedAt: now)
        )

        XCTAssertEqual(try store.countProjectionJobs(), 2)

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

        XCTAssertEqual(
            try store.countProjectionJobs(),
            1,
            "Retention purge should reap the stale completed job and keep the fresh one."
        )
        let survivors = try store.fetchProjectionJobs(
            statuses: ProjectionJobStatus.allCases,
            limit: 10
        ).map(\.id)
        XCTAssertEqual(survivors, ["fresh-completed"])
    }
}
