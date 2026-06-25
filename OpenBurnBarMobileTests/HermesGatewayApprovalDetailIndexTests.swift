import XCTest
@testable import OpenBurnBarMobile

final class HermesGatewayApprovalDetailIndexTests: XCTestCase {

    func testApprovalDetailsAreKeyedBySealedActionIdNotApprovalDocumentId() throws {
        var message = try Self.message(id: "msg-1", clientId: "client-1")
        message.resolvedKind = "approval"
        message.resolvedActionId = "agent-confirm-action-1"
        message.resolvedText = "Run the queued action against the selected client."

        let details = HermesGatewayApprovalDetailIndex.keyedByApprovalTarget(from: [message])
        let key = HermesGatewayApprovalDetailKey(clientId: "client-1", actionId: "agent-confirm-action-1")

        XCTAssertEqual(details[key], "Run the queued action against the selected client.")
        XCTAssertNil(details[HermesGatewayApprovalDetailKey(clientId: "client-1", actionId: "hga_hash_for_server_approval_doc")])
    }

    func testApprovalDetailsSeparateSameActionIdAcrossGatewayClients() throws {
        var firstClient = try Self.message(id: "msg-1", clientId: "client-1")
        firstClient.resolvedKind = "approval"
        firstClient.resolvedActionId = "shared-action"
        firstClient.resolvedText = "Approve action for the first client."

        var secondClient = try Self.message(id: "msg-2", clientId: "client-2")
        secondClient.resolvedKind = "approval"
        secondClient.resolvedActionId = "shared-action"
        secondClient.resolvedText = "Approve action for the second client."

        let details = HermesGatewayApprovalDetailIndex.keyedByApprovalTarget(from: [firstClient, secondClient])

        XCTAssertEqual(
            details[HermesGatewayApprovalDetailKey(clientId: "client-1", actionId: "shared-action")],
            "Approve action for the first client."
        )
        XCTAssertEqual(
            details[HermesGatewayApprovalDetailKey(clientId: "client-2", actionId: "shared-action")],
            "Approve action for the second client."
        )
    }

    func testApprovalDetailsIgnoreOrdinaryRepliesAndEmptyDetails() throws {
        var ordinaryReply = try Self.message(id: "msg-ordinary", clientId: "client-1")
        ordinaryReply.resolvedKind = "reply"
        ordinaryReply.resolvedActionId = "action-ordinary"
        ordinaryReply.resolvedText = "ordinary response"

        var emptyApproval = try Self.message(id: "msg-empty", clientId: "client-1")
        emptyApproval.resolvedKind = "approval"
        emptyApproval.resolvedActionId = "action-empty"
        emptyApproval.resolvedText = ""

        let details = HermesGatewayApprovalDetailIndex.keyedByApprovalTarget(from: [ordinaryReply, emptyApproval])

        XCTAssertTrue(details.isEmpty)
    }

    private static func message(id: String, clientId: String) throws -> HermesGatewayMessageRecord {
        try XCTUnwrap(HermesGatewayMessageRecord(
            documentID: id,
            data: [
                "id": id,
                "clientId": clientId,
                "kind": "reply",
                "destinationId": "destination-1",
                "createdAt": "2026-06-23T00:00:00Z",
                "schemaVersion": 2
            ]
        ))
    }
}
