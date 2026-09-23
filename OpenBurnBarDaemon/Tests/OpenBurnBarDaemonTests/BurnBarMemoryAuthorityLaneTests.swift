import Foundation
import OpenBurnBarKernel
import OpenBurnBarEngine
@testable import OpenBurnBarMemoryExport
@testable import OpenBurnBarDaemon
import XCTest

/// Wave 2.1c-iii: storage semantics for the memory authority app lane.
/// Every test pins the same promise — the daemon stores the app-finalized
/// write set verbatim and assigns only the audit chain fields — and the
/// audit assertions verify through the real export chain verifier
/// (`MemoryExportAuditChain`), not a reimplementation of the payload.
final class BurnBarMemoryAuthorityLaneTests: XCTestCase {
    // MARK: - Harness

    private func makeStore() throws -> BurnBarProjectCodeMemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryAuthorityLaneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let store = try BurnBarProjectCodeMemoryStore(
            databasePath: root.appendingPathComponent("openburnbar.sqlite").path,
            logger: BurnBarDaemonLogger(category: "authority-lane-test")
        )
        try store.memoryAuthorityTestCompleteSchema()
        return store
    }

    private func apply(
        _ store: BurnBarProjectCodeMemoryStore,
        _ operations: [BurnBarMemoryAuthorityOperation]
    ) throws -> BurnBarMemoryAuthorityApplyResponse {
        try store.memoryAuthorityApplyAppLane(BurnBarMemoryAuthorityApplyRequest(
            mutationID: UUID().uuidString,
            actor: "app",
            operations: operations
        ))
    }

    private func fetchStrings(
        _ store: BurnBarProjectCodeMemoryStore,
        _ sql: String,
        _ binds: [BurnBarProjectCodeMemoryStore.SQLiteBind] = []
    ) throws -> [[String?]] {
        try store.queryRows(sql, binds).map { $0.values }
    }

    private func fetchInts(
        _ store: BurnBarProjectCodeMemoryStore,
        _ sql: String,
        _ binds: [BurnBarProjectCodeMemoryStore.SQLiteBind] = []
    ) throws -> [Int] {
        try store.queryRows(sql, binds).map { Int($0.int64(0)) }
    }

    /// Reads the full audit table back and verifies it through the real
    /// export verifier: every hash recomputes, every link names its
    /// predecessor, and no row diverges from its own `seq`.
    private func verifyAuditChain(
        _ store: BurnBarProjectCodeMemoryStore,
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rows = try store.queryRows(
            "SELECT seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash FROM memory_audit ORDER BY seq ASC",
            []
        )
        XCTAssertEqual(rows.count, expectedCount, file: file, line: line)
        let exportRows = try rows.map { row -> MemoryExportAuditRow in
            let labelsJSON = row.string(7)
            let labels = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(labelsJSON.utf8)) as? [String],
                file: file,
                line: line
            )
            return MemoryExportAuditRow(
                seq: Int(row.int64(0)),
                ts: row.string(1),
                actor: row.string(2),
                action: row.string(3),
                domain: row.string(4),
                projectID: row.optionalString(5),
                subjectID: row.optionalString(6),
                labels: labels,
                prevHash: row.optionalString(8),
                hash: row.string(9)
            )
        }
        let verification = MemoryExportAuditChain.verify(rows: exportRows)
        XCTAssertEqual(verification.verifiedThroughSeq, expectedCount, file: file, line: line)
        XCTAssertEqual(verification.brokenAt, [], file: file, line: line)
        XCTAssertEqual(verification.forks, [], file: file, line: line)
        XCTAssertFalse(verification.seqDivergence, file: file, line: line)
    }

    // MARK: - Fixtures

    private func audit(
        action: String,
        projectID: String? = "project-1",
        subjectID: String? = "memory-1",
        labels: [String] = ["memory_id:memory-1", "source_kind:chat"],
        timestampText: String = "2026-09-23T05:00:00.000Z"
    ) -> BurnBarMemoryAuthorityAuditEvent {
        // `try?` (not `try!`): a string array always encodes; the fallback is
        // unreachable and exists only to keep the helper non-throwing.
        let json = (try? JSONSerialization.data(withJSONObject: labels))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return BurnBarMemoryAuthorityAuditEvent(
            action: action,
            projectID: projectID,
            subjectID: subjectID,
            labels: labels,
            labelsJSON: json,
            timestampText: timestampText
        )
    }

    private func snapshot(memoryID: String = "memory-1") -> BurnBarMemoryAuthoritySnapshotRow {
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

    private func memory(
        id: String = "memory-1",
        sourceKind: String = "chat",
        reviewStatus: String = "quarantined",
        userID: String? = "user-1"
    ) -> BurnBarMemoryAuthorityMemoryRow {
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
            sourceKind: sourceKind,
            reviewStatus: reviewStatus,
            userID: userID,
            agentID: nil,
            runID: nil,
            appID: "app-1"
        )
    }

    private func provenance(
        id: String = "prov-1",
        memoryID: String = "memory-1",
        hmac: String = String(repeating: "ef", count: 32)
    ) -> BurnBarMemoryAuthorityProvenanceRow {
        BurnBarMemoryAuthorityProvenanceRow(
            id: id,
            memoryID: memoryID,
            sourceKind: "chat",
            threadLogicalID: "thread-1",
            messageID: "message-1",
            role: "user",
            authoredAtText: "2026-09-23 04:00:00.000",
            contentHash: String(repeating: "cd", count: 32),
            occurrence: 0,
            xdeviceHMAC: hmac,
            citationState: "live",
            createdAtText: "2026-09-23 05:00:00.000"
        )
    }

    private func factTombstone(
        id: String = "tomb-1",
        memoryID: String = "memory-1",
        overwrite: Bool = true,
        refreshRefs: Bool = true
    ) -> BurnBarMemoryAuthorityFactTombstoneRow {
        BurnBarMemoryAuthorityFactTombstoneRow(
            id: id,
            userID: "user-1",
            memoryID: memoryID,
            sourceRefsJSON: "[]",
            reason: "user_delete",
            createdAtText: "2026-09-23 05:00:00.000",
            overwriteOnConflict: overwrite,
            refreshSourceRefsOnConflict: refreshRefs
        )
    }

    private func remember(memoryID: String = "memory-1") -> BurnBarMemoryAuthorityRemember {
        BurnBarMemoryAuthorityRemember(
            snapshot: snapshot(memoryID: memoryID),
            memory: memory(id: memoryID),
            provenance: [provenance(memoryID: memoryID)],
            audits: [audit(action: "memory.add", subjectID: memoryID)],
            merge: nil
        )
    }

    // MARK: - Remember

    func testRememberStoresRowsVerbatimAndHeadsTheChain() throws {
        let store = try makeStore()
        let response = try apply(store, [.remember(remember())])

        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].audits.count, 1)
        XCTAssertEqual(response.results[0].audits[0].sequence, 1)

        let memories = try fetchStrings(store, "SELECT id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json, source_path, valid_from, valid_to, superseded_by, created_at, updated_at, source_kind, review_status, user_id, agent_id, run_id, app_id FROM agent_memories")
        XCTAssertEqual(memories, [[
            "memory-1", "project-1", "fact", "chat", "0.9",
            "memory_body_snapshots:snapshot-memory-1", "memory_body_snapshots:snapshot-memory-1",
            "[]", nil,
            "2026-09-23 05:00:00.000", nil, nil,
            "2026-09-23 05:00:00.000", "2026-09-23 05:00:00.000",
            "chat", "quarantined", "user-1", nil, nil, "app-1"
        ]])
        let snapshots = try fetchStrings(store, "SELECT id, memory_id, body_ref, snapshot_json, body_hash, source_kind, created_at, updated_at FROM memory_body_snapshots")
        XCTAssertEqual(snapshots, [[
            "snapshot-memory-1", "memory-1", "memory_body_snapshots:snapshot-memory-1",
            #"{"schemaVersion":1}"#, String(repeating: "ab", count: 32), "chat",
            "2026-09-23 05:00:00.000", "2026-09-23 05:00:00.000"
        ]])
        let provenanceRows = try fetchStrings(store, "SELECT id, memory_id, source_kind, thread_logical_id, message_id, role, authored_at, content_hash, occurrence, xdevice_hmac, citation_state, created_at FROM memory_provenance")
        XCTAssertEqual(provenanceRows, [[
            "prov-1", "memory-1", "chat", "thread-1", "message-1", "user",
            "2026-09-23 04:00:00.000", String(repeating: "cd", count: 32), "0",
            String(repeating: "ef", count: 32), "live", "2026-09-23 05:00:00.000"
        ]])
        let audits = try fetchStrings(store, "SELECT seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash FROM memory_audit")
        XCTAssertEqual(audits.count, 1)
        XCTAssertEqual(audits[0][0], "1")
        XCTAssertEqual(audits[0][1], "2026-09-23T05:00:00.000Z")
        XCTAssertEqual(audits[0][2], "app")
        XCTAssertEqual(audits[0][3], "memory.add")
        XCTAssertEqual(audits[0][4], "memory")
        XCTAssertEqual(audits[0][5], "project-1")
        XCTAssertEqual(audits[0][6], "memory-1")
        XCTAssertEqual(audits[0][7], #"["memory_id:memory-1","source_kind:chat"]"#)
        XCTAssertNil(audits[0][8])
        try verifyAuditChain(store, expectedCount: 1)
    }

    func testRememberRetryConvergesRowsAndExtendsTheTrail() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember())])
        let second = try apply(store, [.remember(remember())])

        // Row effects are idempotent ...
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM agent_memories"), [1])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_body_snapshots"), [1])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_provenance"), [1])
        // ... while the retry appends the truthful second event.
        XCTAssertEqual(second.results[0].audits[0].sequence, 2)
        try verifyAuditChain(store, expectedCount: 2)
    }

    func testRememberWithMergeSupersedesLosersAndCopiesProvenance() throws {
        let store = try makeStore()
        // Seed the loser the new memory will supersede.
        _ = try apply(store, [.remember(remember(memoryID: "memory-0"))])

        var mergeRemember = remember(memoryID: "memory-1")
        let copy = provenance(id: "copy-1", memoryID: "memory-1")
        mergeRemember = BurnBarMemoryAuthorityRemember(
            snapshot: mergeRemember.snapshot,
            memory: mergeRemember.memory,
            provenance: [],
            audits: [audit(action: "memory.add", subjectID: "memory-1")],
            merge: BurnBarMemoryAuthorityMerge(
                winnerID: "memory-1",
                loserIDs: ["memory-0"],
                sourceKinds: ["chat"],
                storageProjectID: "project-1",
                nowText: "2026-09-23 06:00:00.000",
                nowTimestampText: "2026-09-23T06:00:00.000Z",
                provenanceCopies: [copy],
                supersedeAudits: [audit(action: "memory.supersede", subjectID: "memory-0")],
                mergeAudit: audit(action: "memory.merge", subjectID: "memory-1")
            )
        )
        let response = try apply(store, [.remember(mergeRemember)])

        let loser = try fetchStrings(store, "SELECT valid_to, superseded_by, updated_at FROM agent_memories WHERE id = 'memory-0'")
        XCTAssertEqual(loser, [["2026-09-23 06:00:00.000", "memory-1", "2026-09-23 06:00:00.000"]])
        let copies = try fetchStrings(store, "SELECT id, memory_id FROM memory_provenance WHERE id = 'copy-1'")
        XCTAssertEqual(copies, [["copy-1", "memory-1"]])
        XCTAssertEqual(response.results[0].audits.map(\.sequence), [2, 3, 4])
        let actions = try fetchStrings(store, "SELECT action FROM memory_audit ORDER BY seq ASC").map { $0[0] }
        XCTAssertEqual(actions, ["memory.add", "memory.add", "memory.supersede", "memory.merge"])
        try verifyAuditChain(store, expectedCount: 4)
    }

    // MARK: - Update

    func testUpdateResealsSnapshotAndColumnsOnPreconditionMatch() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember())])

        let update = BurnBarMemoryAuthorityUpdate(
            memoryID: "memory-1",
            sourceKind: "chat",
            kind: "preference",
            confidence: 0.95,
            updatedAtText: "2026-09-23 07:00:00.000",
            reseal: BurnBarMemoryAuthorityReseal(
                expectedBodyHash: String(repeating: "ab", count: 32),
                expectedUpdatedAtText: "2026-09-23 05:00:00.000",
                snapshot: BurnBarMemoryAuthoritySnapshotRow(
                    id: "snapshot-memory-1",
                    memoryID: "memory-1",
                    bodyRef: "memory_body_snapshots:snapshot-memory-1",
                    snapshotJSON: #"{"schemaVersion":1,"edited":true}"#,
                    bodyHash: String(repeating: "01", count: 32),
                    sourceKind: "chat",
                    createdAtText: "2026-09-23 05:00:00.000",
                    updatedAtText: "2026-09-23 07:00:00.000"
                )
            ),
            audit: audit(action: "memory.update")
        )
        _ = try apply(store, [.updateBody(update)])

        let row = try fetchStrings(store, "SELECT kind, confidence, updated_at FROM agent_memories WHERE id = 'memory-1'")
        XCTAssertEqual(row, [["preference", "0.95", "2026-09-23 07:00:00.000"]])
        let seal = try fetchStrings(store, "SELECT body_hash, snapshot_json, updated_at FROM memory_body_snapshots WHERE memory_id = 'memory-1'")
        XCTAssertEqual(seal, [[String(repeating: "01", count: 32), #"{"schemaVersion":1,"edited":true}"#, "2026-09-23 07:00:00.000"]])
        try verifyAuditChain(store, expectedCount: 2)
    }

    func testUpdateWithoutResealLeavesTheSnapshotUntouched() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember())])

        let update = BurnBarMemoryAuthorityUpdate(
            memoryID: "memory-1",
            sourceKind: "chat",
            kind: nil,
            confidence: 0.5,
            updatedAtText: "2026-09-23 07:00:00.000",
            reseal: nil,
            audit: audit(action: "memory.update")
        )
        _ = try apply(store, [.updateBody(update)])

        let seal = try fetchStrings(store, "SELECT body_hash, updated_at FROM memory_body_snapshots WHERE memory_id = 'memory-1'")
        XCTAssertEqual(seal, [[String(repeating: "ab", count: 32), "2026-09-23 05:00:00.000"]])
        let row = try fetchStrings(store, "SELECT kind, confidence FROM agent_memories WHERE id = 'memory-1'")
        XCTAssertEqual(row, [["fact", "0.5"]])
    }

    func testUpdateWithStalePreconditionRefusesWithoutApplying() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember())])

        let update = BurnBarMemoryAuthorityUpdate(
            memoryID: "memory-1",
            sourceKind: "chat",
            kind: "preference",
            confidence: nil,
            updatedAtText: "2026-09-23 07:00:00.000",
            reseal: BurnBarMemoryAuthorityReseal(
                expectedBodyHash: String(repeating: "ff", count: 32),
                expectedUpdatedAtText: "2026-09-23 05:00:00.000",
                snapshot: snapshot()
            ),
            audit: audit(action: "memory.update")
        )
        XCTAssertThrowsError(try apply(store, [.updateBody(update)])) { error in
            guard case .memoryAuthorityConflict = error as? BurnBarProjectCodeMemoryStoreError else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        // Nothing applied: the row, the snapshot, and the chain are untouched.
        XCTAssertEqual(try fetchStrings(store, "SELECT kind FROM agent_memories WHERE id = 'memory-1'"), [["fact"]])
        XCTAssertEqual(
            try fetchStrings(store, "SELECT body_hash FROM memory_body_snapshots WHERE memory_id = 'memory-1'"),
            [[String(repeating: "ab", count: 32)]]
        )
        try verifyAuditChain(store, expectedCount: 1)
    }

    func testConflictOnALaterOperationRollsBackTheWholeMutation() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember())])

        let stale = BurnBarMemoryAuthorityUpdate(
            memoryID: "memory-1",
            sourceKind: "chat",
            kind: nil,
            confidence: nil,
            updatedAtText: "2026-09-23 07:00:00.000",
            reseal: BurnBarMemoryAuthorityReseal(
                expectedBodyHash: nil,
                expectedUpdatedAtText: nil,
                snapshot: snapshot()
            ),
            audit: audit(action: "memory.update")
        )
        XCTAssertThrowsError(try apply(store, [
            .appendAudit(audit(action: "memory.candidate_dropped")),
            .updateBody(stale)
        ])) { error in
            guard case .memoryAuthorityConflict = error as? BurnBarProjectCodeMemoryStoreError else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        // The valid first operation did not half-land.
        try verifyAuditChain(store, expectedCount: 1)
    }

    // MARK: - Review

    func testReviewApproveMarksPendingTombstoneReplicated() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember())])
        try store.execute(
            "INSERT INTO memory_fact_tombstones (id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
            [.text("tomb-1"), .text("user-1"), .text("memory-1"), .text("[]"), .text("user_delete"), .text("2026-09-23 04:00:00.000")]
        )

        let review = BurnBarMemoryAuthorityReview(
            memoryID: "memory-1",
            sourceKind: "chat",
            reviewStatus: "approved",
            updatedAtText: "2026-09-23T07:00:00.000Z",
            factTombstone: nil,
            markFactTombstoneReplicated: true,
            replicatedAtText: "2026-09-23 07:00:00.000",
            audit: audit(action: "memory.approve")
        )
        _ = try apply(store, [.setReviewStatus(review)])

        // The legacy ISO quirk in `updated_at` is preserved byte-for-byte.
        let row = try fetchStrings(store, "SELECT review_status, updated_at FROM agent_memories WHERE id = 'memory-1'")
        XCTAssertEqual(row, [["approved", "2026-09-23T07:00:00.000Z"]])
        let tomb = try fetchStrings(store, "SELECT replicated_at FROM memory_fact_tombstones WHERE id = 'tomb-1'")
        XCTAssertEqual(tomb, [["2026-09-23 07:00:00.000"]])
        try verifyAuditChain(store, expectedCount: 2)
    }

    func testReviewUnapproveOverwritesTombstoneIncludingRefs() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember())])
        try store.execute(
            "UPDATE agent_memories SET review_status = 'approved' WHERE id = 'memory-1'",
            []
        )
        try store.execute(
            "INSERT INTO memory_fact_tombstones (id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text("tomb-1"), .text("user-1"), .text("memory-1"), .text(#"["stale"]"#), .text("clear_history"), .text("2026-09-20 00:00:00.000"), .text("2026-09-21 00:00:00.000")]
        )

        let review = BurnBarMemoryAuthorityReview(
            memoryID: "memory-1",
            sourceKind: "chat",
            reviewStatus: "quarantined",
            updatedAtText: "2026-09-23T07:00:00.000Z",
            factTombstone: factTombstone(),
            markFactTombstoneReplicated: false,
            replicatedAtText: nil,
            audit: audit(action: "memory.reject")
        )
        _ = try apply(store, [.setReviewStatus(review)])

        let tomb = try fetchStrings(store, "SELECT user_id, source_refs_json, reason, created_at, replicated_at FROM memory_fact_tombstones WHERE id = 'tomb-1'")
        XCTAssertEqual(tomb, [["user-1", "[]", "user_delete", "2026-09-23 05:00:00.000", nil]])
    }

    // MARK: - Delete

    func testDeleteChatCascadeRemovesRowsAndKeepsTombstone() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember())])
        try store.execute(
            "INSERT INTO memory_embedding_refs (memory_id, embedding_version_id, dimension, vector, norm, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            [.text("memory-1"), .text("v1"), .int(3), .blob(Data([1, 2, 3])), .double(1.0), .text("2026-09-23 05:00:00.000")]
        )

        let delete = BurnBarMemoryAuthorityDelete(
            memoryID: "memory-1",
            sourceKind: "chat",
            agent: nil,
            factTombstone: factTombstone(),
            blankedBodyUpdatedAtText: nil,
            audit: audit(action: "memory.delete")
        )
        _ = try apply(store, [.deleteMemory(delete)])

        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM agent_memories"), [0])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_body_snapshots"), [0])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_provenance"), [0])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_embedding_refs"), [0])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_fact_tombstones"), [1])
        try verifyAuditChain(store, expectedCount: 2)
    }

    func testDeleteAgentCascadeBlanksSyncBodyWithLegacyStamp() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember(memoryID: "agent-1"))])
        try store.execute("UPDATE agent_memories SET source_kind = 'agent' WHERE id = 'agent-1'", [])
        try store.execute(
            "INSERT INTO memory_quarantine_bodies (memory_id, project_id, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            [.text("agent-1"), .text("project-1"), .text("secret"), .text("2026-09-23 05:00:00.000"), .text("2026-09-23 05:00:00.000")]
        )
        try store.execute(
            "INSERT INTO agent_memory_bodies (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text("agent-1"), .text("project-1"), .text("engine-1"), .text("secret"), .text(String(repeating: "aa", count: 32)), .text("2026-09-23 05:00:00.000"), .text("2026-09-23 05:00:00.000")]
        )

        let delete = BurnBarMemoryAuthorityDelete(
            memoryID: "agent-1",
            sourceKind: "agent",
            agent: BurnBarMemoryAuthorityAgentDelete(factTombstone: factTombstone(id: "tomb-agent", memoryID: "agent-1", overwrite: true, refreshRefs: false)),
            factTombstone: nil,
            blankedBodyUpdatedAtText: "2026-09-23T07:00:00.000Z",
            audit: audit(action: "memory.delete", subjectID: "agent-1")
        )
        _ = try apply(store, [.deleteMemory(delete)])

        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM agent_memories"), [0])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_quarantine_bodies"), [0])
        // BLANKED, not deleted — and the legacy ISO stamp preserved.
        let bodies = try fetchStrings(store, "SELECT engine_memory_id, body, body_hash, updated_at FROM agent_memory_bodies WHERE memory_id = 'agent-1'")
        XCTAssertEqual(bodies, [["engine-1", "", "", "2026-09-23T07:00:00.000Z"]])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_fact_tombstones"), [1])
    }

    // MARK: - Sweeps

    func testReconcileSuppressesEveryMatchWithPerRowAudit() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember(memoryID: "memory-1"))])
        _ = try apply(store, [.remember(remember(memoryID: "memory-2"))])

        let reconcile = BurnBarMemoryAuthorityReconcile(
            matches: [
                BurnBarMemoryAuthorityReconcileMatch(
                    memoryID: "memory-1",
                    projectID: "project-1",
                    labels: ["memory_id:memory-1", "reason:source_tombstone", "source_kind:chat"],
                    labelsJSON: #"["memory_id:memory-1","reason:source_tombstone","source_kind:chat"]"#
                ),
                BurnBarMemoryAuthorityReconcileMatch(
                    memoryID: "memory-2",
                    projectID: "project-1",
                    labels: ["memory_id:memory-2", "reason:source_tombstone", "source_kind:chat"],
                    labelsJSON: #"["memory_id:memory-2","reason:source_tombstone","source_kind:chat"]"#
                )
            ],
            sourceKind: "chat",
            validToText: "2026-09-23 07:00:00.000",
            updatedAtText: "2026-09-23 07:00:00.000",
            timestampText: "2026-09-23T07:00:00.000Z"
        )
        let response = try apply(store, [.reconcileSuppressions(reconcile)])

        XCTAssertEqual(response.results.first?.affectedRows, 2)
        XCTAssertEqual(
            try fetchInts(store, "SELECT COUNT(*) FROM agent_memories WHERE valid_to = '2026-09-23 07:00:00.000'"),
            [2]
        )
        try verifyAuditChain(store, expectedCount: 4)
    }

    func testClaimClaimsOnlyUnownedAgentRows() throws {
        let store = try makeStore()
        _ = try apply(store, [.remember(remember(memoryID: "memory-1"))])
        _ = try apply(store, [.remember(remember(memoryID: "memory-2"))])
        _ = try apply(store, [.remember(remember(memoryID: "memory-3"))])
        try store.execute("UPDATE agent_memories SET source_kind = 'agent', user_id = NULL WHERE id IN ('memory-1', 'memory-2')", [])
        try store.execute("UPDATE agent_memories SET source_kind = 'agent', user_id = 'owner' WHERE id = 'memory-3'", [])

        let response = try apply(store, [.claimUnowned(BurnBarMemoryAuthorityClaim(userID: "user-9", sourceKind: "agent"))])

        XCTAssertEqual(response.results.first?.affectedRows, 2)
        XCTAssertEqual(
            try fetchStrings(store, "SELECT user_id FROM agent_memories WHERE id IN ('memory-1', 'memory-2', 'memory-3') ORDER BY id ASC"),
            [["user-9"], ["user-9"], ["owner"]]
        )
    }

    func testEnqueueKeepsExistingRowsAndCountsOnlyNew() throws {
        let store = try makeStore()
        try store.execute(
            "INSERT INTO memory_fact_tombstones (id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
            [.text("tomb-1"), .text("user-1"), .text("memory-1"), .text("[]"), .text("user_delete"), .text("2026-09-20 00:00:00.000")]
        )

        let enqueue = BurnBarMemoryAuthorityEnqueueTombstones(tombstones: [
            factTombstone(id: "tomb-1", overwrite: false, refreshRefs: false),
            factTombstone(id: "tomb-2", memoryID: "memory-2", overwrite: false, refreshRefs: false)
        ])
        let response = try apply(store, [.enqueueFactTombstones(enqueue)])

        XCTAssertEqual(response.results.first?.affectedRows, 1)
        let kept = try fetchStrings(store, "SELECT created_at FROM memory_fact_tombstones WHERE id = 'tomb-1'")
        XCTAssertEqual(kept, [["2026-09-20 00:00:00.000"]])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_fact_tombstones"), [2])
    }

    func testRecordSourceTombstoneOverwritesAndClearsReplication() throws {
        let store = try makeStore()
        try store.execute(
            "INSERT INTO memory_source_tombstones (id, user_id, thread_logical_id, message_id, content_hash, reason, created_at, replicated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [.text("source-tomb-1"), .text("user-1"), .text("thread-1"), .null, .null, .text("clear_history"), .text("2026-09-20 00:00:00.000"), .text("2026-09-21 00:00:00.000")]
        )

        let record = BurnBarMemoryAuthoritySourceTombstone(tombstone: BurnBarMemoryAuthoritySourceTombstoneRow(
            id: "source-tomb-1",
            userID: "user-2",
            threadLogicalID: "thread-1",
            messageID: nil,
            contentHash: nil,
            reason: "user_delete",
            createdAtText: "2026-09-23 05:00:00.000"
        ))
        _ = try apply(store, [.recordSourceTombstone(record)])

        let row = try fetchStrings(store, "SELECT user_id, reason, created_at, replicated_at FROM memory_source_tombstones WHERE id = 'source-tomb-1'")
        XCTAssertEqual(row, [["user-2", "user_delete", "2026-09-23 05:00:00.000", nil]])
    }

    func testMarkReplicatedSetsBothTables() throws {
        let store = try makeStore()
        try store.execute(
            "INSERT INTO memory_fact_tombstones (id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
            [.text("tomb-1"), .text("user-1"), .text("memory-1"), .text("[]"), .text("user_delete"), .text("2026-09-23 05:00:00.000")]
        )
        try store.execute(
            "INSERT INTO memory_source_tombstones (id, user_id, thread_logical_id, message_id, content_hash, reason, created_at, replicated_at) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)",
            [.text("source-tomb-1"), .text("user-1"), .text("thread-1"), .null, .null, .text("user_delete"), .text("2026-09-23 05:00:00.000")]
        )

        _ = try apply(store, [
            .markTombstoneReplicated(BurnBarMemoryAuthorityMarkReplicated(
                table: .fact,
                id: "tomb-1",
                replicatedAtText: "2026-09-23 07:00:00.000"
            )),
            .markTombstoneReplicated(BurnBarMemoryAuthorityMarkReplicated(
                table: .source,
                id: "source-tomb-1",
                replicatedAtText: "2026-09-23 07:00:00.000"
            ))
        ])

        XCTAssertEqual(
            try fetchStrings(store, "SELECT replicated_at FROM memory_fact_tombstones WHERE id = 'tomb-1'"),
            [["2026-09-23 07:00:00.000"]]
        )
        XCTAssertEqual(
            try fetchStrings(store, "SELECT replicated_at FROM memory_source_tombstones WHERE id = 'source-tomb-1'"),
            [["2026-09-23 07:00:00.000"]]
        )
    }

    // MARK: - Audit chain

    func testNastyLabelsBindVerbatimAndStillVerify() throws {
        let store = try makeStore()
        let labels = ["a\"b", "c\\d", "e:f,g", "ünïcödé", "🎛️panel", "plain"].sorted()
        let json = String(data: try JSONSerialization.data(withJSONObject: labels), encoding: .utf8)!
        let event = BurnBarMemoryAuthorityAuditEvent(
            action: "memory.candidate_dropped",
            projectID: "project-1",
            subjectID: "memory-1",
            labels: labels,
            labelsJSON: json,
            timestampText: "2026-09-23T05:00:00.000Z"
        )
        _ = try apply(store, [.appendAudit(event)])

        XCTAssertEqual(try fetchStrings(store, "SELECT labels_json FROM memory_audit"), [[json]])
        try verifyAuditChain(store, expectedCount: 1)
    }

    func testCrossLaneAppendsInterleaveIntoOneVerifyingChain() throws {
        let store = try makeStore()
        _ = try store.auditEvent(action: "daemon.first", domain: "memory", projectID: "project-1", subjectID: nil, labels: ["lane:daemon"])
        _ = try apply(store, [.appendAudit(audit(action: "memory.candidate_dropped"))])
        _ = try store.auditEvent(action: "daemon.second", domain: "memory", projectID: "project-1", subjectID: nil, labels: ["lane:daemon"])

        let actors = try fetchStrings(store, "SELECT actor FROM memory_audit ORDER BY seq ASC").map { $0[0] }
        XCTAssertEqual(actors, ["daemon", "app", "daemon"])
        try verifyAuditChain(store, expectedCount: 3)
    }

    // MARK: - Validation

    func testValidationRejectsMalformedMutations() throws {
        let store = try makeStore()
        let cases: [(String, [BurnBarMemoryAuthorityOperation])] = [
            ("blank memory id", [.remember(BurnBarMemoryAuthorityRemember(
                snapshot: snapshot(),
                memory: memory(id: "  "),
                provenance: [],
                audits: [audit(action: "memory.add")],
                merge: nil
            ))]),
            // Short body hashes are covered by the dedicated
            // `testValidationRejectsShortBodyHash` below.
            ("invalid snapshot JSON", [.remember(BurnBarMemoryAuthorityRemember(
                snapshot: BurnBarMemoryAuthoritySnapshotRow(
                    id: "snapshot-memory-1",
                    memoryID: "memory-1",
                    bodyRef: "memory_body_snapshots:snapshot-memory-1",
                    snapshotJSON: "{nope",
                    bodyHash: String(repeating: "ab", count: 32),
                    sourceKind: "chat",
                    createdAtText: "2026-09-23 05:00:00.000",
                    updatedAtText: "2026-09-23 05:00:00.000"
                ),
                memory: memory(),
                provenance: [],
                audits: [audit(action: "memory.add")],
                merge: nil
            ))]),
            ("unparseable timestamp", [.appendAudit(BurnBarMemoryAuthorityAuditEvent(
                action: "memory.add",
                projectID: "project-1",
                subjectID: "memory-1",
                labels: ["a"],
                labelsJSON: #"["a"]"#,
                timestampText: "not-a-date"
            ))]),
            ("unsorted labels", [.appendAudit(BurnBarMemoryAuthorityAuditEvent(
                action: "memory.add",
                projectID: "project-1",
                subjectID: "memory-1",
                labels: ["b", "a"],
                labelsJSON: #"["b","a"]"#,
                timestampText: "2026-09-23T05:00:00.000Z"
            ))]),
            ("labels JSON mismatch", [.appendAudit(BurnBarMemoryAuthorityAuditEvent(
                action: "memory.add",
                projectID: "project-1",
                subjectID: "memory-1",
                labels: ["a"],
                labelsJSON: #"["b"]"#,
                timestampText: "2026-09-23T05:00:00.000Z"
            ))]),
            ("bad action charset", [.appendAudit(audit(action: "memory;drop"))]),
            ("supersede count mismatch", [.remember(BurnBarMemoryAuthorityRemember(
                snapshot: snapshot(),
                memory: memory(),
                provenance: [],
                audits: [audit(action: "memory.add")],
                merge: BurnBarMemoryAuthorityMerge(
                    winnerID: "memory-1",
                    loserIDs: ["memory-0"],
                    sourceKinds: ["chat"],
                    storageProjectID: "project-1",
                    nowText: "2026-09-23 05:00:00.000",
                    nowTimestampText: "2026-09-23T05:00:00.000Z",
                    provenanceCopies: [],
                    supersedeAudits: [],
                    mergeAudit: audit(action: "memory.merge")
                )
            ))]),
            ("mark without stamp", [.setReviewStatus(BurnBarMemoryAuthorityReview(
                memoryID: "memory-1",
                sourceKind: "chat",
                reviewStatus: "approved",
                updatedAtText: "2026-09-23T05:00:00.000Z",
                factTombstone: nil,
                markFactTombstoneReplicated: true,
                replicatedAtText: nil,
                audit: audit(action: "memory.approve")
            ))]),
            ("blanked stamp without agent", [.deleteMemory(BurnBarMemoryAuthorityDelete(
                memoryID: "memory-1",
                sourceKind: "chat",
                agent: nil,
                factTombstone: nil,
                blankedBodyUpdatedAtText: "2026-09-23T05:00:00.000Z",
                audit: audit(action: "memory.delete")
            ))]),
            ("negative occurrence", [.remember(BurnBarMemoryAuthorityRemember(
                snapshot: snapshot(),
                memory: memory(),
                provenance: [BurnBarMemoryAuthorityProvenanceRow(
                    id: "prov-1",
                    memoryID: "memory-1",
                    sourceKind: "chat",
                    threadLogicalID: "thread-1",
                    messageID: nil,
                    role: "user",
                    authoredAtText: "2026-09-23 04:00:00.000",
                    contentHash: String(repeating: "cd", count: 32),
                    occurrence: -1,
                    xdeviceHMAC: String(repeating: "ef", count: 32),
                    citationState: "live",
                    createdAtText: "2026-09-23 05:00:00.000"
                )],
                audits: [audit(action: "memory.add")],
                merge: nil
            ))]),
            ("infinite confidence", [.remember(BurnBarMemoryAuthorityRemember(
                snapshot: snapshot(),
                memory: BurnBarMemoryAuthorityMemoryRow(
                    id: "memory-1",
                    projectID: "project-1",
                    kind: "fact",
                    scopeText: "chat",
                    confidence: Double.infinity,
                    bodyRef: "memory_body_snapshots:snapshot-memory-1",
                    bodyRedacted: "memory_body_snapshots:snapshot-memory-1",
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
                    appID: nil
                ),
                provenance: [],
                audits: [audit(action: "memory.add")],
                merge: nil
            ))])
        ]
        for (name, operations) in cases {
            XCTAssertThrowsError(try apply(store, operations), name) { error in
                guard case .memoryAuthorityInvalidRequest = error as? BurnBarProjectCodeMemoryStoreError else {
                    return XCTFail("\(name): expected invalid request, got \(error)")
                }
            }
        }
        // Every refusal applied nothing.
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM agent_memories"), [0])
        XCTAssertEqual(try fetchInts(store, "SELECT COUNT(*) FROM memory_audit"), [0])
    }

    func testValidationRejectsShortBodyHash() throws {
        let store = try makeStore()
        var bad = snapshot()
        bad = BurnBarMemoryAuthoritySnapshotRow(
            id: bad.id,
            memoryID: bad.memoryID,
            bodyRef: bad.bodyRef,
            snapshotJSON: bad.snapshotJSON,
            bodyHash: "abc123",
            sourceKind: bad.sourceKind,
            createdAtText: bad.createdAtText,
            updatedAtText: bad.updatedAtText
        )
        XCTAssertThrowsError(try apply(store, [.remember(BurnBarMemoryAuthorityRemember(
            snapshot: bad,
            memory: memory(),
            provenance: [],
            audits: [audit(action: "memory.add")],
            merge: nil
        ))])) { error in
            guard case .memoryAuthorityInvalidRequest = error as? BurnBarProjectCodeMemoryStoreError else {
                return XCTFail("expected invalid request, got \(error)")
            }
        }
    }

    func testEmptyOperationsAndForeignActorAreRejected() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.memoryAuthorityApplyAppLane(
            BurnBarMemoryAuthorityApplyRequest(mutationID: "m", actor: "daemon", operations: [.appendAudit(audit(action: "memory.add"))])
        )) { error in
            guard case .memoryAuthorityInvalidRequest = error as? BurnBarProjectCodeMemoryStoreError else {
                return XCTFail("expected invalid request, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.memoryAuthorityApplyAppLane(
            BurnBarMemoryAuthorityApplyRequest(mutationID: "m", actor: "app", operations: [])
        )) { error in
            guard case .memoryAuthorityInvalidRequest = error as? BurnBarProjectCodeMemoryStoreError else {
                return XCTFail("expected invalid request, got \(error)")
            }
        }
    }
}
