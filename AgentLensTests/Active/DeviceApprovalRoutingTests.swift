import XCTest
@testable import OpenBurnBarCore

final class DeviceApprovalRoutingTests: XCTestCase {
    @MainActor
    func testAppCommandRouterHandlesDeviceApprovalUrls() {
        let router = AppCommandRouter()

        let approveUrl = URL(string: "openburnbar://approve-device?deviceId=test-device-123")!
        let handledApprove = router.handle(approveUrl)
        XCTAssertTrue(handledApprove)

        let approvalUrl = URL(string: "openburnbar://device-approval")!
        let handledApproval = router.handle(approvalUrl)
        XCTAssertTrue(handledApproval)

        let devicesUrl = URL(string: "openburnbar://devices")!
        let handledDevices = router.handle(devicesUrl)
        XCTAssertTrue(handledDevices)
    }
}
