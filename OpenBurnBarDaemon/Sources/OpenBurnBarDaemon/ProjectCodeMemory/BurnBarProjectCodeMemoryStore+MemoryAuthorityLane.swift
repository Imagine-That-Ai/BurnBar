import Foundation
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// MARK: - Memory Authority App Lane (Wave 2.1c-iii)

/// The daemon-owned write path for the app lane of the memory authority
/// tables (ADR-005): `agent_memories`, `memory_audit`, and the satellite
/// rows the authority flows touch (`memory_body_snapshots`,
/// `memory_provenance`, fact/source tombstones, and the mirrored-row halves
/// the delete cascade clears).
///
/// Lane contract (do not blur it): the app finalizes every value before
/// sending — this lane validates shape and bounds, checks the reseal
/// precondition, and stores everything verbatim inside one `BEGIN IMMEDIATE`
/// transaction. The ONLY values the daemon assigns are the audit chain
/// fields (`seq`, `prev_hash`, `hash`), computed in-transaction from the
/// live chain head under the shared `openburnbar.memory_audit.v2` payload.
/// That single assignment is what closes the cross-process chain fork the
/// dual writers had: after this cutover no other process writes these
/// tables, and `BEGIN IMMEDIATE` serializes the daemon's own lanes.
///
/// Timestamps bind as the app-finalized TEXT verbatim — including the legacy
/// quirks (ISO 8601 in the review-status `updated_at` and the agent-body
/// blanking stamp; ISO without millis in enqueue `created_at`) — so `ORDER
/// BY` and `MAX()` behave identically across the cutover. Validation proves
/// each stamp parses as ISO 8601 or GRDB text; there is deliberately no
/// range floor, because `authored_at` and preserved `created_at` values can
/// legitimately predate any cutoff the lane could draw.
///
/// Audit labels bind verbatim too: the app's finalized sorted list and its
/// exact `auditLabelsJSON` encoding. The daemon lane's `Set` dedup must
/// never leak into this lane, and the daemon never re-derives the JSON — it
/// verifies the carried encoding decodes to exactly the carried labels, then
/// binds the string untouched. The hash payload builder is shared with the
/// daemon lane (`memoryAuditPayloadData`) so both lanes commit to identical
/// bytes under identical inputs.
extension BurnBarProjectCodeMemoryStore {
    /// Bounds for the app-lane authority fields. Generous on purpose: the
    /// wire carries what the legacy app transactions already wrote, and the
    /// bounds exist to catch corruption and cap abuse, not to police
    /// content. Counts mirror the snapshot lane's headroom style.
    static let authorityMaxOperations = 25
    static let authorityMaxIdentifierBytes = 512
    static let authorityMaxShortTextBytes = 256
    static let authorityMaxActionBytes = 128
    static let authorityMaxSourcePathBytes = 4_096
    static let authorityMaxSnapshotJSONBytes = 1_048_576
    static let authorityMaxSmallJSONBytes = 65_536
    static let authorityMaxLabelsJSONBytes = 16_384
    static let authorityMaxLabels = 64
    static let authorityMaxProvenanceRows = 10_000
    static let authorityMaxTombstones = 100_000
    static let authorityMaxMatches = 100_000
    static let authorityMaxLosers = 10_000
    static let authorityMaxSourceKinds = 16
    static let authorityMaxOccurrence = 10_000_000
    static let authorityExpectedActor = "app"
    static let authorityAuditDomain = "memory"

    func memoryAuthorityApplyAppLane(
        _ request: BurnBarMemoryAuthorityApplyRequest
    ) throws -> BurnBarMemoryAuthorityApplyResponse {
        let mutationID = try Self.validatedAuthorityIdentifier(request.mutationID, field: "mutationID")
        guard request.actor == Self.authorityExpectedActor else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "actor must be \"\(Self.authorityExpectedActor)\""
            )
        }
        guard request.operations.isEmpty == false,
              request.operations.count <= Self.authorityMaxOperations else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "operations must contain 1...\(Self.authorityMaxOperations) entries"
            )
        }
        for operation in request.operations {
            try Self.validateMemoryAuthorityOperation(operation)
        }

        return try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                // Preconditions first, under the write lock: a refused
                // mutation applies nothing, so a conflicting reseal can
                // never half-land.
                for (index, operation) in request.operations.enumerated() {
                    try checkMemoryAuthorityPreconditions(operation, operationIndex: index)
                }
                var results: [BurnBarMemoryAuthorityOperationResult] = []
                results.reserveCapacity(request.operations.count)
                for operation in request.operations {
                    results.append(try applyMemoryAuthorityOperation(operation, actor: request.actor))
                }
                try execute("COMMIT", [])
                return BurnBarMemoryAuthorityApplyResponse(mutationID: mutationID, results: results)
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    // MARK: - Preconditions

    private func checkMemoryAuthorityPreconditions(
        _ operation: BurnBarMemoryAuthorityOperation,
        operationIndex: Int
    ) throws {
        guard case .updateBody(let update) = operation, let reseal = update.reseal else { return }
        let stored = try queryRows(
            "SELECT body_hash, updated_at FROM memory_body_snapshots WHERE memory_id = ?",
            [.text(update.memoryID)]
        ).first
        let storedHash = stored?.values[0]
        let storedUpdatedAt = stored?.values[1]
        guard storedHash == reseal.expectedBodyHash,
              storedUpdatedAt == reseal.expectedUpdatedAtText else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityConflict(
                "operation \(operationIndex) reseal precondition failed for memory \(update.memoryID): " +
                    "expected body_hash \(reseal.expectedBodyHash ?? "<absent>") " +
                    "updated_at \(reseal.expectedUpdatedAtText ?? "<absent>"), " +
                    "stored body_hash \(storedHash ?? "<absent>") updated_at \(storedUpdatedAt ?? "<absent>")"
            )
        }
    }

    // MARK: - Apply

    private func applyMemoryAuthorityOperation(
        _ operation: BurnBarMemoryAuthorityOperation,
        actor: String
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        switch operation {
        case .remember(let remember):
            return try applyMemoryAuthorityRemember(remember, actor: actor)
        case .updateBody(let update):
            return try applyMemoryAuthorityUpdate(update, actor: actor)
        case .setReviewStatus(let review):
            return try applyMemoryAuthorityReview(review, actor: actor)
        case .deleteMemory(let delete):
            return try applyMemoryAuthorityDelete(delete, actor: actor)
        case .reconcileSuppressions(let reconcile):
            return try applyMemoryAuthorityReconcile(reconcile, actor: actor)
        case .claimUnowned(let claim):
            return try applyMemoryAuthorityClaim(claim)
        case .enqueueFactTombstones(let enqueue):
            return try applyMemoryAuthorityEnqueue(enqueue)
        case .recordSourceTombstone(let record):
            var affected = 0
            try upsertMemoryAuthoritySourceTombstone(record.tombstone, affectedRows: &affected)
            return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [])
        case .markTombstoneReplicated(let mark):
            var affected = 0
            switch mark.table {
            case .fact:
                try execute(
                    "UPDATE memory_fact_tombstones SET replicated_at = ? WHERE id = ?",
                    [.text(mark.replicatedAtText), .text(mark.id)]
                )
            case .source:
                try execute(
                    "UPDATE memory_source_tombstones SET replicated_at = ? WHERE id = ?",
                    [.text(mark.replicatedAtText), .text(mark.id)]
                )
            }
            affected += memoryAuthorityChanges()
            return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [])
        case .appendAudit(let event):
            let receipt = try appendMemoryAuthorityAudit(event, actor: actor)
            return BurnBarMemoryAuthorityOperationResult(affectedRows: 1, audits: [receipt])
        }
    }

    private func applyMemoryAuthorityRemember(
        _ remember: BurnBarMemoryAuthorityRemember,
        actor: String
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        var affected = 0
        try upsertMemoryAuthoritySnapshot(remember.snapshot, affectedRows: &affected)
        let memory = remember.memory
        try execute(
            """
            INSERT INTO agent_memories (
                id, project_id, kind, scope, confidence, body_ref, body_redacted,
                tags_json, source_path, valid_from, valid_to, superseded_by, created_at, updated_at,
                source_kind, review_status, user_id, agent_id, run_id, app_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                .text(memory.id),
                .text(memory.projectID),
                .text(memory.kind),
                .text(memory.scopeText),
                .double(memory.confidence),
                .text(memory.bodyRef),
                .text(memory.bodyRedacted),
                .text(memory.tagsJSON),
                memory.sourcePath.map(SQLiteBind.text) ?? .null,
                .text(memory.validFromText),
                memory.validToText.map(SQLiteBind.text) ?? .null,
                memory.supersededBy.map(SQLiteBind.text) ?? .null,
                .text(memory.createdAtText),
                .text(memory.updatedAtText),
                .text(memory.sourceKind),
                .text(memory.reviewStatus),
                memory.userID.map(SQLiteBind.text) ?? .null,
                memory.agentID.map(SQLiteBind.text) ?? .null,
                memory.runID.map(SQLiteBind.text) ?? .null,
                memory.appID.map(SQLiteBind.text) ?? .null
            ]
        )
        affected += memoryAuthorityChanges()
        for provenance in remember.provenance {
            try insertMemoryAuthorityProvenance(provenance, affectedRows: &affected)
        }
        var audits: [BurnBarMemoryAuthorityAuditReceipt] = []
        for event in remember.audits {
            audits.append(try appendMemoryAuthorityAudit(event, actor: actor))
        }
        if let merge = remember.merge {
            try applyMemoryAuthorityMerge(merge, actor: actor, affectedRows: &affected, audits: &audits)
        }
        return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: audits)
    }

    private func applyMemoryAuthorityMerge(
        _ merge: BurnBarMemoryAuthorityMerge,
        actor: String,
        affectedRows: inout Int,
        audits: inout [BurnBarMemoryAuthorityAuditReceipt]
    ) throws {
        let placeholders = merge.sourceKinds.map { _ in "?" }.joined(separator: ", ")
        for (index, loserID) in merge.loserIDs.enumerated() {
            var binds: [SQLiteBind] = [
                .text(merge.nowText),
                .text(merge.winnerID),
                .text(merge.nowText),
                .text(loserID)
            ]
            binds.append(contentsOf: merge.sourceKinds.map(SQLiteBind.text))
            try execute(
                """
                UPDATE agent_memories
                SET valid_to = COALESCE(valid_to, ?),
                    superseded_by = ?,
                    updated_at = ?
                WHERE id = ?
                  AND source_kind IN (\(placeholders))
                """,
                binds
            )
            affectedRows += memoryAuthorityChanges()
            if index < merge.supersedeAudits.count {
                audits.append(try appendMemoryAuthorityAudit(merge.supersedeAudits[index], actor: actor))
            }
        }
        for copy in merge.provenanceCopies {
            try insertMemoryAuthorityProvenance(copy, affectedRows: &affectedRows)
        }
        audits.append(try appendMemoryAuthorityAudit(merge.mergeAudit, actor: actor))
    }

    private func applyMemoryAuthorityUpdate(
        _ update: BurnBarMemoryAuthorityUpdate,
        actor: String
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        var affected = 0
        if let reseal = update.reseal {
            try upsertMemoryAuthoritySnapshot(reseal.snapshot, affectedRows: &affected)
        }
        try execute(
            """
            UPDATE agent_memories
            SET kind = COALESCE(?, kind),
                confidence = COALESCE(?, confidence),
                updated_at = ?
            WHERE id = ?
              AND source_kind = ?
            """,
            [
                update.kind.map(SQLiteBind.text) ?? .null,
                update.confidence.map(SQLiteBind.double) ?? .null,
                .text(update.updatedAtText),
                .text(update.memoryID),
                .text(update.sourceKind)
            ]
        )
        affected += memoryAuthorityChanges()
        let receipt = try appendMemoryAuthorityAudit(update.audit, actor: actor)
        return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [receipt])
    }

    private func applyMemoryAuthorityReview(
        _ review: BurnBarMemoryAuthorityReview,
        actor: String
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        var affected = 0
        if let tombstone = review.factTombstone {
            try upsertMemoryAuthorityFactTombstone(tombstone, affectedRows: &affected)
        }
        if review.markFactTombstoneReplicated, let replicatedAt = review.replicatedAtText {
            try execute(
                """
                UPDATE memory_fact_tombstones
                SET replicated_at = ?
                WHERE memory_id = ?
                  AND replicated_at IS NULL
                """,
                [.text(replicatedAt), .text(review.memoryID)]
            )
            affected += memoryAuthorityChanges()
        }
        try execute(
            """
            UPDATE agent_memories
            SET review_status = ?,
                updated_at = ?
            WHERE id = ?
              AND source_kind = ?
            """,
            [
                .text(review.reviewStatus),
                .text(review.updatedAtText),
                .text(review.memoryID),
                .text(review.sourceKind)
            ]
        )
        affected += memoryAuthorityChanges()
        let receipt = try appendMemoryAuthorityAudit(review.audit, actor: actor)
        return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [receipt])
    }

    private func applyMemoryAuthorityDelete(
        _ delete: BurnBarMemoryAuthorityDelete,
        actor: String
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        var affected = 0
        // Legacy order: tombstones first (the delete must not strand a cloud
        // copy), then the cascade, then the mirrored-row halves, then audit.
        if let agent = delete.agent, let tombstone = agent.factTombstone {
            try upsertMemoryAuthorityFactTombstone(tombstone, affectedRows: &affected)
        } else if let tombstone = delete.factTombstone {
            try upsertMemoryAuthorityFactTombstone(tombstone, affectedRows: &affected)
        }
        try execute("DELETE FROM memory_embedding_refs WHERE memory_id = ?", [.text(delete.memoryID)])
        affected += memoryAuthorityChanges()
        try execute("DELETE FROM memory_provenance WHERE memory_id = ?", [.text(delete.memoryID)])
        affected += memoryAuthorityChanges()
        try execute(
            "DELETE FROM agent_memories WHERE id = ? AND source_kind = ?",
            [.text(delete.memoryID), .text(delete.sourceKind)]
        )
        affected += memoryAuthorityChanges()
        try execute("DELETE FROM memory_body_snapshots WHERE memory_id = ?", [.text(delete.memoryID)])
        affected += memoryAuthorityChanges()
        if delete.agent != nil {
            try execute(
                "DELETE FROM memory_quarantine_bodies WHERE memory_id = ?",
                [.text(delete.memoryID)]
            )
            affected += memoryAuthorityChanges()
            // BLANKED, not deleted: `engine_memory_id` is the only handle the
            // fact-tombstone drain keeps on the sealed cloud document.
            try execute(
                "UPDATE agent_memory_bodies SET body = '', body_hash = '', updated_at = ? WHERE memory_id = ?",
                [.text(delete.blankedBodyUpdatedAtText ?? ""), .text(delete.memoryID)]
            )
            affected += memoryAuthorityChanges()
        }
        let receipt = try appendMemoryAuthorityAudit(delete.audit, actor: actor)
        return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [receipt])
    }

    private func applyMemoryAuthorityReconcile(
        _ reconcile: BurnBarMemoryAuthorityReconcile,
        actor: String
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        var audits: [BurnBarMemoryAuthorityAuditReceipt] = []
        audits.reserveCapacity(reconcile.matches.count)
        for match in reconcile.matches {
            try execute(
                """
                UPDATE agent_memories
                SET valid_to = ?,
                    updated_at = ?
                WHERE id = ?
                  AND source_kind = ?
                  AND valid_to IS NULL
                """,
                [
                    .text(reconcile.validToText),
                    .text(reconcile.updatedAtText),
                    .text(match.memoryID),
                    .text(reconcile.sourceKind)
                ]
            )
            audits.append(try appendMemoryAuthorityAudit(
                BurnBarMemoryAuthorityAuditEvent(
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
        // Legacy counts rows swept, not rows changed: the pre-read matched
        // them all, and a row suppressed between the pre-read and this apply
        // is already in the desired end state.
        return BurnBarMemoryAuthorityOperationResult(affectedRows: reconcile.matches.count, audits: audits)
    }

    private func applyMemoryAuthorityClaim(
        _ claim: BurnBarMemoryAuthorityClaim
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        try execute(
            """
            UPDATE agent_memories SET user_id = ?
            WHERE source_kind = ? AND (user_id IS NULL OR user_id = '')
            """,
            [.text(claim.userID), .text(claim.sourceKind)]
        )
        return BurnBarMemoryAuthorityOperationResult(affectedRows: memoryAuthorityChanges(), audits: [])
    }

    private func applyMemoryAuthorityEnqueue(
        _ enqueue: BurnBarMemoryAuthorityEnqueueTombstones
    ) throws -> BurnBarMemoryAuthorityOperationResult {
        var affected = 0
        for tombstone in enqueue.tombstones {
            try upsertMemoryAuthorityFactTombstone(tombstone, affectedRows: &affected)
        }
        return BurnBarMemoryAuthorityOperationResult(affectedRows: affected, audits: [])
    }

    // MARK: - Row writers (legacy SQL shapes, verbatim bindings)

    private func upsertMemoryAuthoritySnapshot(
        _ snapshot: BurnBarMemoryAuthoritySnapshotRow,
        affectedRows: inout Int
    ) throws {
        try execute(
            """
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
            [
                .text(snapshot.id),
                .text(snapshot.memoryID),
                .text(snapshot.bodyRef),
                .text(snapshot.snapshotJSON),
                .text(snapshot.bodyHash),
                .text(snapshot.sourceKind),
                .text(snapshot.createdAtText),
                .text(snapshot.updatedAtText)
            ]
        )
        affectedRows += memoryAuthorityChanges()
    }

    private func insertMemoryAuthorityProvenance(
        _ provenance: BurnBarMemoryAuthorityProvenanceRow,
        affectedRows: inout Int
    ) throws {
        try execute(
            """
            INSERT INTO memory_provenance (
                id, memory_id, source_kind, thread_logical_id, message_id, role,
                authored_at, content_hash, occurrence, xdevice_hmac, citation_state, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                .text(provenance.id),
                .text(provenance.memoryID),
                .text(provenance.sourceKind),
                .text(provenance.threadLogicalID),
                provenance.messageID.map(SQLiteBind.text) ?? .null,
                .text(provenance.role),
                .text(provenance.authoredAtText),
                .text(provenance.contentHash),
                .int(provenance.occurrence),
                .text(provenance.xdeviceHMAC),
                .text(provenance.citationState),
                .text(provenance.createdAtText)
            ]
        )
        affectedRows += memoryAuthorityChanges()
    }

    private func upsertMemoryAuthorityFactTombstone(
        _ tombstone: BurnBarMemoryAuthorityFactTombstoneRow,
        affectedRows: inout Int
    ) throws {
        let conflictClause: String
        if tombstone.overwriteOnConflict == false {
            conflictClause = "ON CONFLICT(id) DO NOTHING"
        } else if tombstone.refreshSourceRefsOnConflict {
            conflictClause =
                """
                ON CONFLICT(id) DO UPDATE SET
                    user_id = excluded.user_id,
                    source_refs_json = excluded.source_refs_json,
                    reason = excluded.reason,
                    created_at = excluded.created_at,
                    replicated_at = NULL
                """
        } else {
            conflictClause =
                """
                ON CONFLICT(id) DO UPDATE SET
                    user_id = excluded.user_id,
                    reason = excluded.reason,
                    created_at = excluded.created_at,
                    replicated_at = NULL
                """
        }
        try execute(
            """
            INSERT INTO memory_fact_tombstones (
                id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at
            ) VALUES (?, ?, ?, ?, ?, ?, NULL)
            \(conflictClause)
            """,
            [
                .text(tombstone.id),
                .text(tombstone.userID),
                .text(tombstone.memoryID),
                .text(tombstone.sourceRefsJSON),
                .text(tombstone.reason),
                .text(tombstone.createdAtText)
            ]
        )
        affectedRows += memoryAuthorityChanges()
    }

    private func upsertMemoryAuthoritySourceTombstone(
        _ tombstone: BurnBarMemoryAuthoritySourceTombstoneRow,
        affectedRows: inout Int
    ) throws {
        try execute(
            """
            INSERT INTO memory_source_tombstones (
                id, user_id, thread_logical_id, message_id, content_hash, reason, created_at, replicated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                reason = excluded.reason,
                created_at = excluded.created_at,
                replicated_at = NULL
            """,
            [
                .text(tombstone.id),
                tombstone.userID.map(SQLiteBind.text) ?? .null,
                .text(tombstone.threadLogicalID),
                tombstone.messageID.map(SQLiteBind.text) ?? .null,
                tombstone.contentHash.map(SQLiteBind.text) ?? .null,
                .text(tombstone.reason),
                .text(tombstone.createdAtText)
            ]
        )
        affectedRows += memoryAuthorityChanges()
    }

    // MARK: - Audit chain (app lane)

    /// Appends one app-finalized audit event, assigning the chain fields
    /// from the live head. `seq` inserts explicitly (not auto-assigned) so
    /// the stored sequence always equals the hashed sequence, even if
    /// `sqlite_sequence` ever drifted from `MAX(seq)`.
    private func appendMemoryAuthorityAudit(
        _ event: BurnBarMemoryAuthorityAuditEvent,
        actor: String
    ) throws -> BurnBarMemoryAuthorityAuditReceipt {
        let previous = try queryRows(
            "SELECT seq, hash FROM memory_audit ORDER BY seq DESC LIMIT 1",
            []
        ).first
        let previousSequence = previous.map { Int($0.int64(0)) } ?? 0
        let previousHash = previous?.optionalString(1)
        let sequence = previousSequence + 1
        let payload = try Self.memoryAuditPayloadData(
            seq: sequence,
            ts: event.timestampText,
            actor: actor,
            action: event.action,
            domain: Self.authorityAuditDomain,
            projectID: event.projectID,
            subjectID: event.subjectID,
            labels: event.labels,
            prevHash: previousHash
        )
        let hash = Self.sha256Hex(payload)
        try execute(
            """
            INSERT INTO memory_audit (
                seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(sequence),
                .text(event.timestampText),
                .text(actor),
                .text(event.action),
                .text(Self.authorityAuditDomain),
                event.projectID.map(SQLiteBind.text) ?? .null,
                event.subjectID.map(SQLiteBind.text) ?? .null,
                .text(event.labelsJSON),
                previousHash.map(SQLiteBind.text) ?? .null,
                .text(hash)
            ]
        )
        return BurnBarMemoryAuthorityAuditReceipt(sequence: sequence, hash: hash)
    }

    /// The shared `openburnbar.memory_audit.v2` hash payload. Both the daemon
    /// lane (`auditEvent`) and this app lane commit through this builder so
    /// identical inputs hash identically no matter which lane appended.
    static func memoryAuditPayloadData(
        seq: Int,
        ts: String,
        actor: String,
        action: String,
        domain: String,
        projectID: String?,
        subjectID: String?,
        labels: [String],
        prevHash: String?
    ) throws -> Data {
        try jsonData([
            "schema": "openburnbar.memory_audit.v2",
            "seq": seq,
            "ts": ts,
            "actor": actor,
            "action": action,
            "domain": domain,
            "projectID": projectID.map { $0 as Any } ?? NSNull(),
            "subjectID": subjectID.map { $0 as Any } ?? NSNull(),
            "labels": labels,
            "prevHash": prevHash ?? ""
        ])
    }

    /// Rows modified by the most recent write on this connection — the raw
    /// form of GRDB's `db.changesCount`. Captured immediately after each
    /// write; reads never reset it.
    private func memoryAuthorityChanges() -> Int {
        guard let db else { return 0 }
        return Int(sqlite3_changes(db))
    }
}

extension BurnBarProjectCodeMemoryStore {
    // MARK: - Validation (app lane)

    /// Total validation: every field of every operation is checked before
    /// anything applies, so the applier above can bind the request values
    /// verbatim. Field rules mirror the snapshot lane (nonblank, trimmed
    /// identifiers, byte bounds, no control characters); enum-shaped strings
    /// are shape-checked but never membership-checked, so an app carrying a
    /// newer kind/status stores forward-compatibly instead of failing
    /// against an older daemon.
    static func validateMemoryAuthorityOperation(_ operation: BurnBarMemoryAuthorityOperation) throws {
        switch operation {
        case .remember(let remember):
            try validateMemoryAuthoritySnapshot(remember.snapshot, field: "remember.snapshot")
            try validateMemoryAuthorityMemoryRow(remember.memory)
            guard remember.provenance.count <= authorityMaxProvenanceRows else {
                throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                    "remember.provenance exceeds \(authorityMaxProvenanceRows) rows"
                )
            }
            for provenance in remember.provenance {
                try validateMemoryAuthorityProvenance(provenance)
            }
            guard remember.audits.isEmpty == false else {
                throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                    "remember.audits must not be empty"
                )
            }
            for audit in remember.audits {
                try validateMemoryAuthorityAudit(audit, field: "remember.audits")
            }
            if let merge = remember.merge {
                try validateMemoryAuthorityMerge(merge)
            }
        case .updateBody(let update):
            _ = try validatedAuthorityIdentifier(update.memoryID, field: "updateBody.memoryID")
            _ = try validatedAuthorityToken(update.sourceKind, field: "updateBody.sourceKind")
            if let kind = update.kind {
                _ = try validatedAuthorityToken(kind, field: "updateBody.kind")
            }
            if let confidence = update.confidence {
                try validateMemoryAuthorityConfidence(confidence, field: "updateBody.confidence")
            }
            _ = try validatedAuthorityTimestamp(update.updatedAtText, field: "updateBody.updatedAtText")
            if let reseal = update.reseal {
                if let expected = reseal.expectedBodyHash {
                    _ = try validatedAuthorityBodyHash(expected, field: "updateBody.reseal.expectedBodyHash")
                }
                if let expected = reseal.expectedUpdatedAtText {
                    _ = try validatedAuthorityTimestamp(expected, field: "updateBody.reseal.expectedUpdatedAtText")
                }
                try validateMemoryAuthoritySnapshot(reseal.snapshot, field: "updateBody.reseal.snapshot")
            }
            try validateMemoryAuthorityAudit(update.audit, field: "updateBody.audit")
        case .setReviewStatus(let review):
            _ = try validatedAuthorityIdentifier(review.memoryID, field: "setReviewStatus.memoryID")
            _ = try validatedAuthorityToken(review.sourceKind, field: "setReviewStatus.sourceKind")
            _ = try validatedAuthorityToken(review.reviewStatus, field: "setReviewStatus.reviewStatus")
            _ = try validatedAuthorityTimestamp(review.updatedAtText, field: "setReviewStatus.updatedAtText")
            if let tombstone = review.factTombstone {
                try validateMemoryAuthorityFactTombstone(tombstone, field: "setReviewStatus.factTombstone")
            }
            if review.markFactTombstoneReplicated {
                guard let replicatedAt = review.replicatedAtText else {
                    throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                        "setReviewStatus.replicatedAtText is required when markFactTombstoneReplicated is true"
                    )
                }
                _ = try validatedAuthorityTimestamp(replicatedAt, field: "setReviewStatus.replicatedAtText")
            }
            try validateMemoryAuthorityAudit(review.audit, field: "setReviewStatus.audit")
        case .deleteMemory(let delete):
            _ = try validatedAuthorityIdentifier(delete.memoryID, field: "deleteMemory.memoryID")
            _ = try validatedAuthorityToken(delete.sourceKind, field: "deleteMemory.sourceKind")
            if let agent = delete.agent {
                if let tombstone = agent.factTombstone {
                    try validateMemoryAuthorityFactTombstone(tombstone, field: "deleteMemory.agent.factTombstone")
                }
                guard let blankedAt = delete.blankedBodyUpdatedAtText else {
                    throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                        "deleteMemory.blankedBodyUpdatedAtText is required for the agent cascade"
                    )
                }
                _ = try validatedAuthorityTimestamp(blankedAt, field: "deleteMemory.blankedBodyUpdatedAtText")
            } else if delete.blankedBodyUpdatedAtText != nil {
                throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                    "deleteMemory.blankedBodyUpdatedAtText requires the agent cascade"
                )
            }
            if let tombstone = delete.factTombstone {
                try validateMemoryAuthorityFactTombstone(tombstone, field: "deleteMemory.factTombstone")
            }
            try validateMemoryAuthorityAudit(delete.audit, field: "deleteMemory.audit")
        case .reconcileSuppressions(let reconcile):
            guard reconcile.matches.isEmpty == false,
                  reconcile.matches.count <= authorityMaxMatches else {
                throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                    "reconcileSuppressions.matches must contain 1...\(authorityMaxMatches) entries"
                )
            }
            _ = try validatedAuthorityToken(reconcile.sourceKind, field: "reconcileSuppressions.sourceKind")
            _ = try validatedAuthorityTimestamp(reconcile.validToText, field: "reconcileSuppressions.validToText")
            _ = try validatedAuthorityTimestamp(reconcile.updatedAtText, field: "reconcileSuppressions.updatedAtText")
            _ = try validatedAuthorityTimestamp(reconcile.timestampText, field: "reconcileSuppressions.timestampText")
            for match in reconcile.matches {
                _ = try validatedAuthorityIdentifier(match.memoryID, field: "reconcileSuppressions.matches.memoryID")
                _ = try validatedAuthorityIdentifier(match.projectID, field: "reconcileSuppressions.matches.projectID")
                try validateMemoryAuthorityLabels(
                    match.labels,
                    labelsJSON: match.labelsJSON,
                    field: "reconcileSuppressions.matches"
                )
            }
        case .claimUnowned(let claim):
            _ = try validatedAuthorityIdentifier(claim.userID, field: "claimUnowned.userID")
            _ = try validatedAuthorityToken(claim.sourceKind, field: "claimUnowned.sourceKind")
        case .enqueueFactTombstones(let enqueue):
            guard enqueue.tombstones.isEmpty == false,
                  enqueue.tombstones.count <= authorityMaxTombstones else {
                throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                    "enqueueFactTombstones.tombstones must contain 1...\(authorityMaxTombstones) entries"
                )
            }
            for tombstone in enqueue.tombstones {
                try validateMemoryAuthorityFactTombstone(tombstone, field: "enqueueFactTombstones.tombstones")
            }
        case .recordSourceTombstone(let record):
            try validateMemoryAuthoritySourceTombstone(record.tombstone)
        case .markTombstoneReplicated(let mark):
            _ = try validatedAuthorityIdentifier(mark.id, field: "markTombstoneReplicated.id")
            _ = try validatedAuthorityTimestamp(mark.replicatedAtText, field: "markTombstoneReplicated.replicatedAtText")
        case .appendAudit(let event):
            try validateMemoryAuthorityAudit(event, field: "appendAudit")
        }
    }

    private static func validateMemoryAuthoritySnapshot(
        _ snapshot: BurnBarMemoryAuthoritySnapshotRow,
        field: String
    ) throws {
        _ = try validatedAuthorityIdentifier(snapshot.id, field: "\(field).id")
        _ = try validatedAuthorityIdentifier(snapshot.memoryID, field: "\(field).memoryID")
        _ = try validatedAuthorityIdentifier(snapshot.bodyRef, field: "\(field).bodyRef")
        _ = try validatedAuthorityJSON(
            snapshot.snapshotJSON,
            field: "\(field).snapshotJSON",
            maxBytes: authorityMaxSnapshotJSONBytes
        )
        _ = try validatedAuthorityBodyHash(snapshot.bodyHash, field: "\(field).bodyHash")
        _ = try validatedAuthorityToken(snapshot.sourceKind, field: "\(field).sourceKind")
        _ = try validatedAuthorityTimestamp(snapshot.createdAtText, field: "\(field).createdAtText")
        _ = try validatedAuthorityTimestamp(snapshot.updatedAtText, field: "\(field).updatedAtText")
    }

    private static func validateMemoryAuthorityMemoryRow(_ memory: BurnBarMemoryAuthorityMemoryRow) throws {
        _ = try validatedAuthorityIdentifier(memory.id, field: "remember.memory.id")
        _ = try validatedAuthorityIdentifier(memory.projectID, field: "remember.memory.projectID")
        _ = try validatedAuthorityToken(memory.kind, field: "remember.memory.kind")
        _ = try validatedAuthorityToken(memory.scopeText, field: "remember.memory.scopeText")
        try validateMemoryAuthorityConfidence(memory.confidence, field: "remember.memory.confidence")
        _ = try validatedAuthorityIdentifier(memory.bodyRef, field: "remember.memory.bodyRef")
        _ = try validatedAuthorityIdentifier(memory.bodyRedacted, field: "remember.memory.bodyRedacted")
        _ = try validatedAuthorityJSON(
            memory.tagsJSON,
            field: "remember.memory.tagsJSON",
            maxBytes: authorityMaxSmallJSONBytes
        )
        if let sourcePath = memory.sourcePath {
            _ = try validatedAuthorityLongText(sourcePath, field: "remember.memory.sourcePath")
        }
        _ = try validatedAuthorityTimestamp(memory.validFromText, field: "remember.memory.validFromText")
        if let validTo = memory.validToText {
            _ = try validatedAuthorityTimestamp(validTo, field: "remember.memory.validToText")
        }
        if let supersededBy = memory.supersededBy {
            _ = try validatedAuthorityIdentifier(supersededBy, field: "remember.memory.supersededBy")
        }
        _ = try validatedAuthorityTimestamp(memory.createdAtText, field: "remember.memory.createdAtText")
        _ = try validatedAuthorityTimestamp(memory.updatedAtText, field: "remember.memory.updatedAtText")
        _ = try validatedAuthorityToken(memory.sourceKind, field: "remember.memory.sourceKind")
        _ = try validatedAuthorityToken(memory.reviewStatus, field: "remember.memory.reviewStatus")
        if let userID = memory.userID {
            _ = try validatedAuthorityIdentifier(userID, field: "remember.memory.userID")
        }
        if let agentID = memory.agentID {
            _ = try validatedAuthorityIdentifier(agentID, field: "remember.memory.agentID")
        }
        if let runID = memory.runID {
            _ = try validatedAuthorityIdentifier(runID, field: "remember.memory.runID")
        }
        if let appID = memory.appID {
            _ = try validatedAuthorityIdentifier(appID, field: "remember.memory.appID")
        }
    }

    private static func validateMemoryAuthorityProvenance(_ provenance: BurnBarMemoryAuthorityProvenanceRow) throws {
        _ = try validatedAuthorityIdentifier(provenance.id, field: "provenance.id")
        _ = try validatedAuthorityIdentifier(provenance.memoryID, field: "provenance.memoryID")
        _ = try validatedAuthorityToken(provenance.sourceKind, field: "provenance.sourceKind")
        _ = try validatedAuthorityIdentifier(provenance.threadLogicalID, field: "provenance.threadLogicalID")
        if let messageID = provenance.messageID {
            _ = try validatedAuthorityIdentifier(messageID, field: "provenance.messageID")
        }
        _ = try validatedAuthorityToken(provenance.role, field: "provenance.role")
        _ = try validatedAuthorityTimestamp(provenance.authoredAtText, field: "provenance.authoredAtText")
        _ = try validatedAuthorityIdentifier(provenance.contentHash, field: "provenance.contentHash")
        guard provenance.occurrence >= 0, provenance.occurrence <= authorityMaxOccurrence else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "provenance.occurrence must be between 0 and \(authorityMaxOccurrence)"
            )
        }
        _ = try validatedAuthorityIdentifier(provenance.xdeviceHMAC, field: "provenance.xdeviceHMAC")
        _ = try validatedAuthorityToken(provenance.citationState, field: "provenance.citationState")
        _ = try validatedAuthorityTimestamp(provenance.createdAtText, field: "provenance.createdAtText")
    }

    private static func validateMemoryAuthorityFactTombstone(
        _ tombstone: BurnBarMemoryAuthorityFactTombstoneRow,
        field: String
    ) throws {
        _ = try validatedAuthorityIdentifier(tombstone.id, field: "\(field).id")
        _ = try validatedAuthorityIdentifier(tombstone.userID, field: "\(field).userID")
        _ = try validatedAuthorityIdentifier(tombstone.memoryID, field: "\(field).memoryID")
        _ = try validatedAuthorityJSON(
            tombstone.sourceRefsJSON,
            field: "\(field).sourceRefsJSON",
            maxBytes: authorityMaxSmallJSONBytes
        )
        _ = try validatedAuthorityToken(tombstone.reason, field: "\(field).reason")
        _ = try validatedAuthorityTimestamp(tombstone.createdAtText, field: "\(field).createdAtText")
    }

    private static func validateMemoryAuthoritySourceTombstone(
        _ tombstone: BurnBarMemoryAuthoritySourceTombstoneRow
    ) throws {
        _ = try validatedAuthorityIdentifier(tombstone.id, field: "recordSourceTombstone.id")
        if let userID = tombstone.userID {
            _ = try validatedAuthorityIdentifier(userID, field: "recordSourceTombstone.userID")
        }
        _ = try validatedAuthorityIdentifier(
            tombstone.threadLogicalID,
            field: "recordSourceTombstone.threadLogicalID"
        )
        if let messageID = tombstone.messageID {
            _ = try validatedAuthorityIdentifier(messageID, field: "recordSourceTombstone.messageID")
        }
        if let contentHash = tombstone.contentHash {
            _ = try validatedAuthorityIdentifier(contentHash, field: "recordSourceTombstone.contentHash")
        }
        _ = try validatedAuthorityToken(tombstone.reason, field: "recordSourceTombstone.reason")
        _ = try validatedAuthorityTimestamp(tombstone.createdAtText, field: "recordSourceTombstone.createdAtText")
    }

    private static func validateMemoryAuthorityMerge(_ merge: BurnBarMemoryAuthorityMerge) throws {
        _ = try validatedAuthorityIdentifier(merge.winnerID, field: "remember.merge.winnerID")
        guard merge.loserIDs.isEmpty == false, merge.loserIDs.count <= authorityMaxLosers else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "remember.merge.loserIDs must contain 1...\(authorityMaxLosers) entries"
            )
        }
        for loserID in merge.loserIDs {
            _ = try validatedAuthorityIdentifier(loserID, field: "remember.merge.loserIDs")
        }
        guard merge.sourceKinds.isEmpty == false,
              merge.sourceKinds.count <= authorityMaxSourceKinds else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "remember.merge.sourceKinds must contain 1...\(authorityMaxSourceKinds) entries"
            )
        }
        for sourceKind in merge.sourceKinds {
            _ = try validatedAuthorityToken(sourceKind, field: "remember.merge.sourceKinds")
        }
        _ = try validatedAuthorityIdentifier(
            merge.storageProjectID,
            field: "remember.merge.storageProjectID"
        )
        _ = try validatedAuthorityTimestamp(merge.nowText, field: "remember.merge.nowText")
        _ = try validatedAuthorityTimestamp(merge.nowTimestampText, field: "remember.merge.nowTimestampText")
        guard merge.provenanceCopies.count <= authorityMaxProvenanceRows else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "remember.merge.provenanceCopies exceeds \(authorityMaxProvenanceRows) rows"
            )
        }
        for copy in merge.provenanceCopies {
            try validateMemoryAuthorityProvenance(copy)
        }
        // Structural pin: the legacy merge appends exactly one supersede
        // audit per loser, then the merge audit. Anything else is malformed.
        guard merge.supersedeAudits.count == merge.loserIDs.count else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "remember.merge.supersedeAudits must carry one audit per loser"
            )
        }
        for audit in merge.supersedeAudits {
            try validateMemoryAuthorityAudit(audit, field: "remember.merge.supersedeAudits")
        }
        try validateMemoryAuthorityAudit(merge.mergeAudit, field: "remember.merge.mergeAudit")
    }

    private static func validateMemoryAuthorityAudit(
        _ event: BurnBarMemoryAuthorityAuditEvent,
        field: String
    ) throws {
        let action = event.action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard action.isEmpty == false, action == event.action else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field).action must be nonblank and trimmed"
            )
        }
        guard event.action.utf8.count <= authorityMaxActionBytes else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field).action exceeds \(authorityMaxActionBytes) UTF-8 bytes"
            )
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard event.action.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field).action must match [A-Za-z0-9._-]+"
            )
        }
        if let projectID = event.projectID {
            _ = try validatedAuthorityIdentifier(projectID, field: "\(field).projectID")
        }
        if let subjectID = event.subjectID {
            _ = try validatedAuthorityIdentifier(subjectID, field: "\(field).subjectID")
        }
        try validateMemoryAuthorityLabels(event.labels, labelsJSON: event.labelsJSON, field: field)
        _ = try validatedAuthorityTimestamp(event.timestampText, field: "\(field).timestampText")
    }

    /// The carried encoding must decode to exactly the carried labels: the
    /// daemon binds the string verbatim, so it proves the string is the
    /// labels instead of trusting it.
    private static func validateMemoryAuthorityLabels(
        _ labels: [String],
        labelsJSON: String,
        field: String
    ) throws {
        guard labels.count <= authorityMaxLabels else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field).labels exceeds \(authorityMaxLabels) entries"
            )
        }
        for label in labels {
            guard label.utf8.count <= authorityMaxIdentifierBytes else {
                throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                    "\(field).labels entry exceeds \(authorityMaxIdentifierBytes) UTF-8 bytes"
                )
            }
            guard label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
                throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                    "\(field).labels entry contains control characters"
                )
            }
        }
        guard labels == labels.sorted() else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field).labels must arrive sorted"
            )
        }
        guard labelsJSON.utf8.count <= authorityMaxLabelsJSONBytes else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field).labelsJSON exceeds \(authorityMaxLabelsJSONBytes) UTF-8 bytes"
            )
        }
        guard let data = labelsJSON.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String],
              decoded == labels else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field).labelsJSON must decode to exactly the carried labels"
            )
        }
    }

    private static func validatedAuthorityIdentifier(_ raw: String, field: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed == raw else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) must be nonblank and trimmed"
            )
        }
        guard raw.utf8.count <= authorityMaxIdentifierBytes else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) exceeds \(authorityMaxIdentifierBytes) UTF-8 bytes"
            )
        }
        guard raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) contains control characters"
            )
        }
        return raw
    }

    private static func validatedAuthorityToken(_ raw: String, field: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed == raw else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) must be nonblank and trimmed"
            )
        }
        guard raw.utf8.count <= authorityMaxShortTextBytes else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) exceeds \(authorityMaxShortTextBytes) UTF-8 bytes"
            )
        }
        guard raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) contains control characters"
            )
        }
        return raw
    }

    private static func validatedAuthorityLongText(_ raw: String, field: String) throws -> String {
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) must be nonblank"
            )
        }
        guard raw.utf8.count <= authorityMaxSourcePathBytes else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) exceeds \(authorityMaxSourcePathBytes) UTF-8 bytes"
            )
        }
        guard raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) contains control characters"
            )
        }
        return raw
    }

    private static func validatedAuthorityJSON(_ raw: String, field: String, maxBytes: Int) throws -> String {
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) must not be blank"
            )
        }
        guard raw.utf8.count <= maxBytes else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) exceeds \(maxBytes) UTF-8 bytes"
            )
        }
        guard let data = raw.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [])) != nil else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) must be valid JSON"
            )
        }
        return raw
    }

    private static func validatedAuthorityBodyHash(_ raw: String, field: String) throws -> String {
        // The app produces lowercase `%02x` SHA-256; demand exactly 64 hex
        // digits, same rule as the snapshot lane's content hash.
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard raw.count == 64, raw.unicodeScalars.allSatisfy({ hex.contains($0) }) else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) must be 64 hexadecimal characters"
            )
        }
        return raw
    }

    private static func validateMemoryAuthorityConfidence(_ raw: Double, field: String) throws {
        guard raw.isFinite else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) must be finite"
            )
        }
    }

    /// Accepts ISO 8601 (with or without fractional seconds) and GRDB text
    /// (`yyyy-MM-dd HH:mm:ss.SSS`, UTC). Returns the input untouched: the
    /// lane binds app-finalized stamps verbatim, quirks included.
    private static func validatedAuthorityTimestamp(_ raw: String, field: String) throws -> String {
        guard parseMemoryAuthorityTimestamp(raw) != nil else {
            throw BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest(
                "\(field) must be ISO 8601 or GRDB timestamp text"
            )
        }
        return raw
    }

    private static func parseMemoryAuthorityTimestamp(_ raw: String) -> Date? {
        if let iso = ThreadSafeISO8601DateFormatter.parse(raw) { return iso }
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
