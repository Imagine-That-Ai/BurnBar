import XCTest
@testable import OpenBurnBar

/// Regression coverage for "Codex quota never resets after the 5h clock rolls
/// over." The reset countdown advanced past a stale `resetsAt` (showing a fresh
/// "resets in 3h") while the usage bar stayed pinned at the old window's value,
/// because the snapshot freezes once the user is capped — no new Codex rollout
/// events get written, so the last-seen 100%/past-reset event is shown forever.
///
/// `reconcilingElapsedWindow` makes the bar agree with the countdown: a window
/// whose `resetsAt` has passed reports 0 used / full remaining with the reset
/// advanced to the next boundary. The gate is shared with `resetsAtDisplay`, so
/// the two never disagree.
final class ProviderQuotaBucketElapsedResetTests: XCTestCase {

    private func bucket(
        windowKind: ProviderQuotaWindowKind,
        usedPercent: Double?,
        resetsAt: Date?,
        key: String = "codex-primary",
        label: String = "5-hour window"
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind,
            usedValue: usedPercent,
            limitValue: 100,
            remainingValue: usedPercent.map { max(0, 100 - $0) },
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            unit: .percent,
            isEstimated: false
        )
    }

    func test_reconcile_pastFiveHourWindow_resetsUsageAndAdvancesReset() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        let capped = bucket(windowKind: .rollingHours, usedPercent: 100, resetsAt: threeDaysAgo)

        let reset = capped.reconcilingElapsedWindow()

        XCTAssertEqual(reset.usedPercent, 0, "a capped 5h window that elapsed must read as 0% used")
        XCTAssertEqual(reset.remainingPercent, 100)
        XCTAssertEqual(reset.progressFraction, 0)
        XCTAssertEqual(reset.remainingValue, 100)
        XCTAssertNotNil(reset.resetsAt)
        XCTAssertGreaterThan(reset.resetsAt!, Date(), "resetsAt advances to the next future boundary")
    }

    func test_reconcile_pastWeeklyWindow_resetsUsage() {
        let twoWeeksAgo = Date().addingTimeInterval(-14 * 24 * 3600)
        let weekly = bucket(windowKind: .weekly, usedPercent: 96, resetsAt: twoWeeksAgo, key: "codex-secondary", label: "7-day window")

        let reset = weekly.reconcilingElapsedWindow()

        XCTAssertEqual(reset.usedPercent, 0)
        XCTAssertGreaterThan(reset.resetsAt!, Date())
    }

    func test_reconcile_futureWindow_isUnchanged() {
        let inTwoHours = Date().addingTimeInterval(2 * 3600)
        let active = bucket(windowKind: .rollingHours, usedPercent: 40, resetsAt: inTwoHours)

        let same = active.reconcilingElapsedWindow()

        XCTAssertEqual(same.usedPercent, 40, "a window that has not elapsed must not be reset")
        XCTAssertEqual(same.resetsAt, inTwoHours)
    }

    func test_reconcile_customWindow_isUnchanged() {
        // No inferable period (resetsAtDisplay would return nil): leave the
        // last-known usage alone rather than guessing a reset.
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        let custom = bucket(windowKind: .custom, usedPercent: 88, resetsAt: threeDaysAgo)

        let same = custom.reconcilingElapsedWindow()

        XCTAssertEqual(same.usedPercent, 88)
        XCTAssertEqual(same.resetsAt, threeDaysAgo)
    }

    func test_reconcile_lifetimeBalance_isUnchanged() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        let lifetime = bucket(windowKind: .lifetime, usedPercent: 70, resetsAt: threeDaysAgo)
        XCTAssertEqual(lifetime.reconcilingElapsedWindow().usedPercent, 70)
    }

    func test_displayableQuotaBuckets_resetsElapsedCodexWindow() {
        let fourDaysAgo = Date().addingTimeInterval(-4 * 24 * 3600)
        let snapshot = ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: fourDaysAgo,
            source: .localSession,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Codex quota snapshot",
            buckets: [bucket(windowKind: .rollingHours, usedPercent: 100, resetsAt: fourDaysAgo)]
        )

        let shown = snapshot.displayableQuotaBuckets.first
        XCTAssertNotNil(shown)
        XCTAssertEqual(shown?.usedPercent, 0, "the popover/strip must show the rolled-over 5h window as full again")
        XCTAssertEqual(snapshot.hourlyBucket?.usedPercent, 0, "the hourly accessor inherits the reconciled value")
    }
}
