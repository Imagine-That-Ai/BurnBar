#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// L8a — `MacActionDispatcher.dispatch` re-checks the privileged-input kill
/// flag at the actual CGEvent-synthesis chokepoint, so an in-flight phone
/// intent cannot post a synthetic event after panic teardown fires.
final class MacActionDispatcherKillSwitchTests: XCTestCase {
    private var testFlagPath: String!

    override func setUp() {
        super.setUp()
        testFlagPath = NSTemporaryDirectory() + "obb-dispatcher-killswitch-\(UUID().uuidString).flag"
        unsetenv("OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH")
        setenv("OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH", testFlagPath, 1)
        PrivilegedInputKillSwitch.clear()
    }

    override func tearDown() {
        PrivilegedInputKillSwitch.clear()
        unsetenv("OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH")
        try? FileManager.default.removeItem(atPath: testFlagPath)
        super.tearDown()
    }

    func test_dispatchRefusesEveryActionKindWhilePanicFlagIsActive() {
        PrivilegedInputKillSwitch.activate(reason: "test_panic")
        let dispatcher = MacActionDispatcher()

        // Every kind must be refused BEFORE any input synthesis happens — the
        // kill-flag assert is the first statement of `dispatch`.
        let actions: [MacInputAction] = [
            MacInputAction(kind: .click, displayX: 10, displayY: 10),
            MacInputAction(kind: .type, text: "blocked"),
            MacInputAction(kind: .key, key: "Return"),
            MacInputAction(kind: .scroll, displayX: 10, displayY: 10, dragEndX: 10, dragEndY: 40)
        ]
        for action in actions {
            XCTAssertThrowsError(try dispatcher.dispatch(action), "kind \(action.kind) must fail closed") { error in
                XCTAssertTrue(
                    error is PrivilegedInputKillSwitch.KillSwitchActive,
                    "expected KillSwitchActive, got \(error)"
                )
            }
        }
    }
}
#endif
