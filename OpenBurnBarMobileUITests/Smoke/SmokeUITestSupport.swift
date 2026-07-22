import XCTest

/// Shared launch + interaction helpers for the Wave-5 deterministic iOS UI
/// smoke suite.
///
/// Every flow launches the app in **AppStoreScreenshotMode**
/// (`-OpenBurnBarAppStoreScreenshots`). That flag routes the app past Firebase
/// auth and Firestore straight to the seeded, signed-in dashboard
/// (`AuthGateView` → `mainSignedInView`) with deterministic in-memory fixtures
/// (`AppStoreScreenshotData`). No network is touched, so these tests are
/// hermetic and reproducible on a plain simulator.
///
/// Determinism rules honored throughout the suite: no `sleep`/`usleep`/
/// `Thread.sleep`. All waiting is done via `waitForExistence(timeout:)` and
/// `XCTNSPredicateExpectation`, both of which poll the live element tree.
///
/// The helpers live on a protocol extension (rather than directly on the
/// `XCTestCase` subclass) so the test classes themselves contain only their
/// test methods.
@MainActor
protocol SmokeUIFlow: AnyObject {}

@MainActor
extension SmokeUIFlow where Self: XCTestCase {

    /// Launch the app in deterministic, no-network screenshot mode.
    ///
    /// - Parameter route: optional `-OpenBurnBarScreenshotRoute` value
    ///   (e.g. `"burn"`, `"you"`). When omitted the app lands on Pulse.
    @discardableResult
    func launchSeededApp(route: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-OpenBurnBarAppStoreScreenshots"]
        if let route {
            app.launchArguments += ["-OpenBurnBarScreenshotRoute", route]
        }
        // Belt-and-suspenders: the same mode is also readable from the
        // environment, which keeps the flag set even if launch-argument
        // parsing is ever reordered.
        app.launchEnvironment["OPENBURNBAR_APP_STORE_SCREENSHOTS"] = "1"
        app.launch()
        return app
    }

    /// Select a floating Aurora nav-tray tab by its `AuroraNavDestination` id
    /// and confirm the tab became selected.
    ///
    /// The tray is not a set of buttons — it is a single `DragGesture`
    /// surface that resolves the touch x-position to a destination. A tap at
    /// the tab element's center normally commits it; if the gesture doesn't
    /// register the tap (it recognizes on movement), we fall back to a minimal
    /// press-and-drag onto the same point. Selection is verified through the
    /// tab's `isSelected` accessibility trait, which mirrors the live
    /// `selection` that drives the visible destination content.
    @discardableResult
    func selectAuroraTab(_ id: String,
                         in app: XCUIApplication,
                         timeout: TimeInterval = 25,
                         file: StaticString = #file,
                         line: UInt = #line) -> XCUIElement {
        let tab = app.buttons["auroraTab.\(id)"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: timeout),
                      "Aurora tab '\(id)' never appeared.\n\(app.debugDescription)",
                      file: file, line: line)
        let center = tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        let selectionCompleted = "isSelected == true OR exists == false"
        if !waitFor(tab, predicateFormat: selectionCompleted, timeout: 4) {
            // Fallback: nudge the drag surface onto the tab center.
            center.press(forDuration: 0.05, thenDragTo: center)
        }
        XCTAssertTrue(waitFor(tab, predicateFormat: selectionCompleted, timeout: 6),
                      "Aurora tab '\(id)' did not become selected or collapse its sidebar after tapping.\n\(app.debugDescription)",
                      file: file, line: line)
        return tab
    }

    /// Deterministically bring `element` on-screen and hittable by swiping up
    /// a bounded number of times. Each iteration re-queries the live tree, so
    /// no fixed sleep is needed. Returns whether the element ended hittable.
    @discardableResult
    func scrollToHittable(_ element: XCUIElement,
                          in app: XCUIApplication,
                          maxSwipes: Int = 14) -> Bool {
        if element.exists && element.isHittable { return true }
        var swipes = 0
        while swipes < maxSwipes {
            app.swipeUp()
            if element.exists && element.isHittable { return true }
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    /// Wait for a boolean element predicate (e.g. `isEnabled == true`) to hold.
    @discardableResult
    func waitFor(_ element: XCUIElement,
                 predicateFormat: String,
                 timeout: TimeInterval = 6) -> Bool {
        let predicate = NSPredicate(format: predicateFormat)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Find a control by accessibility identifier, falling back to its visible
    /// label. Menus and some composed controls surface their items by label
    /// rather than by an identifier set on the inner `Button`.
    func buttonByIdentifierOrLabel(_ identifier: String,
                                   label: String,
                                   in app: XCUIApplication,
                                   timeout: TimeInterval = 8) -> XCUIElement {
        let byID = app.buttons[identifier].firstMatch
        if byID.waitForExistence(timeout: timeout) { return byID }
        return app.buttons[label].firstMatch
    }

    /// A destination-screen marker element (`screen.<name>`), queried across
    /// any element type since it is attached to a container view.
    func screenMarker(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "screen.\(name)").firstMatch
    }
}

/// Base test case for the smoke suite. Only carries the shared lifecycle
/// configuration; all interaction helpers come from `SmokeUIFlow`.
@MainActor
class SmokeUITestCase: XCTestCase, SmokeUIFlow {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
}
