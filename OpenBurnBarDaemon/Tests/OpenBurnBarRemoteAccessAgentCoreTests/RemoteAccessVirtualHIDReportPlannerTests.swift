import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore

final class RemoteAccessVirtualHIDReportPlannerTests: XCTestCase {
    func testANSIUSCredentialMapsToBootKeyboardReports() {
        let plan = RemoteAccessVirtualHIDReportPlanner.planForANSIUSKeyboard("Az9!") ?? []

        XCTAssertEqual(plan.map(\.down.bytes), [
            [0x02, 0, 0x04, 0, 0, 0, 0, 0], // Shift + A
            [0x00, 0, 0x1d, 0, 0, 0, 0, 0], // z
            [0x00, 0, 0x26, 0, 0, 0, 0, 0], // 9
            [0x02, 0, 0x1e, 0, 0, 0, 0, 0]  // Shift + 1
        ])
        XCTAssertTrue(plan.allSatisfy { $0.up.bytes == [0, 0, 0, 0, 0, 0, 0, 0] })
    }

    func testUnsupportedCharactersFailClosed() {
        XCTAssertNil(RemoteAccessVirtualHIDReportPlanner.planForANSIUSKeyboard("🔒"))
    }

    func testControlKeysMapToBootKeyboardUsages() {
        XCTAssertEqual(RemoteAccessVirtualHIDReportPlanner.escapeKeyPress().down.bytes, [0, 0, 0x29, 0, 0, 0, 0, 0])
        XCTAssertEqual(RemoteAccessVirtualHIDReportPlanner.deleteKeyPress().down.bytes, [0, 0, 0x2a, 0, 0, 0, 0, 0])
        XCTAssertEqual(RemoteAccessVirtualHIDReportPlanner.returnKeyPress().down.bytes, [0, 0, 0x28, 0, 0, 0, 0, 0])
    }
}
