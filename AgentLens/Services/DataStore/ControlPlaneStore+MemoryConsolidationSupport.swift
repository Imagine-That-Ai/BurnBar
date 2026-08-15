import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - Stage-2 consolidation store helpers (PR7)
//
// The write-time consolidation primitives the Stage-2 usage write path uses:
// corroboration bumps on the `memory_salience` sidecar, idempotent typed edges
// in `memory_links`, the cross-source exact-hash probe into the chat
// partition, and the partition-scoped wrapper over the G2 embedding matcher.
// The v61 sidecar tables have exactly one writer lane (the extraction worker
// via these helpers), which is what keeps the mirrored `agent_memories` DDL
// untouched.

extension ControlPlaneStore {
    /// Typed `memory_links.link_kind` vocabulary (mirrors the v61 DDL comment:
    /// near_duplicate | contradicts | supports | promoted_from). Stage-2 writes
    /// only `near_duplicate`; the rest belong to Stage-3 consolidation.
    enum MemoryLinkKind: String, Sendable {
        case nearDuplicate = "near_duplicate"
        case contradicts
        case supports
        case promotedFrom = "promoted_from"
    }

    /// Corroboration bump: the same durable fact was independently observed
    /// again, so strengthen the winner instead of forking a twin row.
    ///
    /// Upsert semantics: an existing sidecar row gets `corroboration + 1` and a
    /// refreshed `last_reinforced_at`; an ABSENT row (the winner predates PR7,
    /// or is a chat row — chat inserts never seed salience) is created at
    /// corroboration 2 = the base observation (1) plus this one. The seed
    /// salience/trust arguments are used ONLY on that insert path; an existing
    /// row's salience and trust are never rewritten by a bump.
    func bumpMemoryCorroboration(
        id: MemoryID,
        seedSalience: Double,
        seedSourceTrust: Double,
        now: Date = Date()
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_salience (
                    memory_id, salience, hit_count, last_reinforced_at,
                    corroboration, source_trust, computed_at, updated_at
                ) VALUES (?, ?, 0, ?, 2, ?, ?, ?)
                ON CONFLICT(memory_id) DO UPDATE SET
                    corroboration = memory_salience.corroboration + 1,
                    last_reinforced_at = excluded.last_reinforced_at,
                    updated_at = excluded.updated_at
                """,
                arguments: [id, seedSalience, now, seedSourceTrust, now, now]
            )
        }
    }

    /// Seed the salience sidecar row for a freshly inserted memory:
    /// {salience: Stage-0 hint, hit_count 0, corroboration 1, source trust
    /// from policy}. `ON CONFLICT DO NOTHING` — a replay (deterministic memory
    /// ids) must never reset corroboration/hits a live row has accumulated.
    func seedMemorySalience(
        memoryID: MemoryID,
        salience: Double,
        sourceTrust: Double,
        now: Date = Date()
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_salience (
                    memory_id, salience, hit_count, last_reinforced_at,
                    corroboration, source_trust, computed_at, updated_at
                ) VALUES (?, ?, 0, NULL, 1, ?, ?, ?)
                ON CONFLICT(memory_id) DO NOTHING
                """,
                arguments: [memoryID, salience, sourceTrust, now, now]
            )
        }
    }

    /// Insert one typed edge into `memory_links`. Idempotent by construction:
    /// `id = sha256(from|to|kind)`, so a replayed Stage-2 pass collapses onto
    /// the existing row (`ON CONFLICT DO NOTHING` keeps the first score).
    ///
    /// NOTE: `memory_links` is deliberately FK-free (v61). Stage-2's
    /// corroboration path records `from` = the DETERMINISTIC id of the
    /// suppressed extraction ("memory-<job>-<index>") that was folded into
    /// `to` — that id never materializes as an `agent_memories` row, but it is
    /// the durable trace of WHICH extraction corroborated the winner.
    func insertMemoryLink(
        from fromMemoryID: MemoryID,
        to toMemoryID: MemoryID,
        kind: MemoryLinkKind,
        score: Double,
        createdBy: String,
        now: Date = Date()
    ) async throws {
        let id = Self.sha256Hex("\(fromMemoryID)|\(toMemoryID)|\(kind.rawValue)")
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_links (
                    id, from_memory_id, to_memory_id, link_kind, score, created_by, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [id, fromMemoryID, toMemoryID, kind.rawValue, score, createdBy, now]
            )
        }
    }

    /// Cross-source corroboration probe: a LIVE chat-partition memory whose
    /// sealed snapshot has exactly this body hash, within the same scope.
    /// Cheap SQL (no vectors) because byte-identical bodies need no semantics.
    /// Deterministic winner: the same ordering `memoryDuplicateCandidates`
    /// uses (confidence DESC, oldest first, id ASC).
    func chatPartitionBodyHashMatch(
        bodyHash: String,
        scope: MemoryScope
    ) async throws -> MemoryID? {
        let projectID = Self.memoryStorageProjectID(for: scope, partition: .chat)
        return try await dbQueue.read { db in
            var predicates = [
                "m.source_kind = ?",
                "m.project_id = ?",
                "m.valid_to IS NULL",
                "s.body_hash = ?",
                "s.source_kind = ?"
            ]
            var arguments: [any DatabaseValueConvertible] = [
                MemorySourceKind.chat.rawValue,
                projectID,
                bodyHash,
                MemorySourceKind.chat.rawValue
            ]
            Self.appendScopePredicates(scope, tableAlias: "m", to: &predicates, arguments: &arguments)
            return try String.fetchOne(
                db,
                sql: """
                SELECT m.id
                FROM agent_memories m
                JOIN memory_body_snapshots s
                  ON s.memory_id = m.id
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY m.confidence DESC, m.valid_from ASC, m.id ASC
                LIMIT 1
                """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Best embedding match within the USAGE partition: the G2 matcher scores
    /// every ref under this version (Stage-2 is the only production writer of
    /// refs, but the guard must not depend on that), then the candidates are
    /// filtered to LIVE usage-kind rows — a superseded row keeps its ref yet
    /// must never win a novelty check (corroborating a dead row would strand
    /// the signal). Returns the highest-scoring survivor.
    func usageMemoryEmbeddingBestMatch(
        queryVector: [Float],
        embeddingVersionID: String,
        dimension: Int,
        limit: Int = 20
    ) async throws -> MemoryEmbeddingMatch? {
        let matches = try await memoryEmbeddingMatches(
            queryVector: queryVector,
            embeddingVersionID: embeddingVersionID,
            dimension: dimension,
            limit: limit
        )
        guard matches.isEmpty == false else { return nil }
        let liveUsageIDs = try await liveUsageMemoryIDs(among: matches.map(\.memoryID))
        return matches.first { liveUsageIDs.contains($0.memoryID) }
    }

    /// The subset of `ids` that are live (`valid_to IS NULL`) usage-partition
    /// authority rows.
    private func liveUsageMemoryIDs(among ids: [MemoryID]) async throws -> Set<MemoryID> {
        guard ids.isEmpty == false else { return [] }
        let kindClause = Self.memorySourceKindInClause(
            column: "source_kind",
            kinds: MemorySourceKind.usageKinds
        )
        let idPlaceholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try await dbQueue.read { db in
            var arguments: [any DatabaseValueConvertible] = ids
            arguments.append(contentsOf: kindClause.arguments)
            let rows = try String.fetchAll(
                db,
                sql: """
                SELECT id
                FROM agent_memories
                WHERE id IN (\(idPlaceholders))
                  AND \(kindClause.sql)
                  AND valid_to IS NULL
                """,
                arguments: StatementArguments(arguments)
            )
            return Set(rows)
        }
    }
}
