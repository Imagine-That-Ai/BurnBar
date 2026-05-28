import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore

final class RemoteAccessKeystrokePlannerTests: XCTestCase {
    func testPlansLowercaseUppercaseDigitsAndSymbolsAsHardwareKeyEvents() throws {
        let plan = try XCTUnwrap(RemoteAccessKeystrokePlanner.planForANSIUSKeyboard("aZ9!_ "))

        XCTAssertEqual(plan.map(\.virtualKey), [0, 6, 25, 18, 27, 49])
        XCTAssertEqual(plan.map(\.requiresShift), [false, true, false, true, true, false])
    }

    func testUnsupportedCharactersReturnNilSoAgentCanUseUnicodeFallback() {
        XCTAssertNil(RemoteAccessKeystrokePlanner.planForANSIUSKeyboard("burnbar🔒"))
    }
}
