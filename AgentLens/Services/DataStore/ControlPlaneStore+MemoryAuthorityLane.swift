import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore
import OpenBurnBarData
import OpenBurnBarKernel

// MARK: - Memory authority app lane (Wave 2.1c-iii single-writer cutover)
//
// The daemon owns the memory authority tables (ADR-005). This file is the
// app side of the cutover: every authority flow finalizes its write set
// here — same decisions, same encodings, same stamps the legacy
// transactions bound — and commits it through `memoryAuthorityWriter`
// instead of writing the tables directly. Reads stay on the app's local
// connection; only the commit crosses the socket.
//
// Byte-compatibility rules, enforced by construction:
// - Date-typed columns render through `memoryAuthorityTimestampText`, which
//   IS GRDB's `Date.databaseValue` path — the exact function a legacy
//   `arguments: [date]` binding called. Lane stamps cannot drift from
//   legacy stamps, even at half-millis boundaries where reimplemented
//   formatters disagree.
// - String-typed stamps (audit `ts`, review `updated_at`, blanking stamps,
//   enqueue `created_at`) carry the legacy call sites' exact formatter
//   output, quirks included, and the daemon binds them verbatim.
// - Audit labels and `labels_json` are the legacy `auditLabelsJSON`
//   encoding of the legacy sorted label lists. The daemon assigns only
//   `seq`/`prev_hash`/`hash`, in-transaction, from the live chain head.

extension ControlPlaneStore {
    /// Max reseal compare-and-swap attempts before surfacing
    /// `conflictRetryExhausted`. Each attempt re-reads the stored snapshot,
    /// so one retry almost always converges; three bounds a hot row.
    static let memoryAuthorityMaxResealAttempts = 3

    // MARK: - Commit

    /// Commits finalized operations through the writer seam. Fails closed on
    /// a shape-mismatched response (fail-closed, never a silent partial
    /// apply). A `rpcConflict` propagates raw so the reseal caller can
    /// re-read and retry; every other flow uses the checked variant below.
    func commitMemoryAuthorityOperations(
        _ operations: [BurnBarMemoryAuthorityOperation]
    ) async throws -> BurnBarMemoryAuthorityApplyResponse {
        let request = BurnBarMemoryAuthorityApplyRequest(
            mutationID: UUID().uuidString,
            actor: "app",
            operations: operations
        )
        let response = try await memoryAuthorityWriter.apply(request)
        guard response.mutationID == request.mutationID,
              response.results.count == operations.count else {
            throw ChatMemoryAuthorityError.authorityResultMismatch
        }
        return response
    }

    /// The commit for flows that set no preconditions: a conflict is
    /// impossible from an honest daemon, so a conflict here maps to a typed
    /// failure instead of leaking the transport error (fail closed, stable
    /// error surface).
    func commitMemoryAuthorityOperationsChecked(
        _ operations: [BurnBarMemoryAuthorityOperation]
    ) async throws -> BurnBarMemoryAuthorityApplyResponse {
        do {
            return try await commitMemoryAuthorityOperations(operations)
        } catch OpenBurnBarDaemonManagerError.rpcConflict {
            throw ChatMemoryAuthorityError.conflictRetryExhausted
        }
    }

    // MARK: - Stamps

    /// Exactly the bytes a legacy `arguments: [date]` binding stored: this
    /// IS GRDB's `Date.databaseValue` path, not a reimplementation. The
    /// fallback is unreachable (GRDB documents TEXT for `Date`) and exists
    /// only so a future GRDB change degrades to the canonical renderer
    /// instead of crashing a write.
    static func memoryAuthorityTimestampText(_ date: Date) -> String {
        if case .string(let text) = date.databaseValue.storage {
            return text
        }
        return OpenBurnBarDatabase.sqliteDateString(date)
    }

    // MARK: - Audit events

    static func memoryAuthorityAuditEvent(
        action: String,
        projectID: String?,
        subjectID: String?,
        labels: [String],
        nowString: String
    ) throws -> BurnBarMemoryAuthorityAuditEvent {
        let (normalized, json) = try memoryAuthoritySortedLabels(labels)
        return BurnBarMemoryAuthorityAuditEvent(
            action: action,
            projectID: projectID,
            subjectID: subjectID,
            labels: normalized,
            labelsJSON: json,
            timestampText: nowString
        )
    }

    /// The legacy label encoding: sorted list plus its exact
    /// `auditLabelsJSON` bytes. Sorting is idempotent, so passing an
    /// already-sorted list yields byte-identical output to the legacy path.
    static func memoryAuthoritySortedLabels(_ labels: [String]) throws -> (labels: [String], json: String) {
        let normalized = labels.sorted()
        return (normalized, try auditLabelsJSON(normalized))
    }

    // MARK: - Row builders

    static func memoryAuthoritySnapshotRow(
        id: String,
        memoryID: String,
        bodyRef: String,
        snapshotJSON: String,
        bodyHash: String,
        sourceKind: MemorySourceKind,
        createdAt: Date,
        updatedAt: Date
    ) -> BurnBarMemoryAuthoritySnapshotRow {
        BurnBarMemoryAuthoritySnapshotRow(
            id: id,
            memoryID: memoryID,
            bodyRef: bodyRef,
            snapshotJSON: snapshotJSON,
            bodyHash: bodyHash,
            sourceKind: sourceKind.rawValue,
            createdAtText: memoryAuthorityTimestampText(createdAt),
            updatedAtText: memoryAuthorityTimestampText(updatedAt)
        )
    }

    /// The remember row image, finalized from the add request. `scopeText`
    /// carries the legacy v50 spelling rule (chat rows ship the literal
    /// `"chat"`; usage rows carry their raw source kind). Remember-time
    /// constants (`tagsJSON`, `sourcePath`, the three `now` stamps) live here
    /// rather than as parameters: the add flow is the only caller.
    static func memoryAuthorityMemoryRow(
        id: String,
        request: MemoryAddRequest,
        sourceKind: MemorySourceKind,
        storageProjectID: String,
        bodyRef: String,
        now: Date,
        validTo: Date?,
        supersededBy: MemoryID?
    ) -> BurnBarMemoryAuthorityMemoryRow {
        BurnBarMemoryAuthorityMemoryRow(
            id: id,
            projectID: storageProjectID,
            kind: request.kind.rawValue,
            scopeText: sourceKind == .chat ? "chat" : sourceKind.rawValue,
            confidence: request.confidence,
            bodyRef: bodyRef,
            bodyRedacted: bodyRef,
            tagsJSON: "[]",
            sourcePath: nil,
            validFromText: memoryAuthorityTimestampText(now),
            validToText: validTo.map(memoryAuthorityTimestampText),
            supersededBy: supersededBy,
            createdAtText: memoryAuthorityTimestampText(now),
            updatedAtText: memoryAuthorityTimestampText(now),
            sourceKind: sourceKind.rawValue,
            reviewStatus: request.reviewStatus.rawValue,
            userID: request.scope.userID,
            agentID: request.scope.agentID,
            runID: request.scope.runID,
            appID: request.scope.appID
        )
    }

    static func memoryAuthorityProvenanceRow(
        id: String,
        memoryID: String,
        sourceKind: MemoryProvenanceSourceKind,
        citation: MemoryCitation,
        createdAt: Date
    ) -> BurnBarMemoryAuthorityProvenanceRow {
        BurnBarMemoryAuthorityProvenanceRow(
            id: id,
            memoryID: memoryID,
            sourceKind: sourceKind.rawValue,
            threadLogicalID: citation.threadLogicalID,
            messageID: citation.messageID,
            role: citation.role,
            authoredAtText: memoryAuthorityTimestampText(citation.authoredAt),
            contentHash: citation.contentHash,
            occurrence: citation.occurrence,
            xdeviceHMAC: citation.crossDeviceHMAC,
            citationState: citation.citationState.rawValue,
            createdAtText: memoryAuthorityTimestampText(createdAt)
        )
    }

    static func memoryAuthorityFactTombstoneRow(
        id: String,
        userID: String,
        memoryID: String,
        sourceRefsJSON: String,
        reason: String,
        createdAtText: String,
        overwriteOnConflict: Bool,
        refreshSourceRefsOnConflict: Bool
    ) -> BurnBarMemoryAuthorityFactTombstoneRow {
        BurnBarMemoryAuthorityFactTombstoneRow(
            id: id,
            userID: userID,
            memoryID: memoryID,
            sourceRefsJSON: sourceRefsJSON,
            reason: normalizedMemoryForgetReason(reason),
            createdAtText: createdAtText,
            overwriteOnConflict: overwriteOnConflict,
            refreshSourceRefsOnConflict: refreshSourceRefsOnConflict
        )
    }

    /// The chat review/delete tombstone: same id, same source-ref encoding
    /// (plain `JSONEncoder`, ISO 8601 dates), same overwrite clause as the
    /// legacy `insertMemoryFactTombstone`. Nil when the row has no owner,
    /// exactly like the legacy early return.
    static func memoryAuthorityChatFactTombstone(
        memory: Memory,
        reason: String,
        createdAt: Date
    ) throws -> BurnBarMemoryAuthorityFactTombstoneRow? {
        guard let userID = memory.scope.userID else { return nil }
        let sourceRefs = memory.citations.map {
            MemoryFactTombstoneSourceRef(
                threadLogicalID: $0.threadLogicalID,
                messageID: $0.messageID,
                contentHash: $0.contentHash
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sourceRefsData = try encoder.encode(sourceRefs)
        return memoryAuthorityFactTombstoneRow(
            id: memoryFactTombstoneID(memoryID: memory.id),
            userID: userID,
            memoryID: memory.id,
            sourceRefsJSON: String(decoding: sourceRefsData, as: UTF8.self),
            reason: reason,
            createdAtText: memoryAuthorityTimestampText(createdAt),
            overwriteOnConflict: true,
            refreshSourceRefsOnConflict: true
        )
    }

    /// The mirrored-row delete tombstone: engine-keyed id, empty source
    /// refs, and the legacy agent clause (no `source_refs_json` refresh).
    static func memoryAuthorityAgentFactTombstone(
        memoryID: MemoryID,
        userID: String,
        engineMemoryID: String?,
        reason: String,
        createdAt: Date
    ) -> BurnBarMemoryAuthorityFactTombstoneRow {
        memoryAuthorityFactTombstoneRow(
            id: agentMemoryFactTombstoneID(memoryID: memoryID, engineMemoryID: engineMemoryID),
            userID: userID,
            memoryID: memoryID,
            sourceRefsJSON: "[]",
            reason: reason,
            createdAtText: memoryAuthorityTimestampText(createdAt),
            overwriteOnConflict: true,
            refreshSourceRefsOnConflict: false
        )
    }

    static func memoryAuthoritySourceTombstoneRow(
        id: String,
        userID: String?,
        threadLogicalID: String,
        messageID: String?,
        contentHash: String?,
        reason: String,
        createdAt: Date
    ) -> BurnBarMemoryAuthoritySourceTombstoneRow {
        BurnBarMemoryAuthoritySourceTombstoneRow(
            id: id,
            userID: userID,
            threadLogicalID: threadLogicalID,
            messageID: messageID,
            contentHash: contentHash,
            reason: normalizedMemoryForgetReason(reason),
            createdAtText: memoryAuthorityTimestampText(createdAt)
        )
    }

    // MARK: - Pre-reads (local connection)

    /// The dedup election inputs plus every candidate id. Both lists come
    /// from the same `memoryDuplicateCandidates` query the legacy path ran
    /// in-transaction; `ids` preserves the legacy merge's
    /// id-inclusion rule (every row with an id, even one the election
    /// skips), while `candidates` carries only electable rows.
    struct MemoryAuthorityDuplicates: Sendable {
        let candidates: [MemoryAuthorityDedupCandidate]
        let ids: [MemoryID]
    }

    struct MemoryAuthorityDedupCandidate: Sendable {
        let id: MemoryID
        let confidence: Double
        let reviewStatus: MemoryReviewStatus
        let validFrom: Date
    }

    func memoryAuthorityDuplicates(
        bodyHash: String,
        storageProjectID: String,
        kind: MemoryKind,
        scope: MemoryScope,
        excludingID: MemoryID,
        sourceKinds: Set<MemorySourceKind>
    ) async throws -> MemoryAuthorityDuplicates {
        try await dbQueue.read { db in
            let rows = try Self.memoryDuplicateCandidates(
                db: db,
                bodyHash: bodyHash,
                storageProjectID: storageProjectID,
                kind: kind,
                scope: scope,
                excludingID: excludingID,
                sourceKinds: sourceKinds
            )
            return Self.memoryAuthorityDuplicates(from: rows)
        }
    }

    static func memoryAuthorityDuplicates(from rows: [Row]) -> MemoryAuthorityDuplicates {
        let ids: [MemoryID] = rows.compactMap { row in row["id"] }
        let candidates: [MemoryAuthorityDedupCandidate] = rows.compactMap { row in
            guard let id: String = row["id"],
                  let confidence: Double = row["confidence"],
                  let reviewStatusRaw: String = row["review_status"],
                  let reviewStatus = MemoryReviewStatus(rawValue: reviewStatusRaw),
                  let validFrom = OpenBurnBarDatabase.parseDateValue(row["valid_from"])
            else {
                return nil
            }
            return MemoryAuthorityDedupCandidate(
                id: id,
                confidence: confidence,
                reviewStatus: reviewStatus,
                validFrom: validFrom
            )
        }
        return MemoryAuthorityDuplicates(candidates: candidates, ids: ids)
    }

    /// The sealed snapshot plus the raw seal columns the reseal
    /// compare-and-swap preconditions on. `bodyHash`/`updatedAtText` are the
    /// stored TEXT, never re-rendered — the precondition compares stored
    /// bytes to stored bytes.
    struct MemoryAuthoritySnapshotSeal: Sendable {
        let body: String?
        let context: String?
        let bodyHash: String?
        let updatedAtText: String?
    }

    func memoryAuthoritySnapshotSeal(id: MemoryID) async throws -> MemoryAuthoritySnapshotSeal {
        try await dbQueue.read { db in
            let stored = try Self.memoryBodySnapshot(db: db, id: id)
            let row = try Row.fetchOne(
                db,
                sql: "SELECT body_hash, updated_at FROM memory_body_snapshots WHERE memory_id = ?",
                arguments: [id]
            )
            var bodyHash: String?
            var updatedAtText: String?
            if let row {
                bodyHash = row["body_hash"]
                updatedAtText = row["updated_at"]
            }
            return MemoryAuthoritySnapshotSeal(
                body: stored?.body,
                context: stored?.context,
                bodyHash: bodyHash,
                updatedAtText: updatedAtText
            )
        }
    }

    /// One loser provenance row as the dedup copy needs it. `authoredAtText`
    /// is the legacy normalization (parse, then re-render through the GRDB
    /// binding path), not a verbatim copy — the legacy copy rebound a parsed
    /// `Date`, which normalizes any non-GRDB spelling already on disk.
    struct MemoryAuthorityProvenanceSource: Sendable {
        let id: String
        let loserID: MemoryID
        let sourceKind: String
        let threadLogicalID: String
        let messageID: String?
        let role: String
        let authoredAtText: String
        let contentHash: String
        let occurrence: Int
        let xdeviceHMAC: String
        let citationState: String
    }

    func memoryAuthorityProvenanceSources(memoryIDs: [MemoryID]) async throws -> [MemoryAuthorityProvenanceSource] {
        guard memoryIDs.isEmpty == false else { return [] }
        return try await dbQueue.read { db in
            let placeholders = memoryIDs.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_provenance
                WHERE memory_id IN (\(placeholders))
                ORDER BY authored_at ASC, occurrence ASC, id ASC
                """,
                arguments: StatementArguments(memoryIDs)
            )
            return rows.compactMap(Self.memoryAuthorityProvenanceSource(from:))
        }
    }

    static func memoryAuthorityProvenanceSource(from row: Row) -> MemoryAuthorityProvenanceSource? {
        guard let sourceID: String = row["id"],
              let loserID: String = row["memory_id"],
              let sourceKind: String = row["source_kind"],
              let threadLogicalID: String = row["thread_logical_id"],
              let role: String = row["role"],
              let authoredAt = OpenBurnBarDatabase.parseDateValue(row["authored_at"]),
              let contentHash: String = row["content_hash"],
              let occurrence: Int = row["occurrence"],
              let xdeviceHMAC: String = row["xdevice_hmac"],
              let citationState: String = row["citation_state"]
        else {
            return nil
        }
        let messageID: String? = row["message_id"]
        return MemoryAuthorityProvenanceSource(
            id: sourceID,
            loserID: loserID,
            sourceKind: sourceKind,
            threadLogicalID: threadLogicalID,
            messageID: messageID,
            role: role,
            authoredAtText: memoryAuthorityTimestampText(authoredAt),
            contentHash: contentHash,
            occurrence: occurrence,
            xdeviceHMAC: xdeviceHMAC,
            citationState: citationState
        )
    }

    struct MemoryAuthorityProvenancePair: Hashable, Sendable {
        let xdeviceHMAC: String
        let occurrence: Int
    }

    /// The winner's existing `(xdevice_hmac, occurrence)` pairs: the
    /// in-memory form of the legacy per-row existence check. Fetched once;
    /// membership decides each copy, exactly like the legacy `COUNT(*)` did
    /// against the same committed state.
    func memoryAuthorityWinnerProvenancePairs(winnerID: MemoryID) async throws -> Set<MemoryAuthorityProvenancePair> {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT xdevice_hmac, occurrence FROM memory_provenance WHERE memory_id = ?",
                arguments: [winnerID]
            )
            return Set(rows.compactMap { row -> MemoryAuthorityProvenancePair? in
                guard let hmac: String = row["xdevice_hmac"],
                      let occurrence: Int = row["occurrence"] else {
                    return nil
                }
                return MemoryAuthorityProvenancePair(xdeviceHMAC: hmac, occurrence: occurrence)
            })
        }
    }

    /// The dedup provenance copies: same deterministic ids, same skip rule,
    /// same row shape as the legacy `copyMemoryProvenance`. The legacy copy
    /// ran per source row inside the write transaction, so each row's
    /// existence check saw the copies emitted just before it; `seen` replays
    /// that sequential check so two losers sharing a pair emit one copy.
    static func memoryAuthorityProvenanceCopies(
        sources: [MemoryAuthorityProvenanceSource],
        winnerID: MemoryID,
        winnerPairs: Set<MemoryAuthorityProvenancePair>,
        now: Date
    ) -> [BurnBarMemoryAuthorityProvenanceRow] {
        var copies: [BurnBarMemoryAuthorityProvenanceRow] = []
        var seen = winnerPairs
        for source in sources {
            guard source.loserID != winnerID else { continue }
            let pair = MemoryAuthorityProvenancePair(xdeviceHMAC: source.xdeviceHMAC, occurrence: source.occurrence)
            guard seen.contains(pair) == false else { continue }
            seen.insert(pair)
            copies.append(BurnBarMemoryAuthorityProvenanceRow(
                id: "dedup-\(winnerID)-\(sha256Hex("\(source.loserID)|\(source.id)"))",
                memoryID: winnerID,
                sourceKind: source.sourceKind,
                threadLogicalID: source.threadLogicalID,
                messageID: source.messageID,
                role: source.role,
                authoredAtText: source.authoredAtText,
                contentHash: source.contentHash,
                occurrence: source.occurrence,
                xdeviceHMAC: source.xdeviceHMAC,
                citationState: source.citationState,
                createdAtText: memoryAuthorityTimestampText(now)
            ))
        }
        return copies
    }

    /// The dedup merge plan: loser updates, provenance copies, per-loser
    /// supersede audits, and the merge audit. Nil when nothing matched,
    /// exactly like the legacy early returns.
    func memoryAuthorityMergePlan(
        duplicateIDs: [MemoryID],
        newID: MemoryID,
        newCitations: [MemoryCitation],
        newSourceKind: MemorySourceKind,
        winnerID: MemoryID,
        storageProjectID: String,
        sourceKinds: Set<MemorySourceKind>,
        now: Date,
        nowString: String
    ) async throws -> BurnBarMemoryAuthorityMerge? {
        guard duplicateIDs.isEmpty == false else { return nil }
        let loserIDs = (duplicateIDs + [newID]).filter { $0 != winnerID }.uniqued()
        guard loserIDs.isEmpty == false else { return nil }
        var sources = try await memoryAuthorityProvenanceSources(memoryIDs: loserIDs)
        // The remember's own provenance rows commit atomically with this
        // merge, so the pre-read above cannot see newID's citations — but the
        // legacy in-transaction copy ran after the insert and did. Synthesize
        // newID's sources from the in-flight citations (same ids, same row
        // shape as the remember inserts) so the union keeps them.
        if loserIDs.contains(newID) {
            let provenanceKind = Self.memoryProvenanceSourceKind(for: newSourceKind).rawValue
            for citation in newCitations {
                sources.append(MemoryAuthorityProvenanceSource(
                    id: Self.memoryProvenanceID(memoryID: newID, citationID: citation.id),
                    loserID: newID,
                    sourceKind: provenanceKind,
                    threadLogicalID: citation.threadLogicalID,
                    messageID: citation.messageID,
                    role: citation.role,
                    authoredAtText: Self.memoryAuthorityTimestampText(citation.authoredAt),
                    contentHash: citation.contentHash,
                    occurrence: citation.occurrence,
                    xdeviceHMAC: citation.crossDeviceHMAC,
                    citationState: citation.citationState.rawValue
                ))
            }
        }
        // Legacy `mergeDuplicateMemories` copied per loser in loserID order
        // (each loser's rows by authored_at, occurrence, id). Replay that
        // order so the same copy wins when two losers share a pair.
        let loserOrder = Dictionary(uniqueKeysWithValues: loserIDs.enumerated().map { ($0.element, $0.offset) })
        sources.sort {
            let leftOrder = loserOrder[$0.loserID] ?? Int.max
            let rightOrder = loserOrder[$1.loserID] ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if $0.authoredAtText != $1.authoredAtText { return $0.authoredAtText < $1.authoredAtText }
            if $0.occurrence != $1.occurrence { return $0.occurrence < $1.occurrence }
            return $0.id < $1.id
        }
        var winnerPairs = try await memoryAuthorityWinnerProvenancePairs(winnerID: winnerID)
        // Same post-insert visibility for the existence check: when the
        // winner is the new record, legacy saw its just-inserted rows.
        if winnerID == newID {
            for citation in newCitations {
                winnerPairs.insert(MemoryAuthorityProvenancePair(
                    xdeviceHMAC: citation.crossDeviceHMAC,
                    occurrence: citation.occurrence
                ))
            }
        }
        let copies = Self.memoryAuthorityProvenanceCopies(
            sources: sources,
            winnerID: winnerID,
            winnerPairs: winnerPairs,
            now: now
        )
        let kindLabel = sourceKinds.map(\.rawValue).sorted().joined(separator: ",")
        var supersedeAudits: [BurnBarMemoryAuthorityAuditEvent] = []
        supersedeAudits.reserveCapacity(loserIDs.count)
        for loserID in loserIDs {
            supersedeAudits.append(try Self.memoryAuthorityAuditEvent(
                action: "memory.supersede",
                projectID: storageProjectID,
                subjectID: loserID,
                labels: [
                    "reason:duplicate_body_hash",
                    "source_kind:\(kindLabel)",
                    "winner_id:\(winnerID)"
                ],
                nowString: nowString
            ))
        }
        let mergeAudit = try Self.memoryAuthorityAuditEvent(
            action: "memory.merge",
            projectID: storageProjectID,
            subjectID: winnerID,
            labels: [
                "merged_ids:\(loserIDs.joined(separator: ","))",
                "reason:duplicate_body_hash",
                "source_kind:\(kindLabel)",
                "winner_id:\(winnerID)"
            ],
            nowString: nowString
        )
        return BurnBarMemoryAuthorityMerge(
            winnerID: winnerID,
            loserIDs: loserIDs,
            sourceKinds: sourceKinds.map(\.rawValue).sorted(),
            storageProjectID: storageProjectID,
            nowText: Self.memoryAuthorityTimestampText(now),
            nowTimestampText: nowString,
            provenanceCopies: copies,
            supersedeAudits: supersedeAudits,
            mergeAudit: mergeAudit
        )
    }

    // MARK: - Sweep pre-reads

    struct MemoryAuthorityEnqueueCandidate: Sendable {
        let memoryID: String
        let engineMemoryID: String?
    }

    /// The unsyncable-row candidates: the same join the legacy enqueue ran
    /// in-transaction, over the same committed state.
    func memoryAuthorityEnqueueCandidates(userID: String) async throws -> [MemoryAuthorityEnqueueCandidate] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.id AS id, b.engine_memory_id AS engine_memory_id
                FROM agent_memories m
                LEFT JOIN agent_memory_bodies b ON b.memory_id = m.id
                WHERE m.source_kind = ? AND m.user_id = ?
                  AND (
                    m.review_status = ?
                    OR (b.memory_id IS NOT NULL AND m.review_status != ?)
                  )
                """,
                arguments: [
                    MemorySourceKind.agent.rawValue,
                    userID,
                    MemoryReviewStatus.forgotten.rawValue,
                    MemoryReviewStatus.approved.rawValue
                ]
            )
            return rows.compactMap { row -> MemoryAuthorityEnqueueCandidate? in
                guard let memoryID: String = row["id"] else { return nil }
                let engineMemoryID: String? = row["engine_memory_id"]
                return MemoryAuthorityEnqueueCandidate(memoryID: memoryID, engineMemoryID: engineMemoryID)
            }
        }
    }

    struct MemoryAuthorityReconcileCandidate: Sendable {
        let memoryID: String
        let projectID: String
    }

    /// The tombstone-suppression matches: the same join the legacy
    /// reconcile ran in-transaction, over the same committed state.
    func memoryAuthorityReconcileCandidates() async throws -> [MemoryAuthorityReconcileCandidate] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT m.id, m.project_id
                FROM agent_memories m
                JOIN memory_provenance p
                  ON p.memory_id = m.id
                JOIN memory_source_tombstones t
                  ON t.thread_logical_id = p.thread_logical_id
                 AND (t.message_id IS NULL OR t.message_id = p.message_id)
                 AND (t.content_hash IS NULL OR t.content_hash = p.content_hash)
                WHERE m.source_kind = ?
                  AND m.valid_to IS NULL
                """,
                arguments: [MemorySourceKind.chat.rawValue]
            )
            return rows.compactMap { row -> MemoryAuthorityReconcileCandidate? in
                guard let memoryID: String = row["id"],
                      let projectID: String = row["project_id"] else {
                    return nil
                }
                return MemoryAuthorityReconcileCandidate(memoryID: memoryID, projectID: projectID)
            }
        }
    }
}
