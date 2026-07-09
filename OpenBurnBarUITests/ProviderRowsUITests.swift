import XCTest

final class ProviderRowsUITests: UITestBase {
    func testAgentsSettingsShowsProviderRows() {
        launchApp(openSettings: true)

        // Anchor on the real sidebar element; the settings root identifier is on
        // a SwiftUI container that does not emit its own AX element.
        waitFor(element(OBBAccessibilityID.settingsSidebar), timeout: 20)
        waitForHittable(element(OBBAccessibilityID.settingsRow("agents")), timeout: 10).tap()

        // Match any provider row by identifier prefix rather than hardcoding
        // provider names — the app tags rows with providerID.rawValue.
        let anyProviderRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "providers.row."))
            .firstMatch

        XCTAssertTrue(
            anyProviderRow.waitForExistence(timeout: 20),
            "Expected at least one provider row to render in Agents settings"
        )
    }
}
