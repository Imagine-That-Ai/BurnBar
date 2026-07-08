import XCTest

/// Flow 5 — Hermes compose: type into the "Ask Hermes" composer and assert the
/// send button's enablement responds to the composed text.
///
/// Uses the always-present Hermes quick-ask composer on the Pulse dashboard
/// (`HermesQuickAskCard`), whose send button is gated by
/// `input.isEmpty || service.isStreaming`. The test only exercises enablement
/// (empty → disabled, composed → enabled) and never taps Send, so no message
/// is dispatched and no network is required.
@MainActor
final class AgentsComposeSmokeUITests: SmokeUITestCase {

    func testHermesComposerEnablesSendWhenTextEntered() {
        let app = launchSeededApp()

        XCTAssertTrue(
            screenMarker("pulse", in: app).waitForExistence(timeout: 30),
            "Pulse dashboard did not render.\n\(app.debugDescription)"
        )

        let input = app.textFields["hermes.quickAsk.input"].firstMatch
        XCTAssertTrue(
            scrollToHittable(input, in: app),
            "Hermes quick-ask composer input was not reachable.\n\(app.debugDescription)"
        )

        let send = app.buttons["hermes.quickAsk.send"].firstMatch
        XCTAssertTrue(
            send.waitForExistence(timeout: 10),
            "Hermes quick-ask send button not found.\n\(app.debugDescription)"
        )

        // Empty composer → send disabled.
        XCTAssertFalse(
            send.isEnabled,
            "Send should be disabled while the composer is empty.\n\(app.debugDescription)"
        )

        // Compose text → send becomes enabled.
        input.tap()
        input.typeText("How much did I burn today?")

        XCTAssertTrue(
            waitFor(send, predicateFormat: "isEnabled == true"),
            "Send did not enable after composing text.\n\(app.debugDescription)"
        )
    }
}
