import XCTest

class UITestBase: XCTestCase {
    var app: XCUIApplication!
    /// Per-test isolated Application Support root so each test gets a fresh,
    /// ephemerally-keyed store. Stable across a relaunch within the same test so
    /// persistence assertions hold.
    private var supportRoot: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        supportRoot = NSTemporaryDirectory()
            + "openburnbar-uitest-" + UUID().uuidString
    }

    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0, let app {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Failure screenshot"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            let axTree = XCTAttachment(string: app.debugDescription)
            axTree.name = "Accessibility tree"
            axTree.lifetime = .keepAlways
            add(axTree)
        }
        app = nil
    }

    @discardableResult
    func launchApp(openSettings: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitest",
            "-ApplePersistenceIgnoreState", "YES",
            "-hasOnboarded", "YES",
            "-hasShownInitialDashboard", "YES",
            "-conversationIndexingConsentShown", "YES",
            "-cliAssistantConsentShown", "YES"
        ]
        app.launchEnvironment = [
            "OPENBURNBAR_UITEST": "1",
            "OPENBURNBAR_ALLOW_MULTIPLE_INSTANCES": "1",
            "OPENBURNBAR_DISABLE_UPDATE_CHECK": "1",
            "OPENBURNBAR_E2E_HOLD_OPEN": "1",
            "OPENBURNBAR_SUPPORT_ROOT": supportRoot
        ]
        if openSettings {
            app.launchEnvironment["OPENBURNBAR_UITEST_OPEN_SETTINGS"] = "1"
        }
        app.launch()
        self.app = app
        return app
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Expected element to exist: \(element)", file: file, line: line)
        return element
    }

    @discardableResult
    func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 15, scrollContainer: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        waitFor(element, timeout: timeout, file: file, line: line)
        // The settings sidebar is taller than the window, so lower rows exist but
        // are not hittable until scrolled into view. Scroll the container (an
        // Outline/ScrollView) — scrolling the target row itself does nothing.
        if !element.isHittable, let container = scrollContainer {
            for _ in 0..<12 where !element.isHittable {
                container.scroll(byDeltaX: 0, deltaY: -90)
            }
        }
        let predicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected element to become hittable: \(element)", file: file, line: line)
        return element
    }

    /// Waits for an element to report a selected state (radio/segmented value of
    /// 1, a "selected" trait, or isSelected).
    @discardableResult
    func waitForSelected(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSelectedValue(element) { return true }
            _ = element.waitForExistence(timeout: 0.3)
        }
        return isSelectedValue(element)
    }

    func isSelectedValue(_ element: XCUIElement) -> Bool {
        if element.isSelected { return true }
        if let value = element.value as? String {
            return value == "1" || value.localizedCaseInsensitiveContains("selected")
        }
        if let value = element.value as? Int { return value == 1 }
        if let value = element.value as? Bool { return value }
        return false
    }
}

