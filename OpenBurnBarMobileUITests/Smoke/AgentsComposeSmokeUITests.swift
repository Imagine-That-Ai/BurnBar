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

    func testWandAgentSelectorIgnoresReplyNotifications() {
        let predicate = wandAgentLabelPredicate(named: "Antigravity")

        XCTAssertTrue(predicate.evaluate(with: ["label": "Antigravity"]))
        XCTAssertTrue(predicate.evaluate(with: ["label": "Antigravity, selected"]))
        XCTAssertFalse(
            predicate.evaluate(with: [
                "label": "Antigravity replied. OpenBurnBar has a new agent reply."
            ])
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
              !missionPrompt.isEmpty,
              let expectedReply = environment["OPENBURNBAR_LIVE_WAND_EXPECTED_REPLY"],
              !expectedReply.isEmpty else {
            XCTFail("The live Pareto proof requires a unique mission title, prompt, and exact expected reply.")
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
        focusAndTypeText(missionTitle, into: title, in: app)

        let prompt = app.textViews.firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        focusAndTypeText(missionPrompt, into: prompt, in: app)

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

        let cast = app.buttons["wand.cast"].firstMatch
        XCTAssertTrue(
            waitFor(cast, predicateFormat: "exists == true AND isEnabled == true", timeout: 30),
            "Cast never became available for the real mission.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            cast.isHittable,
            "The visible Cast action was covered by another view.\n\(app.debugDescription)"
        )
        XCTAssertEqual(
            cast.value as? String,
            "claude,codex",
            "The real Pareto proof must dispatch only Claude and Codex.\n\(app.debugDescription)"
        )
        cast.tap()

        XCTAssertTrue(
            waitFor(wandSheet, predicateFormat: "exists == false", timeout: 180),
            "The Pareto mission was not accepted.\n\(app.debugDescription)"
        )

        let persistedMissionTitle = app.staticTexts[missionTitle].firstMatch
        XCTAssertTrue(
            persistedMissionTitle.waitForExistence(timeout: 90),
            "The accepted Pareto mission was not read back from Firebase.\n\(app.debugDescription)"
        )

        let approvalHeading = app.staticTexts["Approvals waiting"].firstMatch
        XCTAssertTrue(
            approvalHeading.waitForExistence(timeout: 180),
            "The real Claude and Codex approval requests did not reach the iPad.\n\(app.debugDescription)"
        )

        let approvalButtons = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "mission.approval.approve.",
                missionTitle
            )
        )
        for approvalNumber in 1...2 {
            let approve = approvalButtons.firstMatch
            XCTAssertTrue(
                approve.waitForExistence(timeout: 180),
                "Approval \(approvalNumber) of 2 never appeared on the iPad.\n\(app.debugDescription)"
            )
            let handledIdentifier = approve.identifier
            XCTAssertFalse(handledIdentifier.isEmpty)
            XCTAssertTrue(
                scrollApprovalToHittable(approve, in: app),
                "Approval \(approvalNumber) was present but could not be brought onscreen.\n\(app.debugDescription)"
            )
            approve.tap()
            XCTAssertTrue(
                waitFor(
                    app.buttons[handledIdentifier].firstMatch,
                    predicateFormat: "exists == false",
                    timeout: 90
                ),
                "Approval \(approvalNumber) was not accepted.\n\(app.debugDescription)"
            )
        }
        XCTAssertTrue(
            waitForElementCount(approvalButtons, atMost: 0, timeout: 30),
            "The approval inbox did not clear after both approvals.\n\(app.debugDescription)"
        )

        let readyToMerge = app.staticTexts["Ready to merge"].firstMatch
        XCTAssertTrue(
            readyToMerge.waitForExistence(timeout: 300),
            "The real Claude and Codex child missions did not both reach a terminal state.\n\(app.debugDescription)"
        )

        let exactReplies = app.staticTexts.matching(
            NSPredicate(format: "label == %@", expectedReply)
        )
        XCTAssertTrue(
            waitForElementCount(exactReplies, atLeast: 2, timeout: 30),
            "Pareto did not show the exact successful reply from both Claude and Codex.\n\(app.debugDescription)"
        )

        let dispatchedScreenshot = XCTAttachment(screenshot: app.screenshot())
        dispatchedScreenshot.name = "pareto-wand-claude-codex-completed"
        dispatchedScreenshot.lifetime = .keepAlways
        add(dispatchedScreenshot)

        app.terminate()
        app.launch()
        completeOnboardingIfNeeded(in: app)
        selectAuroraTab("hermes", in: app)

        XCTAssertTrue(
            app.staticTexts[missionTitle].firstMatch.waitForExistence(timeout: 90),
            "The completed Pareto mission disappeared after the iPad app restarted.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.staticTexts["Ready to merge"].firstMatch.waitForExistence(timeout: 90),
            "The completed Pareto state was not restored after restart.\n\(app.debugDescription)"
        )
        let restoredReplies = app.staticTexts.matching(
            NSPredicate(format: "label == %@", expectedReply)
        )
        XCTAssertTrue(
            waitForElementCount(restoredReplies, atLeast: 2, timeout: 90),
            "Claude and Codex results were not restored after restart.\n\(app.debugDescription)"
        )

        let restoredScreenshot = XCTAttachment(screenshot: app.screenshot())
        restoredScreenshot.name = "pareto-wand-restored-after-relaunch"
        restoredScreenshot.lifetime = .keepAlways
        add(restoredScreenshot)
    }

    private func configureLiveParetoAgents(in app: XCUIApplication) {
        // A fresh Wand sheet defaults to Claude, Codex, and Hermes. Keep the
        // installed CLIs and remove Hermes without scrolling the interactive
        // sheet through lazily loaded rows (which can dismiss the sheet).
        setWandAgent("claude", displayName: "Claude", selected: true, in: app)
        setWandAgent("codex", displayName: "Codex", selected: true, in: app)
        setWandAgent("hermes", displayName: "Hermes", selected: false, in: app)

        let cast = app.buttons["wand.cast"].firstMatch
        XCTAssertTrue(cast.waitForExistence(timeout: 10))
        XCTAssertEqual(
            cast.value as? String,
            "claude,codex",
            "The Wand selector retained an unexpected runtime before Pareto was armed.\n\(app.debugDescription)"
        )

        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "pareto-codex-claude-only"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)
    }

    private func setWandAgent(
        _ runtimeID: String,
        displayName: String,
        selected: Bool,
        in app: XCUIApplication
    ) {
        let agent = app.buttons["wand.agent.\(runtimeID)"].firstMatch
        XCTAssertTrue(
            scrollToHittable(agent, in: app),
            "The \(displayName) Wand agent was not reachable.\n\(app.debugDescription)"
        )
        if agent.isSelected != selected {
            agent.tap()
        }
        XCTAssertTrue(
            waitFor(agent, predicateFormat: "isSelected == \(selected)", timeout: 10),
            "The \(displayName) Wand agent did not become \(selected ? "selected" : "deselected").\n\(app.debugDescription)"
        )
    }

    private func wandAgent(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(wandAgentLabelPredicate(named: name)).firstMatch
    }

    private func wandAgentLabelPredicate(named name: String) -> NSPredicate {
        NSPredicate(
            format: "label == %@ OR label == %@",
            name,
            "\(name), selected"
        )
    }

    private func waitForElementCount(
        _ query: XCUIElementQuery,
        atLeast expectedCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if query.count >= expectedCount { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return query.count >= expectedCount
    }

    private func waitForElementCount(
        _ query: XCUIElementQuery,
        atMost expectedCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if query.count <= expectedCount { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return query.count <= expectedCount
    }

    private func scrollApprovalToHittable(
        _ approval: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 14
    ) -> Bool {
        if approval.exists && approval.isHittable { return true }

        let containingScrollView = app.scrollViews
            .containing(.button, identifier: approval.identifier)
            .firstMatch
        guard containingScrollView.waitForExistence(timeout: 5) else { return false }

        for _ in 0..<maxSwipes {
            containingScrollView.swipeDown()
            if approval.exists && approval.isHittable { return true }
        }
        return approval.exists && approval.isHittable
    }

    private func focusAndTypeText(
        _ text: String,
        into element: XCUIElement,
        in app: XCUIApplication,
        maxAttempts: Int = 3
    ) {
        for _ in 0..<maxAttempts {
            element.tap()
            if waitFor(element, predicateFormat: "hasKeyboardFocus == true", timeout: 3) {
                element.typeText(text)
                return
            }
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 1)
        }

        XCTFail(
            "The Wand text field never received keyboard focus.\n\(app.debugDescription)"
        )
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
