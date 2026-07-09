import XCTest

final class DashboardUITests: UITestBase {
    func testDashboardRendersRoot() {
        launchApp()

        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
    }

    func testDashboardViewModeSwitcherPersistsSelection() {
        launchApp()

        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
        let switcher = waitFor(element(OBBAccessibilityID.dashboardViewModeSwitcher), timeout: 20)
        let modelsOption = switcher.buttons["Models"].firstMatch
        waitForHittable(modelsOption, timeout: 10).tap()

        XCTAssertTrue(isSelected(modelsOption), "Expected Models view mode to be selected")

        app.terminate()
        launchApp()

        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
        let relaunchedModelsOption = element(OBBAccessibilityID.dashboardViewModeSwitcher).buttons["Models"].firstMatch
        waitFor(relaunchedModelsOption, timeout: 10)
        XCTAssertTrue(isSelected(relaunchedModelsOption), "Expected Models view mode selection to persist across relaunch")
    }

    private func isSelected(_ element: XCUIElement) -> Bool {
        guard let value = element.value as? String else { return false }
        return value == "1" || value.localizedCaseInsensitiveContains("selected")
    }
}
