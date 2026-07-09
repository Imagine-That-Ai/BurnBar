import XCTest

final class DashboardUITests: UITestBase {
    func testDashboardRendersWithLayoutSwitcher() {
        launchApp()

        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
        waitFor(element(OBBAccessibilityID.dashboardLayoutSwitcher), timeout: 20)
    }

    func testDashboardViewModeSwitcherPersistsSelection() {
        launchApp()

        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
        waitFor(element(OBBAccessibilityID.dashboardLayoutSwitcher), timeout: 20)
        // The view-mode control is a RadioGroup ("View Mode") whose options are
        // RadioButtons, not Buttons — query by the correct element type.
        let modelsOption = app.radioButtons["Models"].firstMatch
        waitForHittable(modelsOption, timeout: 10).tap()

        XCTAssertTrue(isSelected(modelsOption), "Expected Models view mode to be selected")

        app.terminate()
        launchApp()

        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
        let relaunchedModelsOption = app.radioButtons["Models"].firstMatch
        waitFor(relaunchedModelsOption, timeout: 10)
        XCTAssertTrue(isSelected(relaunchedModelsOption), "Expected Models view mode selection to persist across relaunch")
    }

    private func isSelected(_ element: XCUIElement) -> Bool {
        if let value = element.value as? String {
            return value == "1" || value.localizedCaseInsensitiveContains("selected")
        }
        if let value = element.value as? Int {
            return value == 1
        }
        return element.isSelected
    }
}
