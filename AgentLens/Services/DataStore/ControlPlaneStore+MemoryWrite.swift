import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    /// How a reseal treats the sealed snapshot's A-MEM `context` sentence.
    ///
    /// A body edit must never touch it *implicitly*: resealing without carrying
    /// the stored sentence forward destroys it and downgrades a usage snapshot
    /// from `schemaVersion` 2 back to 1. `MemoryPatch` deliberately does not
    /// carry this — the `MemoryServing` contract is frozen and cross-track
    /// coordinated, so the knob lives on the store method instead.
    enum MemoryContextEdit: Sendable, Equatable {
        /// Carry the stored context sentence forward unchanged. The default,
        /// and the only correct behavior for a body-only edit.
        case preserve
        /// Replace the context sentence deliberately. `nil` (or whitespace)
        /// clears it, taking the snapshot back to `schemaVersion` 1.
        case replace(String?)
    }

    func updateChatMemoryAuthorityRecord(id: MemoryID, patch: MemoryPatch, now: Date = Date()) async throws -> Bool {
        try await updateMemoryAuthorityRecord(id: id, patch: patch, sourceKinds: [.chat], now: now)
    }

    func updateMemoryAuthorityRecord(
        id: MemoryID,
        patch: MemoryPatch,
        sourceKinds: Set<MemorySourceKind>,
        context: MemoryContextEdit = .preserve,
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(id: id, sourceKinds: sourceKinds) else { return false }
        let partition = MemoryStoragePartition(existing.sourceKind)
        let patchedBody = patch.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let patchedBody, patchedBody.isEmpty {
            throw ChatMemoryAuthorityError.emptyBody
        }
        // `let`, not `var` — the write closure below captures it, and Swift 6
        // rejects a captured `var` in concurrently-executing code.
        let replacementContext: String? = {
            guard case .replace(let value) = context else { return nil }
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == true ? nil : trimmed
        }()
        // G7 covers every string this call would seal into `snapshot_json` —
        // the new body and, when the caller replaces it, the context sentence.
        // Order-preserving union so a body-only edit reports exactly the labels
        // it reported before this parameter existed.
        var secretLabels: [String] = []
        for text in [patchedBody, replacementContext].compactMap({ $0 }) {
            for label in Self.memoryGateFindingIDs(in: text) where secretLabels.contains(label) == false {
                secretLabels.append(label)
            }
        }
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

        // A reseal is needed when this call changes sealed content: a new body,
        // or a deliberate context replacement on an unchanged body.
        let resealsSnapshot = patchedBody != nil || context != .preserve
        let snapshotSlug = Self.memorySnapshotSlug(id)
        let auditLabels = [
            "memory_id:\(id)",
            "source_kind:\(existing.sourceKind.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            // Read the stored snapshot inside the write transaction so a
            // concurrent reseal cannot slip between the read and the rewrite.
            let stored = try resealsSnapshot ? Self.memoryBodySnapshot(db: db, id: id) : nil
            // `stored?.body` only carries a context-only edit; a body patch
            // reseals even when the snapshot row is somehow absent, exactly as
            // this path did before.
            if resealsSnapshot, let resealBody = patchedBody ?? stored?.body {
                let resealContext: String?
                switch context {
                case .preserve: resealContext = stored?.context
                case .replace: resealContext = replacementContext
                }
                let bodyHash = Self.sha256Hex(resealBody)
                let bodyRef = Self.memorySnapshotRef(snapshotSlug)
                let snapshotJSON = try Self.memoryBodySnapshotJSON(
                    memoryID: id,
                    body: resealBody,
                    bodyHash: bodyHash,
                    citations: existing.citations,
                    createdAt: existing.createdAt,
                    sourceKind: existing.sourceKind,
                    context: resealContext
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
