import XCTest
@testable import OpenBurnBarMobile

final class HermesGatewayApprovalDetailIndexTests: XCTestCase {

    func testApprovalDetailsAreKeyedBySealedActionIdNotApprovalDocumentId() throws {
        var message = try Self.message(id: "msg-1")
        message.resolvedKind = "approval"
        message.resolvedActionId = "agent-confirm-action-1"
        message.resolvedText = "Run the queued action against the selected client."

        let details = HermesGatewayApprovalDetailIndex.keyedByActionId(from: [message])

        XCTAssertEqual(details["agent-confirm-action-1"], "Run the queued action against the selected client.")
        XCTAssertNil(details["hga_hash_for_server_approval_doc"])
    }

    func testApprovalDetailsIgnoreOrdinaryRepliesAndEmptyDetails() throws {
        var ordinaryReply = try Self.message(id: "msg-ordinary")
        ordinaryReply.resolvedKind = "reply"
        ordinaryReply.resolvedActionId = "action-ordinary"
        ordinaryReply.resolvedText = "ordinary response"

        var emptyApproval = try Self.message(id: "msg-empty")
        emptyApproval.resolvedKind = "approval"
        emptyApproval.resolvedActionId = "action-empty"
        emptyApproval.resolvedText = ""

        let details = HermesGatewayApprovalDetailIndex.keyedByActionId(from: [ordinaryReply, emptyApproval])

        XCTAssertTrue(details.isEmpty)
    }

    private static func message(id: String) throws -> HermesGatewayMessageRecord {
        try XCTUnwrap(HermesGatewayMessageRecord(
            documentID: id,
            data: [
                "id": id,
                "clientId": "client-1",
                "kind": "reply",
                "destinationId": "destination-1",
                "createdAt": "2026-06-23T00:00:00Z",
                "schemaVersion": 2
            ]
        ))
    }
}
