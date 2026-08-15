import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - Stage-3 consolidation passes (PR8 + PR9 store primitives)
//
// The pure-SQL/Swift-math consolidation primitives `MemoryConsolidationWorker`
// runs on the sleep-time cadence: salience decay recompute, reinforce-on-use,
// decay/cap eviction of quarantined usage rows, and orphan repair/GC over the
// v61 sidecar tables. Everything in this file is deterministic and LLM-free —
// PR9's promote/self-heal passes make their bounded LLM calls in the WORKER
// and come back here only for reads (`consolidatableUsageMemories`,
// `memoryLinkExists`) and deterministic writes (`supersedeUsageMemory`).

extension ControlPlaneStore {
    /// Recall's salience contribution weight: `+ 0.3 · clamp(salience, 0, 1)`
    /// on top of the pre-PR8 `textScore + confidence` ranking. An ABSENT
    /// sidecar row contributes exactly 0.0, so a database with no salience
    /// rows ranks byte-identically to the pre-PR8 formula (regression-pinned
    /// by `UsageMemoryConsolidationTests`).
    static let memorySalienceRecallWeight = 0.3

    /// One eviction sweep's outcome, split by cause.
    struct UsageMemoryEvictionReport: Equatable, Sendable {
        /// Quarantined usage rows that decayed below `thresholds.evict`.
        var decayed = 0
        /// Quarantined usage rows evicted to enforce `caps.maxUsageMemories`.
        var overCap = 0
        var total: Int { decayed + overCap }
    }

    // MARK: - Decay recompute

    /// Recompute `memory_salience.salience` for rows whose `computed_at` is
    /// older than 24 h (bounded by `limit` per pass; the cadence catches the
    /// rest next tick):
    ///
    ///     salience = w.recency       · exp(-ageDays / halfLifeDays)
    ///              + w.hits          · log1p(hit_count) / log(101)
    ///              + w.sourceTrust   · source_trust
    ///              + w.corroboration · min(corroboration, 5) / 5
    ///
    /// where `ageDays` counts from `max(last_reinforced_at, valid_from)` —
    /// a reinforced memory is "fresh as of its last use", never older. The
    /// hits term saturates at 1.0 by hit 100 (`log1p(100) == log(101)`).
    /// Pure SQL fetch + Swift math + batched UPDATE in ONE write transaction.
    /// Sidecar rows whose authority row is gone are skipped here (the JOIN
    /// drops them); `purgeOrphanConsolidationRows` deletes them.
    /// Returns the number of rows recomputed.
    @discardableResult
    func recomputeMemorySalience(
        policy: UsageMemoryCurationPolicy,
        now: Date = Date(),
        limit: Int = 500
    ) async throws -> Int {
        guard limit > 0 else { return 0 }
        let staleCutoff = now.addingTimeInterval(-24 * 3600)
        let weights = policy.decay
        let halfLife = max(weights.recencyHalfLifeDays, 0.0001)
        return try await dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT s.memory_id AS memory_id,
                       s.hit_count AS hit_count,
                       s.last_reinforced_at AS last_reinforced_at,
                       s.corroboration AS corroboration,
                       s.source_trust AS source_trust,
                       m.valid_from AS valid_from
                FROM memory_salience s
                JOIN agent_memories m ON m.id = s.memory_id
                WHERE s.computed_at < ?
                ORDER BY s.computed_at ASC, s.memory_id ASC
                LIMIT ?
                """,
                arguments: [staleCutoff, limit]
            )
            var recomputed = 0
            for row in rows {
                guard let memoryID: String = row["memory_id"],
                      let hitCount: Int = row["hit_count"],
                      let corroboration: Int = row["corroboration"],
                      let sourceTrust: Double = row["source_trust"],
                      let validFrom: Date = row["valid_from"] else {
                    continue
                }
                let lastReinforcedAt: Date? = row["last_reinforced_at"]
                let freshnessAnchor = max(lastReinforcedAt ?? .distantPast, validFrom)
                let ageDays = max(0, now.timeIntervalSince(freshnessAnchor)) / 86_400
                let salience = weights.recency * exp(-ageDays / halfLife)
                    + weights.hits * log1p(Double(max(0, hitCount))) / log(101.0)
                    + weights.sourceTrust * sourceTrust
                    + weights.corroboration * Double(min(max(corroboration, 0), 5)) / 5.0
                try db.execute(
                    sql: """
                    UPDATE memory_salience
                    SET salience = ?, computed_at = ?, updated_at = ?
                    WHERE memory_id = ?
                    """,
                    arguments: [salience, now, now, memoryID]
                )
                recomputed += 1
            }
            return recomputed
        }
    }

    // MARK: - Reinforce-on-use

    /// Record that these memories were actually injected into a committed
    /// turn's prompt: `hit_count + 1`, `last_reinforced_at = now` — the decay
    /// recompute turns those into staying power. Uniform over chat AND usage
    /// ids: usage rows already carry their Stage-2 seed, while chat rows are
    /// seeded LAZILY here (salience 0 = no recall boost until the next
    /// recompute scores them; source trust 1.0 = the policy's chat trust —
    /// chat rows are the only ones that reach this without a seed). The seed
    /// is `INSERT OR IGNORE`, so an existing row's salience/corroboration/
    /// trust are never rewritten by a reinforcement.
    func reinforceMemories(ids: [MemoryID], now: Date = Date()) async throws {
        guard ids.isEmpty == false else { return }
        try await dbQueue.write { db in
            for id in ids {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO memory_salience (
                        memory_id, salience, hit_count, last_reinforced_at,
                        corroboration, source_trust, computed_at, updated_at
                    ) VALUES (?, 0, 0, NULL, 1, 1.0, ?, ?)
                    """,
                    arguments: [id, now, now]
                )
                try db.execute(
                    sql: """
                    UPDATE memory_salience
                    SET hit_count = hit_count + 1,
                        last_reinforced_at = ?,
                        updated_at = ?
                    WHERE memory_id = ?
                    """,
                    arguments: [now, now, id]
                )
            }
        }
    }

    /// Salience values keyed by memory id for recall ranking — the batched
    /// equivalent of a `LEFT JOIN memory_salience` on the recall query (the
    /// recall path scores in Swift, so the join surfaces as a map lookup).
    /// Ids absent from the map get NO contribution.
    func memorySalienceValues(ids: [MemoryID]) async throws -> [MemoryID: Double] {
        guard ids.isEmpty == false else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT memory_id, salience
                FROM memory_salience
                WHERE memory_id IN (\(placeholders))
                """,
                arguments: StatementArguments(ids)
            )
            var values: [MemoryID: Double] = [:]
            values.reserveCapacity(rows.count)
            for row in rows {
                guard let id: String = row["memory_id"], let salience: Double = row["salience"] else {
                    continue
                }
                values[id] = salience
            }
            return values
        }
    }

    // MARK: - Eviction

    /// Evict decayed usage memories, then enforce the usage-partition cap.
    ///
    /// Decay pass — a usage-kind row is evicted only when ALL of:
    ///   * `review_status` quarantined,
    ///   * salience below `thresholds.evict`,
    ///   * never recalled (`hit_count == 0`),
    ///   * older than `caps.quarantineEvictDays`.
    ///
    /// Cap pass — while the usage-kind row count exceeds
    /// `caps.maxUsageMemories`, the lowest-salience quarantined rows go first
    /// (rows without a sidecar count as salience 0).
    ///
    /// APPROVED ROWS ARE EXEMPT FROM ALL AUTO-EVICTION IN V1: both passes
    /// select `review_status = 'quarantined'` only, so the cap can stay
    /// exceeded rather than touch an approved row (the fact-tombstone path in
    /// `deleteMemoryAuthorityRecord` would fire automatically if that v1
    /// invariant were ever relaxed). Every eviction rides
    /// `deleteMemoryAuthorityRecord(sourceKinds: usageKinds)`, so audits and
    /// sidecar/snapshot/provenance cleanup are the delete path's.
    @discardableResult
    func evictDecayedUsageMemories(
        policy: UsageMemoryCurationPolicy,
        now: Date = Date()
    ) async throws -> UsageMemoryEvictionReport {
        var report = UsageMemoryEvictionReport()
        let usageKinds = MemorySourceKind.usageKinds
        let kindClause = Self.memorySourceKindInClause(column: "m.source_kind", kinds: usageKinds)
        let quarantineCutoff = now.addingTimeInterval(
            -Double(max(0, policy.caps.quarantineEvictDays)) * 86_400
        )

        let decayedIDs = try await dbQueue.read { db in
            var arguments: [any DatabaseValueConvertible] = kindClause.arguments
            arguments.append(MemoryReviewStatus.quarantined.rawValue)
            arguments.append(policy.thresholds.evict)
            arguments.append(quarantineCutoff)
            return try String.fetchAll(
                db,
                sql: """
                SELECT m.id
                FROM agent_memories m
                JOIN memory_salience s ON s.memory_id = m.id
                WHERE \(kindClause.sql)
                  AND m.review_status = ?
                  AND s.salience < ?
                  AND s.hit_count = 0
                  AND m.created_at < ?
                ORDER BY s.salience ASC, m.created_at ASC, m.id ASC
                """,
                arguments: StatementArguments(arguments)
            )
        }
        for id in decayedIDs where try await deleteMemoryAuthorityRecord(
            id: id,
            sourceKinds: usageKinds,
            now: now
        ) {
            report.decayed += 1
        }

        let usageCount = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_memories m WHERE \(kindClause.sql)",
                arguments: StatementArguments(kindClause.arguments)
            ) ?? 0
        }
        let overflow = usageCount - max(0, policy.caps.maxUsageMemories)
        if overflow > 0 {
            let victimIDs = try await dbQueue.read { db in
                var arguments: [any DatabaseValueConvertible] = kindClause.arguments
                arguments.append(MemoryReviewStatus.quarantined.rawValue)
                arguments.append(overflow)
                return try String.fetchAll(
                    db,
                    sql: """
                    SELECT m.id
                    FROM agent_memories m
                    LEFT JOIN memory_salience s ON s.memory_id = m.id
                    WHERE \(kindClause.sql)
                      AND m.review_status = ?
                    ORDER BY COALESCE(s.salience, 0.0) ASC, m.created_at ASC, m.id ASC
                    LIMIT ?
                    """,
                    arguments: StatementArguments(arguments)
                )
            }
            for id in victimIDs where try await deleteMemoryAuthorityRecord(
                id: id,
                sourceKinds: usageKinds,
                now: now
            ) {
                report.overCap += 1
            }
        }
        return report
    }

    // MARK: - Orphan repair / GC

    /// Delete sidecar rows whose authority rows no longer exist:
    /// `memory_salience` and `memory_embedding_refs` rows keyed to missing
    /// memory ids, `memory_links` whose `to` end is gone, and `memory_links`
    /// whose `from` end is gone AND is not a legitimate synthetic id.
    ///
    /// The synthetic exception, documented: Stage-2's corroboration path
    /// records `from` = the deterministic `memory-<job>-<index>` id of a
    /// SUPPRESSED extraction — an id that never materializes as an
    /// `agent_memories` row yet is the durable trace of which extraction
    /// corroborated the winner. A dangling `from` matching that shape is
    /// therefore kept — but ONLY while its `to` end still exists (the `to`
    /// sweep above runs first, so a trace whose winner died is purged).
    /// Real worker-minted ids share the shape; that is harmless here because
    /// an EXISTING `from` is never a purge candidate, and a deleted one's
    /// links were already removed by `deleteMemoryAuthorityRecord`.
    /// Returns the total number of rows purged.
    @discardableResult
    func purgeOrphanConsolidationRows() async throws -> Int {
        try await dbQueue.write { db in
            var purged = 0
            try db.execute(
                sql: """
                DELETE FROM memory_salience
                WHERE memory_id NOT IN (SELECT id FROM agent_memories)
                """
            )
            purged += db.changesCount
            try db.execute(
                sql: """
                DELETE FROM memory_embedding_refs
                WHERE memory_id NOT IN (SELECT id FROM agent_memories)
                """
            )
            purged += db.changesCount
            try db.execute(
                sql: """
                DELETE FROM memory_links
                WHERE to_memory_id NOT IN (SELECT id FROM agent_memories)
                """
            )
            purged += db.changesCount
            let danglingFromRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, from_memory_id
                FROM memory_links
                WHERE from_memory_id NOT IN (SELECT id FROM agent_memories)
                """
            )
            for row in danglingFromRows {
                guard let linkID: String = row["id"], let fromID: String = row["from_memory_id"] else {
                    continue
                }
                guard Self.isSyntheticExtractionMemoryID(fromID) == false else { continue }
                try db.execute(sql: "DELETE FROM memory_links WHERE id = ?", arguments: [linkID])
                purged += 1
            }
            return purged
        }
    }

    // MARK: - PR9: promote / self-heal store primitives

    /// One live usage-partition memory as the Stage-3 LLM passes see it:
    /// authority identity + plaintext body (opened from the sealed snapshot)
    /// + salience + embedding vector + the `"k:"`-prefixed retrieval keywords
    /// from `tags_json` (lowercased for overlap checks).
    struct ConsolidatableUsageMemory: Sendable {
        let id: MemoryID
        let sourceKind: MemorySourceKind
        let body: String
        let salience: Double
        let vector: [Float]
        let keywords: Set<String>
        let validFrom: Date
    }

    /// Fetch the LIVE usage-partition rows that carry an embedding ref under
    /// `embeddingVersionID` — the promote pass's clustering space
    /// (`quarantinedOnly: true`) and the self-heal pass's pair space
    /// (`quarantinedOnly: false`). Ordered salience DESC (id ASC tiebreak) so
    /// greedy clustering seeds deterministically; bounded by `limit` per tick.
    /// Rows whose snapshot or vector cannot be decoded are skipped.
    func consolidatableUsageMemories(
        embeddingVersionID: String,
        dimension: Int,
        quarantinedOnly: Bool,
        limit: Int = 200
    ) async throws -> [ConsolidatableUsageMemory] {
        let kindClause = Self.memorySourceKindInClause(
            column: "m.source_kind",
            kinds: MemorySourceKind.usageKinds
        )
        return try await dbQueue.read { db in
            var predicates = [kindClause.sql, "m.valid_to IS NULL"]
            var arguments: [any DatabaseValueConvertible] = kindClause.arguments
            if quarantinedOnly {
                predicates.append("m.review_status = ?")
                arguments.append(MemoryReviewStatus.quarantined.rawValue)
            }
            arguments.append(embeddingVersionID)
            arguments.append(dimension)
            arguments.append(max(1, limit))
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.id AS id,
                       m.source_kind AS source_kind,
                       m.valid_from AS valid_from,
                       m.tags_json AS tags_json,
                       COALESCE(s.salience, 0.0) AS salience,
                       r.vector AS vector,
                       snap.snapshot_json AS snapshot_json
                FROM agent_memories m
                JOIN memory_embedding_refs r
                  ON r.memory_id = m.id
                LEFT JOIN memory_salience s
                  ON s.memory_id = m.id
                JOIN memory_body_snapshots snap
                  ON snap.memory_id = m.id
                WHERE \(predicates.joined(separator: " AND "))
                  AND r.embedding_version_id = ?
                  AND r.dimension = ?
                ORDER BY COALESCE(s.salience, 0.0) DESC, m.id ASC
                LIMIT ?
                """,
                arguments: StatementArguments(arguments)
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return rows.compactMap { row -> ConsolidatableUsageMemory? in
                guard let id: String = row["id"],
                      let sourceKindRaw: String = row["source_kind"],
                      let sourceKind = MemorySourceKind(rawValue: sourceKindRaw),
                      let validFrom = OpenBurnBarDatabase.parseDateValue(row["valid_from"]),
                      let salience: Double = row["salience"],
                      let vectorData: Data = row["vector"],
                      let vector = BurnBarVectorBlobCodec.decode(vectorData),
                      vector.count == dimension,
                      let snapshotJSON: String = row["snapshot_json"],
                      let snapshot = try? decoder.decode( // try?-ok(undecodable snapshot row is skipped, never wedges the pass)
                          MemoryBodySnapshot.self,
                          from: Data(snapshotJSON.utf8)
                      )
                else {
                    return nil
                }
                return ConsolidatableUsageMemory(
                    id: id,
                    sourceKind: sourceKind,
                    body: snapshot.body,
                    salience: salience,
                    vector: vector,
                    keywords: Self.memoryKeywords(fromTagsJSON: row["tags_json"]),
                    validFrom: validFrom
                )
            }
        }
    }

    /// The lowercased `"k:"`-prefixed keyword vocabulary of one
    /// `agent_memories.tags_json` value (see `memoryTagsJSON` for the
    /// encoding). Malformed JSON yields the empty set.
    static func memoryKeywords(fromTagsJSON tagsJSON: String?) -> Set<String> {
        guard let tagsJSON,
              let entries = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8)) // try?-ok(malformed tags row contributes no keywords)
        else {
            return []
        }
        return Set(
            entries.compactMap { entry -> String? in
                guard entry.hasPrefix("k:") else { return nil }
                let keyword = entry.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                return keyword.isEmpty ? nil : keyword.lowercased()
            }
        )
    }

    /// Whether ANY link of the given kinds exists between `a` and `b` in
    /// EITHER direction — the self-heal pass's "already asked / already
    /// decided" check (near_duplicate, contradicts, or the `unrelated`
    /// marker).
    func memoryLinkExists(
        between a: MemoryID,
        and b: MemoryID,
        kinds: [MemoryLinkKind]
    ) async throws -> Bool {
        guard kinds.isEmpty == false else { return false }
        let kindPlaceholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
        let arguments: [any DatabaseValueConvertible] = [a, b, b, a] + kinds.map { $0.rawValue as any DatabaseValueConvertible }
        return try await dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_links
                WHERE ((from_memory_id = ? AND to_memory_id = ?)
                    OR (from_memory_id = ? AND to_memory_id = ?))
                  AND link_kind IN (\(kindPlaceholders))
                """,
                arguments: StatementArguments(arguments)
            ) ?? 0
            return count > 0
        }
    }

    /// Supersede one usage-partition row in favor of `winnerID` — the PR9
    /// promote/self-heal supersede primitive, one write transaction:
    ///   * `valid_to = COALESCE(valid_to, now)` + `superseded_by = winnerID`
    ///     (the existing dedup machinery's exact column semantics);
    ///   * provenance union-copied onto the winner (dedup by hmac+occurrence
    ///     via `copyMemoryProvenance` — the promote pass's citation union);
    ///   * a `memory.supersede` audit event with the caller's reason label
    ///     (`promoted` / `duplicate` / `contradiction`), ids only.
    /// Returns false (and writes nothing) when the loser is missing, already
    /// superseded, or outside the usage partition.
    @discardableResult
    func supersedeUsageMemory(
        loserID: MemoryID,
        winnerID: MemoryID,
        reason: String,
        projectID: String,
        now: Date = Date()
    ) async throws -> Bool {
        guard loserID != winnerID else { return false }
        let kindClause = Self.memorySourceKindInClause(
            column: "source_kind",
            kinds: MemorySourceKind.usageKinds
        )
        let auditSourceKindLabel = MemorySourceKind.usageKinds.map(\.rawValue).sorted().joined(separator: ",")
        let nowString = Self.iso8601String(now)
        return try await dbQueue.write { db in
            var arguments: [any DatabaseValueConvertible] = [now, winnerID, now, loserID]
            arguments.append(contentsOf: kindClause.arguments)
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET valid_to = COALESCE(valid_to, ?),
                    superseded_by = ?,
                    updated_at = ?
                WHERE id = ?
                  AND valid_to IS NULL
                  AND \(kindClause.sql)
                """,
                arguments: StatementArguments(arguments)
            )
            guard db.changesCount > 0 else { return false }
            try Self.copyMemoryProvenance(db: db, from: loserID, to: winnerID, now: now)
            try Self.insertMemoryAuditEvent(
                db: db,
                action: "memory.supersede",
                projectID: projectID,
                subjectID: loserID,
                labels: [
                    "reason:\(reason)",
                    "source_kind:\(auditSourceKindLabel)",
                    "winner_id:\(winnerID)"
                ],
                nowString: nowString
            )
            return true
        }
    }

    /// Whether `id` has the extraction worker's deterministic
    /// `memory-<job>-<index>` shape (see `purgeOrphanConsolidationRows`).
    static func isSyntheticExtractionMemoryID(_ id: MemoryID) -> Bool {
        let prefix = "memory-"
        guard id.hasPrefix(prefix), let lastDash = id.lastIndex(of: "-") else { return false }
        guard id.index(id.startIndex, offsetBy: prefix.count) <= lastDash else { return false }
        let indexPart = id[id.index(after: lastDash)...]
        return indexPart.isEmpty == false && indexPart.allSatisfy(\.isNumber)
    }
}
