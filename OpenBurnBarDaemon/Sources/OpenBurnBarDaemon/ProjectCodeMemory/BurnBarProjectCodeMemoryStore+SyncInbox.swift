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

    /// The member the app says consents to device sync right now, or nil.
    ///
    /// This is the scope predicate the daemon could not previously evaluate. It
    /// holds no Firebase identity, so it reads the app's own marker
    /// (`BurnBarMemoryDeviceSyncMarker`) out of the shared encrypted database:
    /// one row means "this uid, consenting"; anything else — no row, several
    /// rows, or the table absent because the app has never migrated this store —
    /// means no consent, and the drain hands over nothing.
    ///
    /// Fail-closed by construction: every path that is not exactly one row with
    /// a non-empty account returns nil, including a SQL error.
    func memoryDeviceSyncConsentUserID() -> String? {
        let rows: [SQLiteRow]
        do {
            rows = try queryRows(
                """
                SELECT \(BurnBarMemoryDeviceSyncMarker.accountColumn)
                FROM \(BurnBarMemoryDeviceSyncMarker.tableName)
                WHERE \(BurnBarMemoryDeviceSyncMarker.kindColumn) = ?
                LIMIT 2
                """,
                [.text(BurnBarMemoryDeviceSyncMarker.collectionKind)]
            )
        } catch {
            // The table belongs to the app's migrator. On a store the app has
            // never opened it simply is not there, which is not an error worth
            // failing the RPC over — it is the absence of consent.
            return nil
        }
        guard rows.count == 1 else { return nil }
        let uid = rows[0].string(0)
        return uid.isEmpty ? nil : uid
    }

    /// Remote facts the engine has not merged yet, oldest first so a partial
    /// drain still applies updates in `updatedAt` order.
    ///
    /// **User scoping is ENFORCED here, not documented.** The daemon holds no
    /// Firebase identity, so the app publishes the signed-in member and their
    /// live consent as a marker row this reads
    /// (`memoryDeviceSyncConsentUserID()`); the query then filters
    /// `user_id = <that member>` and returns nothing at all when the marker is
    /// absent. Consent off, signed out, or an account whose rows are not the
    /// marker's therefore drains zero entries even though those rows are still
    /// unmerged — which is what a shared Mac needs, because "unmerged" alone
    /// would have handed the previous member's facts to the current one.
    ///
    /// The app additionally purges what may no longer drain on every observed
    /// state transition (`MemoryDeviceSyncInboxGuard`), so the two halves agree;
    /// this predicate is what makes the boundary hold in the window between a
    /// transition and the app noticing it.
    ///
    /// The ordering leads on `(user_id, applied_at)` — the index the migration
    /// created for exactly this read. `user_id` travels on every entry so the
    /// engine can audit what it is merging.
    func syncInboxList(_ request: BurnBarMemorySyncInboxListRequest) throws -> BurnBarMemorySyncInboxListResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let limit = max(1, min(request.limit, 1_000))
        return try databaseSync {
            guard let consentUserID = memoryDeviceSyncConsentUserID() else {
                return BurnBarMemorySyncInboxListResponse(traceID: traceID, entries: [])
            }
            let rows = try queryRows(
                """
                SELECT doc_id, user_id, engine_memory_id, payload_json, remote_updated_at
                FROM agent_memory_inbox
                WHERE user_id = ? AND applied_at IS NULL
                ORDER BY user_id ASC, applied_at ASC, remote_updated_at ASC, doc_id ASC
                LIMIT ?
                """,
                [.text(consentUserID), .int(limit)]
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
    /// member's own vault key, so it is already per-user keyed and could not
    /// collide across accounts. The `user_id` predicate is here anyway, against
    /// the same consent marker `syncInboxList` reads: an acknowledgement is a
    /// write, and a caller with no consent must not be able to mark another
    /// member's parked facts merged and so hide them from the member who owns
    /// them. No marker ⇒ nothing is acknowledged.
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
            guard let consentUserID = memoryDeviceSyncConsentUserID() else {
                return BurnBarMemorySyncInboxAckResponse(traceID: traceID, acknowledged: 0)
            }
            try execute(
                """
                UPDATE agent_memory_inbox
                SET applied_at = ?
                WHERE user_id = ? AND doc_id IN (\(placeholders)) AND applied_at IS NULL
                """,
                [.text(now), .text(consentUserID)] + docIDs.map { .text($0) }
            )
            // Read before the sweep: `changes()` reports the most recent write,
            // and the DELETE below would otherwise overwrite the answer.
            let acknowledged = try fetchInt("SELECT changes()", [])
            try pruneMergedSyncInboxRows(now: Date())
            return BurnBarMemorySyncInboxAckResponse(traceID: traceID, acknowledged: acknowledged)
        }
    }

    /// How long an UNMERGED row waits for the engine before it is swept.
    ///
    /// The other half of the bound. A merged row is a redundant copy and goes
    /// after 30 days; an unmerged row is a fact this device has not applied
    /// anywhere, so it is kept far longer — but not for ever, because the engine
    /// only runs when an agent invokes the MCP tool, and on an install where
    /// that never happens the inbox would otherwise accumulate a permanent
    /// plaintext mirror of every memory the member's other devices ever wrote.
    /// 90 days. Nothing is destroyed: the document is still in the member's
    /// cloud vault, and clearing the pull watermark re-pulls it.
    static let syncInboxUnappliedRetentionSeconds: TimeInterval = 90 * 24 * 60 * 60

    /// Sweeps merged rows whose plaintext has outlived `syncInboxRetentionSeconds`,
    /// and unmerged rows that have outlived `syncInboxUnappliedRetentionSeconds`
    /// waiting for an engine that never came.
    func pruneMergedSyncInboxRows(now: Date) throws {
        let cutoff = Self.isoString(now.addingTimeInterval(-Self.syncInboxRetentionSeconds))
        try execute(
            "DELETE FROM agent_memory_inbox WHERE applied_at IS NOT NULL AND applied_at < ?",
            [.text(cutoff)]
        )
        let staleCutoff = Self.isoString(now.addingTimeInterval(-Self.syncInboxUnappliedRetentionSeconds))
        try execute(
            "DELETE FROM agent_memory_inbox WHERE applied_at IS NULL AND received_at < ?",
            [.text(staleCutoff)]
        )
    }

    /// Drops every inbox row carrying one of these engine memory ids.
    ///
    /// A hard forget must reach the parked plaintext too. `agent_memory_inbox`
    /// holds an opened copy of a memory that has not been merged (or was merged
    /// and is still inside its retention window), and nothing else deletes by
    /// memory: the account purge deletes by owner and the sweeps delete by age.
    /// Without this, forgetting a memory left a readable copy of its body on
    /// disk — and worse, an unmerged copy would have been merged back in on the
    /// next drain if the engine's own forget receipt had not caught it.
    func deleteSyncInboxRows(engineMemoryIDs: [String]) throws {
        let ids = Array(Set(engineMemoryIDs.filter { !$0.isEmpty })).sorted().prefix(1_000)
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try execute(
            "DELETE FROM agent_memory_inbox WHERE engine_memory_id IN (\(placeholders))",
            ids.map { .text($0) }
        )
    }
}
