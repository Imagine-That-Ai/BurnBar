import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - Remote Sync Watermark Record

/// A database record representing remote sync watermark state for a specific
/// account and collection scope.
///
/// Used for tracking incremental sync progress and enabling durable,
/// account-safe watermark behavior.
///
/// VAL-PERSIST-010: Watermark advances only after successful commit.
/// VAL-PERSIST-011: Watermark scope is account-aware and collection-safe.
struct RemoteSyncWatermarkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "remote_sync_watermarks"

    /// The Firebase auth UID of the account.
    let accountUid: String

    /// The collection kind this watermark tracks: "usage", "conversations", "chat_threads".
    let collectionKind: String

    /// The last successful sync timestamp - watermark for next query.
    var lastSyncedAt: Date

    /// The most recent `updatedAt` from remote that was successfully processed.
    /// Used to resume without missing rows after partial failures.
    var lastProcessedRemoteUpdateAt: Date?

    /// Monotonically increasing version for optimistic concurrency.
    var version: Int

    enum CodingKeys: String, CodingKey {
        case accountUid
        case collectionKind
        case lastSyncedAt
        case lastProcessedRemoteUpdateAt
        case version
    }
}

// MARK: - Remote Sync Collection Kind

/// Kinds of collections that have independent watermark tracking.
enum RemoteSyncCollectionKind: String, CaseIterable {
    case usage = "usage"
    case conversations = "conversations"
    case chatThreads = "chat_threads"
    /// Memory Blind Sync: the member's own sealed memory facts, pulled back down
    /// above this watermark by `MemoryCloudPullService`.
    case memoryFacts = "memory_facts"
    /// Memory Blind Sync: the forget receipts that retire a fact on the devices
    /// that already merged it.
    ///
    /// Its OWN cursor, not the facts one, because the two collections are
    /// ordered by different fields written at different moments — a receipt
    /// carries `replicatedAt`, a fact `updatedAt` — and a shared cursor would
    /// let either channel skip the other's documents.
    case memoryForgetReceipts = "memory_forget_receipts"

    /// All collection kinds for iteration.
    static var allCases: [RemoteSyncCollectionKind] {
        [.usage, .conversations, .chatThreads, .memoryFacts, .memoryForgetReceipts]
    }

    /// How far back a FIRST sync of this collection reaches when no watermark
    /// exists yet.
    ///
    /// The conversation-shaped collections keep the 90-day cutoff
    /// `CloudSyncService` has always used: a transcript is an event, it belongs
    /// to the moment it happened, and old ones are not worth a cold backfill.
    ///
    /// **Memory facts are not events.** A memory's `updatedAt` is when it was
    /// last *touched*, not when it stopped being true — a stable preference
    /// learned two years ago and never edited since is still the memory the
    /// member most wants on their new Mac. A 90-day floor silently delivered a
    /// new device only the memories that happened to have been edited recently,
    /// which is the opposite of the feature's headline promise, and it did so
    /// without a single error. So the first sync of `memory_facts` reaches back
    /// past any plausible store, and every later sync is bounded by the durable
    /// watermark exactly as before.
    ///
    /// `memory_forget_receipts` shares that floor for the same reason from the
    /// other side: a receipt says "this fact is gone", and a device that merged
    /// the fact years ago still needs the retirement. Receipts are tiny and
    /// applying one twice is a no-op, so a full first pass is cheap.
    var firstSyncFloor: Date {
        switch self {
        case .usage, .conversations, .chatThreads:
            return Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        case .memoryFacts, .memoryForgetReceipts:
            return Date(timeIntervalSince1970: 0)
        }
    }
}

// MARK: - Remote Sync Watermark Store

/// Stores durable remote sync watermark state per account and collection scope.
///
/// Watermark advancement semantics:
/// - Advances ONLY after successful sync transaction commit (VAL-PERSIST-010)
/// - Per-account scope prevents cross-account pollution (VAL-PERSIST-011)
/// - Per-collection kind allows independent sync cursors
final class RemoteSyncWatermarkStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Read

    /// Fetches the current watermark for a specific account and collection.
    /// Returns nil if no watermark exists yet (fresh sync).
    func fetchWatermark(accountUid: String, collectionKind: RemoteSyncCollectionKind) async throws -> RemoteSyncWatermarkRecord? {
        try await dbQueue.read { db in
            try RemoteSyncWatermarkRecord.fetchOne(db, sql: """
                SELECT * FROM remote_sync_watermarks
                WHERE accountUid = ? AND collectionKind = ?
                """, arguments: [accountUid, collectionKind.rawValue])
        }
    }

    /// Fetches all watermarks for a specific account.
    func fetchAllWatermarks(accountUid: String) async throws -> [RemoteSyncWatermarkRecord] {
        try await dbQueue.read { db in
            try RemoteSyncWatermarkRecord.fetchAll(db, sql: """
                SELECT * FROM remote_sync_watermarks
                WHERE accountUid = ?
                """, arguments: [accountUid])
        }
    }

    /// Fetches the watermark value for a collection, or that collection's own
    /// first-sync floor when none exists yet (`RemoteSyncCollectionKind.firstSyncFloor`
    /// — 90 days for the conversation-shaped collections, the epoch for memory
    /// facts, which are state rather than events).
    func fetchWatermarkOrDefault(accountUid: String, collectionKind: RemoteSyncCollectionKind) async throws -> Date {
        if let watermark = try await fetchWatermark(accountUid: accountUid, collectionKind: collectionKind) {
            return watermark.lastProcessedRemoteUpdateAt ?? watermark.lastSyncedAt
        }
        return collectionKind.firstSyncFloor
    }

    // MARK: - Write

    /// Advances the watermark after successful sync.
    /// This MUST be called only after all items for this collection have been
    /// successfully persisted.
    ///
    /// VAL-PERSIST-010: Watermark advances only after successful commit.
    ///
    /// - Parameters:
    ///   - accountUid: The account UID
    ///   - collectionKind: The collection kind
    ///   - lastProcessedRemoteUpdateAt: The most recent remote `updatedAt` that was processed
    func advanceWatermark(
        accountUid: String,
        collectionKind: RemoteSyncCollectionKind,
        lastProcessedRemoteUpdateAt: Date
    ) async throws {
        let now = Date()
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(accountUid, collectionKind) DO UPDATE SET
                    lastSyncedAt = excluded.lastSyncedAt,
                    lastProcessedRemoteUpdateAt = excluded.lastProcessedRemoteUpdateAt,
                    version = version + 1
                """, arguments: [
                    accountUid,
                    collectionKind.rawValue,
                    now,
                    lastProcessedRemoteUpdateAt
                ])
        }
    }

    /// Clears the watermark for a specific account and collection (forces full re-sync).
    ///
    /// Returns how many rows went, so a caller that rewinds CONDITIONALLY can
    /// tell "there was a cursor and it is now gone" from "there was never one".
    /// The team pull needs that distinction: clearing a row that does not exist
    /// is the same no-op as not clearing it, and reporting the second as a
    /// rewind would put a rewind in the log of every first-ever cycle.
    @discardableResult
    func clearWatermark(accountUid: String, collectionKind: RemoteSyncCollectionKind) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM remote_sync_watermarks
                WHERE accountUid = ? AND collectionKind = ?
                """, arguments: [accountUid, collectionKind.rawValue])
            return db.changesCount
        }
    }

    /// Clears all watermarks for a specific account (e.g., on account switch).
    func clearAllWatermarks(accountUid: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM remote_sync_watermarks
                WHERE accountUid = ?
                """, arguments: [accountUid])
        }
    }

    /// Clears all watermarks for all accounts (full reset).
    func clearAllWatermarks() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM remote_sync_watermarks")
        }
    }

    // MARK: - Team memory PUSH watermark (memory program D16 / P22, PR 3)

    /// The `collectionKind` of the team lane's PUSH watermark.
    ///
    /// Deliberately NOT a `RemoteSyncCollectionKind` case, for the same reason
    /// `BurnBarMemoryDeviceSyncMarker.collectionKind` is not one: nothing PULLS
    /// a collection by this name, so the sync code must never iterate it. It
    /// rides on `remote_sync_watermarks` under the SAME `accountUid` as the team
    /// lane's pull cursor (`TeamMemoryPullService.watermarkAccountKey` —
    /// `team:<teamId>:<uid>`), which is what makes it per-team AND per-member
    /// without a new table and without a migration across the eight schema
    /// surfaces a new table would touch.
    ///
    /// WHY A SIBLING ROW RATHER THAN A COLUMN ON THE PULL CURSOR'S ROW. The row
    /// has exactly five columns and none of them is free: `lastProcessedRemoteUpdateAt`
    /// IS the pull cursor, and `lastSyncedAt` is rewritten to `Date()` by every
    /// `advanceWatermark` — i.e. by every successful PULL — so a push instant
    /// stored there would be dragged forward by unrelated pull traffic and would
    /// then declare edited memories clean. A sibling row keyed on the same
    /// account is the only place the instant survives, short of a migration.
    static let teamMemoryPushCollectionKind = "memory_facts_team_push"

    /// The instant the last COMPLETE, failure-free team push pass finished for
    /// this `(team, member)`, or nil when no such pass has ever run.
    ///
    /// nil means "consider everything", which is exactly right: a first cycle, a
    /// re-opted-in team and an account switch that dropped the row all want the
    /// full pass they would have got before this watermark existed.
    func fetchTeamMemoryPushInstant(accountUid: String) async throws -> Date? {
        try await dbQueue.read { db in
            try Date.fetchOne(db, sql: """
                SELECT lastProcessedRemoteUpdateAt FROM remote_sync_watermarks
                WHERE accountUid = ? AND collectionKind = ?
                """, arguments: [accountUid, Self.teamMemoryPushCollectionKind])
        }
    }

    /// Records a completed team push pass. Called ONLY when every document the
    /// pass touched resolved (uploaded, converged or skipped as stale) — one
    /// failed document leaves the watermark where it was, so the next cycle
    /// reconsiders the whole set rather than stranding the failure below a bar
    /// it can never rise above.
    func recordTeamMemoryPushInstant(accountUid: String, instant: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(accountUid, collectionKind) DO UPDATE SET
                    lastSyncedAt = excluded.lastSyncedAt,
                    lastProcessedRemoteUpdateAt = excluded.lastProcessedRemoteUpdateAt,
                    version = version + 1
                """, arguments: [
                    accountUid,
                    Self.teamMemoryPushCollectionKind,
                    instant,
                    instant
                ])
        }
    }

    /// Drops the push watermark of every team this member is NOT currently
    /// opted into, and returns how many rows went.
    ///
    /// WHY OPT-OUT INVALIDATES, rather than leaving a harmless stale row.
    /// A push watermark means "everything eligible as of then was resolved",
    /// and that sentence is only true while the member is still contributing.
    /// The moment a team is switched off, this Mac stops evaluating that team's
    /// eligible set — memories are edited, retired, `.openburnbar/project.json`
    /// gains or loses the link — and the row goes on asserting a resolution
    /// nobody performed. Re-opting in above it would then push only what was
    /// edited during the OFF period and silently skip everything that was
    /// already clean, which is the one failure mode the whole bound was designed
    /// not to have: a member who believes they are sharing and is not.
    /// Invalidating costs one full pass on re-opt-in, which is exactly what a
    /// first opt-in costs, and `fetchTeamMemoryPushInstant` already documents
    /// nil as "consider everything".
    ///
    /// This is the personal lane's EAGER-PURGE precedent applied to the team
    /// one: `MemoryDeviceSyncInboxGuard` acts on consent "wherever the state is
    /// observed" rather than waiting for a pull that consent has just forbidden,
    /// and the team cycle is where the opted-in set is observed. It is the same
    /// invalidation the account-switch path already performs through
    /// `ControlPlaneStore.dropMemoryInboxCursors`, on the narrower trigger.
    ///
    /// The tail comparison is `substr`, never `LIKE 'team:%:' || uid`, for the
    /// reason `ControlPlaneStore+MemorySyncInbox.accountInboxCursorPredicate`
    /// spells out: `LIKE` would read `_` and `%` inside a uid as wildcards and
    /// match another member's row. The read runs first so that the steady state
    /// — nothing to drop — costs no write transaction at all.
    @discardableResult
    func dropTeamMemoryPushWatermarks(
        localUserID: String,
        keepingTeamIDs teamIDs: Set<String>
    ) async throws -> Int {
        try await dropTeamMemoryRows(
            localUserID: localUserID,
            keepingTeamIDs: teamIDs,
            kindPredicate: "collectionKind = ?",
            kindArguments: [Self.teamMemoryPushCollectionKind]
        )
    }

    // MARK: - Team memory PROJECT-LINK record (memory program D16 / P22, PR 3)

    /// The `collectionKind` prefix of the team lane's PROJECT-LINK record.
    ///
    /// One row per `(team, member, linked teamProjectId)`:
    /// `accountUid = "team:<teamId>:<uid>"` — the same account key as the pull
    /// cursor and the push watermark — and
    /// `collectionKind = "memory_facts_team_link:<teamProjectId>"`.
    ///
    /// WHAT IT RECORDS AND WHY IT EXISTS. `TeamMemoryPullRejection.projectNotLinkedToTeam`
    /// is PERMANENT: a fact whose sealed `teamProjectId` is not linked to this
    /// checkout is refused and the cursor moves past it, because freezing would
    /// let one repository nobody on this Mac has cloned stall every OTHER
    /// project's team facts. That is the right call and it has a cost — the
    /// documents refused before the link existed are behind the cursor for ever
    /// — and this record is what pays it: the pull compares the set of links it
    /// sees NOW against the set it saw at the last successful pull, and a set
    /// that has GAINED an id rewinds that team's cursor so the refused documents
    /// are re-scanned. Refused-until-linked, recovered on link.
    ///
    /// WHY ONE ROW PER PROJECT RATHER THAN A HASH OF THE SET. The rule is a
    /// SUPERSET test, not an equality test: gaining a link must rewind, losing
    /// one must not (nothing became readable, and a rewind would re-read the
    /// whole collection to refuse the same documents again). A hash says only
    /// "changed", which cannot tell those two apart. The id is already bounded
    /// to `TeamMemorySyncService.teamProjectIDPattern`
    /// (`^[A-Za-z0-9_.:-]{1,128}$`) at both ends of the lane, so it is a safe,
    /// self-describing key rather than an opaque digest.
    ///
    /// THESE ROWS ARE NOT CURSORS. `lastProcessedRemoteUpdateAt` is deliberately
    /// NULL and nothing reads it: a link record answers "was this project linked
    /// last time", never "how far did we get". `lastSyncedAt` is NOT NULL in the
    /// schema, so it carries the instant the record was written and is used for
    /// nothing else. Every predicate that means "an inbox cursor" names its
    /// kinds exactly (`ControlPlaneStore.memoryInboxCursorKinds`), so no rewind
    /// or advance can reach these rows by accident.
    static let teamMemoryProjectLinkKindPrefix = "memory_facts_team_link:"

    /// The `collectionKind` of one linked project's record.
    static func teamMemoryProjectLinkCollectionKind(teamProjectID: String) -> String {
        teamMemoryProjectLinkKindPrefix + teamProjectID
    }

    /// The exact-prefix SQL predicate for those rows.
    ///
    /// `substr(collectionKind, 1, ?) = ?`, never `LIKE 'memory_facts_team_link:%'`:
    /// the prefix contains four underscores and `LIKE` reads `_` as a
    /// single-character wildcard, so the `LIKE` form would also match a kind
    /// that merely happened to have the same shape. The account-key predicates
    /// elsewhere in this file get away with `LIKE 'team:%'` only because that
    /// literal has no wildcard characters in it.
    static let teamMemoryProjectLinkKindPredicate = "substr(collectionKind, 1, ?) = ?"

    private static var teamMemoryProjectLinkKindArguments: [any DatabaseValueConvertible] {
        [teamMemoryProjectLinkKindPrefix.count, teamMemoryProjectLinkKindPrefix]
    }

    /// The `teamProjectId`s that were linked to this `(team, member)` at the
    /// last successful pull, or an empty set when none were — which is also what
    /// a first-ever cycle reads.
    ///
    /// Empty needs no sentinel: the rule is "does the CURRENT set contain an id
    /// this does not", and against an empty record a non-empty current set
    /// rewinds a cursor that, on a genuinely first cycle, does not exist yet.
    /// `clearWatermark` reports that as zero rows and the pull calls it no
    /// rewind.
    func fetchTeamMemoryLinkedProjectIDs(accountUid: String) async throws -> Set<String> {
        let kinds: [String] = try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT collectionKind FROM remote_sync_watermarks
                WHERE accountUid = ? AND \(Self.teamMemoryProjectLinkKindPredicate)
                """, arguments: StatementArguments(([accountUid] as [any DatabaseValueConvertible]) + Self.teamMemoryProjectLinkKindArguments))
        }
        return Set(kinds.map { String($0.dropFirst(Self.teamMemoryProjectLinkKindPrefix.count)) })
    }

    /// Replaces the record with exactly `projectIDs`.
    ///
    /// A REPLACE rather than an insert-only merge, so that unlinking is recorded
    /// too: an id that leaves the file leaves the record, and re-adding it later
    /// is a gain again and rewinds again. Called only after a pull COMMITTED —
    /// a pull that threw leaves the record where it was, so the next cycle can
    /// still decide to rewind.
    func replaceTeamMemoryLinkedProjectIDs(
        accountUid: String,
        projectIDs: Set<String>,
        now: Date = Date()
    ) async throws {
        let sorted = projectIDs.sorted()
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM remote_sync_watermarks
                WHERE accountUid = ? AND \(Self.teamMemoryProjectLinkKindPredicate)
                """,
                arguments: StatementArguments(([accountUid] as [any DatabaseValueConvertible]) + Self.teamMemoryProjectLinkKindArguments)
            )
            for projectID in sorted {
                try db.execute(sql: """
                    INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
                    VALUES (?, ?, ?, NULL, 1)
                    """, arguments: [
                        accountUid,
                        Self.teamMemoryProjectLinkCollectionKind(teamProjectID: projectID),
                        now
                    ])
            }
        }
    }

    /// Drops the link record of every team this member is NOT currently opted
    /// into, and returns how many rows went.
    ///
    /// The same invalidation, and the same trigger, as
    /// `dropTeamMemoryPushWatermarks`: while a team is switched off this Mac
    /// stops observing that team's links, so the record goes on asserting an
    /// observation nobody made. Dropping it means the next opt-in reads an empty
    /// record, treats whatever is linked then as a gain, and rewinds once —
    /// which is exactly the full pass a first opt-in gets, and is the only
    /// answer that cannot silently strand documents refused during the OFF
    /// period.
    @discardableResult
    func dropTeamMemoryProjectLinkRecords(
        localUserID: String,
        keepingTeamIDs teamIDs: Set<String>
    ) async throws -> Int {
        try await dropTeamMemoryRows(
            localUserID: localUserID,
            keepingTeamIDs: teamIDs,
            kindPredicate: Self.teamMemoryProjectLinkKindPredicate,
            kindArguments: Self.teamMemoryProjectLinkKindArguments
        )
    }

    // MARK: - Team memory PULL cursor (memory program D16 / P22, PR 3)

    /// Drops the PULL cursor of every team this member is NOT currently opted
    /// into, and returns how many rows went.
    ///
    /// The third of the three team records, and the one whose absence made the
    /// other two a half-measure. The cursor is
    /// `collectionKind = memory_facts` under the team account key
    /// (`TeamMemoryPullService.watermarkAccountKey`), and it means "every
    /// document at or below this instant has been considered".
    ///
    /// WHY IT MUST GO WITH THE OTHER TWO. The scan filter is strictly
    /// greater-than, so a surviving cursor is a floor on everything a later
    /// pull can ever see. While a team is switched off, teammates go on writing
    /// facts and the cloud's `updatedAt`s go on climbing; NONE of that reaches
    /// this Mac, because the opted-out cycle does not pull. Re-opting in above
    /// the stale cursor would resume from where the last OFF-period cycle
    /// stopped — which is where the member's own last ON cycle stopped — so
    /// every fact written during the OFF period whose `updatedAt` happens to
    /// sort below it is skipped for ever. And unlike the push side, nothing
    /// re-offers those documents: the cloud will not rewrite them, and the
    /// link-record rewind only fires when a PROJECT LINK is gained, which a
    /// re-join need not involve at all.
    ///
    /// Dropping it costs one full re-scan of the team space on re-opt-in, which
    /// is exactly what a first opt-in costs (`RemoteSyncCollectionKind.memoryFacts.firstSyncFloor`
    /// is the epoch, because a team fact is state rather than an event), and
    /// parking is idempotent on `(doc_id, remote_updated_at)` so the re-scan
    /// costs reads and nothing else.
    ///
    /// NOT `clearAllWatermarks(accountUid:)` on the team key, even though the
    /// three kinds are today the only things that ride there: naming the kind
    /// keeps this drop honest if a fourth kind is ever parked on that key, the
    /// same way `ControlPlaneStore.memoryInboxCursorKinds` names its kinds
    /// exactly rather than deleting by account.
    ///
    /// The PERSONAL `memory_facts` cursor is untouched by construction: its
    /// `accountUid` is the bare uid, and `dropTeamMemoryRows` matches only rows
    /// whose account key begins `team:` AND ends `:<uid>`.
    @discardableResult
    func dropTeamMemoryPullCursors(
        localUserID: String,
        keepingTeamIDs teamIDs: Set<String>
    ) async throws -> Int {
        try await dropTeamMemoryRows(
            localUserID: localUserID,
            keepingTeamIDs: teamIDs,
            kindPredicate: "collectionKind = ?",
            kindArguments: [RemoteSyncCollectionKind.memoryFacts.rawValue]
        )
    }

    // MARK: - Eager team invalidation (memory program D16 / P22, PR 3)

    /// Drops ALL THREE of one team's records for this member — pull cursor,
    /// push watermark and project-link record — in a single write, and returns
    /// how many rows went.
    ///
    /// The EAGER form of what an opted-out cycle does lazily. The three
    /// `dropTeamMemory*` helpers above are keyed on "every team NOT in the
    /// opted-in set", which is the right shape for a cycle that reads the set
    /// and the wrong shape for a UI that has just acted on ONE team: leaving a
    /// team should invalidate at the moment the member leaves, not at whatever
    /// point in the next ten minutes the refresh cadence happens to land. This
    /// takes the team by name and compares the account key EXACTLY, so no
    /// wildcard reasoning is needed at all — another member's rows and every
    /// other team's rows are outside the key.
    ///
    /// It is an optimisation over the cycle-time drop, never a replacement for
    /// it: a call that never happens (a crash between leaving and the drop, an
    /// opt-out written by some future path that forgets to call this) still
    /// gets its invalidation from `TeamMemorySyncDomain.runCycle`, which
    /// observes the opted-in set every cycle. Idempotent, and a no-op costing
    /// one write on a team that has no records.
    @discardableResult
    func invalidateTeamMemoryRecords(
        teamID: String,
        localUserID: String
    ) async throws -> Int {
        guard !teamID.isEmpty, !localUserID.isEmpty else { return 0 }
        let accountUid = TeamMemoryPullService.watermarkAccountKey(
            teamID: teamID,
            localUserID: localUserID
        )
        let arguments: [any DatabaseValueConvertible] = [
            accountUid,
            RemoteSyncCollectionKind.memoryFacts.rawValue,
            Self.teamMemoryPushCollectionKind
        ] + Self.teamMemoryProjectLinkKindArguments
        return try await dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM remote_sync_watermarks
                WHERE accountUid = ?
                  AND (collectionKind = ?
                       OR collectionKind = ?
                       OR \(Self.teamMemoryProjectLinkKindPredicate))
                """,
                arguments: StatementArguments(arguments)
            )
            return db.changesCount
        }
    }

    /// Deletes this member's `team:<teamId>:<uid>` rows of one kind shape for
    /// every team outside `teamIDs`.
    ///
    /// The tail comparison is `substr`, never `LIKE 'team:%:' || uid`, for the
    /// reason `ControlPlaneStore+MemorySyncInbox.accountInboxCursorPredicate`
    /// spells out: `LIKE` would read `_` and `%` inside a uid as wildcards and
    /// match another member's row. The read runs first so that the steady state
    /// — nothing to drop — costs no write transaction at all.
    private func dropTeamMemoryRows(
        localUserID: String,
        keepingTeamIDs teamIDs: Set<String>,
        kindPredicate: String,
        kindArguments: [any DatabaseValueConvertible]
    ) async throws -> Int {
        guard !localUserID.isEmpty else { return 0 }
        let keep = Set(teamIDs.map {
            TeamMemoryPullService.watermarkAccountKey(teamID: $0, localUserID: localUserID)
        })
        let mine: [String] = try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT accountUid FROM remote_sync_watermarks
                WHERE \(kindPredicate)
                  AND accountUid LIKE 'team:%'
                  AND substr(accountUid, -(length(?) + 1)) = ':' || ?
                """, arguments: StatementArguments(kindArguments + ([localUserID, localUserID] as [any DatabaseValueConvertible])))
        }
        let stale = mine.filter { !keep.contains($0) }
        guard !stale.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: stale.count).joined(separator: ", ")
        return try await dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM remote_sync_watermarks
                WHERE \(kindPredicate) AND accountUid IN (\(placeholders))
                """,
                arguments: StatementArguments(kindArguments + (stale as [any DatabaseValueConvertible]))
            )
            return db.changesCount
        }
    }
}

// MARK: - Atomic Remote Sync Transaction

/// Represents an atomic remote sync operation that couples sync work with
/// durable watermark advancement.
///
/// VAL-PERSIST-010: Watermark advances only after successful commit.
final class AtomicRemoteSyncTransaction {
    private let dbQueue: any DatabaseWriter
    private let watermarkStore: RemoteSyncWatermarkStore
    private let accountUid: String
    private let collectionKind: RemoteSyncCollectionKind

    private var processedItems: Int = 0
    private var latestRemoteUpdateAt: Date?
    private var isCommitted: Bool = false

    init(
        dbQueue: any DatabaseWriter,
        watermarkStore: RemoteSyncWatermarkStore,
        accountUid: String,
        collectionKind: RemoteSyncCollectionKind
    ) {
        self.dbQueue = dbQueue
        self.watermarkStore = watermarkStore
        self.accountUid = accountUid
        self.collectionKind = collectionKind
    }

    /// Records that an item was successfully processed.
    /// Tracks the latest remote `updatedAt` seen.
    func recordProcessedItem(remoteUpdatedAt: Date) {
        processedItems += 1
        if latestRemoteUpdateAt == nil || remoteUpdatedAt > latestRemoteUpdateAt! {
            latestRemoteUpdateAt = remoteUpdatedAt
        }
    }

    /// Commits the transaction and advances the watermark.
    /// This is the ONLY place where watermark advances.
    ///
    /// VAL-PERSIST-010: Watermark advances only after successful commit.
    func commit() async throws {
        guard !isCommitted else { return }
        guard let latestUpdate = latestRemoteUpdateAt else {
            // No items processed - still commit but don't advance watermark
            isCommitted = true
            return
        }

        try await watermarkStore.advanceWatermark(
            accountUid: accountUid,
            collectionKind: collectionKind,
            lastProcessedRemoteUpdateAt: latestUpdate
        )
        isCommitted = true
    }

    /// Abandons the transaction without advancing the watermark.
    /// On next sync, we'll re-fetch from the previous watermark.
    func rollback() {
        guard !isCommitted else { return }
        processedItems = 0
        latestRemoteUpdateAt = nil
    }

    var wasCommitted: Bool { isCommitted }
    var processedCount: Int { processedItems }
    var latestUpdate: Date? { latestRemoteUpdateAt }
}

extension DataStore {
    func fetchRemoteSyncWatermark(
        accountUid: String,
        collectionKind: RemoteSyncCollectionKind
    ) async throws -> RemoteSyncWatermarkRecord? {
        try await actor.remoteSyncWatermarkStore.fetchWatermark(accountUid: accountUid, collectionKind: collectionKind)
    }

    func fetchAllRemoteSyncWatermarks(accountUid: String) async throws -> [RemoteSyncWatermarkRecord] {
        try await actor.remoteSyncWatermarkStore.fetchAllWatermarks(accountUid: accountUid)
    }

    func fetchRemoteSyncWatermarkOrDefault(
        accountUid: String,
        collectionKind: RemoteSyncCollectionKind
    ) async throws -> Date {
        try await actor.remoteSyncWatermarkStore.fetchWatermarkOrDefault(
            accountUid: accountUid,
            collectionKind: collectionKind
        )
    }

    func advanceRemoteSyncWatermark(
        accountUid: String,
        collectionKind: RemoteSyncCollectionKind,
        lastProcessedRemoteUpdateAt: Date
    ) async throws {
        try await actor.remoteSyncWatermarkStore.advanceWatermark(
            accountUid: accountUid,
            collectionKind: collectionKind,
            lastProcessedRemoteUpdateAt: lastProcessedRemoteUpdateAt
        )
    }

    func clearRemoteSyncWatermark(accountUid: String, collectionKind: RemoteSyncCollectionKind) async throws {
        try await actor.remoteSyncWatermarkStore.clearWatermark(accountUid: accountUid, collectionKind: collectionKind)
    }

    func clearAllRemoteSyncWatermarks(accountUid: String) async throws {
        try await actor.remoteSyncWatermarkStore.clearAllWatermarks(accountUid: accountUid)
    }

    func clearAllRemoteSyncWatermarks() async throws {
        try await actor.remoteSyncWatermarkStore.clearAllWatermarks()
    }

    nonisolated func makeRemoteSyncTransaction(
        accountUid: String,
        collectionKind: RemoteSyncCollectionKind
    ) -> AtomicRemoteSyncTransaction {
        AtomicRemoteSyncTransaction(
            dbQueue: actor.dbQueue,
            watermarkStore: actor.remoteSyncWatermarkStore,
            accountUid: accountUid,
            collectionKind: collectionKind
        )
    }
}
