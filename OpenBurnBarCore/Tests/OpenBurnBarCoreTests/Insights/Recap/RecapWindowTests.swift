import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarRecap

final class RecapWindowTests: XCTestCase {

    func testKeyRoundTrip() {
        let window = RecapWindow(year: 2026, month: 8)
        XCTAssertEqual(window.key, "2026-08")
        XCTAssertEqual(RecapWindow(key: "2026-08"), window)
        XCTAssertNil(RecapWindow(key: "2026-13"))
        XCTAssertNil(RecapWindow(key: "nonsense"))
    }

    func testMonthArithmeticWrapsYears() {
        let january = RecapWindow(year: 2026, month: 1)
        XCTAssertEqual(january.previous, RecapWindow(year: 2025, month: 12))
        XCTAssertEqual(january.advanced(by: -13), RecapWindow(year: 2024, month: 12))
        XCTAssertEqual(RecapWindow(year: 2026, month: 12).next, RecapWindow(year: 2027, month: 1))
    }

    func testPriorMonthsAreContiguousAndNewestFirst() {
        let august = RecapWindow(year: 2026, month: 8)
        let prior = august.priorMonths(3)
        XCTAssertEqual(prior.map(\.key), ["2026-07", "2026-06", "2026-05"])
    }

    /// The whole reason this type exists rather than reusing VerdictWindow:
    /// months are calendar months, so day counts vary and adjacent months
    /// never overlap.
    func testDayCountsFollowTheCalendar() {
        let calendar = RecapFixtures.calendar()
        XCTAssertEqual(RecapWindow(year: 2026, month: 8).dayCount(calendar: calendar), 31)
        XCTAssertEqual(RecapWindow(year: 2026, month: 9).dayCount(calendar: calendar), 30)
        XCTAssertEqual(RecapWindow(year: 2026, month: 2).dayCount(calendar: calendar), 28)
        XCTAssertEqual(RecapWindow(year: 2028, month: 2).dayCount(calendar: calendar), 29)
    }

    func testAdjacentMonthsDoNotOverlap() {
        let calendar = RecapFixtures.calendar()
        let august = RecapWindow(year: 2026, month: 8)
        XCTAssertEqual(august.end(calendar: calendar), august.next.start(calendar: calendar))
        XCTAssertFalse(august.contains(august.next.start(calendar: calendar), calendar: calendar))
    }

    /// A month containing a DST transition is still exactly its calendar length,
    /// because the bounds come from Calendar rather than from 30 × 86400.
    func testDSTMonthKeepsCalendarLength() {
        let calendar = RecapFixtures.calendar()
        let march = RecapWindow(year: 2026, month: 3)
        XCTAssertEqual(march.dayCount(calendar: calendar), 31)
        let span = march.end(calendar: calendar).timeIntervalSince(march.start(calendar: calendar))
        // 31 days minus the hour lost to the spring-forward transition.
        XCTAssertEqual(span, 31 * 86_400 - 3_600, accuracy: 1)
    }

    func testMostRecentCompletedIsThePreviousMonth() {
        let calendar = RecapFixtures.calendar()
        let now = RecapFixtures.date(2026, 8, 19, 12, calendar: calendar)
        XCTAssertEqual(
            RecapWindow.mostRecentCompleted(asOf: now, calendar: calendar),
            RecapWindow(year: 2026, month: 7)
        )
        XCTAssertFalse(RecapWindow(year: 2026, month: 8).hasEnded(asOf: now, calendar: calendar))
        XCTAssertTrue(RecapWindow(year: 2026, month: 7).hasEnded(asOf: now, calendar: calendar))
    }
}
