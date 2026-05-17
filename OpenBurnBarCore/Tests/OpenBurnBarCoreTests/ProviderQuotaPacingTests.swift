import XCTest
@testable import OpenBurnBarCore

final class ProviderQuotaPacingTests: XCTestCase {

    // MARK: - Helpers

    private func makeNow(_ minutesAgo: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_750_000_000).addingTimeInterval(-minutesAgo * 60)
    }

    // MARK: - Window duration

    func test_windowDuration_rollingHoursIsFiveHours() {
        let now = makeNow()
        let duration = PacingMath.windowDuration(
            for: .rollingHours,
            resetsAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(duration, 5 * 60 * 60)
    }

    func test_windowDuration_dailyIsTwentyFourHours() {
        let now = makeNow()
        let duration = PacingMath.windowDuration(for: .daily, resetsAt: now)
        XCTAssertEqual(duration, 24 * 60 * 60)
    }

    func test_windowDuration_weeklyIsSevenDays() {
        let now = makeNow()
        let weekly = PacingMath.windowDuration(for: .weekly, resetsAt: now)
        let rolling = PacingMath.windowDuration(for: .rollingDays, resetsAt: now)
        XCTAssertEqual(weekly, 7 * 24 * 60 * 60)
        XCTAssertEqual(rolling, 7 * 24 * 60 * 60)
    }

    func test_windowDuration_monthlyUsesCalendarArithmetic() {
        // March 1 → February (28 days in 2026, which is not a leap year)
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 1
        let calendar = Calendar(identifier: .gregorian)
        let resetsAt = calendar.date(from: components)!

        let duration = PacingMath.windowDuration(
            for: .monthly,
            resetsAt: resetsAt,
            calendar: calendar
        )

        // 28 days in February 2026, ±1 hour tolerance for DST quirks.
        let expectedSeconds: Double = 28 * 24 * 60 * 60
        let tolerance: Double = 60 * 60
        XCTAssertNotNil(duration)
        XCTAssertEqual(duration ?? 0, expectedSeconds, accuracy: tolerance)
    }

    func test_windowDuration_lifetimeIsNil() {
        XCTAssertNil(PacingMath.windowDuration(for: .lifetime, resetsAt: Date()))
    }

    func test_windowDuration_customIsNil() {
        XCTAssertNil(PacingMath.windowDuration(for: .custom, resetsAt: Date()))
    }

    // MARK: - Pace computation

    func test_pace_onPaceWhenElapsedEqualsUsed() {
        // 50% elapsed of a 5h window, 50% used → on pace.
        let now = makeNow()
        let resetsAt = now.addingTimeInterval(2.5 * 60 * 60) // 2.5h ahead
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: resetsAt,
            progressFraction: 0.5,
            now: now
        )
        let unwrapped = try? XCTUnwrap(pace)
        XCTAssertNotNil(unwrapped)
        XCTAssertEqual(unwrapped!.severity, .onPace)
        XCTAssertEqual(unwrapped!.elapsedFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(unwrapped!.delta, 0, accuracy: 0.001)
        XCTAssertEqual(unwrapped!.humanLabel, "on pace")
    }

    func test_pace_aheadOfBudgetWhenBurningFast() {
        // 50% elapsed, 80% used → +30% over pace (ahead of budget,
        // burning fast). 7-day window.
        let now = makeNow()
        let resetsAt = now.addingTimeInterval(3.5 * 24 * 60 * 60)
        let pace = PacingMath.pace(
            windowKind: .weekly,
            resetsAt: resetsAt,
            progressFraction: 0.8,
            now: now
        )!
        XCTAssertEqual(pace.severity, .aheadOfBudget)
        XCTAssertEqual(pace.delta, 0.30, accuracy: 0.005)
        XCTAssertEqual(pace.humanLabel, "+30% pace")
    }

    func test_pace_behindBudgetWhenComfortable() {
        // 50% elapsed, 21% used → -29% under pace.
        let now = makeNow()
        let resetsAt = now.addingTimeInterval(2.5 * 60 * 60)
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: resetsAt,
            progressFraction: 0.21,
            now: now
        )!
        XCTAssertEqual(pace.severity, .behindBudget)
        XCTAssertEqual(pace.delta, -0.29, accuracy: 0.005)
        XCTAssertEqual(pace.humanLabel, "-29% pace")
    }

    func test_pace_clampsUsageToZeroOne() {
        // Usage > 100% (sometimes returned by adapters mid-overage)
        // should clamp.
        let now = makeNow()
        let resetsAt = now.addingTimeInterval(2.5 * 60 * 60)
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: resetsAt,
            progressFraction: 1.5,
            now: now
        )!
        XCTAssertEqual(pace.usedFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(pace.severity, .aheadOfBudget)
    }

    func test_pace_clampsElapsedToZeroOne() {
        // `now < windowStart` would push elapsedFraction negative; must clamp.
        let now = makeNow()
        // resetsAt is 100 hours away — windowStart is 95 hours in the future too.
        let resetsAt = now.addingTimeInterval(100 * 60 * 60)
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: resetsAt,
            progressFraction: 0.3,
            now: now
        )!
        XCTAssertEqual(pace.elapsedFraction, 0, accuracy: 0.001)
        // Used > elapsed → ahead of budget.
        XCTAssertEqual(pace.severity, .aheadOfBudget)
    }

    func test_pace_nilWhenResetsAtMissing() {
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: nil,
            progressFraction: 0.5,
            now: makeNow()
        )
        XCTAssertNil(pace)
    }

    func test_pace_nilForLifetimeWindow() {
        let pace = PacingMath.pace(
            windowKind: .lifetime,
            resetsAt: Date.distantFuture,
            progressFraction: 0.5,
            now: makeNow()
        )
        XCTAssertNil(pace)
    }

    func test_pace_nilForCustomWindow() {
        let pace = PacingMath.pace(
            windowKind: .custom,
            resetsAt: makeNow().addingTimeInterval(60),
            progressFraction: 0.5,
            now: makeNow()
        )
        XCTAssertNil(pace)
    }

    func test_pace_assumesNewWindowWhenStale() {
        // `now > resetsAt` means the snapshot is stale and the next
        // window has begun. Pace should report `elapsedFraction = 0`.
        let now = makeNow()
        let resetsAt = now.addingTimeInterval(-60 * 60) // an hour in the past
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: resetsAt,
            progressFraction: 0.0,
            now: now
        )!
        XCTAssertEqual(pace.elapsedFraction, 0, accuracy: 0.001)
        XCTAssertEqual(pace.severity, .onPace)
    }

    // MARK: - Threshold

    func test_pace_onPaceBelowThreshold() {
        let now = makeNow()
        let resetsAt = now.addingTimeInterval(2.5 * 60 * 60)
        // 50% elapsed, 52% used → +2% delta → below 3% threshold → on pace.
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: resetsAt,
            progressFraction: 0.52,
            now: now
        )!
        XCTAssertEqual(pace.severity, .onPace)
    }

    func test_pace_breaksOnPaceAboveThreshold() {
        let now = makeNow()
        let resetsAt = now.addingTimeInterval(2.5 * 60 * 60)
        // 50% elapsed, 54% used → +4% delta → above 3% threshold.
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: resetsAt,
            progressFraction: 0.54,
            now: now
        )!
        XCTAssertEqual(pace.severity, .aheadOfBudget)
    }

    // MARK: - Window boundaries

    func test_pace_windowStartIsResetsAtMinusDuration() {
        let now = makeNow()
        let resetsAt = now.addingTimeInterval(60 * 60)
        let pace = PacingMath.pace(
            windowKind: .rollingHours,
            resetsAt: resetsAt,
            progressFraction: 0.7,
            now: now
        )!
        XCTAssertEqual(
            pace.windowStart.timeIntervalSince1970,
            resetsAt.addingTimeInterval(-5 * 60 * 60).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(pace.windowEnd, resetsAt)
    }
}
