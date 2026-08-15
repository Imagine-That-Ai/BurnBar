import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - Usage Memory Candidate Spool (PR4)

/// One Stage-0-accepted event bound for the `memory_usage_candidates` spool.
///
/// Mirrors the v61 columns the session miner writes. `status` (always
/// `'pending'` on insert) and `batch_job_id` are lifecycle columns owned by
/// later funnel stages, so they are not part of this value.
struct UsageMemoryCandidate: Equatable, Sendable {
    var id: String
    var sourceKind: MemorySourceKind
    var sourceRef: String
    var threadLogicalID: String
    var payloadJSON: String
    var contentHash: String
    var simhash: Int64
    var salienceHint: Double

    /// sha256 hex of the gated text — the content component of the spool id.
    static func contentHash(ofText text: String) -> String {
        sha256Hex(text)
    }

    /// Content-derived spool id, `sha256(source_ref|content_hash)` per the
    /// v61 contract, so re-mining the same event is a no-op insert.
    static func spoolID(sourceRef: String, contentHash: String) -> String {
        sha256Hex("\(sourceRef)|\(contentHash)")
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The `payload_json` body of one spool row: ONLY the gated text plus
/// role/thread/time metadata — never raw line content. Shared by the writers
/// (the PR4 session miner, PR5's Safari intake) and the Stage-1 readers (the
/// prompt builder and the worker's provenance recompute), so both sides agree
/// on one shape. Encoding is pinned (sortedKeys, no escaped slashes, ISO-8601
/// dates) because the spool id is content-derived and replays must collapse.
struct UsageMemoryCandidatePayload: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var text: String
    var role: String
    var threadLogicalID: String
    var observedAt: Date

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decode(_ json: String) -> UsageMemoryCandidatePayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageMemoryCandidatePayload.self, from: Data(json.utf8)) // try?-ok(malformed payload row yields nil; callers degrade)
    }
}

extension ControlPlaneStore {
    /// `controller_runtime_cache` key holding the session miner's JSON cursor
    /// map. The plan named an `app_state` table for this row, but on macOS no
    /// such table exists in the live GRDB migrator (`app_state` is a
    /// Windows-only extra table per `budgets/migrator-parity-baseline.json`);
    /// `controller_runtime_cache` is the existing generic key/value surface,
    /// so the cursor rides it with the planned key unchanged.
    static let usageSessionMinerCursorKey = "usage_memory.session_miner.cursor.v1"

    /// Inserts Stage-0 candidates and upserts the miner cursor row in ONE
    /// write transaction. Candidate ids are content-derived, so replayed
    /// events collapse via `ON CONFLICT(id) DO NOTHING`; committing the
    /// cursor with the candidates means a crash can never persist a cursor
    /// that covers unpersisted candidates. Returns the number of rows
    /// actually inserted (post-dedup).
    @discardableResult
    func insertUsageMemoryCandidates(
        _ candidates: [UsageMemoryCandidate],
        cursorKey: String?,
        cursorJSON: String?,
        now: Date = Date()
    ) async throws -> Int {
        try await dbQueue.write { db in
            var inserted = 0
            for candidate in candidates {
                try db.execute(
                    sql: """
                    INSERT INTO memory_usage_candidates (
                        id, source_kind, source_ref, thread_logical_id, payload_json,
                        content_hash, simhash, salience_hint, status, batch_job_id,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', NULL, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                    arguments: [
                        candidate.id,
                        candidate.sourceKind.rawValue,
                        candidate.sourceRef,
                        candidate.threadLogicalID,
                        candidate.payloadJSON,
                        candidate.contentHash,
                        candidate.simhash,
                        candidate.salienceHint,
                        now,
                        now
                    ]
                )
                inserted += db.changesCount
            }
            if let cursorKey, let cursorJSON {
                try db.execute(
                    sql: """
                    INSERT INTO controller_runtime_cache (cacheKey, payloadJSON, updatedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(cacheKey) DO UPDATE SET
                        payloadJSON = excluded.payloadJSON,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [cursorKey, cursorJSON, now]
                )
            }
            return inserted
        }
    }

    /// Prior sightings of a SimHash bucket for one source kind since `since`
    /// — the gate's `repetitionCount` input. Served by
    /// `memory_usage_candidates_simhash_idx` (source_kind, simhash).
    func usageCandidateRepetitionCount(
        sourceKind: MemorySourceKind,
        simhash: Int64,
        since: Date
    ) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_usage_candidates
                WHERE source_kind = ? AND simhash = ? AND created_at >= ?
                """,
                arguments: [sourceKind.rawValue, simhash, since]
            ) ?? 0
        }
    }

    /// Candidates waiting for Stage-1 batching.
    func pendingUsageCandidateCount() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_usage_candidates WHERE status = 'pending'"
            ) ?? 0
        }
    }

    /// TTL sweep: pending candidates older than `ttlDays` (from
    /// `UsageMemoryCurationPolicy.caps.candidateTTLDays`) flip to `expired`,
    /// then every expired row is deleted. Returns the number of rows deleted.
    @discardableResult
    func expireUsageCandidates(olderThan ttlDays: Int, now: Date = Date()) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(max(0, ttlDays)) * 86_400)
        return try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE memory_usage_candidates
                SET status = 'expired', updated_at = ?
                WHERE status = 'pending' AND created_at < ?
                """,
                arguments: [now, cutoff]
            )
            try db.execute(sql: "DELETE FROM memory_usage_candidates WHERE status = 'expired'")
            return db.changesCount
        }
    }

    /// The miner's persisted cursor map JSON, or nil before the first mine.
    func usageSessionMinerCursorJSON() async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payloadJSON FROM controller_runtime_cache WHERE cacheKey = ?",
                arguments: [Self.usageSessionMinerCursorKey]
            )
        }
    }

    // MARK: - Stage-1 batch assembly (PR6)

    /// One assembled batch: the enqueued job id plus the candidate rows it
    /// covers (already stamped `batched` in the same transaction).
    struct UsageExtractionBatch: Equatable, Sendable {
        let jobID: String
        let sourceKind: MemorySourceKind
        let candidates: [UsageMemoryCandidate]
    }

    /// Assemble at most one Stage-1 batch job PER usage source kind (bounded by
    /// `policy.maxJobsPerTick` overall) from the pending spool, atomically:
    /// the job INSERT and the `{status: batched, batch_job_id}` candidate stamp
    /// commit in ONE write transaction per tick.
    ///
    /// Batch rule (per kind): take the TOP-SALIENCE pending candidates up to
    /// `policy.maxBatch`. A batch forms when either
    ///   * at least `policy.minBatch` pending candidates exist, OR
    ///   * ANY pending candidate is older than `policy.staleBatchAge`
    ///     (then whatever exists — >= 1 — batches, so a trickle is never
    ///     stranded).
    /// Kinds are NEVER mixed in one batch (provenance clarity): a batch job's
    /// `source_kind` is the kind of every candidate in it.
    func assembleUsageExtractionBatch(
        policy: UsageMemoryExtractionPolicy = .default,
        promptVersion: String,
        scope: MemoryScope,
        now: Date = Date()
    ) async throws -> [UsageExtractionBatch] {
        let maxJobs = max(0, policy.maxJobsPerTick)
        guard maxJobs > 0 else { return [] }
        let staleCutoff = now.addingTimeInterval(-max(0, policy.staleBatchAge))
        // Deterministic kind order (sorted raw values) for stable behavior/tests.
        let kinds = MemorySourceKind.usageKinds.sorted { $0.rawValue < $1.rawValue }

        return try await dbQueue.write { db in
            var batches: [UsageExtractionBatch] = []
            for kind in kinds where batches.count < maxJobs {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM memory_usage_candidates
                    WHERE status = 'pending' AND source_kind = ?
                    ORDER BY salience_hint DESC, created_at ASC, id ASC
                    LIMIT ?
                    """,
                    arguments: [kind.rawValue, max(1, policy.maxBatch)]
                )
                let candidates = rows.compactMap(Self.usageMemoryCandidate(from:))
                guard candidates.isEmpty == false else { continue }

                if candidates.count < policy.minBatch {
                    // Below the batch floor: only a stale spool flushes early.
                    let oldestPending = try Date.fetchOne(
                        db,
                        sql: """
                        SELECT MIN(created_at)
                        FROM memory_usage_candidates
                        WHERE status = 'pending' AND source_kind = ?
                        """,
                        arguments: [kind.rawValue]
                    )
                    guard let oldestPending, oldestPending <= staleCutoff else { continue }
                }

                let jobID = try self.enqueueUsageExtractionJob(
                    candidateIDs: candidates.map(\.id),
                    sourceKind: kind,
                    promptVersion: promptVersion,
                    scope: scope,
                    in: db,
                    now: now
                )
                batches.append(
                    UsageExtractionBatch(jobID: jobID, sourceKind: kind, candidates: candidates)
                )
            }
            return batches
        }
    }

    /// The candidate rows stamped onto one batch job, top-salience first (the
    /// same order the batch was assembled in). The Stage-1 extractor builds the
    /// prompt from these; the worker resolves model-echoed candidate ids
    /// against them when recomputing provenance.
    func usageCandidates(forBatchJobID jobID: String) async throws -> [UsageMemoryCandidate] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_usage_candidates
                WHERE batch_job_id = ?
                ORDER BY salience_hint DESC, created_at ASC, id ASC
                """,
                arguments: [jobID]
            )
            return rows.compactMap(Self.usageMemoryCandidate(from:))
        }
    }

    /// Flip candidates to `extracted` after their batch job committed a
    /// terminal SUCCESS. One write transaction for the whole id set.
    /// "Extracted" means "consumed by a completed extraction pass" — including
    /// candidates the model found nothing durable in — so a completed batch
    /// never leaks `batched` rows. Deferred/failed jobs never call this, which
    /// is what keeps their candidates `batched` for the retry.
    func markUsageCandidatesExtracted(ids: [String], now: Date = Date()) async throws {
        guard ids.isEmpty == false else { return }
        try await dbQueue.write { db in
            for id in ids {
                try db.execute(
                    sql: """
                    UPDATE memory_usage_candidates
                    SET status = 'extracted', updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [now, id]
                )
            }
        }
    }

    /// Row → value mapping for spool reads. Lifecycle columns (`status`,
    /// `batch_job_id`) stay out of `UsageMemoryCandidate` by design.
    private static func usageMemoryCandidate(from row: Row) -> UsageMemoryCandidate? {
        guard let id: String = row["id"],
              let kindRaw: String = row["source_kind"],
              let sourceKind = MemorySourceKind(rawValue: kindRaw),
              let sourceRef: String = row["source_ref"],
              let threadLogicalID: String = row["thread_logical_id"],
              let payloadJSON: String = row["payload_json"],
              let contentHash: String = row["content_hash"],
              let simhash: Int64 = row["simhash"],
              let salienceHint: Double = row["salience_hint"]
        else {
            return nil
        }
        return UsageMemoryCandidate(
            id: id,
            sourceKind: sourceKind,
            sourceRef: sourceRef,
            threadLogicalID: threadLogicalID,
            payloadJSON: payloadJSON,
            contentHash: contentHash,
            simhash: simhash,
            salienceHint: salienceHint
        )
    }
}
