import XCTest

final class SettingsNavigationUITests: UITestBase {
    func testSettingsRowsNavigateToComputerUseSurface() {
        launchApp(openSettings: true)

        waitFor(element(OBBAccessibilityID.settingsRoot), timeout: 20)
        waitFor(element(OBBAccessibilityID.settingsSidebar), timeout: 20)

        let expectedRows = [
            OBBAccessibilityID.settingsRow("home"),
            OBBAccessibilityID.settingsRow("agents"),
            OBBAccessibilityID.settingsRow("modelProxy"),
            OBBAccessibilityID.settingsRow("computerUse")
        ]
        for rowID in expectedRows {
            waitFor(element(rowID), timeout: 10)
        }

        waitForHittable(element(OBBAccessibilityID.settingsRow("computerUse")), timeout: 10).tap()
        waitFor(element(OBBAccessibilityID.computerUseSettingsRoot), timeout: 20)
    }
}
