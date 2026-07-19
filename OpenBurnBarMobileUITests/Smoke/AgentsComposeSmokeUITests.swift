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

    func testLiveParetoHarnessForcesProductionAppCheck() {
        let app = liveParetoApplication()

        XCTAssertEqual(
            app.launchEnvironment["OPENBURNBAR_APP_CHECK_PROVIDER"],
            "appattest"
        )
    }

    /// Opt-in production-surface proof. This intentionally uses the signed-in
    /// device state and real Firestore instead of the seeded smoke fixture.
    func testLiveParetoDispatchFromPhysicalDevice() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["OPENBURNBAR_LIVE_WAND_E2E"] == "1",
            "Set OPENBURNBAR_LIVE_WAND_E2E=1 for the physical-device sales proof."
        )
        #if targetEnvironment(simulator)
        throw XCTSkip("The live Pareto sales proof requires a physical iPhone.")
        #endif

        guard let missionTitle = environment["OPENBURNBAR_LIVE_WAND_MISSION_TITLE"],
              !missionTitle.isEmpty,
              let missionPrompt = environment["OPENBURNBAR_LIVE_WAND_MISSION_PROMPT"],
              !missionPrompt.isEmpty else {
            XCTFail("The live Pareto proof requires a unique mission title and prompt.")
            return
        }

        let app = liveParetoApplication()
        app.launch()

        selectAuroraTab("hermes", in: app)
        XCTAssertTrue(
            screenMarker("agents", in: app).waitForExistence(timeout: 30),
            "Hermes Square did not render from the real signed-in device state.\n\(app.debugDescription)"
        )

        let compose = app.buttons["Compose"].firstMatch
        XCTAssertTrue(
            scrollToHittable(compose, in: app),
            "The Wand Compose action was not reachable.\n\(app.debugDescription)"
        )
        compose.tap()

        let wandSheet = app.navigationBars["The Wand"].firstMatch
        XCTAssertTrue(
            wandSheet.waitForExistence(timeout: 20),
            "The Wand composer did not open.\n\(app.debugDescription)"
        )

        let title = app.textFields["Title (optional)"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText(missionTitle)

        let prompt = app.textViews.firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        prompt.typeText(missionPrompt)

        let pareto = app.buttons["Pareto wand: Best value per quota"].firstMatch
        XCTAssertTrue(
            pareto.waitForExistence(timeout: 20),
            "Pareto was not available to the signed-in account.\n\(app.debugDescription)"
        )
        pareto.tap()
        XCTAssertTrue(
            waitFor(pareto, predicateFormat: "isSelected == true", timeout: 10),
            "Pareto did not become selected.\n\(app.debugDescription)"
        )

        let armedScreenshot = XCTAttachment(screenshot: app.screenshot())
        armedScreenshot.name = "pareto-wand-armed"
        armedScreenshot.lifetime = .keepAlways
        add(armedScreenshot)

        let cast = app.buttons["Cast"].firstMatch
        XCTAssertTrue(
            waitFor(cast, predicateFormat: "exists == true AND isEnabled == true", timeout: 30),
            "Cast never became available for the real mission.\n\(app.debugDescription)"
        )
        cast.tap()

        XCTAssertTrue(
            waitFor(wandSheet, predicateFormat: "exists == false", timeout: 60),
            "The Pareto mission was not accepted.\n\(app.debugDescription)"
        )

        let persistedMissionTitle = app.staticTexts[missionTitle].firstMatch
        XCTAssertTrue(
            persistedMissionTitle.waitForExistence(timeout: 60),
            "The accepted Pareto mission was not read back from Firebase.\n\(app.debugDescription)"
        )

        let dispatchedScreenshot = XCTAttachment(screenshot: app.screenshot())
        dispatchedScreenshot.name = "pareto-wand-dispatched"
        dispatchedScreenshot.lifetime = .keepAlways
        add(dispatchedScreenshot)
    }

    private func liveParetoApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENBURNBAR_APP_CHECK_PROVIDER"] = "appattest"
        return app
    }
}
