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
}
