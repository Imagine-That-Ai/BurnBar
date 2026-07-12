import XCTest

/// Flow 3 — Open Settings and toggle a setting, asserting the toggle state
/// actually changed.
///
/// Path: You tab → Settings row → Settings hub → the "Premium SOTA UX"
/// appearance toggle (an `@AppStorage`-backed switch). The switch's reported
/// `value` ("0"/"1") is read before and after the interaction. The tap targets
/// the trailing control region, since the accessible row spans the full width
/// with its label occupying the center.
@MainActor
final class SettingsToggleSmokeUITests: SmokeUITestCase {

    func testAppearanceToggleFlipsState() {
        let app = launchSeededApp()

        selectAuroraTab("you", in: app)
        XCTAssertTrue(
            screenMarker("you", in: app).waitForExistence(timeout: 20),
            "You screen did not appear.\n\(app.debugDescription)"
        )

        // Open the Settings hub.
        let settingsRow = app.buttons["you.settingsRow"].firstMatch
        XCTAssertTrue(
            scrollToHittable(settingsRow, in: app),
            "Settings row was not reachable on the You screen.\n\(app.debugDescription)"
        )
        settingsRow.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 20),
            "Settings hub did not open.\n\(app.debugDescription)"
        )

        // Locate the appearance toggle.
        let toggle = app.switches["settings.toggle.premiumSOTAUX"].firstMatch
        XCTAssertTrue(
            scrollToHittable(toggle, in: app),
            "Premium SOTA UX toggle was not reachable.\n\(app.debugDescription)"
        )

        let before = (toggle.value as? String) ?? "<nil>"
        // Tap the trailing control region rather than the row center (label).
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()

        let expected = (before == "1") ? "0" : "1"
        XCTAssertTrue(
            waitFor(toggle, predicateFormat: "value == '\(expected)'"),
            "Toggle did not flip from \(before) to \(expected).\n\(app.debugDescription)"
        )
    }
}
