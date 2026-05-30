import XCTest
@testable import OpenBurnBarComputerUseCore

final class PrivilegedInputKillSwitchTests: XCTestCase {
    private var testFlagPath: String!

    override func setUp() {
        super.setUp()
        testFlagPath = NSTemporaryDirectory() + "obb-killswitch-\(UUID().uuidString).flag"
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

    func test_activateSetsFlagAndBlocksDispatch() {
        XCTAssertFalse(PrivilegedInputKillSwitch.isActive)
        PrivilegedInputKillSwitch.activate(reason: "test_panic")
        XCTAssertTrue(PrivilegedInputKillSwitch.isActive)
        XCTAssertThrowsError(try PrivilegedInputKillSwitch.assertNotActive()) { error in
            XCTAssertEqual(error as? PrivilegedInputKillSwitch.KillSwitchActive, .some(.init()))
        }
    }

    func test_clearRemovesFlag() {
        PrivilegedInputKillSwitch.activate(reason: "test")
        PrivilegedInputKillSwitch.clear()
        XCTAssertFalse(PrivilegedInputKillSwitch.isActive)
        XCTAssertNoThrow(try PrivilegedInputKillSwitch.assertNotActive())
    }

    func test_leafDispatchPatternMatchesVirtualHIDBridge() throws {
        PrivilegedInputKillSwitch.activate(reason: ComputerUsePanicSource.hotkey.rawValue)
        do {
            try PrivilegedInputKillSwitch.assertNotActive()
            XCTFail("Virtual HID leaf must reject dispatch when kill switch is active")
        } catch {
            XCTAssertTrue(error is PrivilegedInputKillSwitch.KillSwitchActive)
        }
    }
}
