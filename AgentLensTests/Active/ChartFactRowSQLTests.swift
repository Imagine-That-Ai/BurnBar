import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class ChartFactRowSQLTests: XCTestCase {
    func test_factRows_matchTokenUsageSnapshot_last7DaysCoveringScan() async throws {
        let (usageStore, now) = try await seededStore()
        let recent = ChartsDataService.recentRange(now: now)
        let requested = try XCTUnwrap(TimeRange.last7Days.dateRange(now: now))

        let usages = try await usageStore.fetchUsage(in: recent, limit: Int.max)
        let facts = try await usageStore.fetchChartFactRows(in: recent)
        XCTAssertEqual(facts.count, usages.count)
        XCTAssertEqual(facts.map(\.sessionId), usages.map(\.sessionId))

        let usageWindows = ChartsDataService.deriveWindows(
            coveringRows: usages,
            requestedRange: requested,
            recentRange: recent
        )
        let factWindows = ChartsDataService.deriveWindows(
            coveringRows: facts,
            requestedRange: requested,
            recentRange: recent
        )
        XCTAssertEqual(factWindows.selected.map(\.sessionId), usageWindows.selected.map(\.sessionId))
        XCTAssertEqual(factWindows.recent.map(\.sessionId), usageWindows.recent.map(\.sessionId))

        let fromUsage = ChartsSnapshot.build(
            rows: usageWindows.selected,
            recentRows: usageWindows.recent,
            timeRange: .last7Days,
            usagesVersion: 3,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: factWindows.selected,
            recentRows: factWindows.recent,
            timeRange: .last7Days,
            usagesVersion: 3,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
    }

    func test_factRows_matchTokenUsageSnapshot_allTimeWithoutDecodeUsage() async throws {
        let (usageStore, now) = try await seededStore()
        let recent = ChartsDataService.recentRange(now: now)

        let usages = try await usageStore.fetchAllUsage()
        let facts = try await usageStore.fetchChartFactRows(in: nil)
        XCTAssertEqual(facts.count, usages.count)

        let usageWindows = ChartsDataService.deriveWindows(
            coveringRows: usages,
            requestedRange: nil,
            recentRange: recent
        )
        let factWindows = ChartsDataService.deriveWindows(
            coveringRows: facts,
            requestedRange: nil,
            recentRange: recent
        )

        let fromUsage = ChartsSnapshot.build(
            rows: usageWindows.selected,
            recentRows: usageWindows.recent,
            timeRange: .allTime,
            usagesVersion: 0,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: factWindows.selected,
            recentRows: factWindows.recent,
            timeRange: .allTime,
            usagesVersion: 0,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.cacheReadTokens, fromUsage.cacheReadTokens)
        XCTAssertEqual(fromFacts.exactShare, fromUsage.exactShare, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.remoteCost, fromUsage.remoteCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.apiCost, fromUsage.apiCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.subscriptionCost, fromUsage.subscriptionCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.unknownBillingCost, fromUsage.unknownBillingCost, accuracy: 1e-12)
    }

    func test_factRows_clampsCrossingSessionToRangeLowerBound() async throws {
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

        let today = try XCTUnwrap(TimeRange.today.dateRange(now: now))
        let usages = try await usageStore.fetchUsage(in: today, limit: Int.max)
        let facts = try await usageStore.fetchChartFactRows(in: today)
        XCTAssertEqual(facts.map(\.sessionId), ["crossing"])

        let fromUsage = ChartsSnapshot.build(
            rows: usages,
            recentRows: usages,
            timeRange: .today,
            usagesVersion: 0,
            now: now,
            calendar: calendar
        )
        let fromFacts = ChartsSnapshot.build(
            rows: facts,
            recentRows: facts,
            timeRange: .today,
            usagesVersion: 0,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.burnSeries.reduce(0) { $0 + $1.value }, 2.0, accuracy: 1e-9)
    }

    func test_factRows_stampedApiBillingKind_doesNotReclassifyToSubscription() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        // Claude Code is subscription-first. A stamped `.api` row must stay
        // API after the fact-row scan or Spend Lens would silently rebucket.
        let stamped = TokenUsage(
            provider: .claudeCode,
            sessionId: "stamped-api",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 4.0,
            startTime: now.addingTimeInterval(-3_600),
            endTime: now.addingTimeInterval(-1_800),
            billingKind: .api
        )
        let unclassified = TokenUsage(
            provider: .openCode,
            sessionId: "unclassified",
            projectName: "",
            model: "mystery-model",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 7.5,
            startTime: now.addingTimeInterval(-2 * 3_600),
            endTime: now.addingTimeInterval(-1.5 * 3_600),
            provenanceConfidence: .lowConfidenceEstimate
        )
        try await usageStore.insert([stamped, unclassified])

        let usages = try await usageStore.fetchAllUsage()
        let facts = try await usageStore.fetchChartFactRows(in: nil)
        XCTAssertEqual(facts.first { $0.sessionId == "stamped-api" }?.billingKind, .api)

        let fromUsage = ChartsSnapshot.build(
            rows: usages,
            recentRows: usages,
            timeRange: .last7Days,
            usagesVersion: 1,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: facts,
            recentRows: facts,
            timeRange: .last7Days,
            usagesVersion: 1,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.apiCost, 4.0, accuracy: 1e-9)
        XCTAssertEqual(fromFacts.unknownBillingCost, 7.5, accuracy: 1e-9)
        XCTAssertEqual(
            fromFacts.apiCost + fromFacts.subscriptionCost + fromFacts.unknownBillingCost,
            fromFacts.totalCost,
            accuracy: 0.0001
        )
    }

    private func seededStore() async throws -> (UsageStore, Date) {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        var rows = ChartsSnapshotFixtures.sampleRows(now: now)
        rows.append(
            TokenUsage(
                provider: .openCode,
                sessionId: "session-unclassified",
                projectName: "",
                model: "mystery-model",
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 7.5,
                startTime: now.addingTimeInterval(-3 * 3_600),
                endTime: now.addingTimeInterval(-2.5 * 3_600),
                provenanceConfidence: .lowConfidenceEstimate
            )
        )
        try await usageStore.insert(rows)
        return (usageStore, now)
    }
}
