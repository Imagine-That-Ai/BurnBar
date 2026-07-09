import XCTest

final class LaunchSmokeTests: UITestBase {
    func testLaunchShowsDashboardOrStatusItem() {
        launchApp()

        let dashboard = element(OBBAccessibilityID.dashboardRoot)
        let statusItem = element(OBBAccessibilityID.menuBarStatusItem)

        XCTAssertTrue(
            dashboard.waitForExistence(timeout: 20) || statusItem.waitForExistence(timeout: 3),
            "Expected the deterministic dashboard window or menu-bar status item to appear"
        )
    }
}
