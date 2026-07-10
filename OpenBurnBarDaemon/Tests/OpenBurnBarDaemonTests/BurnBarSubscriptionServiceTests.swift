import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarSubscriptionServiceTests: XCTestCase {
    func testStartAndResumeAdvanceMonotonicNonterminalCursor() async throws {
        let service = makeService(sessionID: "daemon-a")
        let started = try await service.start(
            BurnBarSubscriptionStartRequest(
                topic: "data",
                requestedSubscriptionID: "desktop-data",
                clientID: "linux-desktop"
            )
        )

        XCTAssertEqual(started.seq, 1)
        XCTAssertEqual(started.cursor, "1")
        XCTAssertTrue(started.firstSnapshot)
        XCTAssertTrue(started.degradedFallback)
        XCTAssertEqual(started.degradationReason, "bounded_pull_over_burnbarrpc_envelope")
        XCTAssertFalse(started.terminalStateDelivered)
        XCTAssertEqual(started.events.first?.terminal, false)
        XCTAssertEqual(started.events.first?.snapshot["daemon_session_id"], "daemon-a")

        let resumed = try await service.resume(
            BurnBarSubscriptionResumeRequest(
                subscriptionID: started.subscriptionID,
                topic: "data",
                afterSeq: started.seq,
                clientID: "linux-desktop"
            )
        )

        XCTAssertEqual(resumed.seq, 2)
        XCTAssertEqual(resumed.cursor, "2")
        XCTAssertFalse(resumed.firstSnapshot)
        XCTAssertFalse(resumed.disconnectDetected)
        XCTAssertFalse(resumed.recoveredAfterRestart)
        XCTAssertEqual(resumed.events.first?.kind, "data.tick")
    }

    func testResumeRecoversCursorAfterDaemonRestart() async throws {
        let restarted = makeService(sessionID: "daemon-b")

        let response = try await restarted.resume(
            BurnBarSubscriptionResumeRequest(
                subscriptionID: "desktop-data",
                topic: "data",
                afterSeq: 41,
                clientID: "linux-desktop"
            )
        )

        XCTAssertEqual(response.seq, 42)
        XCTAssertTrue(response.firstSnapshot)
        XCTAssertTrue(response.disconnectDetected)
        XCTAssertTrue(response.recoveredAfterRestart)
        XCTAssertEqual(response.events.first?.snapshot["event_reason"], "daemon_restart_recovery")
        XCTAssertEqual(response.events.first?.snapshot["daemon_session_id"], "daemon-b")
    }

    func testStopCancelsSubscriptionAndRejectsLateResume() async throws {
        let service = makeService()
        _ = try await service.start(
            BurnBarSubscriptionStartRequest(
                topic: "data",
                requestedSubscriptionID: "desktop-data",
                clientID: "linux-desktop"
            )
        )

        let stopped = try await service.stop(
            BurnBarSubscriptionStopRequest(
                subscriptionID: "desktop-data",
                clientID: "linux-desktop"
            )
        )

        XCTAssertTrue(stopped.stopped)
        XCTAssertEqual(stopped.lastSeq, 1)
        await XCTAssertThrowsErrorAsync(
            try await service.resume(
                BurnBarSubscriptionResumeRequest(
                    subscriptionID: "desktop-data",
                    topic: "data",
                    afterSeq: 1,
                    clientID: "linux-desktop"
                )
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSubscriptionServiceError, .subscriptionStopped)
        }
    }

    func testScopeAndIdentifierValidationFailClosed() async throws {
        let service = makeService()
        _ = try await service.start(
            BurnBarSubscriptionStartRequest(
                topic: "data",
                requestedSubscriptionID: "desktop-data",
                clientID: "linux-desktop"
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await service.start(
                BurnBarSubscriptionStartRequest(
                    topic: "data",
                    requestedSubscriptionID: "desktop-data",
                    clientID: "linux-desktop"
                )
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSubscriptionServiceError, .subscriptionAlreadyExists)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.resume(
                BurnBarSubscriptionResumeRequest(
                    subscriptionID: "desktop-data",
                    topic: "health",
                    afterSeq: 1,
                    clientID: "linux-desktop"
                )
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSubscriptionServiceError, .subscriptionMismatch)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.start(BurnBarSubscriptionStartRequest(topic: "run"))
        ) { error in
            XCTAssertEqual(error as? BurnBarSubscriptionServiceError, .invalidTopic("run_without_run_id"))
        }
        await XCTAssertThrowsErrorAsync(
            try await service.start(
                BurnBarSubscriptionStartRequest(topic: "data", clientID: "invalid client")
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSubscriptionServiceError, .invalidSubscriptionID)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.start(
                BurnBarSubscriptionStartRequest(topic: "data", clientID: "unicode-\u{00E9}")
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSubscriptionServiceError, .invalidSubscriptionID)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.resume(
                BurnBarSubscriptionResumeRequest(
                    subscriptionID: "desktop-data",
                    topic: "data",
                    afterSeq: Int.max,
                    clientID: "linux-desktop"
                )
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSubscriptionServiceError, .invalidSequence)
        }
    }

    private func makeService(sessionID: String = "daemon-test") -> BurnBarSubscriptionService {
        BurnBarSubscriptionService(
            daemonVersion: "test-daemon",
            daemonSessionID: sessionID,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
