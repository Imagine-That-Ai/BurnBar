import XCTest
@testable import OpenBurnBarMobile

final class DebugBridgeReleaseGuardTests: XCTestCase {
    func testPhysicalDeviceQABuildHasExplicitDebugBridgeOptIn() {
        XCTAssertTrue(MobileDebugBridgeBuild.isEnabled)
    }
}
