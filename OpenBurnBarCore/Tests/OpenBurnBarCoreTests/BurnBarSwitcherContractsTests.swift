import XCTest
@testable import OpenBurnBarKernel

final class BurnBarSwitcherContractsTests: XCTestCase {
    func testApplyRequestCodableRoundTrip() throws {
        let request = BurnBarSwitcherActiveProfileApplyRequest(
            sets: [
                BurnBarSwitcherActiveProfileSet(profileID: "profile-1"),
                BurnBarSwitcherActiveProfileSet(profileID: "profile-1", providerID: "claude-code")
            ],
            clearProfileID: "profile-9"
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BurnBarSwitcherActiveProfileApplyRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testApplyRequestDefaultsToEmptySetsAndNoClear() {
        let request = BurnBarSwitcherActiveProfileApplyRequest()
        XCTAssertTrue(request.sets.isEmpty)
        XCTAssertNil(request.clearProfileID)
    }

    func testSetDefaultsToGlobalPointer() {
        let set = BurnBarSwitcherActiveProfileSet(profileID: "profile-1")
        XCTAssertNil(set.providerID)
    }

    func testApplyResponseCodableRoundTrip() throws {
        let response = BurnBarSwitcherActiveProfileApplyResponse(setsApplied: 2, rowsCleared: 1)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BurnBarSwitcherActiveProfileApplyResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }
}
