import XCTest

/// Flow 1 — Launch → Inbox renders with the compact tray.
///
/// Proves the seeded, no-network launch reaches the signed-in shell: the
/// Inbox screen marker is present, the Inbox tab reports selected, and the
/// floating Aurora nav tray shows Inbox · Agents · Quota · You.
@MainActor
final class DashboardRenderSmokeUITests: SmokeUITestCase {

    func testLaunchRendersInboxWithNavTray() {
        let app = launchSeededApp()

        // Inbox is the compact launch destination.
        XCTAssertTrue(
            screenMarker("inbox", in: app).waitForExistence(timeout: 30),
            "Inbox did not render after a seeded launch.\n\(app.debugDescription)"
        )

        // Its tab reports selected.
        let inboxTab = app.buttons["auroraTab.inbox"].firstMatch
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10))
        XCTAssertTrue(
            inboxTab.isSelected,
            "Inbox tab should be selected on launch.\n\(app.debugDescription)"
        )

        // The floating Aurora nav tray renders every compact destination.
        for id in ["inbox", "hermes", "burn", "you"] {
            let tab = app.buttons["auroraTab.\(id)"]
            XCTAssertTrue(
                tab.waitForExistence(timeout: 10),
                "Aurora nav tray is missing the '\(id)' tab.\n\(app.debugDescription)"
            )
        }
    }
}
