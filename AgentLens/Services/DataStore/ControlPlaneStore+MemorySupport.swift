import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    struct MemoryBodySnapshot: Codable, Sendable {
        let schemaVersion: Int
        let memoryID: MemoryID
        let sourceKind: MemorySourceKind
        let bodyHash: String
        let body: String
        let citations: [MemoryCitation]
        let createdAt: Date
        /// One situating sentence produced by usage-memory extraction (A-MEM
        /// atomic-note shape). Absent on schemaVersion 1 (all chat snapshots).
        var context: String?
    }

    /// Storage partition for the `project_id` bucket when the scope has no
    /// explicit project. Chat keeps its shipped `chat:` prefix byte-identical;
    /// both usage kinds share `usage:` so cross-source dedup and corroboration
    /// happen inside the existing project-scoped queries.
    enum MemoryStoragePartition: String {
        case chat
        case usage

        init(_ sourceKind: MemorySourceKind) {
            self = MemorySourceKind.usageKinds.contains(sourceKind) ? .usage : .chat
        }

        init(_ sourceKinds: Set<MemorySourceKind>) {
            let isUsage = sourceKinds.isEmpty == false
                && sourceKinds.isSubset(of: MemorySourceKind.usageKinds)
            self = isUsage ? .usage : .chat
        }
    }

    /// Split a mixed kind set into per-partition subsets so partition-scoped
    /// queries (whose `project_id` bucket differs per partition) can run once
    /// per partition and union the results. Chat-partition kinds come first so
    /// the fetch order is deterministic; `[.chat]` yields exactly `[[.chat]]`.
    static func memoryPartitionedSourceKinds(
        _ kinds: Set<MemorySourceKind>
    ) -> [Set<MemorySourceKind>] {
        let usage = kinds.intersection(MemorySourceKind.usageKinds)
        let chatLike = kinds.subtracting(MemorySourceKind.usageKinds)
        return [chatLike, usage].filter { $0.isEmpty == false }
    }

    static func memorySnapshotSlug(_ id: MemoryID) -> String {
        "memory-\(id)"
    }

    static func memorySnapshotRef(_ slug: String) -> String {
        "memory_body_snapshots:\(slug)"
    }

    static func memoryStorageProjectID(
        for scope: MemoryScope,
        partition: MemoryStoragePartition = .chat
    ) -> String {
        scope.projectID ?? "\(partition.rawValue):\(scope.userID ?? scope.appID ?? "unscoped")"
    }

    /// `memory_provenance.source_kind` value for citations written through the
    /// authority add path. `.code` is unreachable here — the daemon owns code
    /// writes through its own store and never calls this method.
    static func memoryProvenanceSourceKind(for sourceKind: MemorySourceKind) -> MemoryProvenanceSourceKind {
        switch sourceKind {
        case .safariAsk: .safariAsk
        case .agentSession: .agentSessionEvent
        case .chat, .code, .agent: .chatMessage
        }
    }

    /// Deterministic `source_kind IN (…)` fragment (kinds sorted by raw value
    /// so the SQL text is stable for tests and plan caches).
    static func memorySourceKindInClause(
        column: String,
        kinds: Set<MemorySourceKind>
    ) -> (sql: String, arguments: [String]) {
        let ordered = kinds.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: max(1, ordered.count)).joined(separator: ", ")
        return ("\(column) IN (\(placeholders))", ordered)
    }

    /// Internal shim exposed for `MemoryExtractionWorker` (which lives outside the extension
    /// and cannot access the private `memoryStorageProjectID`). Same logic, different name.
    static func memoryExtractionProjectID(for scope: MemoryScope) -> String {
        memoryStorageProjectID(for: scope)
    }

    /// Internal shim for reset/forget helpers split into another file.
    static func appendMemoryExtractionScopePredicates(
        _ scope: MemoryScope,
        tableAlias: String = "",
        to predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        appendScopePredicates(scope, tableAlias: tableAlias, to: &predicates, arguments: &arguments)
    }

    static func memoryBodySnapshotJSON(
        memoryID: MemoryID,
        body: String,
        bodyHash: String,
        citations: [MemoryCitation],
        createdAt: Date,
        sourceKind: MemorySourceKind = .chat,
        context: String? = nil
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // schemaVersion 1 stays byte-identical for every chat snapshot (no
        // `context` key is emitted for nil); version 2 exists only when a
        // usage extraction supplies a context sentence.
        let payload = MemoryBodySnapshot(
            schemaVersion: context == nil ? 1 : 2,
            memoryID: memoryID,
            sourceKind: sourceKind,
            bodyHash: bodyHash,
            body: body,
            citations: citations,
            createdAt: createdAt,
            context: context
        )
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.ChatMemory", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Chat memory body snapshot could not be encoded as UTF-8."
            ])
        }
        return json
    }

    /// Decode the sealed snapshot for `id` on an existing connection.
    ///
    /// Body-only callers go through `openChatMemoryBody`; the reseal path needs
    /// the whole snapshot so an edit can carry the A-MEM `context` sentence
    /// forward. Resealing without it would drop the sentence and downgrade the
    /// snapshot from `schemaVersion` 2 back to 1.
    static func memoryBodySnapshot(db: Database, id: MemoryID) throws -> MemoryBodySnapshot? {
        guard let snapshotJSON = try String.fetchOne(
            db,
            sql: "SELECT snapshot_json FROM memory_body_snapshots WHERE id = ? AND memory_id = ?",
            arguments: [memorySnapshotSlug(id), id]
        ),
              let data = snapshotJSON.data(using: .utf8)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MemoryBodySnapshot.self, from: data)
    }

    static func memoryProvenanceID(memoryID: MemoryID, citationID: String) -> String {
        "\(memoryID)#\(citationID)"
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func memoryTokenEstimate(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    static func memoryTextScore(query: String, text: String) -> Double {
        let queryTerms = memoryTerms(query)
        guard queryTerms.isEmpty == false else { return 0 }
        let textTerms = memoryTerms(text)
        guard textTerms.isEmpty == false else { return 0 }
        let overlap = queryTerms.intersection(textTerms).count
        return Double(overlap) / Double(queryTerms.count)
    }

    private static func memoryTerms(_ text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .split { character in
                    character.isLetter == false && character.isNumber == false
                }
                .map(String.init)
        )
    }

    static func memory(from row: Row, citations: [MemoryCitation]) -> Memory? {
        guard let id: String = row["id"],
              let sourceKindRaw: String = row["source_kind"],
              let sourceKind = MemorySourceKind(rawValue: sourceKindRaw),
              let kindRaw: String = row["kind"],
              let kind = MemoryKind(rawValue: kindRaw),
              let confidence: Double = row["confidence"],
              let bodyRedacted: String = row["body_redacted"],
              let reviewStatusRaw: String = row["review_status"],
              let reviewStatus = MemoryReviewStatus(rawValue: reviewStatusRaw),
              let validFrom = OpenBurnBarDatabase.parseDateValue(row["valid_from"]),
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["created_at"]),
              let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updated_at"])
        else {
            return nil
        }
        let projectID: String? = sourceKind == .chat ? nil : row["project_id"]
        let scope = MemoryScope(
            userID: row["user_id"],
            agentID: row["agent_id"],
            runID: row["run_id"],
            appID: row["app_id"],
            projectID: projectID
        )
        return Memory(
            id: id,
            sourceKind: sourceKind,
            kind: kind,
            scope: scope,
            confidence: confidence,
            bodyRedacted: bodyRedacted,
            reviewStatus: reviewStatus,
            citations: citations,
            validFrom: validFrom,
            validTo: OpenBurnBarDatabase.parseDateValue(row["valid_to"]),
            supersededBy: row["superseded_by"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func memoryCitation(from row: Row) -> MemoryCitation? {
        guard let id: String = row["id"],
              let memoryID: String = row["memory_id"],
              let threadLogicalID: String = row["thread_logical_id"],
              let role: String = row["role"],
              let authoredAt = OpenBurnBarDatabase.parseDateValue(row["authored_at"]),
              let contentHash: String = row["content_hash"],
              let occurrence: Int = row["occurrence"],
              let crossDeviceHMAC: String = row["xdevice_hmac"],
              let citationStateRaw: String = row["citation_state"],
              let citationState = MemoryCitationState(rawValue: citationStateRaw)
        else {
            return nil
        }
        let publicCitationID = id.hasPrefix("\(memoryID)#") ? String(id.dropFirst(memoryID.count + 1)) : id
        return MemoryCitation(
            id: publicCitationID,
            threadLogicalID: threadLogicalID,
            messageID: row["message_id"],
            role: role,
            authoredAt: authoredAt,
            contentHash: contentHash,
            occurrence: occurrence,
            crossDeviceHMAC: crossDeviceHMAC,
            citationState: citationState
        )
    }

    static func appendScopePredicates(
        _ scope: MemoryScope,
        tableAlias: String = "",
        to predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        let prefix = tableAlias.isEmpty ? "" : "\(tableAlias)."
        appendNullableScopePredicate(column: "\(prefix)user_id", value: scope.userID, to: &predicates, arguments: &arguments)
        appendNullableScopePredicate(column: "\(prefix)agent_id", value: scope.agentID, to: &predicates, arguments: &arguments)
        appendNullableScopePredicate(column: "\(prefix)run_id", value: scope.runID, to: &predicates, arguments: &arguments)
        appendNullableScopePredicate(column: "\(prefix)app_id", value: scope.appID, to: &predicates, arguments: &arguments)
    }

    private static func appendNullableScopePredicate(
        column: String,
        value: String?,
        to predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        if let value {
            predicates.append("\(column) = ?")
            arguments.append(value)
        } else {
            predicates.append("\(column) IS NULL")
        }
    }

    static func chatMemoryDuplicateCandidates(
        db: Database,
        bodyHash: String,
        storageProjectID: String,
        kind: MemoryKind,
        scope: MemoryScope,
        excludingID: MemoryID
    ) throws -> [Row] {
        try memoryDuplicateCandidates(
            db: db,
            bodyHash: bodyHash,
            storageProjectID: storageProjectID,
            kind: kind,
            scope: scope,
            excludingID: excludingID,
            sourceKinds: [.chat]
        )
    }

    /// Exact-hash duplicate lookup within one storage partition. `sourceKinds`
    /// is a set so the two usage kinds dedup against each other (they share the
    /// `usage:` partition); chat passes `[.chat]` and behaves as before.
    static func memoryDuplicateCandidates(
        db: Database,
        bodyHash: String,
        storageProjectID: String,
        kind: MemoryKind,
        scope: MemoryScope,
        excludingID: MemoryID,
        sourceKinds: Set<MemorySourceKind>
    ) throws -> [Row] {
        let memoryKindClause = memorySourceKindInClause(column: "m.source_kind", kinds: sourceKinds)
        let snapshotKindClause = memorySourceKindInClause(column: "s.source_kind", kinds: sourceKinds)
        var predicates = [
            memoryKindClause.sql,
            "m.kind = ?",
            "m.project_id = ?",
            "m.id <> ?",
            "m.valid_to IS NULL",
            "s.body_hash = ?",
            snapshotKindClause.sql
        ]
        var arguments: [any DatabaseValueConvertible] = memoryKindClause.arguments
        arguments.append(contentsOf: [
            kind.rawValue,
            storageProjectID,
            excludingID,
            bodyHash
        ] as [any DatabaseValueConvertible])
        arguments.append(contentsOf: snapshotKindClause.arguments)
        appendScopePredicates(scope, tableAlias: "m", to: &predicates, arguments: &arguments)

        return try Row.fetchAll(
            db,
            sql: """
            SELECT m.*
            FROM agent_memories m
            JOIN memory_body_snapshots s
              ON s.memory_id = m.id
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY m.confidence DESC, m.valid_from ASC, m.id ASC
            """,
            arguments: StatementArguments(arguments)
        )
    }

    static func memoryDedupWinnerID(
        duplicateRows: [Row],
        newID: MemoryID,
        newConfidence: Double,
        newReviewStatus: MemoryReviewStatus,
        newValidFrom: Date
    ) -> MemoryID {
        var candidates: [(id: MemoryID, confidence: Double, reviewStatus: MemoryReviewStatus, validFrom: Date)] = duplicateRows.compactMap { row in
            guard let id: String = row["id"],
                  let confidence: Double = row["confidence"],
                  let reviewStatusRaw: String = row["review_status"],
                  let reviewStatus = MemoryReviewStatus(rawValue: reviewStatusRaw),
                  let validFrom = OpenBurnBarDatabase.parseDateValue(row["valid_from"])
            else {
                return nil
            }
            return (id, confidence, reviewStatus, validFrom)
        }
        candidates.append((newID, newConfidence, newReviewStatus, newValidFrom))
        return candidates.min { lhs, rhs in
            let lhsRank = memoryReviewDedupRank(lhs.reviewStatus)
            let rhsRank = memoryReviewDedupRank(rhs.reviewStatus)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.validFrom != rhs.validFrom { return lhs.validFrom < rhs.validFrom }
            return lhs.id < rhs.id
        }?.id ?? newID
    }

    private static func memoryReviewDedupRank(_ status: MemoryReviewStatus) -> Int {
        switch status {
        case .approved:
            return 0
        case .quarantined:
            return 1
        case .rejected:
            return 2
        case .forgotten:
            return 3
        }
    }

    static func mergeDuplicateChatMemories(
        db: Database,
        duplicateRows: [Row],
        newID: MemoryID,
        winnerID: MemoryID,
        storageProjectID: String,
        now: Date,
        nowString: String
    ) throws {
        try mergeDuplicateMemories(
            db: db,
            duplicateRows: duplicateRows,
            newID: newID,
            winnerID: winnerID,
            storageProjectID: storageProjectID,
            sourceKinds: [.chat],
            now: now,
            nowString: nowString
        )
    }

    /// Supersede exact-duplicate losers inside one partition. The audit
    /// `source_kind` label joins the sorted raw values of `sourceKinds` — for
    /// chat that is the shipped `chat` label byte-for-byte; a cross-kind usage
    /// merge is labeled `agent_session,safari_ask` deterministically.
    static func mergeDuplicateMemories(
        db: Database,
        duplicateRows: [Row],
        newID: MemoryID,
        winnerID: MemoryID,
        storageProjectID: String,
        sourceKinds: Set<MemorySourceKind>,
        now: Date,
        nowString: String
    ) throws {
        guard duplicateRows.isEmpty == false else { return }
        let duplicateIDs: [MemoryID] = duplicateRows.compactMap { row in row["id"] }
        let loserIDs = (duplicateIDs + [newID]).filter { $0 != winnerID }.uniqued()
        guard loserIDs.isEmpty == false else { return }

        let kindClause = memorySourceKindInClause(column: "source_kind", kinds: sourceKinds)
        let auditSourceKindLabel = sourceKinds.map(\.rawValue).sorted().joined(separator: ",")
        for loserID in loserIDs {
            var arguments: [any DatabaseValueConvertible] = [now, winnerID, now, loserID]
            arguments.append(contentsOf: kindClause.arguments)
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET valid_to = COALESCE(valid_to, ?),
                    superseded_by = ?,
                    updated_at = ?
                WHERE id = ?
                  AND \(kindClause.sql)
                """,
                arguments: StatementArguments(arguments)
            )
            try copyMemoryProvenance(db: db, from: loserID, to: winnerID, now: now)
            let auditLabels = [
                "reason:duplicate_body_hash",
                "source_kind:\(auditSourceKindLabel)",
                "winner_id:\(winnerID)"
            ]
            try insertMemoryAuditEvent(
                db: db,
                action: "memory.supersede",
                projectID: storageProjectID,
                subjectID: loserID,
                labels: auditLabels,
                nowString: nowString
            )
        }

        let mergeLabels = [
            "merged_ids:\(loserIDs.joined(separator: ","))",
            "reason:duplicate_body_hash",
            "source_kind:\(auditSourceKindLabel)",
            "winner_id:\(winnerID)"
        ]
        try insertMemoryAuditEvent(
            db: db,
            action: "memory.merge",
            projectID: storageProjectID,
            subjectID: winnerID,
            labels: mergeLabels,
            nowString: nowString
        )
    }

    private static func copyMemoryProvenance(
        db: Database,
        from loserID: MemoryID,
        to winnerID: MemoryID,
        now: Date
    ) throws {
        guard loserID != winnerID else { return }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT *
            FROM memory_provenance
            WHERE memory_id = ?
            ORDER BY authored_at ASC, occurrence ASC, id ASC
            """,
            arguments: [loserID]
        )
        for row in rows {
            guard let sourceID: String = row["id"],
                  let sourceKind: String = row["source_kind"],
                  let threadLogicalID: String = row["thread_logical_id"],
                  let role: String = row["role"],
                  let authoredAt = OpenBurnBarDatabase.parseDateValue(row["authored_at"]),
                  let contentHash: String = row["content_hash"],
                  let occurrence: Int = row["occurrence"],
                  let xdeviceHMAC: String = row["xdevice_hmac"],
                  let citationState: String = row["citation_state"]
            else {
                continue
            }
            let messageID: String? = row["message_id"]
            let existing = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_provenance
                WHERE memory_id = ?
                  AND xdevice_hmac = ?
                  AND occurrence = ?
                """,
                arguments: [winnerID, xdeviceHMAC, occurrence]
            ) ?? 0
            guard existing == 0 else { continue }

            let copyID = "dedup-\(winnerID)-\(sha256Hex("\(loserID)|\(sourceID)"))"
            try db.execute(
                sql: """
                INSERT INTO memory_provenance (
                    id, memory_id, source_kind, thread_logical_id, message_id, role,
                    authored_at, content_hash, occurrence, xdevice_hmac, citation_state, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    copyID,
                    winnerID,
                    sourceKind,
                    threadLogicalID,
                    messageID,
                    role,
                    authoredAt,
                    contentHash,
                    occurrence,
                    xdeviceHMAC,
                    citationState,
                    now
                ]
            )
        }
    }

    func appendMemoryAuditEvent(
        action: String,
        projectID: String,
        subjectID: String,
        labels: [String: String],
        now: Date
    ) async throws {
        let auditLabels = labels.map { "\($0.key):\($0.value)" }.sorted()
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            try Self.insertMemoryAuditEvent(
                db: db,
                action: action,
                projectID: projectID,
                subjectID: subjectID,
                labels: auditLabels,
                nowString: nowString
            )
        }
    }

    /// Emit a `memory.candidate_dropped` audit event for a G7-rejected extraction candidate.
    ///
    /// Called by `MemoryExtractionWorker` when the G7 gate rejects a candidate. Labels carry
    /// only stable, non-sensitive identifiers — NEVER the secret text or the candidate body.
    /// The `findingLabels` must be the finding IDs/labels (e.g. `openai-api-key`) joined with
    /// commas; the raw candidate text MUST NOT appear in any label.
    func appendMemoryCandidateDroppedAuditEvent(
        projectID: String,
        memoryID: String,
        sourceKind: String,
        findingLabels: String,
        candidateIndex: Int,
        now: Date
    ) async throws {
        try await appendMemoryAuditEvent(
            action: "memory.candidate_dropped",
            projectID: projectID,
            subjectID: memoryID,
            labels: [
                "candidate_index": String(candidateIndex),
                "finding_labels": findingLabels,
                "memory_id": memoryID,
                "source_kind": sourceKind
            ],
            now: now
        )
    }

}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
