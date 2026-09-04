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
    ///
    /// **User scoping is the APP's invariant, not a predicate here.** The daemon
    /// holds no Firebase identity and the engine has no uid, so neither could
    /// evaluate `user_id = <the signed-in member>` even if it wanted to. The app
    /// is the one process that knows the member, and its pull lane drops every
    /// unmerged row belonging to another account before it writes anything
    /// (`ControlPlaneStore.purgeUnappliedRemoteMemoryFacts(otherThanUserID:)`).
    /// So "unmerged" already means "the signed-in member's", and this query
    /// filters on `applied_at IS NULL` alone. The ordering leads on
    /// `(user_id, applied_at)` — the index the migration created for exactly this
    /// read — and under the invariant `user_id` is constant across the result, so
    /// leading with it changes nothing about oldest-first. `user_id` travels on
    /// every entry so the engine can audit what it is merging.
    func syncInboxList(_ request: BurnBarMemorySyncInboxListRequest) throws -> BurnBarMemorySyncInboxListResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let limit = max(1, min(request.limit, 1_000))
        return try databaseSync {
            let rows = try queryRows(
                """
                SELECT doc_id, user_id, engine_memory_id, payload_json, remote_updated_at
                FROM agent_memory_inbox
                WHERE applied_at IS NULL
                ORDER BY user_id ASC, applied_at ASC, remote_updated_at ASC, doc_id ASC
                LIMIT ?
                """,
                [.int(limit)]
            )
            return BurnBarMemorySyncInboxListResponse(
                traceID: traceID,
                entries: rows.map {
                    BurnBarMemorySyncInboxEntry(
                        docID: $0.string(0),
                        userID: $0.string(1),
                        engineMemoryID: $0.string(2),
                        payloadJSON: $0.string(3),
                        remoteUpdatedAt: $0.string(4)
                    )
                }
            )
        }
    }

    /// Marks the named documents merged. Idempotent by construction: the update
    /// is guarded on `applied_at IS NULL`, so acknowledging a doc id twice — or
    /// one that was never parked — changes nothing and reports zero.
    ///
    /// A doc id is `pensieveSlugHmac("memory-fact:<engine id>")` under the
    /// member's own vault key, so it is already per-user keyed: another account's
    /// row cannot collide with one of these, and the acknowledgement needs no
    /// `user_id` predicate to stay inside the signed-in member's rows.
    ///
    /// One guarded statement does the whole batch and `changes()` reports what it
    /// touched, so the count is the database's answer rather than a pre-check
    /// that could disagree with the write that followed it.
    func syncInboxAck(_ request: BurnBarMemorySyncInboxAckRequest) throws -> BurnBarMemorySyncInboxAckResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        // Bound the batch the same way the drain is bounded, so a malformed
        // request cannot build an unbounded statement.
        let docIDs = Array(request.docIDs.filter { !$0.isEmpty }.prefix(1_000))
        guard !docIDs.isEmpty else {
            return BurnBarMemorySyncInboxAckResponse(traceID: traceID, acknowledged: 0)
        }
        let now = Self.isoNow()
        let placeholders = Array(repeating: "?", count: docIDs.count).joined(separator: ", ")
        return try databaseSync {
            try execute(
                """
                UPDATE agent_memory_inbox
                SET applied_at = ?
                WHERE doc_id IN (\(placeholders)) AND applied_at IS NULL
                """,
                [.text(now)] + docIDs.map { .text($0) }
            )
            // Read before the sweep: `changes()` reports the most recent write,
            // and the DELETE below would otherwise overwrite the answer.
            let acknowledged = try fetchInt("SELECT changes()", [])
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
