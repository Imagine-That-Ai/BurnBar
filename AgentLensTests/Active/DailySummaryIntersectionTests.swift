import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class DailySummaryIntersectionTests: XCTestCase {
    func test_overlappingDayStarts_countsSpanningSessionOnBothDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let yesterday = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_776_268_800)) // 2026-04-14
        let today = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: yesterday))
        let start = yesterday.addingTimeInterval(22 * 3600)
        let end = today.addingTimeInterval(2 * 3600)

        let days = UsageDayIntersection.overlappingDayStarts(
            startTime: start,
            endTime: end,
            calendar: calendar
        )
        XCTAssertEqual(days, [yesterday, today])
    }

    func test_overlappingDayStarts_sameDaySessionCountsOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_776_355_200))
        let start = today.addingTimeInterval(3600)
        let end = today.addingTimeInterval(7200)

        XCTAssertEqual(
            UsageDayIntersection.overlappingDayStarts(startTime: start, endTime: end, calendar: calendar),
            [today]
        )
    }

    func test_fetchDailySummaries_matchesPerDayIntersectionSQL() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))

        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "span",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 20,
            costUSD: 2,
            startTime: yesterday.addingTimeInterval(23 * 3600),
            endTime: today.addingTimeInterval(3600)
        ))
        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .claudeCode,
            sessionId: "today-only",
            model: "sonnet",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 1,
            startTime: today.addingTimeInterval(2 * 3600),
            endTime: today.addingTimeInterval(2 * 3600 + 30)
        ))

        let folded = try await queue.read { db in
            try UsageStore.fetchDailySummaries(db: db, calendar: calendar)
        }
        let perDay = try await queue.read { db in
            try UsageStore.fetchDailySummariesByPerDayIntersection(db: db, calendar: calendar)
        }
        try assertSummariesEqual(folded, perDay, calendar: calendar)

        let byDay = Dictionary(
            uniqueKeysWithValues: folded.map { (calendar.startOfDay(for: $0.date), $0) }
        )
        let yesterdaySummary = try XCTUnwrap(byDay[yesterday])
        let todaySummary = try XCTUnwrap(byDay[today])
        XCTAssertEqual(yesterdaySummary.sessionCount, 1)
        XCTAssertEqual(yesterdaySummary.totalTokens, 120)
        XCTAssertEqual(yesterdaySummary.totalCost, 2, accuracy: 0.0001)
        XCTAssertEqual(todaySummary.sessionCount, 2)
        XCTAssertEqual(todaySummary.totalTokens, 135)
        XCTAssertEqual(todaySummary.totalCost, 3, accuracy: 0.0001)
    }

    func test_inMemoryRebuild_dailySummariesMatchFoldedSQL() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let spanning = ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "span-rebuild",
            model: "gpt-5",
            inputTokens: 40,
            outputTokens: 10,
            costUSD: 4,
            startTime: yesterday.addingTimeInterval(20 * 3600),
            endTime: today.addingTimeInterval(1800)
        )
        try await usageStore.insert(spanning)

        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        let rebuilt = UsageDayIntersection.summaries(from: [spanning], calendar: calendar)
        try assertSummariesEqual(snapshot.dailySummaries, rebuilt, calendar: calendar)
        XCTAssertEqual(snapshot.dailySummaries.count, 2)
    }

    private func assertSummariesEqual(
        _ lhs: [DailyUsageSummary],
        _ rhs: [DailyUsageSummary],
        calendar: Calendar
    ) throws {
        XCTAssertEqual(lhs.count, rhs.count)
        for (left, right) in zip(lhs, rhs) {
            XCTAssertEqual(calendar.startOfDay(for: left.date), calendar.startOfDay(for: right.date))
            XCTAssertEqual(left.provider, right.provider)
            XCTAssertEqual(left.totalInputTokens, right.totalInputTokens)
            XCTAssertEqual(left.totalOutputTokens, right.totalOutputTokens)
            XCTAssertEqual(left.totalCacheCreationTokens, right.totalCacheCreationTokens)
            XCTAssertEqual(left.totalCacheReadTokens, right.totalCacheReadTokens)
            XCTAssertEqual(left.totalTokens, right.totalTokens)
            XCTAssertEqual(left.totalCost, right.totalCost, accuracy: 0.0001)
            XCTAssertEqual(left.sessionCount, right.sessionCount)
            XCTAssertEqual(Set(left.models), Set(right.models))
        }
    }
}
