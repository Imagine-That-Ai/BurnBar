import XCTest
@testable import OpenBurnBarKernel

/// Scheduling is where a fleet feature quietly goes wrong — an order that
/// stampedes after a sleep, or one that never fires at all. These pin the
/// rhythm against a fixed UTC calendar so the answers are exact.
final class StandingOrderSchedulerTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let parsed = formatter.date(from: iso) else {
            preconditionFailure("bad fixture date \(iso)")
        }
        return parsed
    }

    private func order(
        id: String = "order-1",
        cadence: StandingOrder.Cadence,
        enabled: Bool = true,
        lastFiredAt: Date? = nil
    ) -> StandingOrder {
        StandingOrder(
            id: id,
            title: "Run the suite",
            instruction: "run the test suite",
            cadence: cadence,
            isEnabled: enabled,
            lastFiredAt: lastFiredAt
        )
    }

    // MARK: - Interval cadence

    func test_intervalFiresFromTheLastRun() {
        let last = date("2026-08-17T09:00:00Z")
        let next = StandingOrderScheduler.nextFireDate(
            for: order(cadence: .everyMinutes(30), lastFiredAt: last),
            after: date("2026-08-17T09:05:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(next, date("2026-08-17T09:30:00Z"))
    }

    /// A Mac that slept through several intervals resumes the rhythm on the
    /// next interval instead of stampeding to replay every missed one.
    func test_intervalDoesNotStampedeAfterALongSleep() {
        let last = date("2026-08-17T09:00:00Z")
        let now = date("2026-08-17T17:00:00Z")
        let next = StandingOrderScheduler.nextFireDate(
            for: order(cadence: .everyMinutes(30), lastFiredAt: last),
            after: now,
            calendar: calendar
        )
        XCTAssertEqual(next, date("2026-08-17T17:30:00Z"))
    }

    func test_intervalWithoutAPriorRunSchedulesFromNow() {
        let now = date("2026-08-17T09:00:00Z")
        let next = StandingOrderScheduler.nextFireDate(
            for: order(cadence: .everyMinutes(15)),
            after: now,
            calendar: calendar
        )
        XCTAssertEqual(next, date("2026-08-17T09:15:00Z"))
    }

    func test_nonPositiveIntervalHasNoNextFire() {
        XCTAssertNil(StandingOrderScheduler.nextFireDate(
            for: order(cadence: .everyMinutes(0)),
            after: date("2026-08-17T09:00:00Z"),
            calendar: calendar
        ))
        XCTAssertNil(StandingOrderScheduler.nextFireDate(
            for: order(cadence: .everyMinutes(-5)),
            after: date("2026-08-17T09:00:00Z"),
            calendar: calendar
        ))
    }

    // MARK: - Daily cadence

    func test_dailyFiresLaterTheSameDay() {
        let next = StandingOrderScheduler.nextFireDate(
            for: order(cadence: .daily(hour: 9, minute: 0)),
            after: date("2026-08-17T06:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(next, date("2026-08-17T09:00:00Z"))
    }

    func test_dailyRollsToTomorrowOncePassed() {
        let next = StandingOrderScheduler.nextFireDate(
            for: order(cadence: .daily(hour: 9, minute: 0)),
            after: date("2026-08-17T09:30:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(next, date("2026-08-18T09:00:00Z"))
    }

    func test_dailyRejectsImpossibleTimes() {
        for cadence in [
            StandingOrder.Cadence.daily(hour: 24, minute: 0),
            .daily(hour: -1, minute: 0),
            .daily(hour: 9, minute: 60)
        ] {
            XCTAssertNil(StandingOrderScheduler.nextFireDate(
                for: order(cadence: cadence),
                after: date("2026-08-17T06:00:00Z"),
                calendar: calendar
            ))
        }
    }

    // MARK: - Weekly cadence

    /// 2026-08-17 is a Monday; weekday 2 is Monday in Calendar's numbering.
    func test_weeklyFiresLaterOnTheMatchingWeekday() {
        let next = StandingOrderScheduler.nextFireDate(
            for: order(cadence: .weekly(weekday: 2, hour: 9, minute: 0)),
            after: date("2026-08-17T06:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(next, date("2026-08-17T09:00:00Z"))
    }

    func test_weeklyRollsAWholeWeekOncePassed() {
        let next = StandingOrderScheduler.nextFireDate(
            for: order(cadence: .weekly(weekday: 2, hour: 9, minute: 0)),
            after: date("2026-08-17T09:30:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(next, date("2026-08-24T09:00:00Z"))
    }

    func test_weeklyRejectsAnImpossibleWeekday() {
        for weekday in [0, 8] {
            XCTAssertNil(StandingOrderScheduler.nextFireDate(
                for: order(cadence: .weekly(weekday: weekday, hour: 9, minute: 0)),
                after: date("2026-08-17T06:00:00Z"),
                calendar: calendar
            ))
        }
    }

    // MARK: - Enablement

    func test_disabledOrderNeverSchedulesOrComesDue() {
        let disabled = order(cadence: .daily(hour: 9, minute: 0), enabled: false)
        XCTAssertNil(StandingOrderScheduler.nextFireDate(
            for: disabled,
            after: date("2026-08-17T06:00:00Z"),
            calendar: calendar
        ))
        XCTAssertFalse(StandingOrderScheduler.isDue(
            disabled,
            now: date("2026-08-20T12:00:00Z"),
            calendar: calendar
        ))
    }

    // MARK: - Due

    func test_orderIsDueOnceItsFireTimePasses() {
        let daily = order(cadence: .daily(hour: 9, minute: 0), lastFiredAt: date("2026-08-16T09:00:00Z"))
        XCTAssertFalse(StandingOrderScheduler.isDue(daily, now: date("2026-08-17T08:00:00Z"), calendar: calendar))
        XCTAssertTrue(StandingOrderScheduler.isDue(daily, now: date("2026-08-17T09:00:00Z"), calendar: calendar))
    }

    func test_neverFiredOrderBecomesDue() {
        let daily = order(cadence: .daily(hour: 9, minute: 0))
        XCTAssertTrue(StandingOrderScheduler.isDue(daily, now: date("2026-08-17T12:00:00Z"), calendar: calendar))
    }

    func test_dueReturnsLongestOverdueFirst() {
        let stale = order(id: "b", cadence: .everyMinutes(10), lastFiredAt: date("2026-08-17T08:00:00Z"))
        let fresher = order(id: "a", cadence: .everyMinutes(10), lastFiredAt: date("2026-08-17T08:30:00Z"))
        let due = StandingOrderScheduler.due(
            orders: [fresher, stale],
            now: date("2026-08-17T09:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(due.map(\.id), ["b", "a"])
    }

    func test_dueTiesBreakOnIdSoDispatchIsDeterministic() {
        let last = date("2026-08-17T08:00:00Z")
        let orders = [
            order(id: "z", cadence: .everyMinutes(10), lastFiredAt: last),
            order(id: "a", cadence: .everyMinutes(10), lastFiredAt: last)
        ]
        XCTAssertEqual(
            StandingOrderScheduler.due(orders: orders, now: date("2026-08-17T09:00:00Z"), calendar: calendar).map(\.id),
            ["a", "z"]
        )
    }

    func test_dueExcludesOrdersThatHaveNotComeAround() {
        let recent = order(cadence: .everyMinutes(60), lastFiredAt: date("2026-08-17T08:55:00Z"))
        XCTAssertTrue(StandingOrderScheduler.due(
            orders: [recent],
            now: date("2026-08-17T09:00:00Z"),
            calendar: calendar
        ).isEmpty)
    }

    // MARK: - Attribution

    /// A standing order is scheduled by the user, so it must not be attributed
    /// to the Flame even when the Flame picks the machine at fire time.
    func test_orderAttributesAsMissionNotFlame() {
        let originator = order(cadence: .everyMinutes(10)).originator
        XCTAssertEqual(originator.kind, .mission)
        XCTAssertEqual(originator.missionID, "order-1")
        XCTAssertEqual(originator.confidence, .exact)
        XCTAssertEqual(originator.primaryRef, "order-1")
    }

    func test_orderRoundTripsThroughCodable() throws {
        let original = StandingOrder(
            id: "order-9",
            title: "Nightly suite",
            instruction: "run the full suite",
            cadence: .weekly(weekday: 6, hour: 22, minute: 30),
            targetBodyID: "relay-host-mini",
            requiredCapabilities: ["hermes_chat"],
            lastFiredAt: date("2026-08-17T09:00:00Z")
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(StandingOrder.self, from: data), original)
    }
}
