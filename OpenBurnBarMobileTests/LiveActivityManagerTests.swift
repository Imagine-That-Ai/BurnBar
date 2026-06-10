#if canImport(ActivityKit) && canImport(UIKit)
import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

@MainActor
final class LiveActivityManagerTests: XCTestCase {
    func test_startUpdateEnd_routesThroughBackend() async throws {
        guard #available(iOS 16.1, *) else { throw XCTSkip("ActivityKit requires iOS 16.1+") }
        let backend = StubBurnBarLiveActivityBackend()
        let manager = LiveActivityManager(backend: backend)

        manager.startActivity(cost: 3.42, tokens: 1_200, provider: "anthropic", sessionActive: true)

        XCTAssertTrue(manager.hasActiveActivity)
        XCTAssertEqual(backend.requests.count, 1)
        XCTAssertEqual(backend.requests.first?.attributes.heroTitle, "Today's Burn")
        XCTAssertEqual(
            backend.requests.first?.state,
            BurnBarLiveActivityAttributes.ContentState(
                heroCost: 3.42,
                heroTokens: 1_200,
                topProvider: "anthropic",
                sessionActive: true
            )
        )

        let handle = try XCTUnwrap(backend.handles.first)
        let updated = expectation(description: "update routed to handle")
        handle.onUpdate = { updated.fulfill() }

        manager.updateActivity(cost: 4.10, tokens: 1_500, provider: "anthropic", sessionActive: false)

        await fulfillment(of: [updated], timeout: 1.0)
        XCTAssertEqual(
            handle.updates,
            [
                BurnBarLiveActivityAttributes.ContentState(
                    heroCost: 4.10,
                    heroTokens: 1_500,
                    topProvider: "anthropic",
                    sessionActive: false
                )
            ]
        )

        let ended = expectation(description: "end routed to handle")
        handle.onEndFinished = { ended.fulfill() }

        manager.endActivity()

        // The reference must clear synchronously, before the async end lands.
        XCTAssertFalse(manager.hasActiveActivity)
        await fulfillment(of: [ended], timeout: 1.0)
        XCTAssertEqual(handle.endCount, 1)
    }

    func test_startActivity_whenActivitiesDisabled_doesNotRequest() throws {
        guard #available(iOS 16.1, *) else { throw XCTSkip("ActivityKit requires iOS 16.1+") }
        let backend = StubBurnBarLiveActivityBackend()
        backend.areActivitiesEnabled = false
        let manager = LiveActivityManager(backend: backend)

        manager.startActivity(cost: 1.0, tokens: 100, provider: "openai", sessionActive: true)

        XCTAssertFalse(manager.hasActiveActivity)
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func test_startActivity_requestFailure_leavesNoActiveActivity() throws {
        guard #available(iOS 16.1, *) else { throw XCTSkip("ActivityKit requires iOS 16.1+") }
        let backend = StubBurnBarLiveActivityBackend()
        backend.requestError = StubBurnBarLiveActivityBackend.Error()
        let manager = LiveActivityManager(backend: backend)

        manager.startActivity(cost: 1.0, tokens: 100, provider: "openai", sessionActive: true)

        XCTAssertFalse(manager.hasActiveActivity)
        XCTAssertEqual(backend.requests.count, 1)
    }

    /// Regression for the end/start race: an in-flight `end` Task must never
    /// nil out an activity requested after `endActivity()` returned, which
    /// previously orphaned the new Lock Screen activity and made the next
    /// rollup snapshot request a duplicate.
    func test_endThenRestart_inFlightEndDoesNotOrphanNewActivity() async throws {
        guard #available(iOS 16.1, *) else { throw XCTSkip("ActivityKit requires iOS 16.1+") }
        let backend = StubBurnBarLiveActivityBackend()
        let manager = LiveActivityManager(backend: backend)

        manager.startActivity(cost: 1.0, tokens: 100, provider: "anthropic", sessionActive: true)
        let firstHandle = try XCTUnwrap(backend.handles.first)
        firstHandle.suspendEnd = true

        let firstEndSuspended = expectation(description: "first end suspended")
        firstHandle.onEndStarted = { firstEndSuspended.fulfill() }
        let firstEndFinished = expectation(description: "first end finished")
        firstHandle.onEndFinished = { firstEndFinished.fulfill() }

        // Overlapping ends (e.g. two stores calling stopListening) collapse to
        // one backend end; the reference clears synchronously either way.
        manager.endActivity()
        manager.endActivity()
        XCTAssertFalse(manager.hasActiveActivity)

        manager.startActivity(cost: 2.0, tokens: 200, provider: "openai", sessionActive: false)
        XCTAssertTrue(manager.hasActiveActivity)
        XCTAssertEqual(backend.handles.count, 2)

        // Let the suspended end of the FIRST activity complete after the
        // SECOND was requested; the new activity must survive it.
        await fulfillment(of: [firstEndSuspended], timeout: 1.0)
        firstHandle.resumeEnd()
        await fulfillment(of: [firstEndFinished], timeout: 1.0)

        XCTAssertEqual(firstHandle.endCount, 1)
        XCTAssertTrue(manager.hasActiveActivity)

        // Updates still route to the new activity, proving it was not orphaned.
        let secondHandle = try XCTUnwrap(backend.handles.last)
        let updated = expectation(description: "update routed to new handle")
        secondHandle.onUpdate = { updated.fulfill() }

        manager.updateActivity(cost: 2.5, tokens: 250, provider: "openai", sessionActive: false)

        await fulfillment(of: [updated], timeout: 1.0)
        XCTAssertEqual(secondHandle.updates.count, 1)
        XCTAssertTrue(firstHandle.updates.isEmpty)
    }
}

@available(iOS 16.1, *)
@MainActor
private final class StubBurnBarLiveActivityBackend: BurnBarLiveActivityBackend {
    struct Error: Swift.Error {}

    struct Request {
        var attributes: BurnBarLiveActivityAttributes
        var state: BurnBarLiveActivityAttributes.ContentState
    }

    var areActivitiesEnabled = true
    var requestError: Swift.Error?
    private(set) var requests: [Request] = []
    private(set) var handles: [StubBurnBarLiveActivityHandle] = []

    func request(
        attributes: BurnBarLiveActivityAttributes,
        state: BurnBarLiveActivityAttributes.ContentState
    ) throws -> any BurnBarLiveActivityHandle {
        requests.append(Request(attributes: attributes, state: state))
        if let requestError { throw requestError }
        let handle = StubBurnBarLiveActivityHandle()
        handles.append(handle)
        return handle
    }
}

@available(iOS 16.1, *)
@MainActor
private final class StubBurnBarLiveActivityHandle: BurnBarLiveActivityHandle {
    private(set) var updates: [BurnBarLiveActivityAttributes.ContentState] = []
    private(set) var endCount = 0

    /// When true, `end()` parks on a continuation until `resumeEnd()` is
    /// called, modeling an in-flight ActivityKit end.
    var suspendEnd = false
    var onUpdate: (() -> Void)?
    var onEndStarted: (() -> Void)?
    var onEndFinished: (() -> Void)?
    private var pendingEnd: CheckedContinuation<Void, Never>?

    func update(_ state: BurnBarLiveActivityAttributes.ContentState) async {
        updates.append(state)
        onUpdate?()
    }

    func end() async {
        onEndStarted?()
        if suspendEnd {
            await withCheckedContinuation { pendingEnd = $0 }
        }
        endCount += 1
        onEndFinished?()
    }

    func resumeEnd() {
        pendingEnd?.resume()
        pendingEnd = nil
    }
}
#endif
