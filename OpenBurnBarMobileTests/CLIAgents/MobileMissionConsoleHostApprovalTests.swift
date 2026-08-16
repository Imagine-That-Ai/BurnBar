import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class MobileMissionConsoleHostApprovalTests: XCTestCase {

    func test_denySuccessRemovesAskAndListenerCannotResurrectIt() async throws {
        let responder = StubMissionApprovalResponder()
        let host = MobileMissionConsoleHost(approvalResponder: responder)
        let waiting = try Self.waitingMission(id: "pareto-final12-codex")
        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        XCTAssertEqual(host.snapshot.approvalAsks.map(\.missionID), [waiting.id])

        await host.respond(to: waiting.id, approve: false)

        XCTAssertEqual(responder.calls.map(\.requestID), [waiting.id])
        XCTAssertEqual(responder.calls.map(\.approve), [false])
        XCTAssertTrue(host.snapshot.approvalAsks.isEmpty)
        XCTAssertNil(host.approvalResponseError)
        XCTAssertNil(host.inlineError)

        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        XCTAssertTrue(
            host.snapshot.approvalAsks.isEmpty,
            "A successful Deny must not come back when the listener re-emits the still-waiting document."
        )
        XCTAssertNil(host.approvalResponseError)
    }

    func test_approveSuccessHidesAskWithoutChangingApproveProductPath() async throws {
        let responder = StubMissionApprovalResponder()
        let host = MobileMissionConsoleHost(approvalResponder: responder)
        let waiting = try Self.waitingMission(id: "pareto-final12-claude")
        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        await host.respond(to: waiting.id, approve: true)

        XCTAssertEqual(responder.calls.map(\.approve), [true])
        XCTAssertTrue(host.snapshot.approvalAsks.isEmpty)
        XCTAssertEqual(host.snapshot.activeTiles.map(\.id), [waiting.id])
        XCTAssertEqual(host.snapshot.activeTiles.first?.approvalPending, false)
        XCTAssertNil(host.approvalResponseError)
    }

    func test_denyFailureKeepsAskAndSurfacesErrorThroughListenerAbsorb() async throws {
        let responder = StubMissionApprovalResponder()
        responder.result = .failure(
            StubMissionApprovalResponder.StubError.message(
                "Mission approvals require a trusted native device. Trust this device first."
            )
        )
        let host = MobileMissionConsoleHost(approvalResponder: responder)
        let waiting = try Self.waitingMission(id: "pareto-final11-codex")
        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        await host.respond(to: waiting.id, approve: false)

        XCTAssertEqual(host.snapshot.approvalAsks.map(\.missionID), [waiting.id])
        XCTAssertEqual(
            host.approvalResponseError,
            "Mission approvals require a trusted native device. Trust this device first."
        )
        XCTAssertEqual(host.inlineError, host.approvalResponseError)

        host.absorbMissionSnapshots([waiting], documentCount: 1, hasResolvedKey: true)

        XCTAssertEqual(
            host.snapshot.approvalAsks.map(\.missionID),
            [waiting.id],
            "A failed Deny must keep the waiting card so the user can retry."
        )
        XCTAssertEqual(
            host.approvalResponseError,
            "Mission approvals require a trusted native device. Trust this device first.",
            "The previous silent no-op cleared the error on the next list snapshot."
        )
        XCTAssertEqual(host.inlineError, host.approvalResponseError)
    }

    func test_newApprovalRequestIdAfterDenyCanSurfaceAgain() async throws {
        let responder = StubMissionApprovalResponder()
        let host = MobileMissionConsoleHost(approvalResponder: responder)
        let first = try Self.waitingMission(id: "pareto-reask", approvalRequestId: "approval-1")
        host.absorbMissionSnapshots([first], documentCount: 1, hasResolvedKey: true)

        await host.respond(to: first.id, approve: false)
        XCTAssertTrue(host.snapshot.approvalAsks.isEmpty)

        let second = try Self.waitingMission(id: "pareto-reask", approvalRequestId: "approval-2")
        host.absorbMissionSnapshots([second], documentCount: 1, hasResolvedKey: true)

        XCTAssertEqual(host.snapshot.approvalAsks.map(\.missionID), [second.id])
    }

    func test_rejectedOrCanceledMissionIsNotWaitingForApproval() throws {
        let rejected = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "denied-1", data: [
            "id": "denied-1",
            "title": "PARETO-SALES-READY-20260720T100425Z-FINAL12",
            "status": "waiting_for_approval",
            "requestedRuntime": "codex",
            "approvalRequestId": "approval-1",
            "approvalStatus": "rejected",
            "events": []
        ]))
        XCTAssertFalse(rejected.isWaitingForApproval)

        let canceled = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "denied-2", data: [
            "id": "denied-2",
            "title": "PARETO-SALES-READY-20260720T093530Z-FINAL11",
            "status": "canceled",
            "requestedRuntime": "claude",
            "approvalRequestId": "approval-2",
            "approvalStatus": "rejected",
            "events": []
        ]))
        XCTAssertFalse(canceled.isWaitingForApproval)
        XCTAssertTrue(canceled.isTerminal)
    }

    private static func waitingMission(
        id: String,
        approvalRequestId: String? = nil
    ) throws -> CLIAgentMissionSnapshot {
        try XCTUnwrap(CLIAgentMissionSnapshot(documentID: id, data: [
            "id": id,
            "title": "PARETO-SALES-READY-20260720T100425Z-FINAL12",
            "status": "waiting_for_approval",
            "requestedRuntime": "codex",
            "selectedRuntime": "codex",
            "selectedRuntimeName": "Codex",
            "approvalRequestId": approvalRequestId ?? "approval-\(id)",
            "approvalStatus": "pending",
            "approvalTitle": "Approve \(id)",
            "approvalMessage": "Codex is waiting for approval.",
            "createdAt": "2026-07-20T10:04:25Z",
            "events": []
        ]))
    }
}

@MainActor
private final class StubMissionApprovalResponder: MobileMissionApprovalResponding {
    enum StubError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    var result: Result<Void, Error> = .success(())
    private(set) var calls: [(requestID: String, approve: Bool)] = []

    func respondToApproval(requestID: String, approve: Bool) async throws {
        calls.append((requestID, approve))
        try result.get()
    }
}
