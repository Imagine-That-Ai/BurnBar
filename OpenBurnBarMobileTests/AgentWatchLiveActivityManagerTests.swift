#if canImport(ActivityKit) && canImport(UIKit)
import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

@MainActor
final class AgentWatchLiveActivityManagerTests: XCTestCase {
    func test_startUpdateEnd_routesThroughBackendAndSkipsDuplicateStart() throws {
        guard #available(iOS 16.1, *) else { throw XCTSkip("ActivityKit requires iOS 16.1+") }
        let backend = StubAgentWatchLiveActivityBackend()
        let manager = AgentWatchLiveActivityManager(backend: backend)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        manager.start(sessionId: "session-1", startedAt: startedAt)
        manager.start(sessionId: "session-1", startedAt: startedAt.addingTimeInterval(10))

        XCTAssertTrue(manager.hasActiveActivity)
        XCTAssertEqual(backend.starts.count, 1)
        XCTAssertEqual(backend.starts.first?.sessionId, "session-1")
        XCTAssertEqual(backend.starts.first?.startedAt, startedAt)
        XCTAssertEqual(
            backend.starts.first?.initialState,
            AgentWatchLiveActivityAttributes.ContentState(
                appName: "Agent Live",
                lastAction: "Watching Mac",
                actionsCount: 0,
                approvalPending: false,
                elapsed: 0
            )
        )

        manager.update(
            appName: "Xcode",
            lastAction: "Edited RootTabView.swift",
            actionsCount: 7,
            approvalPending: true,
            elapsed: 42
        )

        XCTAssertEqual(
            backend.updates,
            [
                AgentWatchLiveActivityAttributes.ContentState(
                    appName: "Xcode",
                    lastAction: "Edited RootTabView.swift",
                    actionsCount: 7,
                    approvalPending: true,
                    elapsed: 42
                )
            ]
        )

        manager.end()

        XCTAssertFalse(manager.hasActiveActivity)
        XCTAssertEqual(backend.endCount, 1)
    }

    func test_startFailureClearsBackendState() throws {
        guard #available(iOS 16.1, *) else { throw XCTSkip("ActivityKit requires iOS 16.1+") }
        let backend = StubAgentWatchLiveActivityBackend()
        backend.activeSessionId = "stale-session"
        backend.requestError = StubAgentWatchLiveActivityBackend.Error()
        let manager = AgentWatchLiveActivityManager(backend: backend)

        manager.start(sessionId: "session-2", startedAt: Date())

        XCTAssertFalse(manager.hasActiveActivity)
        XCTAssertEqual(backend.endCount, 1)
    }

    func test_liveActivityIntentRouterQueuesCommandUntilAppHandlerIsInstalled() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Live Activity intents require iOS 17+") }
        AgentWatchLiveActivityIntentRouter.resetForTesting()
        defer { AgentWatchLiveActivityIntentRouter.resetForTesting() }

        await AgentWatchLiveActivityIntentRouter.perform(.approve)

        let routed = expectation(description: "queued command routed")
        var received: [AgentWatchLiveActivityCommand] = []
        AgentWatchLiveActivityIntentRouter.install { command in
            received.append(command)
            routed.fulfill()
        }

        await fulfillment(of: [routed], timeout: 1.0)
        XCTAssertEqual(received, [.approve])
    }

    func test_liveActivityIntentRouterPreservesCommandsAddedWhileQueueDrains() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Live Activity intents require iOS 17+") }
        AgentWatchLiveActivityIntentRouter.resetForTesting()
        defer { AgentWatchLiveActivityIntentRouter.resetForTesting() }

        await AgentWatchLiveActivityIntentRouter.perform(.approve)

        let routed = expectation(description: "queued and reentrant commands routed")
        routed.expectedFulfillmentCount = 2
        var received: [AgentWatchLiveActivityCommand] = []
        AgentWatchLiveActivityIntentRouter.install { command in
            received.append(command)
            routed.fulfill()
            if command == .approve {
                await AgentWatchLiveActivityIntentRouter.perform(.halt)
            }
        }

        await fulfillment(of: [routed], timeout: 1.0)
        XCTAssertEqual(received, [.approve, .halt])
    }
}

@available(iOS 16.1, *)
@MainActor
private final class StubAgentWatchLiveActivityBackend: AgentWatchLiveActivityBackend {
    struct Error: Swift.Error {}

    struct Start: Equatable {
        var sessionId: String
        var startedAt: Date
        var initialState: AgentWatchLiveActivityAttributes.ContentState
    }

    var activeSessionId: String?
    var starts: [Start] = []
    var updates: [AgentWatchLiveActivityAttributes.ContentState] = []
    var endCount = 0
    var requestError: Swift.Error?

    func request(
        sessionId: String,
        startedAt: Date,
        initialState: AgentWatchLiveActivityAttributes.ContentState
    ) throws {
        starts.append(Start(sessionId: sessionId, startedAt: startedAt, initialState: initialState))
        if let requestError { throw requestError }
        activeSessionId = sessionId
    }

    func update(_ state: AgentWatchLiveActivityAttributes.ContentState) {
        guard activeSessionId != nil else { return }
        updates.append(state)
    }

    func end() {
        endCount += 1
        activeSessionId = nil
    }
}
#endif
