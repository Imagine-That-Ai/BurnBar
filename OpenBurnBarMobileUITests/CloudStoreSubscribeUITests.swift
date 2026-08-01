import XCTest

@MainActor
final class CloudStoreSubscribeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testIPadCloudStoreSubscribeTapPresentsStoreKitPurchaseConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OPENBURNBAR_E2E_ROUTE"] = "cloud-store"
        app.launchEnvironment["OPENBURNBAR_E2E_CLOUD_STORE_GUEST"] = "1"
        app.launch()

        let storeScrollView = app.scrollViews["cloudStore.scrollView"].firstMatch
        XCTAssertTrue(
            storeScrollView.waitForExistence(timeout: 45),
            "Cloud Store scroll view did not appear. \(app.debugDescription)"
        )

        let subscribeButton = app.buttons[
            "cloudStore.tier.com.openburnbar.pro.monthly.subscribe"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(subscribeButton, timeout: 45, scrollingIn: storeScrollView),
            "BurnBar Cloud monthly Subscribe button did not appear. \(app.debugDescription)"
        )
        scrollUntilHittable(subscribeButton, in: storeScrollView)
        XCTAssertTrue(
            subscribeButton.isHittable,
            "BurnBar Cloud monthly Subscribe button was visible but not hittable."
        )

        subscribeButton.tap()

        XCTAssertTrue(
            waitForStoreKitConfirmation(in: app, timeout: 25),
            "Tapping Subscribe did not present the StoreKit confirmation UI. \(app.debugDescription)"
        )
    }

    private func waitForStoreKitConfirmation(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let storeKitUIService = XCUIApplication(bundleIdentifier: "com.apple.StoreKitUIService")
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if containsPurchaseConfirmation(in: app)
                || containsPurchaseConfirmation(in: springboard)
                || containsPurchaseConfirmation(in: storeKitUIService) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        return containsPurchaseConfirmation(in: app)
            || containsPurchaseConfirmation(in: springboard)
            || containsPurchaseConfirmation(in: storeKitUIService)
    }

    private func containsPurchaseConfirmation(in app: XCUIApplication) -> Bool {
        let candidates = [
            "Confirm Subscription",
            "Confirm with Side Button",
            "OpenBurnBar Cloud Monthly",
            "StoreKit Testing",
            "Sandbox",
            "Apple ID",
            "Double Click to Pay"
        ]

        for candidate in candidates
        where app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", candidate))
            .firstMatch
            .exists {
            return true
        }

        let subscribeButtons = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Subscribe")
        )
        return subscribeButtons.count > 1
    }

    private func scrollUntilHittable(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            scrollView.swipeUp()
        }
    }

    private func waitForExistence(
        _ element: XCUIElement,
        timeout: TimeInterval,
        scrollingIn scrollView: XCUIElement
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            scrollView.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        return element.exists
    }
}

@MainActor
final class PhysicalTouchIDPromptDismissUITests: XCTestCase {
    func testDismissVisibleTouchIDPrompt() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancel = springboard.buttons[
            "com.apple.localauthentication.ax.authentication.button.cancel"
        ].firstMatch

        if cancel.waitForExistence(timeout: 5), cancel.isHittable {
            cancel.tap()
            return
        }

        let alert = springboard.alerts[
            "com.apple.localauthentication.ax.authentication.alert"
        ].firstMatch
        guard alert.waitForExistence(timeout: 2) else {
            throw XCTSkip("No LocalAuthentication prompt is visible.")
        }

        // Physical-device LocalAuthentication overlays can expose duplicate,
        // inaccessible Cancel elements. Only after proving the alert exists,
        // use its stable lower action area as a narrow UI-test fallback.
        springboard.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.575)
        ).tap()
    }
}

@MainActor
final class PhysicalIPadMercuryE2EUITests: XCTestCase {
    private var configuredPeerName: String? {
        let configured = ProcessInfo.processInfo.environment["OPENBURNBAR_UI_TEST_PEER_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return configured
        }
        return nil
    }

    private var sustainedStreamingSeconds: TimeInterval {
        let configured = ProcessInfo.processInfo.environment[
            "OPENBURNBAR_UI_TEST_SUSTAINED_SECONDS"
        ]
        guard let configured,
              let seconds = TimeInterval(configured),
              seconds >= 0
        else {
            return 190
        }
        return seconds
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMirrorStopReconnect() throws {
        let app = XCUIApplication()
        app.launch()
        dismissTouchIDPromptIfPresent(timeout: 3)

        if !waitForAgentsRoute(in: app, timeout: 8) {
            // The signed-in app can ask for its Secure Enclave identity while
            // the dashboard is settling. Dismiss that system overlay before
            // querying the app hierarchy; otherwise XCTest temporarily sees
            // no sidebar elements at all.
            dismissTouchIDPromptIfPresent(timeout: 3)
            let sidebarAgents = app.buttons["sidebar.destination.agents"].firstMatch
            if sidebarAgents.waitForExistence(timeout: 20) {
                if sidebarAgents.isHittable {
                    sidebarAgents.tap()
                } else {
                    // On a physical iPad, NavigationSplitView can expose the
                    // visible sidebar button before XCTest marks it hittable.
                    // A center-coordinate tap still targets only the proved
                    // Agents button and avoids falling through to the
                    // compact-width deep-link path.
                    sidebarAgents.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                    ).tap()
                }
            } else {
                // Compact-width fallback for running the same physical test on
                // an iPhone without weakening the iPad path.
                app.open(URL(string: "burnbar://hermes")!)
            }
        }
        if !waitForAgentsRoute(in: app, timeout: 20) {
            let hermesTab = app.buttons["auroraTab.hermes"].firstMatch
            XCTAssertTrue(
                hermesTab.waitForExistence(timeout: 20) && hermesTab.isHittable,
                "Agents route did not appear and the compact navigation control was not hittable. \(app.debugDescription)"
            )
            hermesTab.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
        }
        XCTAssertTrue(
            waitForAgentsRoute(in: app, timeout: 20),
            "Agents screen did not appear. \(app.debugDescription)"
        )

        let pairedMacTile = app.descendants(matching: .any)
            .matching(identifier: "agent.tile.paired-mac")
            .firstMatch
        let peer: XCUIElement
        if pairedMacTile.waitForExistence(timeout: 45) {
            peer = pairedMacTile
        } else if let configuredPeerName {
            peer = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", configuredPeerName)
            ).firstMatch
        } else {
            peer = pairedMacTile
        }
        XCTAssertTrue(
            peer.waitForExistence(timeout: 45),
            "The paired Mac tile did not appear. \(app.debugDescription)"
        )
        peer.tap()

        let liveSheet = app.scrollViews.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Mercury Live for")
        ).firstMatch
        XCTAssertTrue(liveSheet.waitForExistence(timeout: 45))

        try requestMirror(in: app)
        XCTAssertTrue(waitForStreamingVideo(in: app, timeout: 180))
        attachScreenshot(named: "01-connected")
        RunLoop.current.run(
            until: Date().addingTimeInterval(sustainedStreamingSeconds)
        )
        attachScreenshot(named: "02-connected-later")

        closeMirror(in: app)

        let ask = app.buttons["Ask to mirror Mac screen"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 45))
        attachScreenshot(named: "03-disconnected")

        try requestMirror(in: app)
        XCTAssertTrue(waitForStreamingVideo(in: app, timeout: 180))
        attachScreenshot(named: "04-reconnected")
    }

    private func waitForAgentsRoute(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let agentsScreen = app.descendants(matching: .any)
            .matching(identifier: "screen.agents")
            .firstMatch
        let agentsNavigationBar = app.navigationBars["Agents"].firstMatch
        let pairedMacTile = app.descendants(matching: .any)
            .matching(identifier: "agent.tile.paired-mac")
            .firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if agentsScreen.exists || agentsNavigationBar.exists || pairedMacTile.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return agentsScreen.exists || agentsNavigationBar.exists || pairedMacTile.exists
    }

    private func requestMirror(in app: XCUIApplication) throws {
        let ask = app.buttons["Ask to mirror Mac screen"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 45))
        XCTAssertTrue(ask.isEnabled)
        ask.tap()

        // The production Secure Enclave key may request Touch ID while
        // deriving an optional controller identity. Cancelling this prompt
        // keeps the mirror request read-only and allows frame/reconnect QA;
        // real input QA still requires a live biometric match.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        dismissTouchIDPromptIfPresent(timeout: 2)
    }

    private func dismissTouchIDPromptIfPresent(timeout: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts[
            "com.apple.localauthentication.ax.authentication.alert"
        ].firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }

        let cancel = springboard.buttons[
            "com.apple.localauthentication.ax.authentication.button.cancel"
        ].firstMatch
        if cancel.exists, cancel.isHittable {
            cancel.tap()
            return
        }

        springboard.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.575)
        ).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func waitForStreamingVideo(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let video = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "mercury.screen.video")
        ).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if video.exists, video.value as? String == "Streaming" {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        attachScreenshot(named: "streaming-timeout")
        return video.exists && video.value as? String == "Streaming"
    }

    private func closeMirror(in app: XCUIApplication) {
        let close = app.buttons["Close mirror"].firstMatch
        if !close.exists {
            let openControls = app.buttons["Open mirror controls"].firstMatch
            XCTAssertTrue(openControls.waitForExistence(timeout: 20))
            openControls.tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        close.tap()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
