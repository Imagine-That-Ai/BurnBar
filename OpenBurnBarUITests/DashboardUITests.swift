import XCTest

final class DashboardUITests: UITestBase {
    func testDashboardRendersWithLayoutSwitcher() {
        launchApp()

        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
        waitFor(element(OBBAccessibilityID.dashboardLayoutSwitcher), timeout: 20)
    }

    func testDashboardViewModeSwitcherIsInteractive() {
        launchApp()

        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
        waitFor(element(OBBAccessibilityID.dashboardLayoutSwitcher), timeout: 20)

        // The view-mode control is a "View Mode" RadioGroup with Agents/Models
        // RadioButtons. Assert both options render and are interactive, then
        // exercise a selection tap. (SwiftUI does not expose radio selection
        // state to XCUITest reliably, so we assert interactivity, not the
        // selected value.)
        let agentsOption = app.radioButtons["Agents"].firstMatch
        let modelsOption = app.radioButtons["Models"].firstMatch
        waitFor(agentsOption, timeout: 10)
        waitForHittable(modelsOption, timeout: 10).tap()

        // The dashboard stays live after switching view modes, across a relaunch.
        app.terminate()
        launchApp()
        waitFor(element(OBBAccessibilityID.dashboardRoot), timeout: 20)
        waitFor(app.radioButtons["Models"].firstMatch, timeout: 10)
    }
}
