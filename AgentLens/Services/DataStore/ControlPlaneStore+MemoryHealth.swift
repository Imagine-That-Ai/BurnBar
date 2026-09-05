import Foundation
@preconcurrency import GRDB
import OpenBurnBarKernel

// MARK: - App-producible memory-health inputs

/// One link of the `memory_audit` hash chain: the seq it sits at, the hash it
/// claims its predecessor had, and its own hash.
struct MemoryAuditChainLink: Equatable, Sendable {
    let seq: Int
    let prevHash: String?
    let hash: String
}

/// A project the DAEMON has already recorded in `pcm_projects`.
///
/// The health card exists to report on a project, and the only projects that
/// exist are the ones the daemon's indexer already registered. The app reads
/// that registry directly — the daemon indexes into the app's own
/// `openburnbar.sqlite`, so `pcm_projects` is right here — and reads it
/// READ-ONLY: `daemon.memory.analytics` resolves its `projectPath` through the
/// WRITING resolver (`BurnBarProjectCodeMemoryStore.resolveProjectIdentity`,
/// which INSERTs into `pcm_projects` and upserts `pcm_project_aliases`), so
/// asking about anything the registry does not already hold would MAKE a
/// project rather than measure one. Passing no path at all is worse: the daemon
/// falls back to `FileManager.default.currentDirectoryPath`, which its
/// LaunchAgent pins to its own support directory, and the card would then render
/// that directory's zero as a measurement of your project.
struct MemoryHealthProject: Equatable, Identifiable, Sendable {
    /// `pcm_projects.project_id`.
    let id: String
    /// `pcm_projects.project_name`.
    let name: String
    /// `pcm_projects.primary_path` — the canonical root the DAEMON itself
    /// recorded. Handing this exact string back to `daemon.memory.analytics`
    /// makes its resolver hit the existing fingerprint/alias and register
    /// nothing new.
    let recordedRoot: String
    /// `pcm_projects.updated_at`, the ordering key for "most recently written".
    let lastWrittenAt: String
}

/// The device-sync consent marker as every reader in the tree agrees to read
/// it: exactly one row, or nothing.
///
/// `BurnBarProjectMemoryContracts` states the rule — "Anything ambiguous — the
/// table missing, no row, **more than one row**, an unreadable stamp — is also
/// nothing (fail closed)" — and the daemon
/// (`BurnBarProjectCodeMemoryStore+SyncInbox.memoryDeviceSyncConsentUserID`)
/// enforces it by counting BEFORE it looks at freshness. This app target has
/// exactly one implementation of the same rule —
/// `ControlPlaneStore.memoryDeviceSyncMarkerReading` — and every app reader
/// goes through it, the drain's own `fetchMemoryDeviceSyncMarkerUserID`
/// included. A reporting surface that picked the newest of two rows would tell
/// a member "consent marker: just now" in the exact state the daemon is
/// refusing to drain, so this type has no way to express a winner: an
/// ambiguous table reads as `absent`.
struct MemoryDeviceSyncMarkerReading: Equatable, Sendable {
    /// The member the single marker row names. Nil whenever the table is
    /// ambiguous — no row, or more than one — which is what the daemon reads
    /// as no consent.
    let accountUid: String?

    /// When that single row was last refreshed. Nil in the same states, so an
    /// absent reading can never be aged.
    let refreshedAt: Date?

    /// No consent: no row, or an ambiguous table.
    static let absent = MemoryDeviceSyncMarkerReading(accountUid: nil, refreshedAt: nil)

    /// Whether this marker names somebody OTHER than `accountUid`.
    ///
    /// The marker is unscoped by design — it is the claim about *which* member
    /// consents — so every surface that reports it as "your" consent has to
    /// compare. Written once here so the health card and the sync-status row
    /// cannot drift into disagreeing about whose marker they are looking at:
    /// on a shared Mac the card would otherwise age (and warn about) another
    /// member's marker while the row directly beneath it says "Another member".
    ///
    /// An absent reading is never a mismatch — it is already the no-consent
    /// answer. A nil `accountUid` (nobody signed in) is not a mismatch either:
    /// there is no account to contradict, and the surfaces render a signed-out
    /// Mac's marker exactly as they did before this comparison existed.
    func namesAnotherMember(than accountUid: String?) -> Bool {
        guard let markerAccount = self.accountUid, let accountUid else { return false }
        return markerAccount != accountUid
    }

    /// The refresh stamp, but only when the marker is THIS account's consent.
    ///
    /// Fails closed on a mismatch: a surface that judges freshness must not
    /// judge a marker it does not own, and nil is the same value it would see
    /// for an absent marker — which is already "not consented here, not a
    /// fault".
    func refreshedAt(forAccount accountUid: String?) -> Date? {
        namesAnotherMember(than: accountUid) ? nil : refreshedAt
    }
}

/// Everything the health card can measure WITHOUT the engine.
///
/// Deliberately no doctor findings: `burnbar_memory_doctor` runs inside the
/// engine, against the engine's own store, and nothing in this process can run
/// it. The card says so rather than presenting an absence as a clean bill.
struct MemoryHealthLocalSnapshot: Equatable, Sendable {
    /// The tail of the audit chain, oldest first. Bounded — see
    /// `ControlPlaneStore.memoryAuditChainWindow` — so opening Settings never
    /// walks an unbounded ledger.
    let auditChainLinks: [MemoryAuditChainLink]
    /// Rows still waiting for a human in the review inbox.
    let pendingReviewCount: Int
    /// When this Mac last completed a `memory_facts` pull — `lastSyncedAt`, not
    /// `lastProcessedRemoteUpdateAt`. The latter is the newest REMOTE fact time
    /// this Mac has processed, so a Mac that pulls every cycle and learns nothing
    /// new would render "Last pull: 30 d ago" while syncing perfectly.
    let lastMemoryFactsPullAt: Date?
    /// When THIS account's device-sync consent marker was last rewritten. Nil
    /// when device sync is not consented on this Mac — which includes an
    /// ambiguous marker table (what the daemon reads as no consent too) and a
    /// marker naming another member of a shared Mac, which is that member's
    /// consent and not this one's. Not a fault in any of those cases.
    let deviceSyncMarkerRefreshedAt: Date?
}

extension ControlPlaneStore {

    // MARK: - Shared memory reads
    //
    // Every app-side reader of `remote_sync_watermarks` for memory goes through
    // here: the health card, the sync-status row, and the drain's own consent
    // check (`fetchMemoryDeviceSyncMarkerUserID`). Written once so a change to
    // the marker doctrine cannot be applied to one caller and missed on the
    // others.

    /// `remote_sync_watermarks.lastSyncedAt` for one collection kind, scoped to
    /// one member.
    ///
    /// `lastSyncedAt` and deliberately not `lastProcessedRemoteUpdateAt`: the
    /// latter is the newest REMOTE instant this Mac has processed, so it ages
    /// with the member's other devices rather than with this one's syncing, and
    /// a Mac that pulls every cycle and learns nothing new would render "30 d
    /// ago" while syncing perfectly.
    ///
    /// Nil `accountUid` (nobody signed in) yields nil — absent, not zero.
    static func memoryRemoteSyncWatermark(
        _ db: Database,
        accountUid: String?,
        kind: RemoteSyncCollectionKind
    ) throws -> Date? {
        guard let accountUid else { return nil }
        return try Date.fetchOne(
            db,
            sql: """
            SELECT lastSyncedAt FROM remote_sync_watermarks
            WHERE accountUid = ? AND collectionKind = ?
            """,
            arguments: [accountUid, kind.rawValue]
        )
    }

    /// The device-sync consent marker, read the way the daemon reads it.
    ///
    /// `LIMIT 2` and then `count == 1`, counted BEFORE anything looks at the
    /// stamp, so an ambiguous table (two markers, one of them fresh) reads as
    /// no consent rather than picking a winner. This is the app target's ONLY
    /// implementation of that rule — `fetchMemoryDeviceSyncMarkerUserID` reads
    /// through it — and it mirrors the daemon's separate-target copy in
    /// `BurnBarProjectCodeMemoryStore.memoryDeviceSyncConsentUserID`.
    ///
    /// Read UNSCOPED on purpose: the marker is the app's claim about WHICH
    /// member consents, so filtering it by an assumed member would beg the
    /// question it exists to answer. The member it names comes back on the
    /// reading instead, so a caller that wants to compare can.
    static func memoryDeviceSyncMarkerReading(_ db: Database) throws -> MemoryDeviceSyncMarkerReading {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT \(BurnBarMemoryDeviceSyncMarker.accountColumn),
                   \(BurnBarMemoryDeviceSyncMarker.refreshedAtColumn)
            FROM \(BurnBarMemoryDeviceSyncMarker.tableName)
            WHERE \(BurnBarMemoryDeviceSyncMarker.kindColumn) = ?
            LIMIT 2
            """,
            arguments: [BurnBarMemoryDeviceSyncMarker.collectionKind]
        )
        guard rows.count == 1, let row = rows.first else { return .absent }
        return MemoryDeviceSyncMarkerReading(
            accountUid: row[BurnBarMemoryDeviceSyncMarker.accountColumn],
            refreshedAt: row[BurnBarMemoryDeviceSyncMarker.refreshedAtColumn]
        )
    }

    /// How many audit links the health check walks. The chain is global rather
    /// than per-memory, so an unbounded walk would grow without limit; the check
    /// is honest about being a tail check.
    static let memoryAuditChainWindow = 500

    /// How many recorded projects the card offers to pick between.
    static let memoryHealthProjectLimit = 25

    /// Lists the projects the daemon has already recorded, most recently written
    /// first. READ-ONLY by construction: a plain `SELECT` on the shared
    /// database, never a resolve.
    ///
    /// An empty result means the daemon has never indexed a project on this Mac.
    /// That is not "a project with zero memories" — there is no project — so the
    /// card says so and issues no RPC at all.
    func memoryHealthProjects(limit: Int = ControlPlaneStore.memoryHealthProjectLimit) async throws -> [MemoryHealthProject] {
        let cappedLimit = max(1, min(limit, Self.memoryHealthProjectLimit))
        return try await dbQueue.read { db -> [MemoryHealthProject] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT project_id, project_name, primary_path, updated_at
                FROM pcm_projects
                ORDER BY updated_at DESC, project_id ASC
                LIMIT ?
                """,
                arguments: [cappedLimit]
            ).compactMap { row in
                guard let id: String = row["project_id"],
                      let root: String = row["primary_path"],
                      root.isEmpty == false else { return nil }
                return MemoryHealthProject(
                    id: id,
                    name: row["project_name"] ?? id,
                    recordedRoot: root,
                    lastWrittenAt: row["updated_at"] ?? ""
                )
            }
        }
    }

    /// Reads every health input the app can produce on its own.
    ///
    /// - Parameter accountUid: the signed-in member, for the `memory_facts`
    ///   watermark. Nil when nobody is signed in — the pull age is then simply
    ///   absent, which the card renders as "—" rather than as "never".
    func memoryHealthLocalSnapshot(accountUid: String?) async throws -> MemoryHealthLocalSnapshot {
        try await dbQueue.read { db -> MemoryHealthLocalSnapshot in
            // Ordered by seq DESC to take the TAIL, then reversed so the walk
            // reads oldest-first the way the chain was written.
            let linkRows = try Row.fetchAll(
                db,
                sql: """
                SELECT seq, prev_hash, hash
                FROM memory_audit
                ORDER BY seq DESC
                LIMIT ?
                """,
                arguments: [Self.memoryAuditChainWindow]
            )
            let links: [MemoryAuditChainLink] = linkRows.reversed().map { row in
                MemoryAuditChainLink(
                    seq: row["seq"] ?? 0,
                    prevHash: row["prev_hash"],
                    hash: row["hash"] ?? ""
                )
            }

            let pending = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_memories WHERE review_status = 'quarantined'"
            ) ?? 0

            let lastPull = try Self.memoryRemoteSyncWatermark(
                db,
                accountUid: accountUid,
                kind: .memoryFacts
            )
            let marker = try Self.memoryDeviceSyncMarkerReading(db)

            return MemoryHealthLocalSnapshot(
                auditChainLinks: links,
                pendingReviewCount: pending,
                lastMemoryFactsPullAt: lastPull,
                // Scoped to the member this snapshot was read for. A marker
                // naming somebody else is not this account's consent, so the
                // card must neither age it nor raise SYNC_MARKER_STALE about
                // it — the same comparison the sync-status row makes.
                deviceSyncMarkerRefreshedAt: marker.refreshedAt(forAccount: accountUid)
            )
        }
    }
}
