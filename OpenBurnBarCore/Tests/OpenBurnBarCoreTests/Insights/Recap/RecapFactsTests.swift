import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarRecap

final class RecapFactsTests: XCTestCase {

    private let calendar = RecapFixtures.calendar()
    private let august = RecapWindow(year: 2026, month: 8)

    func testTotalsMatchTheRows() {
        let batch = RecapFixtures.busyMonth(august, calendar: calendar)
        let facts = RecapFacts.build(batch: batch, builtAt: august.end(calendar: calendar), calendar: calendar)

        XCTAssertEqual(facts.totalCostUSD, batch.usages.reduce(0) { $0 + $1.costUSD }, accuracy: 0.0001)
        XCTAssertEqual(facts.totalTokens, batch.usages.reduce(0) { $0 + $1.totalTokens })
        XCTAssertEqual(facts.sessionCount, Set(batch.usages.map { "\($0.provider)|\($0.sessionID)" }).count)
        XCTAssertEqual(facts.dailyCost.count, 31)
        XCTAssertEqual(facts.dayCount, 31)
    }

    /// A 31-day month must not lose its last day — the exact failure the
    /// digest builder's 30-point cap would have introduced.
    func testThirtyFirstDayIsRepresented() {
        var batch = RecapFixtures.busyMonth(august, calendar: calendar)
        let lastDay = RecapFixtures.date(2026, 8, 31, 14, calendar: calendar)
        batch = RecapRowBatch(
            window: august,
            usages: batch.usages + [RecapFixtures.usage(session: "last", start: lastDay, cost: 99)],
            sessions: batch.sessions,
            hasSessionData: true
        )
        let facts = RecapFacts.build(batch: batch, builtAt: august.end(calendar: calendar), calendar: calendar)
        XCTAssertEqual(facts.dailyCost.count, 31)
        XCTAssertGreaterThanOrEqual(facts.dailyCost[30], 99)
    }

    func testHourAndWeekdayBucketsAreLocal() {
        let start = RecapFixtures.date(2026, 8, 4, 1, calendar: calendar) // a Tuesday, 1am
        let batch = RecapRowBatch(
            window: august,
            usages: [RecapFixtures.usage(session: "a", start: start, cost: 5)],
            hasSessionData: false
        )
        let facts = RecapFacts.build(batch: batch, builtAt: august.end(calendar: calendar), calendar: calendar)

        XCTAssertEqual(facts.hourCost[1], 5, accuracy: 0.0001)
        // Gregorian weekday 3 = Tuesday, index 2.
        XCTAssertEqual(facts.weekdayCost[2], 5, accuracy: 0.0001)
        XCTAssertEqual(facts.hourWeekdayCost[2][1], 5, accuracy: 0.0001)
        XCTAssertEqual(facts.lateNightCostShare, 1.0, accuracy: 0.0001)
    }

    func testSessionsAreGroupedAcrossRows() throws {
        let start = RecapFixtures.date(2026, 8, 4, 9, calendar: calendar)
        let batch = RecapRowBatch(
            window: august,
            usages: [
                RecapFixtures.usage(session: "shared", start: start, durationMinutes: 30, cost: 1),
                RecapFixtures.usage(session: "shared", start: start.addingTimeInterval(3_600), durationMinutes: 30, cost: 2)
            ],
            hasSessionData: false
        )
        let facts = RecapFacts.build(batch: batch, builtAt: august.end(calendar: calendar), calendar: calendar)

        XCTAssertEqual(facts.sessionCount, 1)
        // Span runs from the first row's start to the last row's end.
        XCTAssertEqual(facts.longestSession?.durationSeconds, 3_600 + 1_800)
        XCTAssertEqual(try XCTUnwrap(facts.longestSession).costUSD, 3, accuracy: 0.0001)
    }

    func testStreakCountsConsecutiveActiveDays() {
        let days = [1, 2, 3, 4, 7, 8]
        let usages = days.map {
            RecapFixtures.usage(
                session: "d\($0)",
                start: RecapFixtures.date(2026, 8, $0, 10, calendar: calendar)
            )
        }
        let facts = RecapFacts.build(
            batch: RecapRowBatch(window: august, usages: usages, hasSessionData: false),
            builtAt: august.end(calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(facts.activeDayCount, 6)
        XCTAssertEqual(facts.longestActiveStreak, 4)
    }

    func testBusiestWeekIsASlidingSevenDayWindow() throws {
        var usages: [InsightUsageRow] = []
        for day in 1...31 {
            let cost = (8...14).contains(day) ? 10.0 : 1.0
            usages.append(RecapFixtures.usage(
                session: "d\(day)",
                start: RecapFixtures.date(2026, 8, day, 10, calendar: calendar),
                cost: cost
            ))
        }
        let facts = RecapFacts.build(
            batch: RecapRowBatch(window: august, usages: usages, hasSessionData: false),
            builtAt: august.end(calendar: calendar),
            calendar: calendar
        )
        // Days 8–14 are indices 7–13.
        XCTAssertEqual(facts.busiestWeek?.startDayIndex, 7)
        XCTAssertEqual(facts.busiestWeek?.endDayIndex, 13)
        XCTAssertEqual(try XCTUnwrap(facts.busiestWeek).costUSD, 70, accuracy: 0.0001)
    }

    func testCacheHitRateMatchesTheCanonicalFormula() {
        let batch = RecapRowBatch(
            window: august,
            usages: [RecapFixtures.usage(
                session: "a",
                start: RecapFixtures.date(2026, 8, 4, 10, calendar: calendar),
                input: 100, output: 50, cacheRead: 300, cacheCreation: 100
            )],
            hasSessionData: false
        )
        let facts = RecapFacts.build(batch: batch, builtAt: august.end(calendar: calendar), calendar: calendar)
        // cacheRead / (input + cacheCreation + cacheRead) = 300 / 500
        XCTAssertEqual(facts.cacheHitRate, 0.6, accuracy: 0.0001)
    }

    func testToolsCountEachSessionOnce() {
        let start = RecapFixtures.date(2026, 8, 4, 10, calendar: calendar)
        let batch = RecapRowBatch(
            window: august,
            usages: [RecapFixtures.usage(session: "a", start: start)],
            sessions: [
                RecapFixtures.session(id: "a", start: start, tools: ["Read", "Read", "Read", "Edit"])
            ],
            hasSessionData: true
        )
        let facts = RecapFacts.build(batch: batch, builtAt: august.end(calendar: calendar), calendar: calendar)
        XCTAssertEqual(facts.tools.first { $0.name == "Read" }?.count, 1)
        XCTAssertEqual(facts.tools.first { $0.name == "Edit" }?.count, 1)
    }

    func testFoldIsDeterministic() {
        let batch = RecapFixtures.busyMonth(august, calendar: calendar)
        let stamp = august.end(calendar: calendar)
        let first = RecapFacts.build(batch: batch, builtAt: stamp, calendar: calendar)
        let second = RecapFacts.build(batch: batch, builtAt: stamp, calendar: calendar)
        XCTAssertEqual(first, second)
    }

    func testThinMonthFailsTheSubstanceFloor() {
        let facts = RecapFacts.build(
            batch: RecapFixtures.thinMonth(august, calendar: calendar),
            builtAt: august.end(calendar: calendar),
            calendar: calendar
        )
        XCTAssertFalse(facts.meetsMinimumSubstance)
    }
}
