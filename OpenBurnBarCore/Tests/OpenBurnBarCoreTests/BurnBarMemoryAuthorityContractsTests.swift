import XCTest
@testable import OpenBurnBarCore

/// Wave 2.1c-iii: the memory authority lane rides stable wire keys. Every
/// temporal rides as an app-finalized string; the `kind`/`value`
/// discriminator selects the operation; unknown kinds fail the decode.
final class BurnBarMemoryAuthorityContractsTests: XCTestCase {
    func testRequestRoundTripsWithStableWireKeys() throws {
        let request = BurnBarMemoryAuthorityApplyRequest(
            mutationID: "mutation-1",
            actor: "app",
            operations: [.appendAudit(Self.audit(action: "memory.add"))]
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["mutationID"] as? String, "mutation-1")
        XCTAssertEqual(object["actor"] as? String, "app")
        let operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations[0]["kind"] as? String, "appendAudit")
        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarMemoryAuthorityApplyRequest.self, from: data),
            request
        )

        let response = BurnBarMemoryAuthorityApplyResponse(
            mutationID: "mutation-1",
            results: [BurnBarMemoryAuthorityOperationResult(
                affectedRows: 3,
                audits: [BurnBarMemoryAuthorityAuditReceipt(sequence: 9, hash: "abc123")]
            )]
        )
        let responseData = try JSONEncoder().encode(response)
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(responseObject["mutationID"] as? String, "mutation-1")
        let results = try XCTUnwrap(responseObject["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["affectedRows"] as? Int, 3)
        let audits = try XCTUnwrap(results[0]["audits"] as? [[String: Any]])
        XCTAssertEqual(audits.count, 1)
        XCTAssertEqual(audits[0]["sequence"] as? Int, 9)
        XCTAssertEqual(audits[0]["hash"] as? String, "abc123")
        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarMemoryAuthorityApplyResponse.self, from: responseData),
            response
        )
    }

    func testEveryOperationKindRoundTripsThroughTheDiscriminator() throws {
        let operations: [(BurnBarMemoryAuthorityOperation, String)] = [
            (.remember(Self.remember()), "remember"),
            (.updateBody(Self.update()), "updateBody"),
            (.setReviewStatus(Self.review()), "setReviewStatus"),
            (.deleteMemory(Self.delete()), "deleteMemory"),
            (.reconcileSuppressions(Self.reconcile()), "reconcileSuppressions"),
            (.claimUnowned(BurnBarMemoryAuthorityClaim(userID: "user-1", sourceKind: "agent")), "claimUnowned"),
            (
                .enqueueFactTombstones(BurnBarMemoryAuthorityEnqueueTombstones(tombstones: [Self.factTombstone()])),
                "enqueueFactTombstones"
            ),
            (
                .recordSourceTombstone(BurnBarMemoryAuthoritySourceTombstone(tombstone: Self.sourceTombstone())),
                "recordSourceTombstone"
            ),
            (
                .markTombstoneReplicated(BurnBarMemoryAuthorityMarkReplicated(
                    table: .fact,
                    id: "tomb-1",
                    replicatedAtText: "2026-09-23 05:00:00.000"
                )),
                "markTombstoneReplicated"
            ),
            (.appendAudit(Self.audit(action: "memory.secret_rejected")), "appendAudit")
        ]
        for (operation, kind) in operations {
            let request = BurnBarMemoryAuthorityApplyRequest(
                mutationID: "mutation-\(kind)",
                actor: "app",
                operations: [operation]
            )
            let data = try JSONEncoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let wire = try XCTUnwrap(object["operations"] as? [[String: Any]])
            XCTAssertEqual(wire.count, 1, "kind \(kind)")
            XCTAssertEqual(wire[0]["kind"] as? String, kind)
            XCTAssertNotNil(wire[0]["value"], "kind \(kind)")
            XCTAssertEqual(
                try JSONDecoder().decode(BurnBarMemoryAuthorityApplyRequest.self, from: data),
                request,
                "kind \(kind)"
            )
        }
    }

    func testUnknownOperationKindFailsTheDecode() {
        let data = Data(
            #"{"mutationID":"m","actor":"app","operations":[{"kind":"nope","value":{}}]}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarMemoryAuthorityApplyRequest.self, from: data))
    }

    func testTombstoneTableRoundTripsBothCases() throws {
        for table in [BurnBarMemoryAuthorityTombstoneTable.fact, .source] {
            let operation = BurnBarMemoryAuthorityOperation.markTombstoneReplicated(
                BurnBarMemoryAuthorityMarkReplicated(
                    table: table,
                    id: "tomb-1",
                    replicatedAtText: "2026-09-23 05:00:00.000"
                )
            )
            let data = try JSONEncoder().encode(operation)
            XCTAssertEqual(try JSONDecoder().decode(BurnBarMemoryAuthorityOperation.self, from: data), operation)
        }
    }

    // MARK: - Fixtures

    private static func audit(action: String) -> BurnBarMemoryAuthorityAuditEvent {
        BurnBarMemoryAuthorityAuditEvent(
            action: action,
            projectID: "project-1",
            subjectID: "memory-1",
            labels: ["memory_id:memory-1", "source_kind:chat"],
            labelsJSON: #"["memory_id:memory-1","source_kind:chat"]"#,
            timestampText: "2026-09-23T05:00:00.000Z"
        )
    }

    private static func snapshot(memoryID: String = "memory-1") -> BurnBarMemoryAuthoritySnapshotRow {
        BurnBarMemoryAuthoritySnapshotRow(
            id: "snapshot-\(memoryID)",
            memoryID: memoryID,
            bodyRef: "memory_body_snapshots:snapshot-\(memoryID)",
            snapshotJSON: #"{"schemaVersion":1}"#,
            bodyHash: String(repeating: "ab", count: 32),
            sourceKind: "chat",
            createdAtText: "2026-09-23 05:00:00.000",
            updatedAtText: "2026-09-23 05:00:00.000"
        )
    }

    private static func memory(id: String = "memory-1") -> BurnBarMemoryAuthorityMemoryRow {
        BurnBarMemoryAuthorityMemoryRow(
            id: id,
            projectID: "project-1",
            kind: "fact",
            scopeText: "chat",
            confidence: 0.9,
            bodyRef: "memory_body_snapshots:snapshot-\(id)",
            bodyRedacted: "memory_body_snapshots:snapshot-\(id)",
            tagsJSON: "[]",
            sourcePath: nil,
            validFromText: "2026-09-23 05:00:00.000",
            validToText: nil,
            supersededBy: nil,
            createdAtText: "2026-09-23 05:00:00.000",
            updatedAtText: "2026-09-23 05:00:00.000",
            sourceKind: "chat",
            reviewStatus: "quarantined",
            userID: "user-1",
            agentID: nil,
            runID: nil,
            appID: "app-1"
        )
    }

    private static func provenance(memoryID: String = "memory-1") -> BurnBarMemoryAuthorityProvenanceRow {
        BurnBarMemoryAuthorityProvenanceRow(
            id: "prov-1",
            memoryID: memoryID,
            sourceKind: "chat",
            threadLogicalID: "thread-1",
            messageID: "message-1",
            role: "user",
            authoredAtText: "2026-09-23 04:00:00.000",
            contentHash: String(repeating: "cd", count: 32),
            occurrence: 0,
            xdeviceHMAC: String(repeating: "ef", count: 32),
            citationState: "live",
            createdAtText: "2026-09-23 05:00:00.000"
        )
    }

    private static func factTombstone() -> BurnBarMemoryAuthorityFactTombstoneRow {
        BurnBarMemoryAuthorityFactTombstoneRow(
            id: "tomb-1",
            userID: "user-1",
            memoryID: "memory-1",
            sourceRefsJSON: "[]",
            reason: "user_delete",
            createdAtText: "2026-09-23 05:00:00.000",
            overwriteOnConflict: true,
            refreshSourceRefsOnConflict: true
        )
    }

    private static func sourceTombstone() -> BurnBarMemoryAuthoritySourceTombstoneRow {
        BurnBarMemoryAuthoritySourceTombstoneRow(
            id: "source-tomb-1",
            userID: "user-1",
            threadLogicalID: "thread-1",
            messageID: nil,
            contentHash: nil,
            reason: "user_delete",
            createdAtText: "2026-09-23 05:00:00.000"
        )
    }

    private static func remember() -> BurnBarMemoryAuthorityRemember {
        BurnBarMemoryAuthorityRemember(
            snapshot: snapshot(),
            memory: memory(),
            provenance: [provenance()],
            audits: [audit(action: "memory.add")],
            merge: BurnBarMemoryAuthorityMerge(
                winnerID: "memory-1",
                loserIDs: ["memory-0"],
                sourceKinds: ["chat"],
                storageProjectID: "project-1",
                nowText: "2026-09-23 05:00:00.000",
                nowTimestampText: "2026-09-23T05:00:00.000Z",
                provenanceCopies: [],
                supersedeAudits: [audit(action: "memory.supersede")],
                mergeAudit: audit(action: "memory.merge")
            )
        )
    }

    private static func update() -> BurnBarMemoryAuthorityUpdate {
        BurnBarMemoryAuthorityUpdate(
            memoryID: "memory-1",
            sourceKind: "chat",
            kind: "preference",
            confidence: 0.95,
            updatedAtText: "2026-09-23 05:00:00.000",
            reseal: BurnBarMemoryAuthorityReseal(
                expectedBodyHash: String(repeating: "01", count: 32),
                expectedUpdatedAtText: "2026-09-23 04:00:00.000",
                snapshot: snapshot()
            ),
            audit: audit(action: "memory.update")
        )
    }

    private static func review() -> BurnBarMemoryAuthorityReview {
        BurnBarMemoryAuthorityReview(
            memoryID: "memory-1",
            sourceKind: "chat",
            reviewStatus: "approved",
            updatedAtText: "2026-09-23T05:00:00.000Z",
            factTombstone: nil,
            markFactTombstoneReplicated: true,
            replicatedAtText: "2026-09-23 05:00:00.000",
            audit: audit(action: "memory.approve")
        )
    }

    private static func delete() -> BurnBarMemoryAuthorityDelete {
        BurnBarMemoryAuthorityDelete(
            memoryID: "memory-1",
            sourceKind: "chat",
            agent: nil,
            factTombstone: factTombstone(),
            blankedBodyUpdatedAtText: nil,
            audit: audit(action: "memory.delete")
        )
    }

    private static func reconcile() -> BurnBarMemoryAuthorityReconcile {
        BurnBarMemoryAuthorityReconcile(
            matches: [BurnBarMemoryAuthorityReconcileMatch(
                memoryID: "memory-1",
                projectID: "project-1",
                labels: ["memory_id:memory-1", "reason:source_tombstone", "source_kind:chat"],
                labelsJSON: #"["memory_id:memory-1","reason:source_tombstone","source_kind:chat"]"#
            )],
            sourceKind: "chat",
            validToText: "2026-09-23 05:00:00.000",
            updatedAtText: "2026-09-23 05:00:00.000",
            timestampText: "2026-09-23T05:00:00.000Z"
        )
    }
}
