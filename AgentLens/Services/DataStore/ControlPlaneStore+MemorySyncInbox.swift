import Foundation
@preconcurrency import GRDB
import OpenBurnBarKernel

// MARK: - Remote memory-fact inbox (Memory Blind Sync, pull half)

/// One opened, verified memory fact pulled down from the member's own cloud
/// vault and parked for the Memory MCP engine to merge.
///
/// Rows deliberately do NOT land in `agent_memories`: that table is this
/// device's own *upload* source, so a remote row written there would be
/// re-sealed and re-uploaded by this device's push lane in a loop. The inbox is
/// a one-way landing zone the engine drains through the daemon.
struct MemoryCloudInboxRecord: Equatable, Sendable {
    let docID: String
    let userID: String
    let engineMemoryID: String
    let payloadJSON: String
    let remoteUpdatedAt: Date
    let receivedAt: Date
    let appliedAt: Date?
}

/// What an inbox upsert actually did, so the pull service can report honest
/// counters instead of claiming work it skipped.
enum MemoryCloudInboxUpsertOutcome: String, Equatable, Sendable {
    /// A document this device had never seen.
    case inserted
    /// A strictly newer revision of a document already parked here; the row is
    /// replaced and `applied_at` cleared so the engine merges the new revision.
    case replaced
    /// The same (or an older) revision arrived again — a no-op, which is what
    /// makes re-applying a whole batch cost nothing.
    case unchanged
}

extension ControlPlaneStore {
    /// Parks one verified remote memory fact.
    ///
    /// Idempotence is keyed on `(doc_id, remote_updated_at)` exactly as §5 of the
    /// design requires: an identical or stale revision is dropped, a newer one
    /// replaces the row and resets `applied_at` so the engine re-merges it.
    @discardableResult
    func upsertRemoteMemoryFact(
        docID: String,
        userID: String,
        engineMemoryID: String,
        payloadJSON: String,
        remoteUpdatedAt: Date,
        now: Date = Date()
    ) async throws -> MemoryCloudInboxUpsertOutcome {
        let remoteStamp = Self.iso8601String(remoteUpdatedAt)
        let receivedStamp = Self.iso8601String(now)
        return try await dbQueue.write { db -> MemoryCloudInboxUpsertOutcome in
            let existing = try String.fetchOne(
                db,
                sql: "SELECT remote_updated_at FROM agent_memory_inbox WHERE doc_id = ?",
                arguments: [docID]
            )
            if let existing {
                // Fixed-width ISO-8601 UTC stamps, so lexicographic order is
                // chronological order and the comparison needs no date parse.
                guard existing < remoteStamp else { return .unchanged }
                try db.execute(
                    sql: """
                    UPDATE agent_memory_inbox
                    SET user_id = ?, engine_memory_id = ?, payload_json = ?,
                        remote_updated_at = ?, received_at = ?, applied_at = NULL
                    WHERE doc_id = ?
                    """,
                    arguments: [userID, engineMemoryID, payloadJSON, remoteStamp, receivedStamp, docID]
                )
                return .replaced
            }
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [docID, userID, engineMemoryID, payloadJSON, remoteStamp, receivedStamp]
            )
            return .inserted
        }
    }

    /// Drops every UNMERGED inbox row that belongs to some other account.
    ///
    /// The inbox is user-scoped, and this is one of the two things that make
    /// that true. The app is the one process that knows which member is signed
    /// in, so it owns the scoping; `MemoryDeviceSyncInboxGuard` runs this on
    /// every observed state transition (not only inside a gated pull), and the
    /// daemon enforces the same scope independently against the consent marker
    /// the guard writes.
    ///
    /// Merged rows are deliberately untouched. The engine already holds those
    /// facts; deleting them here would erase the audit trail of what it merged,
    /// and the daemon's retention sweep already owns their disposal.
    ///
    /// - Returns: how many rows were dropped, so an account switch is visible in
    ///   the pull result rather than silent.
    @discardableResult
    func purgeUnappliedRemoteMemoryFacts(otherThanUserID userID: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM agent_memory_inbox WHERE user_id <> ? AND applied_at IS NULL",
                arguments: [userID]
            )
            let purged = db.changesCount
            // Same transaction, same reason: the departed members' cursors
            // accounted for the rows that just went. See `memoryInboxCursorKinds`.
            try Self.dropMemoryInboxCursors(db, exceptUserID: userID)
            return purged
        }
    }

    /// Drops EVERY unmerged inbox row, whoever it belongs to.
    ///
    /// What consent-off means for rows already parked. The sub-toggle governs
    /// ingress into the engine as much as ingress into the inbox: a member who
    /// turns device sync off, signs out, or loses the Data Vault entitlement has
    /// withdrawn permission for anything still pending to drain, so the pending
    /// plaintext goes rather than waiting for a future opt-in to release it.
    ///
    /// Merged rows survive for the same reason as above — the engine already
    /// holds those facts and the retention sweep owns their disposal.
    @discardableResult
    func purgeAllUnappliedRemoteMemoryFacts() async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM agent_memory_inbox WHERE applied_at IS NULL")
            let purged = db.changesCount
            try Self.dropMemoryInboxCursors(db, exceptUserID: nil)
            return purged
        }
    }

    /// Drops the whole inbox, merged rows included.
    ///
    /// A memory reset means "this device keeps none of it". The inbox holds a
    /// second plaintext copy of every fact that came down, so leaving it behind
    /// would leave the member's memories on disk after the surface that shows
    /// them is empty.
    ///
    /// The transport cursor is deliberately LEFT ALONE here, unlike every other
    /// purge on this page. A reset is the member erasing their memories on
    /// purpose; rewinding the cursor would re-download the very facts they just
    /// deleted on the next cycle and quietly undo the reset. A consent
    /// withdrawal or an account switch is the opposite — nothing was erased,
    /// the member's cloud copy is still authoritative, and the rows must be
    /// reachable again — which is why those rewind and this does not.
    @discardableResult
    func purgeAllRemoteMemoryFacts() async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM agent_memory_inbox")
            return db.changesCount
        }
    }

    /// Drops unmerged rows the engine has never come for.
    ///
    /// The bound the merged-row sweep has always had, applied to the other half
    /// of the table. An unmerged row is parked plaintext waiting for a drain
    /// that may never happen — the engine only runs when an agent invokes the
    /// MCP tool — so without this the inbox grows without limit on any install
    /// where the Memory MCP is not in use. The window is deliberately longer
    /// than the merged one: a row that is still waiting has not been applied
    /// anywhere, so dropping it early would lose a fact rather than a copy.
    /// Nothing is lost permanently in any case — the row's document is still in
    /// the member's cloud vault, and clearing the pull watermark re-pulls it.
    ///
    /// - Returns: how many rows were dropped.
    @discardableResult
    func pruneStaleUnappliedRemoteMemoryFacts(
        olderThan retention: TimeInterval = ControlPlaneStore.unappliedMemoryInboxRetentionSeconds,
        now: Date = Date()
    ) async throws -> Int {
        let cutoff = Self.iso8601String(now.addingTimeInterval(-retention))
        return try await dbQueue.write { db in
            // Read the doomed rows' owners and oldest instants BEFORE the delete:
            // afterwards there is nothing left to rewind the cursor from, and a
            // cursor left above them would make the sweep a permanent loss
            // rather than a bounded re-fetch.
            let doomed = try Row.fetchAll(
                db,
                sql: """
                SELECT user_id, MIN(remote_updated_at) AS oldest
                FROM agent_memory_inbox
                WHERE applied_at IS NULL AND received_at < ?
                GROUP BY user_id
                """,
                arguments: [cutoff]
            )
            try db.execute(
                sql: "DELETE FROM agent_memory_inbox WHERE applied_at IS NULL AND received_at < ?",
                arguments: [cutoff]
            )
            let swept = db.changesCount
            for row in doomed {
                guard let userID = row["user_id"] as? String,
                      let oldest = OpenBurnBarDatabase.parseDateValue(row["oldest"]) else { continue }
                try Self.rewindMemoryInboxCursors(db, userID: userID, toJustBefore: oldest)
            }
            return swept
        }
    }

    /// How long an unmerged inbox row waits for the engine before the sweep
    /// drops it. 90 days: long enough that a Mac whose Memory MCP is used only
    /// occasionally still merges everything, short enough that an install which
    /// never runs the engine does not accumulate a plaintext mirror of the
    /// member's memories for ever.
    static let unappliedMemoryInboxRetentionSeconds: TimeInterval = 90 * 24 * 60 * 60

    // MARK: - Transport cursors the inbox purges invalidate

    /// The `remote_sync_watermarks` rows that are CURSORS over the inbox — the
    /// ones whose meaning is "every document at or below this instant has been
    /// dealt with", where "dealt with" means "parked as an unmerged inbox row".
    ///
    /// Purging those rows without moving the cursor back is a silent deletion:
    /// the pull's filter is strictly `updatedAt > cursor`, so a purged document
    /// is never requested again on this device, and the member's own cloud copy
    /// becomes unreachable rather than merely un-merged. Every purge on this
    /// page therefore moves the cursor in the SAME transaction as the delete.
    ///
    /// Named explicitly, and never "everything in the table", because this table
    /// also carries the device-sync consent MARKER row
    /// (`BurnBarMemoryDeviceSyncMarker.collectionKind`), which is not a cursor —
    /// and the watermarks of the conversation-shaped collections, which have
    /// nothing to do with the inbox.
    static let memoryInboxCursorKinds: [String] = [RemoteSyncCollectionKind.memoryFacts.rawValue]

    /// Deletes the inbox cursors of every account except `userID` (or of every
    /// account when it is nil). Deletion rather than a rewind: a re-pull is
    /// idempotent (`upsertRemoteMemoryFact` is keyed on `(doc_id, remote_updated_at)`)
    /// and the engine's own last-writer-wins dedupes whatever it already holds,
    /// so the cheapest correct cursor after an unbounded purge is no cursor.
    private static func dropMemoryInboxCursors(_ db: Database, exceptUserID userID: String?) throws {
        let placeholders = Array(repeating: "?", count: memoryInboxCursorKinds.count).joined(separator: ", ")
        if let userID, !userID.isEmpty {
            try db.execute(
                sql: """
                DELETE FROM \(RemoteSyncWatermarkRecord.databaseTableName)
                WHERE collectionKind IN (\(placeholders)) AND accountUid <> ?
                """,
                arguments: StatementArguments(memoryInboxCursorKinds + [userID])
            )
        } else {
            try db.execute(
                sql: """
                DELETE FROM \(RemoteSyncWatermarkRecord.databaseTableName)
                WHERE collectionKind IN (\(placeholders))
                """,
                arguments: StatementArguments(memoryInboxCursorKinds)
            )
        }
    }

    /// Moves `userID`'s inbox cursors to one second BELOW `instant`, but only
    /// when they currently sit at or above it.
    ///
    /// A rewind rather than a deletion here because the sweep drops a bounded,
    /// known set of rows: rewinding to just under the oldest of them re-reads
    /// exactly what was lost, where deleting the cursor would re-read the whole
    /// collection. One second, not zero, because the pull's filter is strictly
    /// greater-than and the swept document must be INSIDE the next page.
    private static func rewindMemoryInboxCursors(_ db: Database, userID: String, toJustBefore instant: Date) throws {
        let rewound = instant.addingTimeInterval(-1)
        for kind in memoryInboxCursorKinds {
            try db.execute(
                sql: """
                UPDATE \(RemoteSyncWatermarkRecord.databaseTableName)
                SET lastProcessedRemoteUpdateAt = ?, version = version + 1
                WHERE accountUid = ? AND collectionKind = ?
                    AND (lastProcessedRemoteUpdateAt IS NULL OR lastProcessedRemoteUpdateAt > ?)
                """,
                arguments: [rewound, userID, kind, rewound]
            )
        }
    }

    // MARK: - Device-sync consent marker

    /// Publishes "this member, right now, consents to device sync" for the
    /// daemon to enforce against. See `BurnBarMemoryDeviceSyncMarker`.
    ///
    /// UNCONDITIONAL — for seeding and tests. Production publishes go through
    /// `publishMemoryDeviceSyncConsent`, which refuses to land a marker whose
    /// scope was observed before a withdrawal.
    func writeMemoryDeviceSyncMarker(userID: String, now: Date = Date()) async throws {
        try await dbQueue.write { db in
            try Self.replaceMemoryDeviceSyncMarker(db, userID: userID, now: now)
        }
    }

    /// The withdrawal count a caller must read BEFORE capturing the scope it
    /// will hand to `publishMemoryDeviceSyncConsent`. See
    /// `memoryDeviceSyncGeneration`.
    func currentMemoryDeviceSyncGeneration() -> UInt64 {
        memoryDeviceSyncGeneration.withLock { $0 }
    }

    /// Withdraws consent and purges, atomically: the marker goes, the unmerged
    /// rows go (every one when `userID` is nil — nobody is present to consent;
    /// every one that is not the named member's otherwise), and the withdrawal
    /// generation advances — all in ONE transaction, so no publish can
    /// interleave between the marker leaving and the rows leaving, and any
    /// publish whose scope predates this call is refused afterwards.
    ///
    /// Returns the number of unmerged rows purged.
    @discardableResult
    func withdrawMemoryDeviceSyncConsent(keepingUnappliedRowsOf userID: String?) async throws -> Int {
        try await dbQueue.write { [memoryDeviceSyncGeneration] db in
            try Self.deleteMemoryDeviceSyncMarker(db)
            if let userID, !userID.isEmpty {
                try db.execute(
                    sql: "DELETE FROM agent_memory_inbox WHERE user_id <> ? AND applied_at IS NULL",
                    arguments: [userID]
                )
            } else {
                try db.execute(sql: "DELETE FROM agent_memory_inbox WHERE applied_at IS NULL")
            }
            let purged = db.changesCount
            // The cursors that accounted for those rows go in the SAME
            // transaction. See `memoryInboxCursorKinds`.
            try Self.dropMemoryInboxCursors(db, exceptUserID: userID?.isEmpty == false ? userID : nil)
            memoryDeviceSyncGeneration.withLock { $0 &+= 1 }
            return purged
        }
    }

    /// Publishes consent for `userID`, atomically and conditionally: purges the
    /// unmerged rows that are not theirs and lands the marker in ONE
    /// transaction — but only if no withdrawal has happened since the caller
    /// read `observedGeneration`. Otherwise it changes nothing and returns nil.
    ///
    /// Why the condition: `MemoryCloudSyncDomain.sync()` captures its gate (who
    /// is signed in, what they consented to) and then awaits. A sign-out, an
    /// account switch, or the Settings toggle closing can complete inside that
    /// await, and without the check the resumed tick would republish the
    /// departed member's marker — or purge the new member's freshly-pulled
    /// rows — for up to a whole refresh interval. The check runs on the
    /// database writer, serialised with the withdrawal that bumps the
    /// generation, so Swift actor reentrancy cannot slip between them.
    ///
    /// Returns the number of foreign unmerged rows purged, or nil when refused.
    func publishMemoryDeviceSyncConsent(
        userID: String,
        observedGeneration: UInt64,
        now: Date = Date()
    ) async throws -> Int? {
        try await dbQueue.write { [memoryDeviceSyncGeneration] db -> Int? in
            guard memoryDeviceSyncGeneration.withLock({ $0 }) == observedGeneration else { return nil }
            try db.execute(
                sql: "DELETE FROM agent_memory_inbox WHERE user_id <> ? AND applied_at IS NULL",
                arguments: [userID]
            )
            let purged = db.changesCount
            try Self.dropMemoryInboxCursors(db, exceptUserID: userID)
            try Self.replaceMemoryDeviceSyncMarker(db, userID: userID, now: now)
            return purged
        }
    }

    private static func deleteMemoryDeviceSyncMarker(_ db: Database) throws {
        try db.execute(
            sql: """
            DELETE FROM \(BurnBarMemoryDeviceSyncMarker.tableName)
            WHERE \(BurnBarMemoryDeviceSyncMarker.kindColumn) = ?
            """,
            arguments: [BurnBarMemoryDeviceSyncMarker.collectionKind]
        )
    }

    private static func replaceMemoryDeviceSyncMarker(_ db: Database, userID: String, now: Date) throws {
        // One marker, ever: the previous member's row goes before this one
        // lands, so "more than one row" can only ever mean a corrupt store —
        // which the daemon reads as no consent.
        try deleteMemoryDeviceSyncMarker(db)
        try db.execute(
            sql: """
            INSERT INTO \(BurnBarMemoryDeviceSyncMarker.tableName)
                (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
            VALUES (?, ?, ?, NULL, 1)
            """,
            arguments: [userID, BurnBarMemoryDeviceSyncMarker.collectionKind, now]
        )
    }

    /// Withdraws consent for the drain. Absence is what the daemon reads as
    /// "nothing may drain", so this is the revocation itself, not a hint.
    /// Every clear is a withdrawal, so it advances the generation too: a
    /// publish whose scope was read before this call must not land afterwards.
    func clearMemoryDeviceSyncMarker() async throws {
        try await dbQueue.write { [memoryDeviceSyncGeneration] db in
            try Self.deleteMemoryDeviceSyncMarker(db)
            memoryDeviceSyncGeneration.withLock { $0 &+= 1 }
        }
    }

    /// The member the marker currently names, or nil when there is no consent.
    /// Reads exactly what the daemon reads, so a test can assert one boundary.
    func fetchMemoryDeviceSyncMarkerUserID() async throws -> String? {
        try await dbQueue.read { db in
            let rows = try String.fetchAll(
                db,
                sql: """
                SELECT accountUid FROM \(BurnBarMemoryDeviceSyncMarker.tableName)
                WHERE \(BurnBarMemoryDeviceSyncMarker.kindColumn) = ?
                LIMIT 2
                """,
                arguments: [BurnBarMemoryDeviceSyncMarker.collectionKind]
            )
            return rows.count == 1 ? rows.first : nil
        }
    }

    /// Remote facts the engine has not merged yet, oldest first so a partial
    /// drain still applies updates in `updatedAt` order.
    func fetchUnappliedRemoteMemoryFacts(userID: String, limit: Int = 200) async throws -> [MemoryCloudInboxRecord] {
        let cappedLimit = max(1, min(limit, 1000))
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at
                FROM agent_memory_inbox
                WHERE user_id = ? AND applied_at IS NULL
                ORDER BY remote_updated_at ASC, doc_id ASC
                LIMIT ?
                """,
                arguments: [userID, cappedLimit]
            ).compactMap(Self.memoryCloudInboxRecord(from:))
        }
    }

    private static func memoryCloudInboxRecord(from row: Row) -> MemoryCloudInboxRecord? {
        guard let docID = row["doc_id"] as? String,
              let userID = row["user_id"] as? String,
              let engineMemoryID = row["engine_memory_id"] as? String,
              let payloadJSON = row["payload_json"] as? String,
              let remoteUpdatedAt = OpenBurnBarDatabase.parseDateValue(row["remote_updated_at"]),
              let receivedAt = OpenBurnBarDatabase.parseDateValue(row["received_at"]) else {
            return nil
        }
        return MemoryCloudInboxRecord(
            docID: docID,
            userID: userID,
            engineMemoryID: engineMemoryID,
            payloadJSON: payloadJSON,
            remoteUpdatedAt: remoteUpdatedAt,
            receivedAt: receivedAt,
            appliedAt: OpenBurnBarDatabase.parseDateValue(row["applied_at"])
        )
    }
}
