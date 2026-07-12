import XCTest

final class SettingsNavigationUITests: UITestBase {
    func testSettingsSidebarRowsReachComputerUse() {
        launchApp(openSettings: true)

        // `settings.sidebar` is the real, unambiguous "settings is open" anchor;
        // the settings root identifier sits on a SwiftUI container that does not
        // emit its own AX element.
        let sidebar = element(OBBAccessibilityID.settingsSidebar)
        waitFor(sidebar, timeout: 20)

        // Every canonical settings section renders as a sidebar row, including the
        // Computer Use surface this lane must cover.
        let expectedRows = [
            OBBAccessibilityID.settingsRow("home"),
            OBBAccessibilityID.settingsRow("agents"),
            OBBAccessibilityID.settingsRow("modelProxy"),
            OBBAccessibilityID.settingsRow("computerUse")
        ]
        for rowID in expectedRows {
            waitFor(element(rowID), timeout: 10)
        }

        // The Computer Use row sits below the fold; assert it can be scrolled into
        // view and is interactive, then exercise the tap. (The detail pane is a
        // NavigationSplitView whose root container does not emit a distinct AX
        // element, so we assert reachability + a live surface rather than the
        // detail root.)
        let computerUseRow = waitForHittable(
            element(OBBAccessibilityID.settingsRow("computerUse")),
            timeout: 10,
            scrollContainer: sidebar
        )
        computerUseRow.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Expected settings to stay live after selecting Computer Use")
    }
}
