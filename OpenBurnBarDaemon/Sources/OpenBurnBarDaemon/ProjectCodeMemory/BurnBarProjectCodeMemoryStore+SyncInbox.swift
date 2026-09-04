import Foundation
import OpenBurnBarEngine

// MARK: - Memory Blind Sync inbox (PR-2)
//
// The daemon's half of the read-back path. The app's `MemoryCloudPullService`
// opens the member's own sealed `memory_facts` documents, verifies them, and
// parks the plaintext in `agent_memory_inbox`. The Memory MCP engine has no
// keys and no network — it reaches those rows only here, over the local unix
// socket it already uses, and stamps `applied_at` once it has merged them.
//
// This extension deliberately does NOT merge anything: the engine owns merge
// semantics (§5 of the design). The daemon is a courier for rows the app
// already verified.

extension BurnBarProjectCodeMemoryStore {
    /// How long a merged fact's plaintext stays parked before the drain sweeps it.
    ///
    /// The inbox is a transit buffer, not a store: once the engine has merged a
    /// fact, its own record is canonical and this copy is redundant plaintext at
    /// rest. Keeping it for ever would quietly accumulate a second copy of every
    /// synced memory. The window is generous enough that an engine re-run, or a
    /// merge the member rolls back, can still find the row.
    static let syncInboxRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60

    /// Remote facts the engine has not merged yet, oldest first so a partial
    /// drain still applies updates in `updatedAt` order.
    func syncInboxList(_ request: BurnBarMemorySyncInboxListRequest) throws -> BurnBarMemorySyncInboxListResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let limit = max(1, min(request.limit, 1_000))
        return try databaseSync {
            let rows = try queryRows(
                """
                SELECT doc_id, engine_memory_id, payload_json, remote_updated_at
                FROM agent_memory_inbox
                WHERE applied_at IS NULL
                ORDER BY remote_updated_at ASC, doc_id ASC
                LIMIT ?
                """,
                [.int(limit)]
            )
            return BurnBarMemorySyncInboxListResponse(
                traceID: traceID,
                entries: rows.map {
                    BurnBarMemorySyncInboxEntry(
                        docID: $0.string(0),
                        engineMemoryID: $0.string(1),
                        payloadJSON: $0.string(2),
                        remoteUpdatedAt: $0.string(3)
                    )
                }
            )
        }
    }

    /// Marks the named documents merged. Idempotent by construction: the update
    /// is guarded on `applied_at IS NULL`, so acknowledging a doc id twice — or
    /// one that was never parked — changes nothing and reports zero.
    func syncInboxAck(_ request: BurnBarMemorySyncInboxAckRequest) throws -> BurnBarMemorySyncInboxAckResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        // Bound the batch the same way the drain is bounded, so a malformed
        // request cannot build an unbounded statement.
        let docIDs = Array(request.docIDs.filter { !$0.isEmpty }.prefix(1_000))
        guard !docIDs.isEmpty else {
            return BurnBarMemorySyncInboxAckResponse(traceID: traceID, acknowledged: 0)
        }
        let now = Self.isoNow()
        return try databaseSync {
            var acknowledged = 0
            for docID in docIDs {
                let before = try fetchInt(
                    "SELECT COUNT(*) FROM agent_memory_inbox WHERE doc_id = ? AND applied_at IS NULL",
                    [.text(docID)]
                )
                guard before > 0 else { continue }
                try execute(
                    "UPDATE agent_memory_inbox SET applied_at = ? WHERE doc_id = ? AND applied_at IS NULL",
                    [.text(now), .text(docID)]
                )
                acknowledged += 1
            }
            try pruneMergedSyncInboxRows(now: Date())
            return BurnBarMemorySyncInboxAckResponse(traceID: traceID, acknowledged: acknowledged)
        }
    }

    /// Sweeps merged rows whose plaintext has outlived `syncInboxRetentionSeconds`.
    /// Unmerged rows are never touched — dropping one would lose a fact the engine
    /// has not seen, and the pull watermark has already moved past its document.
    func pruneMergedSyncInboxRows(now: Date) throws {
        let cutoff = Self.isoString(now.addingTimeInterval(-Self.syncInboxRetentionSeconds))
        try execute(
            "DELETE FROM agent_memory_inbox WHERE applied_at IS NOT NULL AND applied_at < ?",
            [.text(cutoff)]
        )
    }
}
