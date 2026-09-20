import XCTest
@testable import OpenBurnBarComputerUseCore

final class ComputerUseTrustModePolicyTests: XCTestCase {
    func testLiveSessionRejectsElevation() {
        XCTAssertEqual(
            ComputerUseTrustModePolicy.resolve(requested: .trusted, current: .manual, sessionIsLive: true),
            .manual
        )
        XCTAssertTrue(
            ComputerUseTrustModePolicy.rejectsElevation(requested: .step, current: .manual, sessionIsLive: true)
        )
    }

    func testLiveSessionAcceptsDowngrade() {
        XCTAssertEqual(
            ComputerUseTrustModePolicy.resolve(requested: .manual, current: .trusted, sessionIsLive: true),
            .manual
        )
        XCTAssertFalse(
            ComputerUseTrustModePolicy.rejectsElevation(requested: .step, current: .trusted, sessionIsLive: true)
        )
    }

    func testIdleSessionAllowsElevation() {
        XCTAssertEqual(
            ComputerUseTrustModePolicy.resolve(requested: .trusted, current: .manual, sessionIsLive: false),
            .trusted
        )
    }
}
