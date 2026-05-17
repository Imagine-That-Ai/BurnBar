import XCTest
@testable import OpenBurnBarCore

final class VerdictWindowTests: XCTestCase {

    private func calendar(_ tz: String = "America/Los_Angeles") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2 // Monday — matches the renderer's week label.
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? Date()
    }

    func testBucketKeyIsStableForSameDay() {
        let cal = calendar()
        let morning = date("2026-05-16T08:00:00.000-07:00")
        let evening = date("2026-05-16T22:00:00.000-07:00")
        let key1 = VerdictWindow.today.dayBucketKey(for: morning, calendar: cal)
        let key2 = VerdictWindow.today.dayBucketKey(for: evening, calendar: cal)
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1, "2026-05-16")
    }

    func testBucketKeyDiffersAcrossDays() {
        let cal = calendar()
        let day1 = date("2026-05-16T20:00:00.000-07:00")
        let day2 = date("2026-05-17T03:00:00.000-07:00")
        XCTAssertNotEqual(
            VerdictWindow.today.dayBucketKey(for: day1, calendar: cal),
            VerdictWindow.today.dayBucketKey(for: day2, calendar: cal)
        )
    }

    func testQuarterBucketKey() {
        let cal = calendar()
        XCTAssertEqual(
            VerdictWindow.quarter.dayBucketKey(
                for: date("2026-01-04T12:00:00.000-07:00"),
                calendar: cal
            ),
            "2026-Q1"
        )
        XCTAssertEqual(
            VerdictWindow.quarter.dayBucketKey(
                for: date("2026-04-04T12:00:00.000-07:00"),
                calendar: cal
            ),
            "2026-Q2"
        )
        XCTAssertEqual(
            VerdictWindow.quarter.dayBucketKey(
                for: date("2026-12-31T12:00:00.000-07:00"),
                calendar: cal
            ),
            "2026-Q4"
        )
    }

    func testTTLsAreOrderedShortToLong() {
        XCTAssertLessThan(VerdictWindow.today.cacheTTL, VerdictWindow.yesterday.cacheTTL)
        XCTAssertLessThan(VerdictWindow.yesterday.cacheTTL, VerdictWindow.thisWeek.cacheTTL)
        XCTAssertLessThan(VerdictWindow.thisWeek.cacheTTL, VerdictWindow.thisMonth.cacheTTL)
        XCTAssertLessThan(VerdictWindow.thisMonth.cacheTTL, VerdictWindow.quarter.cacheTTL)
        XCTAssertLessThan(VerdictWindow.quarter.cacheTTL, VerdictWindow.year.cacheTTL)
    }

    func testDisplayLabelsArePresentForEveryCase() {
        for window in VerdictWindow.allCases {
            XCTAssertFalse(window.displayLabel.isEmpty, "missing label for \(window)")
        }
    }
}
