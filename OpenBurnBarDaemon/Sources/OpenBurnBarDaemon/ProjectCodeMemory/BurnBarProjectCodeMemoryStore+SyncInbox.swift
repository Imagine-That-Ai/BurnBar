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

    /// The ONE timestamp format `agent_memory_inbox` is written and compared in.
    ///
    /// Both processes write this table — the app parks rows (`received_at`,
    /// `remote_updated_at`) and the daemon stamps and sweeps them (`applied_at`,
    /// the retention cutoffs) — and the comparisons are lexicographic on TEXT,
    /// so the two sides have to agree on the exact string shape or the ordering
    /// silently stops meaning "chronological".
    ///
    /// They did not. The app writes ISO-8601 WITH fractional seconds
    /// (`ControlPlaneStore.iso8601String`, `.withFractionalSeconds`), while the
    /// daemon's general-purpose `isoString` emits bare seconds. `'.'` (0x2E)
    /// sorts before `'Z'` (0x5A), so `2026-09-04T00:00:00.500Z` compared as less
    /// than the cutoff `2026-09-04T00:00:00Z` — an unmerged row up to a second
    /// NEWER than the cutoff was swept as if it were older. Matching the app's
    /// formatter here makes the comparison exact at the boundary second.
    static func syncInboxTimestamp(_ date: Date) -> String {
        ThreadSafeISO8601DateFormatter.formatFractional(date)
    }

    /// How long a consent marker authorises drains before it goes stale.
    ///
    /// Presence alone was not enough. The marker is a claim the app makes about
    /// a live gate, but the daemon **outlives the app**: quit or crash the Mac
    /// app after a sign-out and the marker persists on disk indefinitely, with
    /// every subsequent drain still honouring it. The app's eager purges
    /// (`MemoryDeviceSyncInboxGuard.enforceAccountTransition`) close that door
    /// from the app's side; this closes it from the daemon's, so the boundary
    /// holds even when the app is not running to enforce anything.
    ///
    /// 20 minutes, and it is `BurnBarMemoryDeviceSyncMarker.maxAge` rather than a
    /// literal because the bound and the app's refresh cadence are ONE contract
    /// between two processes. It used to be `2 * 600`, pinned to
    /// `BehaviorSettings.refreshInterval` — but that interval is user-adjustable
    /// up to 15 minutes and `BackgroundCadenceCoordinator` stretches it 5x while
    /// the app is inactive, so a normally-backgrounded menu-bar app could go 75
    /// minutes between refreshes and this bound would expire a consent that was
    /// never withdrawn. The app now refreshes the marker on its own fixed timer
    /// (`BurnBarMemoryDeviceSyncMarker.refreshInterval`, 5 minutes) and this is
    /// four of those: three missed beats tolerated, the fourth read as "no app
    /// is vouching for this any more". It is deliberately NOT a security timeout
    /// tuned to an attacker: it is the window in which an app that stopped
    /// running stops being believed.
    static let deviceSyncConsentMarkerMaxAge: TimeInterval = BurnBarMemoryDeviceSyncMarker.maxAge

    /// The member the app says consents to device sync right now, or nil.
    ///
    /// This is the scope predicate the daemon could not previously evaluate. It
    /// holds no Firebase identity, so it reads the app's own marker
    /// (`BurnBarMemoryDeviceSyncMarker`) out of the shared encrypted database:
    /// one FRESH row means "this uid, consenting"; anything else — no row,
    /// several rows, a row no sync has refreshed inside
    /// `deviceSyncConsentMarkerMaxAge`, or the table absent because the app has
    /// never migrated this store — means no consent, and the drain hands over
    /// nothing.
    ///
    /// Freshness is evaluated by SQLite's own `julianday()` rather than by
    /// parsing the stamp here, because the column is written by GRDB (whose
    /// `Date` binding is `YYYY-MM-DD HH:MM:SS.SSS`) and a daemon-side parser
    /// would be a second, silently-drifting copy of that format. `julianday()`
    /// accepts that shape and ISO-8601 alike, and answers NULL for anything it
    /// cannot read — which the `CASE` below turns into "stale", i.e. closed.
    ///
    /// Fail-closed by construction: every path that is not exactly one fresh row
    /// with a non-empty account returns nil, including a SQL error.
    func memoryDeviceSyncConsentUserID(now: Date = Date()) -> String? {
        let freshnessCutoff = Self.syncInboxTimestamp(now.addingTimeInterval(-Self.deviceSyncConsentMarkerMaxAge))
        let rows: [SQLiteRow]
        do {
            rows = try queryRows(
                """
                SELECT \(BurnBarMemoryDeviceSyncMarker.accountColumn),
                       CASE
                           WHEN julianday(\(BurnBarMemoryDeviceSyncMarker.refreshedAtColumn)) >= julianday(?)
                           THEN 1 ELSE 0
                       END
                FROM \(BurnBarMemoryDeviceSyncMarker.tableName)
                WHERE \(BurnBarMemoryDeviceSyncMarker.kindColumn) = ?
                LIMIT 2
                """,
                [.text(freshnessCutoff), .text(BurnBarMemoryDeviceSyncMarker.collectionKind)]
            )
        } catch {
            // The table belongs to the app's migrator. On a store the app has
            // never opened it simply is not there, which is not an error worth
            // failing the RPC over — it is the absence of consent.
            return nil
        }
        // Counted BEFORE freshness so an ambiguous table (two markers, one of
        // them fresh) still reads as no consent rather than picking a winner.
        guard rows.count == 1 else { return nil }
        guard rows[0].int64(1) == 1 else { return nil }
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
                entries: rows.map { row in
                    let payloadJSON = row.string(3)
                    return BurnBarMemorySyncInboxEntry(
                        docID: row.string(0),
                        userID: row.string(1),
                        engineMemoryID: row.string(2),
                        payloadJSON: payloadJSON,
                        remoteUpdatedAt: row.string(4),
                        entryKind: Self.syncInboxEntryKind(fromPayloadJSON: payloadJSON)
                    )
                }
            )
        }
    }

    /// Lifts the routing discriminator out of a parked payload, so an entry says
    /// what it is without a reader having to open it.
    ///
    /// This is the ONE thing the courier reads inside a payload, and it reads
    /// exactly one key. The daemon still does not understand facts, receipts, or
    /// merge semantics — the engine owns all of that — but `agent_memory_inbox`
    /// has no kind column, this wave adds no migration, and a discriminator that
    /// only exists inside an opaque string cannot be honoured by anything that
    /// declines to look. Anything unparseable is nil, i.e. "a fact", which is
    /// what every entry written before this field existed is.
    static func syncInboxEntryKind(fromPayloadJSON payloadJSON: String) -> String? {
        struct Discriminator: Decodable {
            let entryKind: String?
        }
        guard let data = payloadJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Discriminator.self, from: data),
              let entryKind = decoded.entryKind,
              !entryKind.isEmpty else {
            return nil
        }
        return entryKind
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
        // The app's format, not `isoNow()`'s — see `syncInboxTimestamp`: this
        // stamp is later compared against a cutoff in the merged-row sweep, and
        // every other timestamp in this table carries fractional seconds.
        let now = Self.syncInboxTimestamp(Date())
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
        // Both cutoffs use the table's one format (`syncInboxTimestamp`), so the
        // `<` is exact against `applied_at` (written here) and against
        // `received_at` (written by the app) alike.
        let cutoff = Self.syncInboxTimestamp(now.addingTimeInterval(-Self.syncInboxRetentionSeconds))
        try execute(
            "DELETE FROM agent_memory_inbox WHERE applied_at IS NOT NULL AND applied_at < ?",
            [.text(cutoff)]
        )
        let staleCutoff = Self.syncInboxTimestamp(now.addingTimeInterval(-Self.syncInboxUnappliedRetentionSeconds))
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
    ///
    /// Scoped to the consent marker's member, like every other statement in this
    /// file: a forget arrives from one member's engine and must not reach into
    /// another member's parked rows on a shared Mac.
    ///
    /// The one deliberate difference from `syncInboxList` / `syncInboxAck` is
    /// what happens with NO marker. Those two fail closed by handing over
    /// nothing, because reading and acknowledging are the directions that leak.
    /// A DELETE has no such direction — refusing to delete is what leaves
    /// readable plaintext behind — so with no marker the forget still reaches
    /// every row carrying the id. It costs nothing in scope terms: an engine
    /// memory id is a random 128-bit label, so a row that carries the id being
    /// forgotten is a copy of that same memory whoever parked it.
    func deleteSyncInboxRows(engineMemoryIDs: [String]) throws {
        let ids = Array(Set(engineMemoryIDs.filter { !$0.isEmpty })).sorted().prefix(1_000)
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        guard let consentUserID = memoryDeviceSyncConsentUserID() else {
            try execute(
                "DELETE FROM agent_memory_inbox WHERE engine_memory_id IN (\(placeholders))",
                ids.map { .text($0) }
            )
            return
        }
        try execute(
            "DELETE FROM agent_memory_inbox WHERE user_id = ? AND engine_memory_id IN (\(placeholders))",
            [.text(consentUserID)] + ids.map { .text($0) }
        )
    }
}
