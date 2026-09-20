import XCTest

/// Flow 2 — Drive the Aurora floating tab tray through every destination and
/// assert each destination screen appears.
///
/// Visits Agents → Quota → You → back to Inbox. Each hop
/// confirms both that the tapped tab became selected and that the destination
/// screen's marker (`screen.<name>`) rendered.
@MainActor
final class TabNavigationSmokeUITests: SmokeUITestCase {

    func testAuroraTrayNavigatesEveryDestination() {
        let app = launchSeededApp()

        // Launch destination.
        XCTAssertTrue(
            screenMarker("inbox", in: app).waitForExistence(timeout: 30),
            "Did not start on the Inbox screen.\n\(app.debugDescription)"
        )
        writeQuietTabScreenshot(named: "inbox")

        // Each entry: (tray tab id, destination screen marker name).
        let journey: [(tab: String, screen: String)] = [
            ("hermes", "agents"),
            ("burn", "burn"),
            ("you", "you"),
            ("inbox", "inbox")
        ]

        for step in journey {
            selectAuroraTab(step.tab, in: app)
            XCTAssertTrue(
                screenMarker(step.screen, in: app).waitForExistence(timeout: 15),
                "Selecting the '\(step.tab)' tab did not reveal the '\(step.screen)' screen.\n\(app.debugDescription)"
            )
            writeQuietTabScreenshot(named: step.screen)
        }
    }

    /// Attaches the quiet-chrome shot for each tab to the test result, so the
    /// run itself carries the visual evidence rather than a machine-local path.
    private func writeQuietTabScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "tab-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
