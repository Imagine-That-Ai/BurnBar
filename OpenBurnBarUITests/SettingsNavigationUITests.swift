import XCTest

final class SettingsNavigationUITests: UITestBase {
    func testSettingsRowsNavigateToComputerUseSurface() {
        launchApp(openSettings: true)

        // `settings.sidebar` is the real, unambiguous "settings is open" anchor;
        // the settings root identifier sits on a SwiftUI container that does not
        // emit its own AX element.
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
