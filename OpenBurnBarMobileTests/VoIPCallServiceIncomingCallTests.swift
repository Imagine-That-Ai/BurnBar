import XCTest
@testable import OpenBurnBarMobile

@MainActor
final class VoIPCallServiceIncomingCallTests: XCTestCase {
    func testIncomingCallMatchingReturnsInFlightCall() {
        let call = VoIPCallService.IncomingCall(
            callID: UUID(),
            connectionID: "conn-live",
            pairedDeviceID: "mac-1",
            displayName: "Mac",
            isVideo: true
        )
        let matched = VoIPCallService.incomingCall(call, matching: "conn-live")
        XCTAssertEqual(matched, call)
    }

    func testIncomingCallMismatchReturnsNil() {
        let call = VoIPCallService.IncomingCall(
            callID: UUID(),
            connectionID: "conn-live",
            pairedDeviceID: "mac-1",
            displayName: "Mac",
            isVideo: true
        )
        XCTAssertNil(VoIPCallService.incomingCall(call, matching: "conn-other"))
    }

    func testIncomingCallNilInFlightReturnsNil() {
        XCTAssertNil(VoIPCallService.incomingCall(nil, matching: "conn-live"))
    }
}
