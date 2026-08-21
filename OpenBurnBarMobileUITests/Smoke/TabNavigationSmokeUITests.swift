import XCTest

/// Flow 2 — Drive the Aurora floating tab tray through every destination and
/// assert each destination screen appears.
///
/// Visits Pulse → Burn → Insights → Streams → Agents → You → back to Pulse. Each hop
/// confirms both that the tapped tab became selected and that the destination
/// screen's marker (`screen.<name>`) rendered.
@MainActor
final class TabNavigationSmokeUITests: SmokeUITestCase {

    func testAuroraTrayNavigatesEveryDestination() {
        let app = launchSeededApp()

        // Launch destination.
        XCTAssertTrue(
            screenMarker("pulse", in: app).waitForExistence(timeout: 30),
            "Did not start on the Pulse screen.\n\(app.debugDescription)"
        )

        // Each entry: (tray tab id, destination screen marker name).
        let journey: [(tab: String, screen: String)] = [
            ("burn", "burn"),
            ("insights", "insights"),
            ("streams", "streams"),
            ("hermes", "agents"),
            ("you", "you"),
            ("pulse", "pulse")
        ]

        for step in journey {
            selectAuroraTab(step.tab, in: app)
            XCTAssertTrue(
                screenMarker(step.screen, in: app).waitForExistence(timeout: 15),
                "Selecting the '\(step.tab)' tab did not reveal the '\(step.screen)' screen.\n\(app.debugDescription)"
            )
        }
    }
}
