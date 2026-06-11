import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Pure-function coverage for the no-change replace short-circuit
/// (`UsageContentFingerprint` + `UsageReplaceGate.nextWindowBoundary`).
/// The coordinator-level behavior lives in `DataStoreUsagesVersionTests`.
final class UsageReplaceGateTests: XCTestCase {

    private func usage(
        seed: Int,
        startTime: Date,
        duration: TimeInterval = 60
    ) -> TokenUsage {
        TokenUsage(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seed))!,
            provider: .factory,
            sessionId: "session-\(seed)",
            projectName: "project",
            model: "model",
            inputTokens: 100,
            outputTokens: 200,
            costUSD: Double(seed),
            startTime: startTime,
            endTime: startTime.addingTimeInterval(duration)
        )
    }

    private var noon: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
    }

    // MARK: - Fingerprint

    func testFingerprint_isOrderInsensitive() {
        let now = noon
        let a = usage(seed: 1, startTime: now.addingTimeInterval(-100))
        let b = usage(seed: 2, startTime: now.addingTimeInterval(-200))

        XCTAssertEqual(
            UsageContentFingerprint(rows: [a, b]),
            UsageContentFingerprint(rows: [b, a])
        )
    }

    func testFingerprint_changesWithContentAndCount() {
        let now = noon
        let a = usage(seed: 1, startTime: now.addingTimeInterval(-100))
        let b = usage(seed: 2, startTime: now.addingTimeInterval(-200))
        let mutated = usage(seed: 1, startTime: now.addingTimeInterval(-100), duration: 120)

        XCTAssertNotEqual(
            UsageContentFingerprint(rows: [a]),
            UsageContentFingerprint(rows: [a, b])
        )
        XCTAssertNotEqual(
            UsageContentFingerprint(rows: [a]),
            UsageContentFingerprint(rows: [mutated])
        )
        XCTAssertEqual(UsageContentFingerprint(rows: []), UsageContentFingerprint(rows: []))
    }

    // MARK: - Window boundary

    func testNextWindowBoundary_emptyRows_isNextMidnight() {
        let now = noon
        let expected = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: now)
        )!
        XCTAssertEqual(UsageReplaceGate.nextWindowBoundary(rows: [], after: now), expected)
    }

    func testNextWindowBoundary_freshRows_dontPullBoundaryBeforeMidnight() {
        let now = noon
        let fresh = usage(seed: 1, startTime: now.addingTimeInterval(-3_600))
        let expected = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: now)
        )!
        // A one-hour-old row exits the 7d window in ~7 days — midnight wins.
        XCTAssertEqual(UsageReplaceGate.nextWindowBoundary(rows: [fresh], after: now), expected)
    }

    func testNextWindowBoundary_rowNearSevenDayExit_setsEarlierBoundary() {
        let now = noon
        let nearExit = usage(seed: 1, startTime: now.addingTimeInterval(-7 * 86_400 + 2 * 3_600))
        let boundary = UsageReplaceGate.nextWindowBoundary(rows: [nearExit], after: now)
        // Exit at now+2h, pulled one hour earlier by the DST safety margin.
        XCTAssertEqual(boundary, now.addingTimeInterval(3_600))
    }

    func testNextWindowBoundary_rowInsideExitMargin_disablesSkipping() {
        let now = noon
        // Exit at now+30min: the margin-adjusted exit is in the past, so the
        // gate must return `now` (skip window closed) rather than a stale
        // future boundary.
        let exiting = usage(seed: 1, startTime: now.addingTimeInterval(-7 * 86_400 + 1_800))
        XCTAssertEqual(UsageReplaceGate.nextWindowBoundary(rows: [exiting], after: now), now)
    }

    func testNextWindowBoundary_alreadyExitedRows_dontHoldBoundaryAtNow() {
        let now = noon
        let ancient = usage(seed: 1, startTime: now.addingTimeInterval(-40 * 86_400))
        let expected = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: now)
        )!
        // Rows already outside every rolling window can't change anything —
        // midnight remains the boundary.
        XCTAssertEqual(UsageReplaceGate.nextWindowBoundary(rows: [ancient], after: now), expected)
    }

    func testNextWindowBoundary_thirtyDayWindowAlsoCounts() {
        let now = noon
        let nearExit = usage(seed: 1, startTime: now.addingTimeInterval(-30 * 86_400 + 2 * 3_600))
        let boundary = UsageReplaceGate.nextWindowBoundary(rows: [nearExit], after: now)
        XCTAssertEqual(boundary, now.addingTimeInterval(3_600))
    }
}
