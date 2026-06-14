import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// T-TRN-03 — control-plane downgrade classification + sliding-window
/// fallback-rate alarm. Pure logic, no live transport.
final class HermesTransportFallbackGuardTests: XCTestCase {

    func testContentStreamsAreNotControlPlane() {
        XCTAssertFalse(HermesTransportDowngradePolicy.isControlPlane(.chatCompletions))
        XCTAssertFalse(HermesTransportDowngradePolicy.isControlPlane(.cliAgentChat))
    }

    func testControlPlaneOperationsClassified() {
        for op: HermesRelayOperation in [.models, .sessions, .sessionDetail, .profiles, .jobs, .cliAgentModelCatalog, .cliAgentSessionAction] {
            XCTAssertTrue(HermesTransportDowngradePolicy.isControlPlane(op), "\(op) should be control-plane")
        }
    }

    func testSecurityErrorBlocksSilentDowngrade() {
        XCTAssertFalse(
            HermesTransportDowngradePolicy.allowsSilentDowngrade(
                operation: .models,
                irohEnabled: true,
                errorStopsFallback: true
            ),
            "A security/model-binding error must halt the downgrade."
        )
    }

    func testDisabledIrohIsConfiguredChoiceNotDowngrade() {
        XCTAssertTrue(
            HermesTransportDowngradePolicy.allowsSilentDowngrade(
                operation: .models,
                irohEnabled: false,
                errorStopsFallback: false
            )
        )
    }

    func testAlarmFiresOnceWhenThresholdCrossed() {
        let alarm = FallbackRateAlarm(threshold: 3, window: 60)
        let base = Date()
        XCTAssertFalse(alarm.record(at: base))
        XCTAssertFalse(alarm.record(at: base.addingTimeInterval(1)))
        XCTAssertTrue(alarm.record(at: base.addingTimeInterval(2)), "Crossing the threshold fires the alarm.")
        // Stays armed-off until the window drains below threshold — no repeat spam.
        XCTAssertFalse(alarm.record(at: base.addingTimeInterval(3)))
    }

    func testAlarmReArmsAfterWindowDrains() {
        let alarm = FallbackRateAlarm(threshold: 2, window: 10)
        let base = Date()
        XCTAssertFalse(alarm.record(at: base))
        XCTAssertTrue(alarm.record(at: base.addingTimeInterval(1)))
        // 30s later the window has fully drained; a fresh burst re-fires.
        let later = base.addingTimeInterval(40)
        XCTAssertFalse(alarm.record(at: later))
        XCTAssertTrue(alarm.record(at: later.addingTimeInterval(1)))
    }

    func testOldFallbacksLeaveTheWindow() {
        let alarm = FallbackRateAlarm(threshold: 3, window: 10)
        let base = Date()
        _ = alarm.record(at: base)
        // 20s later only the new events count.
        XCTAssertEqual(alarm.count(at: base.addingTimeInterval(20)), 0)
    }
}
