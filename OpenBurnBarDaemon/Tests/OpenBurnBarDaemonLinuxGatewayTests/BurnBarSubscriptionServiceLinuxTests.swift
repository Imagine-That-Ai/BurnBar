import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarSubscriptionServiceLinuxTests: XCTestCase {
    func testLinuxSubscriptionCursorRecoversAcrossDaemonRestart() async throws {
        let firstService = BurnBarSubscriptionService(
            daemonVersion: "linux-test",
            daemonSessionID: "linux-daemon-a"
        )
        let started = try await firstService.start(
            BurnBarSubscriptionStartRequest(
                topic: "data",
                requestedSubscriptionID: "linux-desktop-data",
                clientID: "linux-desktop"
            )
        )
        let restartedService = BurnBarSubscriptionService(
            daemonVersion: "linux-test",
            daemonSessionID: "linux-daemon-b"
        )

        let recovered = try await restartedService.resume(
            BurnBarSubscriptionResumeRequest(
                subscriptionID: started.subscriptionID,
                topic: "data",
                afterSeq: started.seq,
                clientID: "linux-desktop"
            )
        )

        XCTAssertEqual(recovered.seq, 2)
        XCTAssertTrue(recovered.disconnectDetected)
        XCTAssertTrue(recovered.recoveredAfterRestart)
        XCTAssertFalse(recovered.terminalStateDelivered)
        XCTAssertEqual(recovered.events.first?.snapshot["daemon_session_id"], "linux-daemon-b")
    }

    func testLinuxSubscriptionStopRejectsLateResume() async throws {
        let service = BurnBarSubscriptionService(daemonVersion: "linux-test")
        let started = try await service.start(
            BurnBarSubscriptionStartRequest(
                topic: "data",
                requestedSubscriptionID: "linux-desktop-data",
                clientID: "linux-desktop"
            )
        )
        let stopped = try await service.stop(
            BurnBarSubscriptionStopRequest(
                subscriptionID: started.subscriptionID,
                clientID: "linux-desktop"
            )
        )

        XCTAssertTrue(stopped.stopped)
        do {
            _ = try await service.resume(
                BurnBarSubscriptionResumeRequest(
                    subscriptionID: started.subscriptionID,
                    topic: "data",
                    afterSeq: stopped.lastSeq,
                    clientID: "linux-desktop"
                )
            )
            XCTFail("A stopped Linux subscription must not resume")
        } catch {
            XCTAssertEqual(error as? BurnBarSubscriptionServiceError, .subscriptionStopped)
        }
    }
}
