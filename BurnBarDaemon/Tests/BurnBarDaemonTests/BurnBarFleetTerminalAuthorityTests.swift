import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// M4 terminal-authority regressions: immutable dismissed/delivered outcomes
/// must win against stale callbacks, while a failed delivery can be retried
/// to delivered.
final class BurnBarFleetTerminalAuthorityTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-terminal-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private func makeStore() throws -> BurnBarFleetStore {
        let store = BurnBarFleetStore(
            databasePath: fixtureRoot.appendingPathComponent("fleet.sqlite").path
        )
        _ = try store.open()
        return store
    }

    private func makeDirective(
        id: String,
        state: BurnBarFleetDirectiveState,
        deliveryChannel: String? = nil,
        deliveryAttemptID: String? = nil
    ) -> BurnBarFleetDirective {
        BurnBarFleetDirective(
            id: id,
            kind: .summarize,
            targetAgent: .claudeCode,
            payload: "Summarize current work",
            state: state,
            createdAt: Date(timeIntervalSince1970: 1_752_000_000),
            decidedAt: Date(timeIntervalSince1970: 1_752_000_100),
            deliveryChannel: deliveryChannel,
            deliveryAttemptID: deliveryAttemptID
        )
    }

    private func recordConcurrently(
        _ candidates: [BurnBarFleetDirective],
        with control: BurnBarFleetControlStore
    ) async throws -> [BurnBarFleetDirective] {
        try await withThrowingTaskGroup(
            of: BurnBarFleetDirective.self,
            returning: [BurnBarFleetDirective].self
        ) { group in
            for candidate in candidates {
                group.addTask {
                    try await control.recordDirective(candidate)
                }
            }
            var results: [BurnBarFleetDirective] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }

    func testDismissedThenDeliveredCallback_staysDismissed() async throws {
        let store = try makeStore()
        let control = BurnBarFleetControlStore(store: store)
        let dismissed = makeDirective(id: "dir-dismissed-race", state: .dismissed)
        _ = try await control.recordDirective(dismissed)

        let candidates = [
            makeDirective(id: dismissed.id, state: .delivered),
            makeDirective(id: dismissed.id, state: .failed(reason: "late gateway timeout")),
            makeDirective(id: dismissed.id, state: .dismissed),
            makeDirective(id: dismissed.id, state: .approved),
            makeDirective(id: dismissed.id, state: .proposed)
        ]
        let results = try await recordConcurrently(candidates, with: control)

        XCTAssertEqual(results.count, candidates.count)
        XCTAssertTrue(results.allSatisfy { $0 == dismissed }, "dismissal is terminal authority")
        XCTAssertEqual(try store.directiveRecords().first?.state, .dismissed)
    }

    func testDeliveredThenFailedCallback_staysDelivered() async throws {
        let store = try makeStore()
        let control = BurnBarFleetControlStore(store: store)
        let delivered = makeDirective(
            id: "dir-delivered-race",
            state: .delivered,
            deliveryChannel: "hermes"
        )
        _ = try await control.recordDirective(delivered)

        let candidates = [
            makeDirective(
                id: delivered.id,
                state: .failed(reason: "late gateway timeout"),
                deliveryChannel: "hermes"
            ),
            makeDirective(id: delivered.id, state: .delivered, deliveryChannel: "hermes"),
            makeDirective(id: delivered.id, state: .dismissed),
            makeDirective(id: delivered.id, state: .approved),
            makeDirective(id: delivered.id, state: .proposed)
        ]
        let results = try await recordConcurrently(candidates, with: control)

        XCTAssertEqual(results.count, candidates.count)
        XCTAssertTrue(results.allSatisfy { $0 == delivered }, "delivery completion is terminal authority")
        XCTAssertEqual(try store.directiveRecords().first?.state, .delivered)
    }

    func testFailedThenDeliveredRetry_stillWorks() async throws {
        let store = try makeStore()
        let control = BurnBarFleetControlStore(store: store)
        let failed = makeDirective(
            id: "dir-failed-retry",
            state: .failed(reason: "first gateway timeout"),
            deliveryChannel: "hermes"
        )
        _ = try await control.recordDirective(failed)

        let retryDelivered = makeDirective(
            id: failed.id,
            state: .delivered,
            deliveryChannel: "hermes"
        )
        let recorded = try await control.recordDirective(retryDelivered)

        XCTAssertEqual(recorded, retryDelivered)
        XCTAssertEqual(try store.directiveRecords().first?.state, .delivered)
    }

    func testApprovedDeliveryAttemptMarkerSurvivesRecoveryCandidate() async throws {
        let store = try makeStore()
        let control = BurnBarFleetControlStore(store: store)
        let attempt = makeDirective(
            id: "dir-attempt-handoff",
            state: .approved,
            deliveryChannel: "hermes",
            deliveryAttemptID: "attempt-1"
        )
        _ = try await control.recordDirective(attempt)

        // A relaunch sends the daemon an approved reconciliation candidate
        // without the attempt metadata. The durable handoff must remain the
        // authority, otherwise a second Hermes call could be started.
        let recoveryCandidate = makeDirective(id: attempt.id, state: .approved)
        let reconciled = try await control.recordDirective(recoveryCandidate)

        XCTAssertEqual(reconciled, attempt)
        XCTAssertEqual(try store.directiveRecord(id: attempt.id), attempt)

        let competingAttempt = makeDirective(
            id: attempt.id,
            state: .approved,
            deliveryChannel: "hermes",
            deliveryAttemptID: "attempt-2"
        )
        let competingResult = try await control.recordDirective(competingAttempt)
        XCTAssertEqual(
            competingResult,
            attempt,
            "a competing approved attempt must not replace the durable fence"
        )
    }

    func testFailedRecordRequiresFreshAttemptForApprovedRetry() async throws {
        let store = try makeStore()
        let control = BurnBarFleetControlStore(store: store)
        let failed = makeDirective(
            id: "dir-failed-attempt",
            state: .failed(reason: "gateway timeout"),
            deliveryChannel: "hermes",
            deliveryAttemptID: "attempt-1"
        )
        _ = try await control.recordDirective(failed)

        let staleRetry = makeDirective(
            id: failed.id,
            state: .approved,
            deliveryChannel: "hermes",
            deliveryAttemptID: "attempt-1"
        )
        let staleResult = try await control.recordDirective(staleRetry)
        XCTAssertEqual(staleResult, failed, "the old attempt cannot reopen a failed record")

        let freshRetry = makeDirective(
            id: failed.id,
            state: .approved,
            deliveryChannel: "hermes",
            deliveryAttemptID: "attempt-2"
        )
        let freshResult = try await control.recordDirective(freshRetry)
        XCTAssertEqual(freshResult, freshRetry)
        XCTAssertEqual(try store.directiveRecord(id: failed.id), freshRetry)
    }
}
