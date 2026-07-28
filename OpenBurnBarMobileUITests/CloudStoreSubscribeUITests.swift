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
