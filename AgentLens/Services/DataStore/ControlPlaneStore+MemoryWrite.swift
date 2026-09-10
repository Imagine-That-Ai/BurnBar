import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    func updateChatMemoryAuthorityRecord(id: MemoryID, patch: MemoryPatch, now: Date = Date()) async throws -> Bool {
        try await updateMemoryAuthorityRecord(id: id, patch: patch, sourceKinds: [.chat], now: now)
    }

    func updateMemoryAuthorityRecord(
        id: MemoryID,
        patch: MemoryPatch,
        sourceKinds: Set<MemorySourceKind>,
        actingAccountUserID: String? = nil,
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(
            id: id,
            sourceKinds: sourceKinds,
            actingAccountUserID: actingAccountUserID
        ) else { return false }
        let partition = MemoryStoragePartition(existing.sourceKind)
        let patchedBody = patch.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let patchedBody {
            guard patchedBody.isEmpty == false else { throw ChatMemoryAuthorityError.emptyBody }
            let secretLabels = Self.memoryGateFindingIDs(in: patchedBody)
            if secretLabels.isEmpty == false {
                try await appendMemoryAuditEvent(
                    action: "memory.secret_rejected",
                    projectID: Self.memoryStorageProjectID(for: existing.scope, partition: partition),
                    subjectID: id,
                    labels: [
                        "memory_id": id,
                        "source_kind": existing.sourceKind.rawValue,
                        "labels": secretLabels.joined(separator: ",")
                    ],
                    now: now
                )
                throw ChatMemoryAuthorityError.secretRejected(labels: secretLabels)
            }
        }

        let snapshotSlug = Self.memorySnapshotSlug(id)
        let auditLabels = [
            "memory_id:\(id)",
            "source_kind:\(existing.sourceKind.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            if let patchedBody {
                let bodyHash = Self.sha256Hex(patchedBody)
                let bodyRef = Self.memorySnapshotRef(snapshotSlug)
                let snapshotJSON = try Self.memoryBodySnapshotJSON(
                    memoryID: id,
                    body: patchedBody,
                    bodyHash: bodyHash,
                    citations: existing.citations,
                    createdAt: existing.createdAt,
                    sourceKind: existing.sourceKind
                )
                try db.execute(
                    sql: """
                    INSERT INTO memory_body_snapshots (
                        id, memory_id, body_ref, snapshot_json, body_hash, source_kind, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(memory_id) DO UPDATE SET
                        body_ref = excluded.body_ref,
                        snapshot_json = excluded.snapshot_json,
                        body_hash = excluded.body_hash,
                        source_kind = excluded.source_kind,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        snapshotSlug,
                        id,
                        bodyRef,
                        snapshotJSON,
                        bodyHash,
                        existing.sourceKind.rawValue,
                        existing.createdAt,
                        now
                    ]
                )
            }
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET kind = COALESCE(?, kind),
                    confidence = COALESCE(?, confidence),
                    updated_at = ?
                WHERE id = ?
                  AND source_kind = ?
                """,
                arguments: [
                    patch.kind?.rawValue,
                    patch.confidence,
                    now,
                    id,
                    existing.sourceKind.rawValue
                ]
            )
            try Self.insertMemoryAuditEvent(
                db: db,
                action: "memory.update",
                projectID: Self.memoryStorageProjectID(for: existing.scope, partition: partition),
                subjectID: id,
                labels: auditLabels,
                nowString: nowString
            )
        }
        return true
    }

    func setChatMemoryReviewStatus(id: MemoryID, status: MemoryReviewStatus, now: Date = Date()) async throws -> Bool {
        try await setMemoryReviewStatus(id: id, status: status, sourceKinds: [.chat], now: now)
    }

    func setMemoryReviewStatus(
        id: MemoryID,
        status: MemoryReviewStatus,
        sourceKinds: Set<MemorySourceKind>,
        actingAccountUserID: String? = nil,
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(
            id: id,
            sourceKinds: sourceKinds,
            actingAccountUserID: actingAccountUserID
        ) else { return false }
        let partition = MemoryStoragePartition(existing.sourceKind)
        let auditLabels = [
            "memory_id:\(id)",
            "review_status:\(status.rawValue)",
            "source_kind:\(existing.sourceKind.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            if existing.reviewStatus == .approved,
               status != .approved,
               existing.scope.userID != nil {
                try Self.insertMemoryFactTombstone(
                    db: db,
                    memory: existing,
                    reason: "review_status_\(status.rawValue)",
                    now: now
                )
            }
            if existing.reviewStatus != .approved,
               status == .approved,
               existing.scope.userID != nil {
                try db.execute(
                    sql: """
                    UPDATE memory_fact_tombstones
                    SET replicated_at = ?
                    WHERE memory_id = ?
                      AND replicated_at IS NULL
                    """,
                    arguments: [now, id]
                )
            }
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET review_status = ?,
                    updated_at = ?
                WHERE id = ?
                  AND source_kind = ?
                """,
                arguments: [status.rawValue, nowString, id, existing.sourceKind.rawValue]
            )
            try Self.insertMemoryAuditEvent(
                db: db,
                action: status == .approved ? "memory.approve" : "memory.reject",
                projectID: Self.memoryStorageProjectID(for: existing.scope, partition: partition),
                subjectID: id,
                labels: auditLabels,
                nowString: nowString
            )
        }
        // The verdict is durable and audited above; publishing the BODY is the
        // daemon's, so an agent-lane verdict is handed to
        // `daemon.memory.review_status` and the daemon stays the single
        // publisher (I-56). The call never throws and never undoes the verdict:
        // an unreachable daemon leaves the row in the derived
        // pending-publication state the inbox shows and the next launch
        // retries. Chat and usage rows keep their bodies in the app's own
        // snapshot table and have nothing to hand over.
        if existing.sourceKind == .agent {
            // The stamp is the `updated_at` this verdict was committed under:
            // sent as the daemon's precondition so an RPC that lands after a
            // newer verdict is refused instead of resurrecting it (#2565-F4).
            await publishAgentMemoryReview(
                id: id,
                status: status,
                projectID: existing.scope.projectID,
                expectedUpdatedAt: nowString
            )
        }
        return true
    }

    func deleteChatMemoryAuthorityRecord(id: MemoryID, now: Date = Date()) async throws -> Bool {
        try await deleteMemoryAuthorityRecord(id: id, sourceKinds: [.chat], now: now)
    }

    func deleteMemoryAuthorityRecord(
        id: MemoryID,
        sourceKinds: Set<MemorySourceKind>,
        actingAccountUserID: String? = nil,
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(
            id: id,
            sourceKinds: sourceKinds,
            actingAccountUserID: actingAccountUserID
        ) else { return false }
        let partition = MemoryStoragePartition(existing.sourceKind)
        let auditLabels = [
            "memory_id:\(id)",
            "source_kind:\(existing.sourceKind.rawValue)"
        ]
        let nowString = Self.iso8601String(now)

        // Review #2565-F1: an agent-lane forget goes to the daemon FIRST and
        // fails closed. The daemon owns the mirrored memory's other halves —
        // the quarantined plaintext in `memory_quarantine_bodies`, the
        // published project-memory section, the engine mirror — and it needs
        // this row's `project_id` to find them, so the row must still exist
        // when the call lands. A refused or unreachable daemon throws and
        // every local byte stays: a forget that cannot reach the daemon is
        // not a forget.
        let engineMemoryID: String?
        if existing.sourceKind == .agent {
            let resolvedEngineID = try await self.engineMemoryID(for: id)
            guard let projectID = existing.scope.projectID, projectID.isEmpty == false,
                  let root = try await memoryProjectRecordedRoot(engineProjectID: projectID) else {
                throw ChatMemoryAuthorityError.agentForgetRequiresDaemon
            }
            let response = try await forgetAgentMemory(id, root)
            guard response.localDeleted,
                  response.memoryID == id,
                  response.projectID == projectID else {
                throw ChatMemoryAuthorityError.agentForgetRequiresDaemon
            }
            engineMemoryID = resolvedEngineID
        } else {
            engineMemoryID = nil
        }

        try await dbQueue.write { db in
            // The sealed cloud copy deletes through a fact tombstone — keyed on
            // the engine id for a mirrored row, the same spelling
            // `enqueueTombstonesForUnsyncableAgentMemories` uses, because that
            // is what the cloud document is named. A mirrored row that was ever
            // owned may have been uploaded under ANY earlier verdict, so the
            // tombstone is not gated on `review_status` the way the chat path's
            // is: a rejected or still-parked row can still have a cloud copy.
            if existing.sourceKind == .agent {
                if let owner = existing.scope.userID ?? actingAccountUserID {
                    try Self.insertAgentMemoryFactTombstone(
                        db: db,
                        memoryID: id,
                        userID: owner,
                        engineMemoryID: engineMemoryID,
                        reason: "user_delete",
                        now: now
                    )
                }
            } else if existing.reviewStatus == .approved,
                      existing.scope.userID != nil {
                try Self.insertMemoryFactTombstone(
                    db: db,
                    memory: existing,
                    reason: "user_delete",
                    now: now
                )
            }
            try db.execute(sql: "DELETE FROM memory_embedding_refs WHERE memory_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM memory_provenance WHERE memory_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM agent_memories WHERE id = ? AND source_kind = ?", arguments: [id, existing.sourceKind.rawValue])
            try db.execute(sql: "DELETE FROM memory_body_snapshots WHERE memory_id = ?", arguments: [id])
            // The daemon's forget already removed its own copies; these are the
            // same shared tables, so the deletes are belt-and-suspenders for a
            // pre-forget daemon build or a row it never saw. The sync-body row
            // is BLANKED, not deleted: `engine_memory_id` is a routing label,
            // not memory content, and it is the only handle the fact-tombstone
            // drain has on the sealed cloud document — deleting the row would
            // make `cloudFactIdentity` fall back to the local id and leave the
            // engine-keyed copy behind for ever.
            if existing.sourceKind == .agent {
                try db.execute(sql: "DELETE FROM memory_quarantine_bodies WHERE memory_id = ?", arguments: [id])
                try db.execute(
                    sql: "UPDATE agent_memory_bodies SET body = '', body_hash = '', updated_at = ? WHERE memory_id = ?",
                    arguments: [nowString, id]
                )
            }
            try Self.insertMemoryAuditEvent(
                db: db,
                action: "memory.delete",
                projectID: Self.memoryStorageProjectID(for: existing.scope, partition: partition),
                subjectID: id,
                labels: auditLabels,
                nowString: nowString
            )
        }
        return true
    }

    func deleteChatMemoryAuthorityRecords(scope: MemoryScope, now: Date = Date()) async throws -> Int {
        let ids = try await chatMemoryAuthorityDeletionIDs(scope: scope)
        var records: [Memory] = []
        for id in ids {
            if let record = try await fetchChatMemoryAuthorityRecord(id: id) {
                records.append(record)
            }
        }
        var deleted = 0
        for record in records where try await deleteChatMemoryAuthorityRecord(id: record.id, now: now) {
            deleted += 1
        }
        // "Reset memory" must leave nothing readable behind. The blind-sync
        // inbox holds an opened plaintext copy of every fact pulled down from
        // the member's other devices, merged or not, and no other delete path
        // touches it — so a reset that skipped it would empty the surface the
        // member can see while leaving the copy they cannot.
        try await purgeAllRemoteMemoryFacts()
        return deleted
    }

    func listChatMemoryEntities() async throws -> [MemoryEntity] {
        let records = try await fetchActiveChatMemoryAuthorityRecords()
            .filter { $0.reviewStatus != .rejected }
        var counts: [String: Int] = [:]
        for memory in records {
            if let value = memory.scope.userID { counts["user_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.agentID { counts["agent_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.runID { counts["run_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.appID { counts["app_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.projectID { counts["project_id:\(value)", default: 0] += 1 }
        }
        return counts.map { key, count in
            let parts = key.split(separator: ":", maxSplits: 1)
            return MemoryEntity(
                keyName: String(parts.first ?? ""),
                value: String(parts.last ?? ""),
                count: count
            )
        }
        .sorted { lhs, rhs in
            if lhs.keyName == rhs.keyName { return lhs.value < rhs.value }
            return lhs.keyName < rhs.keyName
        }
    }

}
