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

    func test_rollupSnapshot_reportsUnavailable_whenNoInputsExist() throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages([])

        let snapshot = WorkflowInsightRollupService(dataStore: store).snapshot(refreshIfStale: false)

        XCTAssertEqual(snapshot.freshness, .unavailable)
        XCTAssertTrue(snapshot.insights.isEmpty)
    }

    private func makeRollupInMemoryStore() throws -> DataStoreCoordinator {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStoreCoordinator(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
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

