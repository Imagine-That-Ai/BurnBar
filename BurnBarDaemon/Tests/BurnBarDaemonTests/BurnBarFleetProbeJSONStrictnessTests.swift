@testable import BurnBarDaemon
import Foundation
import XCTest
/// Strict primitive validation for the shared probe JSON helpers
/// (probe-hardening-repair-a, reviewer issue 1): integer fields must reject
/// NSNumber booleans and fractional/non-integral values instead of coercing
/// via `intValue`, and epoch-millisecond timestamps must reject booleans and
/// fractional values. A malformed value must never become a live-looking
/// integer or timestamp.
final class BurnBarFleetProbeJSONStrictnessTests: XCTestCase {
    // MARK: - integerValue

    func testIntegerValue_acceptsIntegralNumbers() {
        XCTAssertEqual(BurnBarFleetProbeJSON.integerValue(42), 42)
        XCTAssertEqual(BurnBarFleetProbeJSON.integerValue(0), 0)
        XCTAssertEqual(BurnBarFleetProbeJSON.integerValue(-7), -7)
        XCTAssertEqual(BurnBarFleetProbeJSON.integerValue(Int64(9_999_999_999)), 9_999_999_999)
    }

    func testIntegerValue_rejectsBoolean() {
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(true), "JSON true must never coerce to an integer")
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(false), "JSON false must never coerce to an integer")
    }

    func testIntegerValue_rejectsFractional() {
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(1.5), "fractional values must be rejected")
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(-0.5), "negative fractional values must be rejected")
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(1.000_000_1), "near-integral values must be rejected")
    }

    func testIntegerValue_rejectsNonNumbers() {
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue("42"))
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(NSNull()))
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(nil))
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue([1, 2]))
    }

    func testIntegerValue_rejectsOutOfRange() {
        // 1e30 exceeds Int64; must not wrap or truncate into a live pid.
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(1e30))
        XCTAssertNil(BurnBarFleetProbeJSON.integerValue(-1e30))
    }

    // MARK: - dateFromEpochMilliseconds

    func testDateFromEpochMilliseconds_acceptsIntegralEpochMilliseconds() {
        let date = BurnBarFleetProbeJSON.dateFromEpochMilliseconds(1_750_000_000_000)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_750_000_000.0, accuracy: 0.001)
    }

    func testDateFromEpochMilliseconds_rejectsBoolean() {
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromEpochMilliseconds(true))
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromEpochMilliseconds(false))
    }

    func testDateFromEpochMilliseconds_rejectsFractional() {
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromEpochMilliseconds(1_750_000_000.5))
    }

    func testDateFromEpochMilliseconds_rejectsNonNumbers() {
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromEpochMilliseconds("1750000000000"))
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromEpochMilliseconds(nil))
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromEpochMilliseconds(NSNull()))
    }

    // MARK: - End-to-end: a fractional pid never reaches liveness

    func testFractionalPid_neverBecomesLivePid() async throws {
        // A live pid + 0.5 must be rejected as malformed, never truncated to
        // the live pid via intValue (reviewer issue 1: "livePid + 0.5 can be
        // converted to a real live pid and claim exactProcess").
        let live = try LiveSleepProcess()
        defer { live.terminate() }
        let fractionalPid = Double(live.pid) + 0.5
        XCTAssertNil(
            BurnBarFleetProbeJSON.integerValue(fractionalPid),
            "a fractional pid must never coerce to the live pid"
        )
    }

    // MARK: - dateFromStartTime (probe-hardening-repair-b: hermes start_time
    // dual encoding — the real gateway.pid writes epoch-ms while the
    // heartbeat writes fractional epoch-seconds)

    func testDateFromStartTime_epochSeconds() {
        let date = BurnBarFleetProbeJSON.dateFromStartTime(1_750_000_000)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_750_000_000.0, accuracy: 0.001)
    }

    func testDateFromStartTime_epochMilliseconds() {
        // The real gateway.pid writes epoch-milliseconds; a plausible
        // integral ms value parses as ms, not seconds.
        let date = BurnBarFleetProbeJSON.dateFromStartTime(1_750_000_000_000)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_750_000_000.0, accuracy: 0.001)
    }

    func testDateFromStartTime_fractionalEpochSeconds() {
        // The real heartbeat writes fractional epoch-seconds.
        let date = BurnBarFleetProbeJSON.dateFromStartTime(1_786_536_834.708_521)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_786_536_834.708_521, accuracy: 0.001)
    }

    func testDateFromStartTime_rejectsMalformed() {
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromStartTime(true), "boolean must be rejected")
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromStartTime("1750000000"), "string must be rejected")
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromStartTime(nil))
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromStartTime(NSNull()))
        // Fractional epoch-milliseconds are malformed (integral only).
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromStartTime(178_653_683_051.5))
        // The real gateway.pid's ms-in-seconds bug maps to 1975 — implausible
        // for any current process and treated as absent.
        XCTAssertNil(BurnBarFleetProbeJSON.dateFromStartTime(178_653_683_051 / 1000))
    }
}
