import XCTest

final class ProviderRowsUITests: UITestBase {
    func testAgentsSettingsShowsProviderRows() {
        launchApp(openSettings: true)

        waitFor(element(OBBAccessibilityID.settingsRoot), timeout: 20)
        waitForHittable(element(OBBAccessibilityID.settingsRow("agents")), timeout: 10).tap()

        let providerRows = [
            OBBAccessibilityID.providersRow("Claude Code"),
            OBBAccessibilityID.providersRow("OpenAI"),
            OBBAccessibilityID.providersRow("Codex")
        ]

        XCTAssertTrue(
            providerRows.contains { element($0).waitForExistence(timeout: 15) },
            "Expected at least one canonical provider row to render in Agents settings"
        )
    }
}
