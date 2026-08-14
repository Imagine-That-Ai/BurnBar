import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class ChartSessionAnalyticsSQLTests: XCTestCase {
    func test_sqlHeatmapOutliersEntropy_matchChartsSnapshotBuild() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        let rows = ChartsSnapshotFixtures.sampleRows(now: now)
        try await usageStore.insert(rows)

        let stored = try await usageStore.fetchAllUsage()
        let snapshot = ChartsSnapshot.build(
            rows: stored,
            recentRows: stored,
            timeRange: .last7Days,
            usagesVersion: 0,
            now: now
        )
        let sql = try await usageStore.fetchChartSessionAnalytics(
            timeRange: .last7Days,
            now: now,
            calendar: .current
        )

        XCTAssertEqual(sql.hourWeekdayCost, snapshot.hourWeekdayCost)
        XCTAssertEqual(sql.outlierSessions, snapshot.outlierSessions)
        XCTAssertEqual(sql.projectEntropy, snapshot.projectEntropy, accuracy: 1e-12)
    }

    func test_sqlHeatmap_clampsCrossingSessionToRangeLowerBound() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        let startOfToday = calendar.startOfDay(for: now)
        let row = TokenUsage(
            provider: .claudeCode,
            sessionId: "crossing",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 2.0,
            startTime: startOfToday.addingTimeInterval(-300),
            endTime: startOfToday.addingTimeInterval(300)
        )
        try await usageStore.insert(row)

        let stored = try await usageStore.fetchAllUsage()
        let snapshot = ChartsSnapshot.build(
            rows: stored,
            recentRows: stored,
            timeRange: .today,
            usagesVersion: 0,
            now: now,
            calendar: calendar
        )
        let sql = try await usageStore.fetchChartSessionAnalytics(
            timeRange: .today,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(sql.hourWeekdayCost, snapshot.hourWeekdayCost)
        XCTAssertEqual(sql.outlierSessions.first?.sessionId, "crossing")
        XCTAssertEqual(sql.outlierSessions.first?.cost ?? 0, 2.0, accuracy: 1e-9)
        XCTAssertEqual(sql.projectEntropy, snapshot.projectEntropy, accuracy: 1e-12)
    }

    func test_sqlAllTime_matchesBuildWithoutMaterializingTokenUsageShape() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        let rows = ChartsSnapshotFixtures.sampleRows(now: now)
        try await usageStore.insert(rows)

        let stored = try await usageStore.fetchAllUsage()
        let snapshot = ChartsSnapshot.build(
            rows: stored,
            recentRows: stored,
            timeRange: .allTime,
            usagesVersion: 0,
            now: now
        )
        let sql = try await usageStore.fetchChartSessionAnalytics(
            timeRange: .allTime,
            now: now,
            calendar: .current
        )

        XCTAssertEqual(sql.hourWeekdayCost, snapshot.hourWeekdayCost)
        XCTAssertEqual(sql.outlierSessions.map(\.sessionId), snapshot.outlierSessions.map(\.sessionId))
        XCTAssertEqual(sql.projectEntropy, snapshot.projectEntropy, accuracy: 1e-12)
    }
}
