import XCTest
@testable import OpenBurnBarCore

final class CadenceSchedulerTests: XCTestCase {

    func testDailyDueAtScheduledTime() async {
        let cal = Calendar(identifier: .gregorian)
        let schedule = CadenceScheduler.Schedule(
            dailyAt: DateComponents(hour: 7, minute: 0)
        )
        let scheduler = CadenceScheduler(schedule: schedule, calendar: cal)

        // 2024-01-15 at 07:05 — within 15-minute window of 07:00
        let comps = DateComponents(year: 2024, month: 1, day: 15, hour: 7, minute: 5)
        let now = cal.date(from: comps)!

        let due = await scheduler.due(now: now)
        XCTAssertTrue(due.cadences.contains(.daily))
        XCTAssertEqual(due.nextDaily, cal.date(from: DateComponents(year: 2024, month: 1, day: 16, hour: 7, minute: 0)))
    }

    func testDailyNotDueOutsideWindow() async {
        let cal = Calendar(identifier: .gregorian)
        let schedule = CadenceScheduler.Schedule(
            dailyAt: DateComponents(hour: 7, minute: 0)
        )
        let scheduler = CadenceScheduler(schedule: schedule, calendar: cal)

        // 2024-01-15 at 09:00 — outside 15-minute window
        var comps = DateComponents(year: 2024, month: 1, day: 15, hour: 9, minute: 0)
        let now = cal.date(from: comps)!

        let due = await scheduler.due(now: now)
        XCTAssertFalse(due.cadences.contains(.daily))
    }

    func testDailyNotDueIfRecentlyDelivered() async {
        let cal = Calendar(identifier: .gregorian)
        let schedule = CadenceScheduler.Schedule(
            dailyAt: DateComponents(hour: 7, minute: 0)
        )
        var lastDelivered: [CadenceArtifact.Cadence: Date] = [:]
        // Delivered 2 hours ago at 05:00
        lastDelivered[.daily] = cal.date(from: DateComponents(year: 2024, month: 1, day: 15, hour: 5, minute: 0))!
        let scheduler = CadenceScheduler(schedule: schedule, lastDelivered: lastDelivered, calendar: cal)

        let comps = DateComponents(year: 2024, month: 1, day: 15, hour: 7, minute: 5)
        let now = cal.date(from: comps)!

        let due = await scheduler.due(now: now)
        // Min gap is 20h, so 2h since last delivery means NOT due
        XCTAssertFalse(due.cadences.contains(.daily))
    }

    func testWeeklyDueOnSunday() async {
        let cal = Calendar(identifier: .gregorian)
        let schedule = CadenceScheduler.Schedule(
            weeklyAt: DateComponents(hour: 18, minute: 0, weekday: 1) // Sunday
        )
        let scheduler = CadenceScheduler(schedule: schedule, calendar: cal)

        // 2024-01-07 is a Sunday at 18:05
        var comps = DateComponents(year: 2024, month: 1, day: 7, hour: 18, minute: 5)
        let now = cal.date(from: comps)!

        let due = await scheduler.due(now: now)
        XCTAssertTrue(due.cadences.contains(.weekly))
    }

    func testMarkDeliveredPreventsRefire() async {
        let cal = Calendar(identifier: .gregorian)
        let schedule = CadenceScheduler.Schedule(
            dailyAt: DateComponents(hour: 7, minute: 0)
        )
        let scheduler = CadenceScheduler(schedule: schedule, calendar: cal)

        let comps = DateComponents(year: 2024, month: 1, day: 15, hour: 7, minute: 5)
        let now = cal.date(from: comps)!

        // First call: should be due
        let due1 = await scheduler.due(now: now)
        XCTAssertTrue(due1.cadences.contains(.daily))

        // Mark delivered
        await scheduler.markDelivered(.daily, at: now)

        // Second call: should NOT be due (min gap 20h)
        let due2 = await scheduler.due(now: now)
        XCTAssertFalse(due2.cadences.contains(.daily))
    }
}
