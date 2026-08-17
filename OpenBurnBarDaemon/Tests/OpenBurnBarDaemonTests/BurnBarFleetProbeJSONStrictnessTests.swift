@testable import OpenBurnBarDaemon
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

    // MARK: - dateFromStartTimeTriState (probe-hardening-repair-b: hermes
    // start_time dual encoding — the real gateway.pid writes epoch-ms while
    // the heartbeat writes fractional epoch-seconds)

    func testDateFromStartTime_epochSeconds() {
        let outcome = BurnBarFleetProbeJSON.dateFromStartTimeTriState(1_750_000_000)
        guard case .valid(let date) = outcome else {
            XCTFail("epoch-seconds must be valid, got \(outcome)")
            return
        }
        XCTAssertEqual(date.timeIntervalSince1970, 1_750_000_000.0, accuracy: 0.001)
    }

    func testDateFromStartTime_epochMilliseconds() {
        // The real gateway.pid writes epoch-milliseconds; a plausible
        // integral ms value parses as ms, not seconds.
        let outcome = BurnBarFleetProbeJSON.dateFromStartTimeTriState(1_750_000_000_000)
        guard case .valid(let date) = outcome else {
            XCTFail("epoch-milliseconds must be valid, got \(outcome)")
            return
        }
        XCTAssertEqual(date.timeIntervalSince1970, 1_750_000_000.0, accuracy: 0.001)
    }

    func testDateFromStartTime_fractionalEpochSeconds() {
        // The real heartbeat writes fractional epoch-seconds.
        let outcome = BurnBarFleetProbeJSON.dateFromStartTimeTriState(1_786_536_834.708_521)
        guard case .valid(let date) = outcome else {
            XCTFail("fractional epoch-seconds must be valid, got \(outcome)")
            return
        }
        XCTAssertEqual(date.timeIntervalSince1970, 1_786_536_834.708_521, accuracy: 0.001)
    }

    func testDateFromStartTime_rejectsMalformed() {
        if case .invalid = BurnBarFleetProbeJSON.dateFromStartTimeTriState(true) {
            // boolean must be rejected as invalid
        } else {
            XCTFail("boolean must be invalid")
        }
        if case .invalid = BurnBarFleetProbeJSON.dateFromStartTimeTriState("1750000000") {
            // string must be rejected as invalid
        } else {
            XCTFail("string must be invalid")
        }
        XCTAssertEqual(BurnBarFleetProbeJSON.dateFromStartTimeTriState(nil), .absent)
        XCTAssertEqual(BurnBarFleetProbeJSON.dateFromStartTimeTriState(NSNull()), .absent)
        // Fractional epoch-milliseconds are malformed (integral only).
        if case .invalid = BurnBarFleetProbeJSON.dateFromStartTimeTriState(178_653_683_051.5) {
            // fractional epoch-ms must be invalid
        } else {
            XCTFail("fractional epoch-ms must be invalid")
        }
        // The real gateway.pid's ms-in-seconds bug maps to 1975 — implausible
        // for any current process and treated as absent.
        XCTAssertEqual(BurnBarFleetProbeJSON.dateFromStartTimeTriState(178_653_683_051 / 1000), .absent)
    }

    // MARK: - dateFromEpochMillisecondsTriState: absent vs invalid

    func testDateFromEpochMillisecondsTriState_absentVsInvalid() {
        XCTAssertEqual(BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(nil), .absent)
        XCTAssertEqual(BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(NSNull()), .absent)
        if case .invalid(let reason) = BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(true) {
            XCTAssertTrue(reason.contains("boolean"), "unexpected reason: \(reason)")
        } else {
            XCTFail("boolean startTime must be invalid, not absent")
        }
        if case .invalid(let reason) = BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(1_750_000_000.5) {
            XCTAssertTrue(reason.contains("fractional"), "unexpected reason: \(reason)")
        } else {
            XCTFail("fractional startTime must be invalid, not absent")
        }
        if case .invalid = BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState("not-a-number") {
            // non-numeric must be invalid
        } else {
            XCTFail("non-numeric startTime must be invalid, not absent")
        }
        if case .valid = BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(1_750_000_000_000) {
            // integral epoch-ms is valid
        } else {
            XCTFail("integral epoch-ms must be valid")
        }
    }

    // MARK: - pidValue: positive macOS pid_t range (reviewer issue 2)

    func testPidValue_acceptsPositivePidRange() {
        XCTAssertEqual(BurnBarFleetProbeJSON.pidValue(1), 1)
        XCTAssertEqual(BurnBarFleetProbeJSON.pidValue(Int32.max), Int(Int32.max))
        XCTAssertEqual(BurnBarFleetProbeJSON.pidValue(42_000), 42_000)
    }

    func testPidValue_rejectsZeroNegativeAndOversize() {
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue(0), "pid 0 is not a positive pid")
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue(-1), "negative pid must be rejected")
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue(-42), "negative pid must be rejected")
        XCTAssertNil(
            BurnBarFleetProbeJSON.pidValue(Int64(Int32.max) + 1),
            "pid beyond Int32.max must be rejected before pid_t conversion"
        )
        XCTAssertNil(
            BurnBarFleetProbeJSON.pidValue(3_000_000_000),
            "pid 3000000000 must be rejected before pid_t conversion"
        )
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue(1e30), "huge pid must be rejected")
    }

    func testPidValue_rejectsNonIntegralAndNonNumeric() {
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue(true), "boolean must never coerce to a pid")
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue(1.5), "fractional pid must be rejected")
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue("42"), "string pid must be rejected")
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue(nil))
        XCTAssertNil(BurnBarFleetProbeJSON.pidValue(NSNull()))
    }

    func testPidRejectionReason_namesMalformedValue() {
        XCTAssertNil(BurnBarFleetProbeJSON.pidRejectionReason(42))
        XCTAssertEqual(
            BurnBarFleetProbeJSON.pidRejectionReason(0)?.contains("positive"),
            true,
            "reason must name the malformed pid: \(String(describing: BurnBarFleetProbeJSON.pidRejectionReason(0)))"
        )
        XCTAssertEqual(
            BurnBarFleetProbeJSON.pidRejectionReason(-1)?.contains("positive"),
            true
        )
        XCTAssertEqual(
            BurnBarFleetProbeJSON.pidRejectionReason(3_000_000_000)?.contains("pid_t"),
            true,
            "reason must name the pid_t range: "
                + String(describing: BurnBarFleetProbeJSON.pidRejectionReason(3_000_000_000))
        )
        XCTAssertEqual(
            BurnBarFleetProbeJSON.pidRejectionReason(true)?.contains("numeric"),
            true
        )
    }

    // MARK: - Liveness range guard: out-of-range pids never reach pid_t

    func testLiveness_rejectsOutOfRangePidsWithoutTrap() {
        // The liveness helpers themselves must never trap on out-of-range
        // Int values (second line of defense behind pidValue).
        XCTAssertFalse(BurnBarFleetProcessLiveness.isAlive(pid: 0))
        XCTAssertFalse(BurnBarFleetProcessLiveness.isAlive(pid: -1))
        XCTAssertFalse(BurnBarFleetProcessLiveness.isAlive(pid: Int(Int32.max) + 1))
        XCTAssertFalse(BurnBarFleetProcessLiveness.isAlive(pid: 3_000_000_000))
        XCTAssertNil(BurnBarFleetProcessLiveness.processStartTime(pid: 0))
        XCTAssertNil(BurnBarFleetProcessLiveness.processStartTime(pid: -5))
        XCTAssertNil(BurnBarFleetProcessLiveness.processStartTime(pid: Int(Int32.max) + 1))
    }
}
