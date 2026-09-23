import CryptoKit
import Foundation
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Local memory authority writer (test double)
//
// Wave 2.1c-iii: production memory authority writes go through the daemon
// (single writer, ADR-005). Tests that need a working memory store without
// a live daemon inject this double, which applies the finalized write set
// against the test queue with the exact pre-cutover local semantics — the
// same statements, in the same order, with the same conflict clauses the
// daemon applier runs. Test files are exempt from the dual-writer grep, so
// the legacy SQL lives here and only here.
//
// The audit chain uses the shared `openburnbar.memory_audit.v2` payload
// (sorted-keys JSON, SHA-256 hex), so rows this double appends verify
// through the real export chain verifier exactly like daemon rows.

final class LocalMemoryAuthorityWriter: MemoryAuthorityWriter {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func apply(_ request: BurnBarMemoryAuthorityApplyRequest) async throws -> BurnBarMemoryAuthorityApplyResponse {
        guard request.actor == "app" else {
            throw LocalMemoryAuthorityWriterError.invalidRequest("actor must be \"app\"")
        }
        guard request.operations.isEmpty == false else {
            throw LocalMemoryAuthorityWriterError.invalidRequest("operations must not be empty")
        }
        return try await dbQueue.write { db in
            for (index, operation) in request.operations.enumerated() {
                try Self.checkPreconditions(db: db, operation: operation, operationIndex: index)
            }
            var results: [BurnBarMemoryAuthorityOperationResult] = []
            results.reserveCapacity(request.operations.count)
            for operation in request.operations {
                results.append(try Self.applyOperation(db: db, operation: operation, actor: request.actor))
            }
            return BurnBarMemoryAuthorityApplyResponse(mutationID: request.mutationID, results: results)
        }
    }

    // MARK: - Preconditions

    private static func checkPreconditions(db: Database, operation: BurnBarMemoryAuthorityOperation, operationIndex: Int) throws {
        guard case .updateBody(let update) = operation, let reseal = update.reseal else { return }
        let stored = try Row.fetchOne(
            db,
            sql: "SELECT body_hash, updated_at FROM memory_body_snapshots WHERE memory_id = ?",
            arguments: [update.memoryID]
        )
        let storedHash: String? = stored?[0]
        let storedUpdatedAt: String? = stored?[1]
        guard storedHash == reseal.expectedBodyHash,
              storedUpdatedAt == reseal.expectedUpdatedAtText else {
            throw OpenBurnBarDaemonManagerError.rpcConflict(
                "operation \(operationIndex) reseal precondition failed for memory \(update.memoryID)"
            )
        }
    }

    // MARK: - Apply

    private static func applyOperation(
        db: Database,
        operation: BurnBarMemoryAuthorityOperation,
        actor: String
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        switch operation {
        case .remember(let remember):
            var affected = 0
            try upsertSnapshot(db: db, snapshot: remember.snapshot, affectedRows: &affected)
            let memory = remember.memory
            try db.execute(
                sql: """
                INSERT INTO agent_memories (
                    id, project_id, kind, scope, confidence, body_ref, body_redacted,
                    tags_json, source_path, valid_from, valid_to, superseded_by, created_at, updated_at,
                    source_kind, review_status, user_id, agent_id, run_id, app_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    memory.id,
                    memory.projectID,
                    memory.kind,
                    memory.scopeText,
                    memory.confidence,
                    memory.bodyRef,
                    memory.bodyRedacted,
                    memory.tagsJSON,
                    memory.sourcePath,
                    memory.validFromText,
                    memory.validToText,
                    memory.supersededBy,
                    memory.createdAtText,
                    memory.updatedAtText,
                    memory.sourceKind,
                    memory.reviewStatus,
                    memory.userID,
                    memory.agentID,
                    memory.runID,
                    memory.appID
                ]
            )
            affected += db.changesCount
            for provenance in remember.provenance {
                try insertProvenance(db: db, provenance: provenance, affectedRows: &affected)
            }
            var audits: [BurnBarMemoryAuthorityAuditReceipt] = []
            for event in remember.audits {
                audits.append(try appendAudit(db: db, event: event, actor: actor))
            }
            if let merge = remember.merge {
                try applyMerge(db: db, merge: merge, actor: actor, affectedRows: &affected, audits: &audits)
            }
            return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: audits)

        case .updateBody(let update):
            var affected = 0
            if let reseal = update.reseal {
                try upsertSnapshot(db: db, snapshot: reseal.snapshot, affectedRows: &affected)
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
                    update.kind,
                    update.confidence,
                    update.updatedAtText,
                    update.memoryID,
                    update.sourceKind
                ]
            )
            affected += db.changesCount
            let receipt = try appendAudit(db: db, event: update.audit, actor: actor)
            return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [receipt])

        case .setReviewStatus(let review):
            var affected = 0
            if let tombstone = review.factTombstone {
                try upsertFactTombstone(db: db, tombstone: tombstone, affectedRows: &affected)
            }
            if review.markFactTombstoneReplicated, let replicatedAt = review.replicatedAtText {
                try db.execute(
                    sql: """
                    UPDATE memory_fact_tombstones
                    SET replicated_at = ?
                    WHERE memory_id = ?
                      AND replicated_at IS NULL
                    """,
                    arguments: [replicatedAt, review.memoryID]
                )
                affected += db.changesCount
            }
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET review_status = ?,
                    updated_at = ?
                WHERE id = ?
                  AND source_kind = ?
                """,
                arguments: [
                    review.reviewStatus,
                    review.updatedAtText,
                    review.memoryID,
                    review.sourceKind
                ]
            )
            affected += db.changesCount
            let receipt = try appendAudit(db: db, event: review.audit, actor: actor)
            return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [receipt])

        case .deleteMemory(let delete):
            var affected = 0
            if let agent = delete.agent, let tombstone = agent.factTombstone {
                try upsertFactTombstone(db: db, tombstone: tombstone, affectedRows: &affected)
            } else if let tombstone = delete.factTombstone {
                try upsertFactTombstone(db: db, tombstone: tombstone, affectedRows: &affected)
            }
            try db.execute(sql: "DELETE FROM memory_embedding_refs WHERE memory_id = ?", arguments: [delete.memoryID])
            affected += db.changesCount
            try db.execute(sql: "DELETE FROM memory_provenance WHERE memory_id = ?", arguments: [delete.memoryID])
            affected += db.changesCount
            try db.execute(
                sql: "DELETE FROM agent_memories WHERE id = ? AND source_kind = ?",
                arguments: [delete.memoryID, delete.sourceKind]
            )
            affected += db.changesCount
            try db.execute(sql: "DELETE FROM memory_body_snapshots WHERE memory_id = ?", arguments: [delete.memoryID])
            affected += db.changesCount
            if delete.agent != nil {
                try db.execute(
                    sql: "DELETE FROM memory_quarantine_bodies WHERE memory_id = ?",
                    arguments: [delete.memoryID]
                )
                affected += db.changesCount
                try db.execute(
                    sql: "UPDATE agent_memory_bodies SET body = '', body_hash = '', updated_at = ? WHERE memory_id = ?",
                    arguments: [delete.blankedBodyUpdatedAtText ?? "", delete.memoryID]
                )
                affected += db.changesCount
            }
            let receipt = try appendAudit(db: db, event: delete.audit, actor: actor)
            return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [receipt])

        case .reconcileSuppressions(let reconcile):
            var audits: [BurnBarMemoryAuthorityAuditReceipt] = []
            audits.reserveCapacity(reconcile.matches.count)
            for match in reconcile.matches {
                try db.execute(
                    sql: """
                    UPDATE agent_memories
                    SET valid_to = ?,
                        updated_at = ?
                    WHERE id = ?
                      AND source_kind = ?
                      AND valid_to IS NULL
                    """,
                    arguments: [
                        reconcile.validToText,
                        reconcile.updatedAtText,
                        match.memoryID,
                        reconcile.sourceKind
                    ]
                )
                audits.append(try appendAudit(
                    db: db,
                    event: BurnBarMemoryAuthorityAuditEvent(
                        action: "memory.source_tombstone_suppressed",
                        projectID: match.projectID,
                        subjectID: match.memoryID,
                        labels: match.labels,
                        labelsJSON: match.labelsJSON,
                        timestampText: reconcile.timestampText
                    ),
                    actor: actor
                ))
            }
            return BurnBarMemoryAuthorityOperationResult(affectedRows: reconcile.matches.count, audits: audits)

        case .claimUnowned(let claim):
            try db.execute(
                sql: """
                UPDATE agent_memories SET user_id = ?
                WHERE source_kind = ? AND (user_id IS NULL OR user_id = '')
                """,
                arguments: [claim.userID, claim.sourceKind]
            )
            return BurnBarMemoryAuthorityOperationResult(affectedRows: db.changesCount, audits: [])

        case .enqueueFactTombstones(let enqueue):
            var affected = 0
            for tombstone in enqueue.tombstones {
                try upsertFactTombstone(db: db, tombstone: tombstone, affectedRows: &affected)
            }
            return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [])

        case .recordSourceTombstone(let record):
            var affected = 0
            try upsertSourceTombstone(db: db, tombstone: record.tombstone, affectedRows: &affected)
            return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [])

        case .markTombstoneReplicated(let mark):
            switch mark.table {
            case .fact:
                try db.execute(
                    sql: "UPDATE memory_fact_tombstones SET replicated_at = ? WHERE id = ?",
                    arguments: [mark.replicatedAtText, mark.id]
                )
            case .source:
                try db.execute(
                    sql: "UPDATE memory_source_tombstones SET replicated_at = ? WHERE id = ?",
                    arguments: [mark.replicatedAtText, mark.id]
                )
            }
            return BurnBarMemoryAuthorityOperationResult(affectedRows: db.changesCount, audits: [])

        case .appendAudit(let event):
            let receipt = try appendAudit(db: db, event: event, actor: actor)
            return BurnBarMemoryAuthorityOperationResult(affectedRows: 1, audits: [receipt])
        }
    }

    private static func applyMerge(
        db: Database,
        merge: BurnBarMemoryAuthorityMerge,
        actor: String,
        affectedRows: inout Int,
        audits: inout [BurnBarMemoryAuthorityAuditReceipt]
    ) throws {
        let placeholders = merge.sourceKinds.map { _ in "?" }.joined(separator: ", ")
        for (index, loserID) in merge.loserIDs.enumerated() {
            var arguments: [DatabaseValueConvertible?] = [
                merge.nowText,
                merge.winnerID,
                merge.nowText,
                loserID
            ]
            arguments.append(contentsOf: merge.sourceKinds.map { Optional($0) as DatabaseValueConvertible? })
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET valid_to = COALESCE(valid_to, ?),
                    superseded_by = ?,
                    updated_at = ?
                WHERE id = ?
                  AND source_kind IN (\(placeholders))
                """,
                arguments: StatementArguments(arguments)
            )
            affectedRows += db.changesCount
            if index < merge.supersedeAudits.count {
                audits.append(try appendAudit(db: db, event: merge.supersedeAudits[index], actor: actor))
            }
        }
        for copy in merge.provenanceCopies {
            try insertProvenance(db: db, provenance: copy, affectedRows: &affectedRows)
        }
        audits.append(try appendAudit(db: db, event: merge.mergeAudit, actor: actor))
    }

    // MARK: - Row writers

    private static func upsertSnapshot(
        db: Database,
        snapshot: BurnBarMemoryAuthoritySnapshotRow,
        affectedRows: inout Int
    ) throws {
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
                snapshot.id,
                snapshot.memoryID,
                snapshot.bodyRef,
                snapshot.snapshotJSON,
                snapshot.bodyHash,
                snapshot.sourceKind,
                snapshot.createdAtText,
                snapshot.updatedAtText
            ]
        )
        affectedRows += db.changesCount
    }

    private static func insertProvenance(
        db: Database,
        provenance: BurnBarMemoryAuthorityProvenanceRow,
        affectedRows: inout Int
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO memory_provenance (
                id, memory_id, source_kind, thread_logical_id, message_id, role,
                authored_at, content_hash, occurrence, xdevice_hmac, citation_state, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            arguments: [
                provenance.id,
                provenance.memoryID,
                provenance.sourceKind,
                provenance.threadLogicalID,
                provenance.messageID,
                provenance.role,
                provenance.authoredAtText,
                provenance.contentHash,
                provenance.occurrence,
                provenance.xdeviceHMAC,
                provenance.citationState,
                provenance.createdAtText
            ]
        )
        affectedRows += db.changesCount
    }

    private static func upsertFactTombstone(
        db: Database,
        tombstone: BurnBarMemoryAuthorityFactTombstoneRow,
        affectedRows: inout Int
    ) throws {
        let conflictClause: String
        if tombstone.overwriteOnConflict == false {
            conflictClause = "ON CONFLICT(id) DO NOTHING"
        } else if tombstone.refreshSourceRefsOnConflict {
            conflictClause = """
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                source_refs_json = excluded.source_refs_json,
                reason = excluded.reason,
                created_at = excluded.created_at,
                replicated_at = NULL
            """
        } else {
            conflictClause = """
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                reason = excluded.reason,
                created_at = excluded.created_at,
                replicated_at = NULL
            """
        }
        try db.execute(
            sql: """
            INSERT INTO memory_fact_tombstones (
                id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at
            ) VALUES (?, ?, ?, ?, ?, ?, NULL)
            \(conflictClause)
            """,
            arguments: [
                tombstone.id,
                tombstone.userID,
                tombstone.memoryID,
                tombstone.sourceRefsJSON,
                tombstone.reason,
                tombstone.createdAtText
            ]
        )
        affectedRows += db.changesCount
    }

    private static func upsertSourceTombstone(
        db: Database,
        tombstone: BurnBarMemoryAuthoritySourceTombstoneRow,
        affectedRows: inout Int
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO memory_source_tombstones (
                id, user_id, thread_logical_id, message_id, content_hash, reason, created_at, replicated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                reason = excluded.reason,
                created_at = excluded.created_at,
                replicated_at = NULL
            """,
            arguments: [
                tombstone.id,
                tombstone.userID,
                tombstone.threadLogicalID,
                tombstone.messageID,
                tombstone.contentHash,
                tombstone.reason,
                tombstone.createdAtText
            ]
        )
        affectedRows += db.changesCount
    }

    // MARK: - Audit chain

    private static func appendAudit(
        db: Database,
        event: BurnBarMemoryAuthorityAuditEvent,
        actor: String
    ) throws -> BurnBarMemoryAuthorityAuditReceipt {
        let previous = try Row.fetchOne(db, sql: "SELECT seq, hash FROM memory_audit ORDER BY seq DESC LIMIT 1")
        let previousSequence: Int = previous?[0] ?? 0
        let previousHash: String? = previous?[1]
        let sequence = previousSequence + 1
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "schema": "openburnbar.memory_audit.v2",
                "seq": sequence,
                "ts": event.timestampText,
                "actor": actor,
                "action": event.action,
                "domain": "memory",
                "projectID": event.projectID.map { $0 as Any } ?? NSNull(),
                "subjectID": event.subjectID.map { $0 as Any } ?? NSNull(),
                "labels": event.labels,
                "prevHash": previousHash ?? ""
            ] as [String: Any],
            options: [.sortedKeys]
        )
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try db.execute(
            sql: """
            INSERT INTO memory_audit (
                seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                sequence,
                event.timestampText,
                actor,
                event.action,
                "memory",
                event.projectID,
                event.subjectID,
                event.labelsJSON,
                previousHash,
                hash
            ]
        )
        return BurnBarMemoryAuthorityAuditReceipt(sequence: sequence, hash: hash)
    }
}

enum LocalMemoryAuthorityWriterError: Error {
    case invalidRequest(String)
}

/// Stands in for a daemon that is unreachable: every mutation throws, proving
/// the store fails closed (no local write, no silent success).
struct ThrowingMemoryAuthorityWriter: MemoryAuthorityWriter {
    struct Boom: Error {}

    func apply(_ request: BurnBarMemoryAuthorityApplyRequest) async throws -> BurnBarMemoryAuthorityApplyResponse {
        throw Boom()
    }
}

/// Records the apply requests the store issues, so cutover tests can assert
/// the exact app→daemon mapping without a live socket.
///
/// The stubbed response echoes the request's mutation id with one result per
/// operation, like an honest daemon. `stubAffectedRows` feeds the
/// reconcile/claim/enqueue counts the flows return; `scriptedErrors` throws
/// in call order (a recorded attempt still counts — the app did issue the
/// RPC), which drives the reseal conflict-retry tests; `stubMutationID` and
/// `stubResultCount` corrupt the response shape for the mismatch tests.
final class RecordingMemoryAuthorityWriter: MemoryAuthorityWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [BurnBarMemoryAuthorityApplyRequest] = []
    private var _scriptedErrors: [any Error] = []

    /// Applied to every stubbed result. Tests that need per-call counts set
    /// it between calls.
    var stubAffectedRows: Int = 0
    /// When set, the stubbed response carries this mutation id instead of
    /// the request's, tripping the commit's shape check.
    var stubMutationID: String?
    /// When set, the stubbed response carries this many results instead of
    /// one per operation, tripping the commit's shape check.
    var stubResultCount: Int?

    var requests: [BurnBarMemoryAuthorityApplyRequest] {
        lock.withLock { _requests }
    }

    /// Errors to throw on successive `apply` calls, in order. A scripted
    /// call still records its request before throwing.
    func scriptErrors(_ errors: [any Error]) {
        lock.withLock { _scriptedErrors = errors }
    }

    func apply(_ request: BurnBarMemoryAuthorityApplyRequest) async throws -> BurnBarMemoryAuthorityApplyResponse {
        let scripted: (any Error)? = lock.withLock {
            _requests.append(request)
            guard _scriptedErrors.isEmpty == false else { return nil }
            return _scriptedErrors.removeFirst()
        }
        if let scripted {
            throw scripted
        }
        let count = stubResultCount ?? request.operations.count
        let results = (0..<count).map { _ in
            BurnBarMemoryAuthorityOperationResult(affectedRows: stubAffectedRows, audits: [])
        }
        return BurnBarMemoryAuthorityApplyResponse(
            mutationID: stubMutationID ?? request.mutationID,
            results: results
        )
    }
}
