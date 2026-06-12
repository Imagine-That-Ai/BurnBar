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

        let subscribeButton = app.buttons["cloudStore.subscribe"].firstMatch
        XCTAssertTrue(
            waitForExistence(subscribeButton, timeout: 45, scrollingIn: app),
            "Cloud Store Subscribe button did not appear. \(app.debugDescription)"
        )
        scrollUntilHittable(subscribeButton, in: app)
        XCTAssertTrue(subscribeButton.isHittable, "Cloud Store Subscribe button was visible but not hittable.")

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

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            dragUp(in: app)
        }
    }

    private func waitForExistence(_ element: XCUIElement, timeout: TimeInterval, scrollingIn app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            dragUp(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        return element.exists
    }

    private func dragUp(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        start.press(forDuration: 0.02, thenDragTo: end)
    }
}
