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
        throw XCTSkip("The live Pareto sales proof requires a physical iOS device.")
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

        completeOnboardingIfNeeded(in: app)
        selectAuroraTab("hermes", in: app)

        let compose = app.buttons["Compose"].firstMatch
        XCTAssertTrue(
            compose.waitForExistence(timeout: 30),
            "Hermes Square did not render from the real signed-in device state.\n\(app.debugDescription)"
        )

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

        let hideKeyboard = app.keyboards.buttons["Hide keyboard"].firstMatch
        if hideKeyboard.waitForExistence(timeout: 5) {
            hideKeyboard.tap()
            XCTAssertTrue(
                waitFor(hideKeyboard, predicateFormat: "exists == false", timeout: 10),
                "The iPad keyboard still covered the Wand agent grid.\n\(app.debugDescription)"
            )
        }

        configureLiveParetoAgents(in: app)

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

    private func configureLiveParetoAgents(in app: XCUIApplication) {
        let desiredAgents = Set(["Codex", "Claude"])
        let agentNames = [
            "Hermes", "Pi", "Codex", "Claude", "OpenClaw", "OpenClaude", "OMP",
            "Droid", "Forge", "Antigravity", "Grok Build", "Cursor Agent", "Junie"
        ]

        // First clear every non-target runtime so a stale/default selection can
        // never consume the plan cap or silently send this proof to Junie.
        for name in agentNames where !desiredAgents.contains(name) {
            setWandAgent(name, selected: false, in: app)
        }

        // Return to the top of the sheet, then select the two installed CLIs.
        for _ in 0..<14 {
            app.swipeDown()
        }
        for name in ["Codex", "Claude"] {
            setWandAgent(name, selected: true, in: app)
        }

        for name in agentNames {
            let agent = wandAgent(named: name, in: app)
            let expectedSelection = desiredAgents.contains(name)
            XCTAssertEqual(
                agent.isSelected,
                expectedSelection,
                "Expected only Codex and Claude to be selected; \(name) had the wrong state.\n\(app.debugDescription)"
            )
        }

        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "pareto-codex-claude-only"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)
    }

    private func setWandAgent(
        _ name: String,
        selected: Bool,
        in app: XCUIApplication
    ) {
        let agent = wandAgent(named: name, in: app)
        XCTAssertTrue(
            scrollToHittable(agent, in: app),
            "The \(name) Wand agent was not reachable.\n\(app.debugDescription)"
        )
        if agent.isSelected != selected {
            agent.tap()
        }
        XCTAssertTrue(
            waitFor(agent, predicateFormat: "isSelected == \(selected)", timeout: 10),
            "The \(name) Wand agent did not become \(selected ? "selected" : "deselected").\n\(app.debugDescription)"
        )
    }

    private func wandAgent(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", name)
        ).firstMatch
    }

    private func completeOnboardingIfNeeded(in app: XCUIApplication) {
        let welcome = app.staticTexts["Welcome to OpenBurnBar"].firstMatch
        let completion = app.staticTexts["You're all set"].firstMatch
        let getStarted = app.buttons["Get started"].firstMatch
        let skip = app.buttons["Skip"].firstMatch

        if welcome.waitForExistence(timeout: 5) {
            getStarted.tap()
            XCTAssertTrue(
                skip.waitForExistence(timeout: 10),
                "Onboarding did not expose its skip action.\n\(app.debugDescription)"
            )
            skip.tap()
        } else if completion.exists {
            getStarted.tap()
        } else if skip.waitForExistence(timeout: 2) {
            skip.tap()
        } else {
            return
        }

        XCTAssertTrue(
            waitFor(skip, predicateFormat: "exists == false", timeout: 20)
                && waitFor(completion, predicateFormat: "exists == false", timeout: 20),
            "Onboarding still covered the signed-in app after completion.\n\(app.debugDescription)"
        )
    }

    private func liveParetoApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENBURNBAR_APP_CHECK_PROVIDER"] = "appattest"
        return app
    }
}
