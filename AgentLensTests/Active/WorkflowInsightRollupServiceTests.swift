import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class WorkflowInsightRollupServiceTests: XCTestCase {
    func test_rollupSnapshot_materializesFreshAndPersistsHealth() throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages(makeRollupFixtureUsages())

        let snapshot = WorkflowInsightRollupService(dataStore: store).snapshot(refreshIfStale: true)

        XCTAssertEqual(snapshot.freshness, .fresh)
        XCTAssertFalse(snapshot.insights.isEmpty)
        XCTAssertNotNil(snapshot.computedAt)
        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .insightRollups })
        XCTAssertEqual(health?.status, .healthy)
        XCTAssertNil(health?.errorCode)
    }

    func test_rollupSnapshot_reportsStale_whenNewUsageArrivesAfterMaterialization() throws {
        let store = try makeRollupInMemoryStore()
        let fixture = makeRollupFixtureUsages()
        store.replaceUsages(fixture)

        let now = Date()
        let initialService = WorkflowInsightRollupService(dataStore: store, nowProvider: { now })
        _ = initialService.snapshot(refreshIfStale: true)

        let futureUsage = TokenUsage(
            provider: .factory,
            sessionId: "rollup-future",
            projectName: "OpenBurnBar",
            model: "future-model",
            inputTokens: 12,
            outputTokens: 8,
            costUSD: 0.30,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180)
        )
        store.replaceUsages(fixture + [futureUsage])

        let staleSnapshot = initialService.snapshot(refreshIfStale: false)
        XCTAssertEqual(staleSnapshot.freshness, .stale)

        let refreshed = WorkflowInsightRollupService(
            dataStore: store,
            nowProvider: { now.addingTimeInterval(900) }
        ).snapshot(refreshIfStale: true)
        XCTAssertEqual(refreshed.freshness, .fresh)
    }

    func test_rollupSnapshot_reportsRebuilding_whenRebuildJobsArePending() throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages(makeRollupFixtureUsages())
        let service = WorkflowInsightRollupService(dataStore: store)
        _ = service.snapshot(refreshIfStale: true)

        let now = Date()
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "rollup-rebuild-pending",
                jobType: .rebuild,
                status: .queued,
                priority: 1,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )

        let snapshot = service.snapshot(refreshIfStale: false)
        XCTAssertEqual(snapshot.freshness, .rebuilding)
        XCTAssertFalse(snapshot.insights.isEmpty)
    }

    func test_rollupSnapshotAsync_materializesFreshAndPersistsHealth() async throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages(makeRollupFixtureUsages())

        let snapshot = await WorkflowInsightRollupService(dataStore: store).snapshotAsync(refreshIfStale: true)

        XCTAssertEqual(snapshot.freshness, .fresh)
        XCTAssertFalse(snapshot.insights.isEmpty)
        XCTAssertNotNil(snapshot.computedAt)
        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .insightRollups })
        XCTAssertEqual(health?.status, .healthy)
        XCTAssertNil(health?.errorCode)
    }

    func test_rollupSnapshot_skipsHealthWrite_whenNothingChanged() throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages(makeRollupFixtureUsages())

        let t0 = Date()
        _ = WorkflowInsightRollupService(dataStore: store, nowProvider: { t0 }).snapshot(refreshIfStale: true)
        let firstRow = try XCTUnwrap(
            store.fetchRetrievalHealth().first(where: { $0.subsystem == .insightRollups })
        )

        let second = WorkflowInsightRollupService(
            dataStore: store,
            nowProvider: { t0.addingTimeInterval(60) }
        ).snapshot(refreshIfStale: true)
        XCTAssertEqual(second.freshness, .fresh)

        let secondRow = try XCTUnwrap(
            store.fetchRetrievalHealth().first(where: { $0.subsystem == .insightRollups })
        )
        XCTAssertEqual(
            secondRow.observedAt,
            firstRow.observedAt,
            "A fresh snapshot must not rewrite an unchanged health row"
        )
        XCTAssertEqual(secondRow.detailsJSON, firstRow.detailsJSON)
        XCTAssertEqual(secondRow.status, .healthy)
    }

    func test_rollupSnapshot_reportsUnavailable_whenNoInputsExist() throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages([])

        let snapshot = WorkflowInsightRollupService(dataStore: store).snapshot(refreshIfStale: false)

        XCTAssertEqual(snapshot.freshness, .unavailable)
        XCTAssertTrue(snapshot.insights.isEmpty)
    }

    func test_rollupSnapshotQueryCount_isIndependentOfUsageVolume() throws {
        let queue = try DatabaseQueue(configuration: .withQueryTracing())
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let tracer = OpenBurnBarQueryTracer.shared
        let fixture = makeRollupFixtureUsages()
        let now = Date()

        // Warm-up materialization absorbs GRDB's one-time schema introspection.
        store.replaceUsages(fixture)
        _ = WorkflowInsightRollupService(dataStore: store, nowProvider: { now }).snapshot(refreshIfStale: true)

        // Baseline: a stale snapshot re-materializes over a small usage set.
        store.replaceUsages(fixture + makeVolumeUsages(count: 4, after: now.addingTimeInterval(60)))
        tracer.resetLog()
        _ = WorkflowInsightRollupService(
            dataStore: store,
            nowProvider: { now.addingTimeInterval(900) }
        ).snapshot(refreshIfStale: true)
        let baseline = tracer.queryCount
        XCTAssertGreaterThan(baseline, 0, "Query tracer recorded nothing — tracing is not installed")

        // 10x the usages: the pipeline reads them from main-actor memory, so
        // the GRDB statement count must not grow with usage volume.
        store.replaceUsages(fixture + makeVolumeUsages(count: 40, after: now.addingTimeInterval(1_000)))
        tracer.resetLog()
        _ = WorkflowInsightRollupService(
            dataStore: store,
            nowProvider: { now.addingTimeInterval(1_800) }
        ).snapshot(refreshIfStale: true)

        XCTAssertEqual(
            tracer.queryCount,
            baseline,
            "Rollup snapshot must run a constant number of queries — growth with usage volume is an N+1 regression"
        )
        tracer.assertMaxQueries(count: 64)
    }

    private func makeRollupInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    /// Usages whose `endTime` lands after `date`, so the previous
    /// materialization reads as stale and the snapshot re-materializes.
    private func makeVolumeUsages(count: Int, after date: Date) -> [TokenUsage] {
        (0..<count).map { index in
            TokenUsage(
                provider: .factory,
                sessionId: "rollup-volume-\(Int(date.timeIntervalSince1970))-\(index)",
                projectName: "OpenBurnBar",
                model: "gpt-5.4-mini",
                inputTokens: 10,
                outputTokens: 5,
                costUSD: 0.10,
                startTime: date.addingTimeInterval(Double(index)),
                endTime: date.addingTimeInterval(Double(index) + 30)
            )
        }
    }

    private func makeRollupFixtureUsages() -> [TokenUsage] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart

        return [
            TokenUsage(
                provider: .factory,
                sessionId: "rollup-yesterday",
                projectName: "OpenBurnBar",
                model: "gpt-5.4-mini",
                inputTokens: 30,
                outputTokens: 20,
                costUSD: 0.90,
                startTime: yesterdayStart.addingTimeInterval(120),
                endTime: yesterdayStart.addingTimeInterval(180)
            ),
            TokenUsage(
                provider: .claudeCode,
                sessionId: "rollup-today",
                projectName: "OpenBurnBar",
                model: "claude-sonnet",
                inputTokens: 24,
                outputTokens: 16,
                costUSD: 0.50,
                startTime: todayStart.addingTimeInterval(120),
                endTime: todayStart.addingTimeInterval(180)
            )
        ]
    }
}

