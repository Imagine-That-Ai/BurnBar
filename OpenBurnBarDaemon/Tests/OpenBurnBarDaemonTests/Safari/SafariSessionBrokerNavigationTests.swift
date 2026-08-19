import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class SafariSessionBrokerNavigationTests: XCTestCase {
    func testBrokerEmitsTheExactDaemonArgumentSchemaExpectedByTheExtension() async throws {
        let broker = BurnBarSafariSessionBroker()
        let page = pageState()
        let attach = try await attach(broker: broker, page: page)

        let click = try await commandArguments(
            broker: broker,
            page: page,
            action: SafariActionDescriptor(
                kind: .click,
                safariSessionId: attach.sessionId,
                tabId: page.tabId,
                expectedNavigationEpoch: page.navigationEpoch,
                positionX: 12.5,
                positionY: 24.75
            )
        )
        XCTAssertEqual(click["positionX"], .number(12.5))
        XCTAssertEqual(click["positionY"], .number(24.75))

        let selection = try await commandArguments(
            broker: broker,
            page: page,
            action: SafariActionDescriptor(
                kind: .selectOption,
                safariSessionId: attach.sessionId,
                tabId: page.tabId,
                expectedNavigationEpoch: page.navigationEpoch,
                selector: "#size",
                value: "large"
            )
        )
        XCTAssertEqual(selection["value"], .string("large"))

        let javaScript = try await commandArguments(
            broker: broker,
            page: page,
            action: SafariActionDescriptor(
                kind: .runJavaScript,
                safariSessionId: attach.sessionId,
                tabId: page.tabId,
                expectedNavigationEpoch: page.navigationEpoch,
                script: "return document.title;"
            )
        )
        XCTAssertEqual(javaScript["script"], .string("return document.title;"))
        XCTAssertEqual(javaScript["approved"], .bool(true))

        let fullPage = try await commandArguments(
            broker: broker,
            page: page,
            action: SafariActionDescriptor(
                kind: .fullPageScreenshot,
                safariSessionId: attach.sessionId,
                tabId: page.tabId,
                expectedNavigationEpoch: page.navigationEpoch
            )
        )
        XCTAssertEqual(fullPage["optIn"], .bool(true))
    }

    func testPreCancelledExecutionNeverEnqueuesACommand() async throws {
        let broker = BurnBarSafariSessionBroker(
            configuration: .init(maximumCommandTimeoutMillis: 1_000)
        )
        let page = pageState()
        let attach = try await attach(broker: broker, page: page)
        let started = expectation(description: "pre-cancelled execution entered")
        let execution = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            started.fulfill()
            return try await broker.execute(
                action: SafariActionDescriptor(
                    kind: .pageContext,
                    safariSessionId: attach.sessionId,
                    tabId: page.tabId,
                    expectedNavigationEpoch: page.navigationEpoch
                )
            )
        }
        await fulfillment(of: [started], timeout: 1)
        for _ in 0..<20 {
            await Task.yield()
        }

        let poll = try await broker.poll(
            BurnBarSafariCommandPollRequest(
                sessionId: attach.sessionId,
                activePage: page,
                knownTabs: [tabSnapshot(page)]
            )
        )
        XCTAssertNil(poll.command)
        do {
            _ = try await execution.value
            XCTFail("A pre-cancelled Safari command must fail before it enters the queue.")
        } catch let error as BurnBarSafariSessionBroker.BrokerError {
            XCTAssertEqual(error, .commandCancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testOpenTabClaimsOnlyTheExactCompletionResultDuringConcurrentTabAppearance() async throws {
        let broker = BurnBarSafariSessionBroker()
        let page = pageState()
        let attach = try await attach(broker: broker, page: page)
        let execution = Task {
            try await broker.execute(
                action: SafariActionDescriptor(
                    kind: .openTab,
                    safariSessionId: attach.sessionId,
                    url: "https://example.org/"
                )
            )
        }
        let command = try await nextCommand(
            broker: broker,
            sessionID: attach.sessionId,
            page: page
        )

        let openedResult = tabSnapshot(
            tabID: 9,
            windowID: 3,
            url: "https://example.org/",
            title: "Example",
            isActive: true,
            isOwned: true,
            navigationEpoch: 0
        )
        let openedReported = tabSnapshot(
            tabID: 9,
            windowID: 3,
            url: "https://example.org/",
            title: "Example",
            isActive: false,
            isOwned: true,
            navigationEpoch: 1
        )
        let unrelated = tabSnapshot(
            tabID: 8,
            windowID: 4,
            url: "https://private.example/",
            title: "User tab",
            isActive: true,
            isOwned: false,
            navigationEpoch: 2
        )
        _ = try await broker.complete(
            BurnBarSafariCommandCompletionRequest(
                sessionId: attach.sessionId,
                commandId: command.commandId,
                ok: true,
                result: tabResult(openedResult),
                pageState: pageState(
                    tabID: unrelated.tabId,
                    windowID: unrelated.windowId,
                    url: unrelated.url,
                    title: unrelated.title,
                    navigationEpoch: unrelated.navigationEpoch
                ),
                tabs: [
                    tabSnapshot(page, isActive: false),
                    unrelated,
                    openedReported
                ]
            )
        )
        let response = try await execution.value
        XCTAssertTrue(response.ok)

        let status = try await broker.status(sessionID: attach.sessionId)
        XCTAssertEqual(status.ownedTabIds, [7, 9])
        XCTAssertNil(status.activePage)
    }

    func testOpenTabRejectsMissingAmbiguousMismatchedAndUnreportedResults() async throws {
        let opened = tabSnapshot(
            tabID: 9,
            windowID: 3,
            url: "https://example.org/",
            title: "Example",
            isActive: true,
            isOwned: true,
            navigationEpoch: 0
        )
        let mismatchedWindow = tabSnapshot(
            tabID: 9,
            windowID: 4,
            url: opened.url,
            title: opened.title,
            isActive: true,
            isOwned: true,
            navigationEpoch: opened.navigationEpoch
        )
        let cases: [(name: String, result: BurnBarJSONValue?, tabs: [BurnBarSafariTabSnapshot])] = [
            ("missing result", nil, [opened]),
            ("ambiguous result", tabResult(opened), [opened, opened]),
            ("mismatched result", tabResult(opened), [mismatchedWindow]),
            ("unreported result", tabResult(opened), [])
        ]

        for testCase in cases {
            let broker = BurnBarSafariSessionBroker()
            let page = pageState()
            let attach = try await attach(broker: broker, page: page)
            let execution = Task {
                try await broker.execute(
                    action: SafariActionDescriptor(
                        kind: .openTab,
                        safariSessionId: attach.sessionId,
                        url: "https://example.org/"
                    )
                )
            }
            let command = try await nextCommand(
                broker: broker,
                sessionID: attach.sessionId,
                page: page
            )

            do {
                _ = try await broker.complete(
                    BurnBarSafariCommandCompletionRequest(
                        sessionId: attach.sessionId,
                        commandId: command.commandId,
                        ok: true,
                        result: testCase.result,
                        pageState: pageState(
                            tabID: opened.tabId,
                            windowID: opened.windowId,
                            url: opened.url,
                            title: opened.title,
                            navigationEpoch: opened.navigationEpoch
                        ),
                        tabs: testCase.tabs
                    )
                )
                XCTFail("\(testCase.name) must fail closed.")
            } catch let error as BurnBarSafariSessionBroker.BrokerError {
                XCTAssertEqual(error, .invalidOpenTabResult, testCase.name)
            } catch {
                XCTFail("\(testCase.name) returned an unexpected error: \(error)")
            }
            await broker.abort(sessionID: attach.sessionId)
            _ = try? await execution.value
        }
    }

    func testBrokerForwardsTypedHistoryNavigationWithoutInventingAURL() async throws {
        let broker = BurnBarSafariSessionBroker()
        let page = pageState()
        let attach = try await attach(broker: broker, page: page)

        let execution = Task {
            try await broker.execute(
                action: SafariActionDescriptor(
                    kind: .navigate,
                    safariSessionId: attach.sessionId,
                    tabId: page.tabId,
                    expectedNavigationEpoch: page.navigationEpoch,
                    navigationOperation: .back
                )
            )
        }

        let command = try await nextCommand(
            broker: broker,
            sessionID: attach.sessionId,
            page: page
        )
        let arguments = try XCTUnwrap(command.arguments.objectValue())
        XCTAssertEqual(arguments["operation"], .string("back"))
        XCTAssertNil(arguments["url"])

        _ = try await broker.complete(
            BurnBarSafariCommandCompletionRequest(
                sessionId: attach.sessionId,
                commandId: command.commandId,
                ok: true,
                result: .object(["navigated": .bool(true)]),
                pageState: page,
                tabs: [tabSnapshot(page)]
            )
        )
        let response = try await execution.value
        XCTAssertTrue(response.ok)
    }

    func testSafariNavigationApprovalSummaryDistinguishesHistoryAndReload() {
        let context = ComputerUseScopeContext(
            url: "https://example.com/account",
            bundleId: "com.apple.Safari",
            windowTitle: "Account"
        )

        XCTAssertEqual(
            SafariActionDescriptor(
                kind: .navigate,
                safariSessionId: "session",
                navigationOperation: .back
            ).executableSummary(forApproval: context),
            "Navigate Safari back on example.com"
        )
        XCTAssertEqual(
            SafariActionDescriptor(
                kind: .navigate,
                safariSessionId: "session",
                navigationOperation: .reload
            ).executableSummary(forApproval: context),
            "Reload example.com in Safari"
        )
    }

    private func nextCommand(
        broker: BurnBarSafariSessionBroker,
        sessionID: String,
        page: BurnBarSafariPageState
    ) async throws -> BurnBarSafariCommand {
        for _ in 0..<100 {
            let response = try await broker.poll(
                BurnBarSafariCommandPollRequest(
                    sessionId: sessionID,
                    activePage: page,
                    knownTabs: [tabSnapshot(page)]
                )
            )
            if let command = response.command {
                return command
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the brokered Safari navigation command.")
        throw TestError.commandUnavailable
    }

    private func attach(
        broker: BurnBarSafariSessionBroker,
        page: BurnBarSafariPageState
    ) async throws -> BurnBarSafariSessionAttachResponse {
        try await broker.attach(
            BurnBarSafariSessionAttachRequest(
                extensionInstanceId: "extension-instance-\(UUID().uuidString)",
                clientName: "OpenBurnBar Safari tests",
                activePage: page,
                capabilities: capabilities()
            )
        )
    }

    private func commandArguments(
        broker: BurnBarSafariSessionBroker,
        page: BurnBarSafariPageState,
        action: SafariActionDescriptor
    ) async throws -> [String: BurnBarJSONValue] {
        let execution = Task {
            try await broker.execute(action: action)
        }
        let command = try await nextCommand(
            broker: broker,
            sessionID: action.safariSessionId,
            page: page
        )
        _ = try await broker.complete(
            BurnBarSafariCommandCompletionRequest(
                sessionId: action.safariSessionId,
                commandId: command.commandId,
                ok: true,
                result: .object(["completed": .bool(true)]),
                pageState: page,
                tabs: [tabSnapshot(page)]
            )
        )
        let response = try await execution.value
        XCTAssertTrue(response.ok)
        return try XCTUnwrap(command.arguments.objectValue())
    }

    private func pageState(
        tabID: Int = 7,
        windowID: Int? = 3,
        url: String = "https://example.com/account",
        title: String = "Account",
        navigationEpoch: Int = 11
    ) -> BurnBarSafariPageState {
        BurnBarSafariPageState(
            tabId: tabID,
            windowId: windowID,
            url: url,
            title: title,
            navigationEpoch: navigationEpoch,
            isActive: true
        )
    }

    private func tabSnapshot(
        _ page: BurnBarSafariPageState,
        isActive: Bool? = nil
    ) -> BurnBarSafariTabSnapshot {
        BurnBarSafariTabSnapshot(
            tabId: page.tabId,
            windowId: page.windowId,
            url: page.url,
            title: page.title,
            isActive: isActive ?? page.isActive,
            isOwned: true,
            navigationEpoch: page.navigationEpoch
        )
    }

    private func tabSnapshot(
        tabID: Int,
        windowID: Int?,
        url: String,
        title: String,
        isActive: Bool,
        isOwned: Bool,
        navigationEpoch: Int
    ) -> BurnBarSafariTabSnapshot {
        BurnBarSafariTabSnapshot(
            tabId: tabID,
            windowId: windowID,
            url: url,
            title: title,
            isActive: isActive,
            isOwned: isOwned,
            navigationEpoch: navigationEpoch
        )
    }

    private func tabResult(_ tab: BurnBarSafariTabSnapshot) -> BurnBarJSONValue {
        var object: [String: BurnBarJSONValue] = [
            "tabId": .number(Double(tab.tabId)),
            "url": .string(tab.url),
            "title": .string(tab.title),
            "isActive": .bool(tab.isActive),
            "isOwned": .bool(tab.isOwned),
            "navigationEpoch": .number(Double(tab.navigationEpoch))
        ]
        if let windowID = tab.windowId {
            object["windowId"] = .number(Double(windowID))
        }
        return .object(object)
    }

    private func capabilities() -> BurnBarSafariExtensionCapabilities {
        BurnBarSafariExtensionCapabilities(
            captureVisibleTab: true,
            scripting: true,
            nativeMessaging: true,
            activeTabPermission: true,
            siteAccessGranted: true
        )
    }
}

private enum TestError: Error {
    case commandUnavailable
}
