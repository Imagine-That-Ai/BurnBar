import XCTest

/// Flow 1 — Launch → the Pulse dashboard renders with its core chrome.
///
/// Proves the seeded, no-network launch reaches the signed-in dashboard: the
/// Pulse screen marker is present, the Pulse tab reports selected, and the
/// floating Aurora nav tray shows every core destination.
@MainActor
final class DashboardRenderSmokeUITests: SmokeUITestCase {

    func testLaunchRendersPulseDashboardWithNavTray() {
        let app = launchSeededApp()

        // The Pulse dashboard is the launch destination.
        XCTAssertTrue(
            screenMarker("pulse", in: app).waitForExistence(timeout: 30),
            "Pulse dashboard did not render after a seeded launch.\n\(app.debugDescription)"
        )

        // Its tab reports selected.
        let pulseTab = app.buttons["auroraTab.pulse"].firstMatch
        XCTAssertTrue(pulseTab.waitForExistence(timeout: 10))
        XCTAssertTrue(
            pulseTab.isSelected,
            "Pulse tab should be selected on launch.\n\(app.debugDescription)"
        )

        // The floating Aurora nav tray renders every core destination.
        for id in ["pulse", "burn", "insights", "streams", "hermes", "you"] {
            let tab = app.buttons["auroraTab.\(id)"]
            XCTAssertTrue(
                tab.waitForExistence(timeout: 10),
                "Aurora nav tray is missing the '\(id)' tab.\n\(app.debugDescription)"
            )
        }
    }
}
