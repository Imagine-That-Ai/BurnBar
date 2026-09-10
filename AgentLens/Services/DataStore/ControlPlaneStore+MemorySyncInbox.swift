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

/// What an inbox upsert actually did, plus what parking it taught the rows
/// already there.
struct MemoryCloudInboxUpsertResult: Equatable, Sendable {
    let outcome: MemoryCloudInboxUpsertOutcome
    /// Parked forget-receipt rows whose opaque `memoryIdHmac` this fact just
    /// resolved to a plain engine id. Each had its `applied_at` cleared, so the
    /// daemon lists it again and the engine — which holds no key material and
    /// could only ack it as `RECEIPT_UNRESOLVED` before — can finally act on it.
    let resolvedReceipts: Int
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
    ///
    /// - Parameter resolvingReceiptHmac: for a FACT, `pensieveSlugHmac("memory-id:<engine id>")`
    ///   under the member's vault key — the value a fact-level forget receipt for
    ///   this very memory carries. Passing it lets the SAME transaction retro-fit
    ///   any receipt already parked under that opaque HMAC with the plain engine
    ///   id, which is the only form the engine can act on. Nil for a receipt
    ///   upsert, and for any caller that holds no key.
    @discardableResult
    func upsertRemoteMemoryFact(
        docID: String,
        userID: String,
        engineMemoryID: String,
        payloadJSON: String,
        remoteUpdatedAt: Date,
        resolvingReceiptHmac: String? = nil,
        now: Date = Date()
    ) async throws -> MemoryCloudInboxUpsertResult {
        let remoteStamp = Self.iso8601String(remoteUpdatedAt)
        let receivedStamp = Self.iso8601String(now)
        return try await dbQueue.write { db -> MemoryCloudInboxUpsertResult in
            let existing = try String.fetchOne(
                db,
                sql: "SELECT remote_updated_at FROM agent_memory_inbox WHERE doc_id = ?",
                arguments: [docID]
            )
            let outcome: MemoryCloudInboxUpsertOutcome
            if let existing {
                // Fixed-width ISO-8601 UTC stamps, so lexicographic order is
                // chronological order and the comparison needs no date parse.
                if existing < remoteStamp {
                    try db.execute(
                        sql: """
                        UPDATE agent_memory_inbox
                        SET user_id = ?, engine_memory_id = ?, payload_json = ?,
                            remote_updated_at = ?, received_at = ?, applied_at = NULL
                        WHERE doc_id = ?
                        """,
                        arguments: [userID, engineMemoryID, payloadJSON, remoteStamp, receivedStamp, docID]
                    )
                    outcome = .replaced
                } else {
                    outcome = .unchanged
                }
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO agent_memory_inbox
                        (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL)
                    """,
                    arguments: [docID, userID, engineMemoryID, payloadJSON, remoteStamp, receivedStamp]
                )
                outcome = .inserted
            }
            // Deliberately NOT conditioned on `outcome`. A receipt for this
            // memory can land in the cycle after the fact did, so the run where
            // the fact reports `unchanged` is exactly the run where a stale
            // receipt row is waiting to be taught what it names.
            let resolved = try Self.resolveParkedForgetReceipts(
                db,
                userID: userID,
                engineMemoryID: engineMemoryID,
                memoryIDHmac: resolvingReceiptHmac
            )
            return MemoryCloudInboxUpsertResult(outcome: outcome, resolvedReceipts: resolved)
        }
    }

    /// Rewrites every parked forget receipt that names `memoryIDHmac` to carry
    /// the plain `engineMemoryID` instead, and reopens it for the engine.
    ///
    /// The whole reason this exists: the engine holds NO key material. It cannot
    /// turn a keyed HMAC into an id, so `_apply_remote_receipt` matches
    /// `^mem_[0-9a-f]{32}$` and acks anything else as `RECEIPT_UNRESOLVED` — a
    /// terminal no-op. The app is the only party that can do the mapping, and a
    /// receipt that arrived before its fact had nothing to map against at park
    /// time. Clearing `applied_at` is the other half: a receipt the engine
    /// already acked is never listed again unless something reopens it.
    ///
    /// Matching on `engine_memory_id` alone is complete. A receipt is parked with
    /// `engine_memory_id` = its payload's `memoryIdHmac` (see
    /// `MemoryCloudPullService.VerifiedReceipt.identityHmac`), so the two are the
    /// same value for every unresolved row; the only thing that ever makes them
    /// differ is THIS rewrite, which leaves behind a plain engine id that needs
    /// no further resolution. A source-level receipt carries a `sourceRefHmac`
    /// computed over a different domain and can never be named here.
    private static func resolveParkedForgetReceipts(
        _ db: Database,
        userID: String,
        engineMemoryID: String,
        memoryIDHmac: String?
    ) throws -> Int {
        guard let memoryIDHmac, !memoryIDHmac.isEmpty, memoryIDHmac != engineMemoryID else { return 0 }
        try db.execute(
            sql: """
            UPDATE agent_memory_inbox
            SET engine_memory_id = ?, applied_at = NULL
            WHERE user_id = ? AND engine_memory_id = ? AND doc_id NOT LIKE ?
            """,
            // The team-row exclusion is belt to the HMAC's braces: a team row's
            // `engine_memory_id` is an engine id and this predicate matches a
            // 64-hex HMAC, so the two shapes cannot meet today. Stated in SQL
            // anyway, because "these shapes happen not to collide" is a weaker
            // guarantee than "this statement cannot reach a team row", and this
            // one reopens rows for the engine to act on (PR3 Cursor ruling, T2).
            arguments: [engineMemoryID, userID, memoryIDHmac, "\(TeamMemoryPullService.inboxDocIDPrefix)%"]
        )
        return db.changesCount
    }

    /// Every engine memory id this device could resolve a forget receipt to.
    ///
    /// Two sources, because they answer two different halves of "does this
    /// device know the memory a receipt names":
    ///
    ///   * `agent_memory_inbox` — facts pulled down from the member's own vault,
    ///     merged or still waiting. A receipt arriving beside a fact this device
    ///     has parked names something the engine is about to hold.
    ///   * `agent_memory_bodies` — memories the engine already mirrors here.
    ///     This is the case that actually retires a row.
    ///
    /// Receipt rows live in the inbox too, under an opaque 64-hex HMAC rather
    /// than an engine id; the caller drops those (`isOpaqueHmac`) rather than
    /// hashing an HMAC and matching nothing.
    ///
    /// TEAM ROWS ARE EXCLUDED (PR3 Cursor ruling, T2). This is the candidate set
    /// a PERSONAL forget receipt is resolved against, and a team row is parked
    /// under the engine id its payload seals — an id chosen by whoever sealed
    /// the document. Leaving them in would let any member of a team seed this
    /// member's receipt-resolution set with ids of their choosing. The team
    /// lane resolves nothing against this set (`resolvingReceiptHmac: nil`), so
    /// nothing legitimate is lost.
    func fetchResolvableEngineMemoryIDs(userID: String) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT engine_memory_id FROM agent_memory_inbox
                WHERE user_id = ? AND doc_id NOT LIKE ?
                UNION
                SELECT engine_memory_id FROM agent_memory_bodies
                """,
                arguments: [userID, "\(TeamMemoryPullService.inboxDocIDPrefix)%"]
            )
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
    static let memoryInboxCursorKinds: [String] = [
        RemoteSyncCollectionKind.memoryFacts.rawValue,
        RemoteSyncCollectionKind.memoryForgetReceipts.rawValue
    ]

    /// The team lane's PUSH watermark rows
    /// (`RemoteSyncWatermarkStore.teamMemoryPushCollectionKind`), which share the
    /// `team:<teamId>:<uid>` account key with the pull cursors above but are NOT
    /// inbox cursors — they record what this member has already SENT.
    ///
    /// They belong in the account-switch DELETE and nowhere else. In the delete,
    /// because a signed-out member's push state has no business surviving on
    /// this Mac once their inbox cursors are gone; NOT in the 90-day rewind,
    /// because that sweep drops parked INBOUND rows and moving the outbound
    /// watermark backwards in response would re-read documents the sweep never
    /// touched.
    private static let memoryTeamPushWatermarkKinds: [String] = [
        RemoteSyncWatermarkStore.teamMemoryPushCollectionKind
    ]

    /// The team lane's project-LINK records
    /// (`RemoteSyncWatermarkStore.teamMemoryProjectLinkKindPrefix`), which share
    /// the same account key again and are not cursors either — they record which
    /// `teamProjectId`s were linked at the last successful pull, so that a link
    /// appearing later rewinds the cursor and recovers what
    /// `.projectNotLinkedToTeam` refused.
    ///
    /// They belong in the account-switch DELETE for the same reason the push
    /// watermarks do: a signed-out member's observation of THIS Mac's links has
    /// no business surviving their sign-out, and the row is a variable-suffix
    /// kind, so the exact-match `IN (...)` above cannot reach it. NOT in the
    /// 90-day rewind, which moves inbound cursors and nothing else.
    private static let memoryTeamProjectLinkKindPredicate =
        RemoteSyncWatermarkStore.teamMemoryProjectLinkKindPredicate

    private static var memoryTeamProjectLinkKindArguments: [any DatabaseValueConvertible] {
        [
            RemoteSyncWatermarkStore.teamMemoryProjectLinkKindPrefix.count,
            RemoteSyncWatermarkStore.teamMemoryProjectLinkKindPrefix
        ]
    }

    /// Matches every inbox cursor belonging to ONE account — the personal one
    /// (`accountUid = <uid>`) and every TEAM one (`accountUid =
    /// "team:<teamId>:<uid>"`, `TeamMemoryPullService.watermarkAccountKey`).
    ///
    /// `RemoteSyncCollectionKind` is a closed enum, so the team lane's cursors
    /// ride in the free-form `accountUid` column under the same `collectionKind`
    /// as the personal ones. Every predicate in this file that means "this
    /// account's inbox cursors" therefore has to say so in TWO shapes, and a
    /// uid-exact one silently means "the personal one only" — which is how the
    /// 90-day sweep came to delete team inbox rows (they carry `user_id = <uid>`
    /// and are squarely in the doomed set) while rewinding no team cursor, so
    /// the pull's strictly-greater-than filter never asked for them again. The
    /// sweep's own promise is that it is a bounded re-fetch, not a loss.
    ///
    /// The suffix half is deliberately NOT `LIKE 'team:%:' || uid`: `LIKE`
    /// treats `_` and `%` in the uid as wildcards, and a test uid such as
    /// `uid_bob` would then match another member's cursor. `substr(x, -n)` is an
    /// exact tail comparison. The `LIKE 'team:%'` prefix carries no uid text at
    /// all, so it is wildcard-safe by construction.
    private static let accountInboxCursorPredicate = """
    (
        accountUid = ?
        OR (accountUid LIKE 'team:%' AND substr(accountUid, -(length(?) + 1)) = ':' || ?)
    )
    """

    /// Deletes the inbox cursors of every account except `userID` (or of every
    /// account when it is nil). Deletion rather than a rewind: a re-pull is
    /// idempotent (`upsertRemoteMemoryFact` is keyed on `(doc_id, remote_updated_at)`)
    /// and the engine's own last-writer-wins dedupes whatever it already holds,
    /// so the cheapest correct cursor after an unbounded purge is no cursor.
    ///
    /// The `except` clause preserves ALL of that account's cursors — the
    /// personal one and every `team:<teamId>:<uid>` one. A uid-exact `<>` used
    /// to delete the switching-IN member's own team cursors on every account
    /// switch, forcing a full re-pull of every team space they had already
    /// consumed: correct, and pure waste.
    private static func dropMemoryInboxCursors(_ db: Database, exceptUserID userID: String?) throws {
        let kinds = memoryInboxCursorKinds + memoryTeamPushWatermarkKinds
        let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
        // The exact-match kinds OR the variable-suffix link records — see
        // `memoryTeamProjectLinkKindPredicate` for why the second shape exists.
        let kindPredicate = "(collectionKind IN (\(placeholders)) OR \(memoryTeamProjectLinkKindPredicate))"
        let kindArguments: [any DatabaseValueConvertible] =
            (kinds as [any DatabaseValueConvertible]) + memoryTeamProjectLinkKindArguments
        if let userID, !userID.isEmpty {
            try db.execute(
                sql: """
                DELETE FROM \(RemoteSyncWatermarkRecord.databaseTableName)
                WHERE \(kindPredicate) AND NOT \(accountInboxCursorPredicate)
                """,
                arguments: StatementArguments(kindArguments + ([userID, userID, userID] as [any DatabaseValueConvertible]))
            )
        } else {
            try db.execute(
                sql: """
                DELETE FROM \(RemoteSyncWatermarkRecord.databaseTableName)
                WHERE \(kindPredicate)
                """,
                arguments: StatementArguments(kindArguments)
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
    ///
    /// Rewinds this account's TEAM cursors as well as its personal one — see
    /// `accountInboxCursorPredicate` for why that is not one predicate.
    private static func rewindMemoryInboxCursors(_ db: Database, userID: String, toJustBefore instant: Date) throws {
        let rewound = instant.addingTimeInterval(-1)
        for kind in memoryInboxCursorKinds {
            try db.execute(
                sql: """
                UPDATE \(RemoteSyncWatermarkRecord.databaseTableName)
                SET lastProcessedRemoteUpdateAt = ?, version = version + 1
                WHERE collectionKind = ? AND \(accountInboxCursorPredicate)
                    AND (lastProcessedRemoteUpdateAt IS NULL OR lastProcessedRemoteUpdateAt > ?)
                """,
                arguments: [rewound, kind, userID, userID, userID, rewound]
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
    ///
    /// The exactly-one-row rule itself lives ONCE in this target, on
    /// `ControlPlaneStore.memoryDeviceSyncMarkerReading` — the same read the
    /// health card and the sync-status row go through — so a change to the
    /// doctrine cannot land on the reporting surfaces and miss the drain's own
    /// gate, or the reverse.
    func fetchMemoryDeviceSyncMarkerUserID() async throws -> String? {
        try await dbQueue.read { db in
            try Self.memoryDeviceSyncMarkerReading(db).accountUid
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
