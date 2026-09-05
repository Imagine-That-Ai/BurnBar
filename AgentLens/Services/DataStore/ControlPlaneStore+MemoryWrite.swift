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
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(id: id, sourceKinds: sourceKinds) else { return false }
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
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(id: id, sourceKinds: sourceKinds) else { return false }
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
                arguments: [status.rawValue, now, id, existing.sourceKind.rawValue]
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
        return true
    }

    func deleteChatMemoryAuthorityRecord(id: MemoryID, now: Date = Date()) async throws -> Bool {
        try await deleteMemoryAuthorityRecord(id: id, sourceKinds: [.chat], now: now)
    }

    func deleteMemoryAuthorityRecord(
        id: MemoryID,
        sourceKinds: Set<MemorySourceKind>,
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(id: id, sourceKinds: sourceKinds) else { return false }
        let partition = MemoryStoragePartition(existing.sourceKind)
        let auditLabels = [
            "memory_id:\(id)",
            "source_kind:\(existing.sourceKind.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            if existing.reviewStatus == .approved,
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
