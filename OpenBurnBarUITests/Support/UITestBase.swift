import XCTest

class UITestBase: XCTestCase {
    // reason: subclasses share this UI-test helper.
    // swiftlint:disable:next test_case_accessibility
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
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

    // reason: subclasses share this UI-test helper.
    // swiftlint:disable:next test_case_accessibility
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
            "OPENBURNBAR_E2E_HOLD_OPEN": "1"
        ]
        if openSettings {
            app.launchEnvironment["OPENBURNBAR_UITEST_OPEN_SETTINGS"] = "1"
        }
        app.launch()
        self.app = app
        return app
    }

    // reason: subclasses share this UI-test helper.
    // swiftlint:disable:next test_case_accessibility
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    // reason: subclasses share this UI-test helper.
    // swiftlint:disable:next test_case_accessibility
    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Expected element to exist: \(element)", file: file, line: line)
        return element
    }

    // reason: subclasses share this UI-test helper.
    // swiftlint:disable:next test_case_accessibility
    @discardableResult
    func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        waitFor(element, timeout: timeout, file: file, line: line)
        let predicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected element to become hittable: \(element)", file: file, line: line)
        return element
    }
}
