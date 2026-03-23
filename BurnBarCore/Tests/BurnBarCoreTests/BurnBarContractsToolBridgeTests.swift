import XCTest
@testable import BurnBarCore

final class BurnBarContractsToolBridgeTests: XCTestCase {
    func testToolExecutionRequestRoundTripCodable() throws {
        let original = BurnBarToolExecutionRequest(
            clientID: BurnBarClientID(rawValue: "client-1"),
            sessionID: BurnBarSessionID(rawValue: "session-1"),
            runID: BurnBarRunID(rawValue: "run-1")
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BurnBarToolExecutionRequest.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testToolExecutionResponseRoundTripIncludesRefusalErrorShape() throws {
        let snapshot = BurnBarToolCallSnapshot(
            callID: "call-1",
            runID: BurnBarRunID(rawValue: "run-1"),
            tool: .applyPatch,
            arguments: .object(["changes": .array([])]),
            status: .failed,
            requestedBy: BurnBarClientID(rawValue: "client-1"),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            claimedBy: BurnBarClientID(rawValue: "client-1"),
            claimedAt: Date(timeIntervalSince1970: 1_700_000_010),
            completedAt: Date(timeIntervalSince1970: 1_700_000_020),
            output: nil,
            error: BurnBarToolExecutionError(
                code: .trustGated,
                message: "Workspace trust is required."
            )
        )
        let original = BurnBarToolExecutionResponse(disposition: .dispatched, toolCall: snapshot)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BurnBarToolExecutionResponse.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.toolCall?.error?.code, .trustGated)
    }

    func testRunEventBatchRoundTripIncludesPendingToolCalls() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let runID = BurnBarRunID(rawValue: "run-1")
        let clientID = BurnBarClientID(rawValue: "client-1")

        let batch = BurnBarRunEventBatch(
            runs: [
                BurnBarRunStateSnapshot(
                    runID: runID,
                    clientID: clientID,
                    sessionID: BurnBarSessionID(rawValue: "session-1"),
                    phase: .waitingOnCompanion,
                    modelID: "glm-5",
                    updatedAt: now
                )
            ],
            approvals: [],
            pendingToolCalls: [
                BurnBarToolCallSnapshot(
                    callID: "call-1",
                    runID: runID,
                    tool: .readFile,
                    arguments: .object(["path": .string("README.md")]),
                    status: .pending,
                    requestedBy: clientID,
                    requestedAt: now
                )
            ],
            arbitration: BurnBarClientArbitrationSnapshot(
                activeClientID: clientID,
                attachedClientIDs: [clientID],
                reason: "first_controller_attached"
            ),
            emittedAt: now
        )

        let data = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(BurnBarRunEventBatch.self, from: data)

        XCTAssertEqual(decoded.runs.first?.phase, .waitingOnCompanion)
        XCTAssertEqual(decoded.pendingToolCalls.first?.tool, .readFile)
        XCTAssertEqual(decoded.arbitration?.activeClientID, clientID)
    }
}
