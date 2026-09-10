import Foundation
import OpenBurnBarKernel

// MARK: - Team memory cycle (memory program D16 / P22, PR 3)
//
// One push-then-pull cycle per opted-in team, run by `MemoryCloudSyncDomain`
// AFTER the personal cycle has finished, inside its own nested `do/catch`.
//
// THE ORDERING AND THE NESTING ARE THE FEATURE, not an implementation detail.
// Team memory is a strict subset of personal memory sync (`TeamMemorySyncGate`),
// and the levers that close the personal lane close this one too — so a team
// failure must never be able to undo, block or reorder the personal push and
// pull that already succeeded. Running the team half first, or in the same
// `do/catch`, would have made a roster read against a team the member had left
// capable of stopping their OWN memories from reaching their OWN other Macs.
//
// Two tests pin the two halves of that claim, because the `catch` alone only
// buys one of them. `test_team_sync_failing_closed_does_not_affect_member_sync`
// pins CONTAINMENT — a team throw leaves the personal lane green — and would
// still pass against a reordered cycle, since the `catch` swallows the throw
// wherever it happens. `test_the_team_half_runs_after_the_personal_watermark_has_committed`
// pins the ORDERING, from inside the injected double: it reads the personal
// `remote_sync_watermarks` row at the instant the team half starts, and logs
// that against the personal pull's own return, so hoisting the team half fails
// on both the sequence and the durable state.
//
// It is deliberately NOT a `CloudSyncDomain`. A second domain would be scheduled
// independently of the personal one, and the two would then be able to disagree
// about which member is signed in and what they consented to at any instant —
// which is precisely the class of bug `MemoryDeviceSyncScope.current` exists to
// close. One gate read, one cycle, two halves.

/// What one team's roster says about this member, right now.
///
/// Read live on every cycle rather than cached, for the same reason
/// `firestore.rules` re-reads it on every request: a removal takes effect at the
/// instant the roster changes, not at the next launch.
struct TeamRosterSnapshot: Equatable, Sendable {
    let teamID: String
    /// The generation every write this cycle must seal under. The rules pin
    /// `teamKeyVersion == activeTeamKeyVersion(teamId)`, so a stale value here
    /// produces refused writes rather than unreadable documents.
    let activeKeyVersion: Int
    /// `status == "active"`. `pending` means the joiner's key envelopes have not
    /// been issued yet, and `removed` means they are gone; neither may sync.
    let memberStatusActive: Bool
}

/// Reads `team_rosters/{teamId}` and `.../members/{uid}`. A seam because a unit
/// test cannot drive Firestore, and because the roster is the one input to this
/// lane the client does not own.
protocol TeamRosterReading: Sendable {
    func rosterSnapshot(teamID: String, uid: String) async throws -> TeamRosterSnapshot?
}

/// Production reader, through `CloudSyncFirestoreGateway` — never a raw
/// `Firestore.firestore()` handle (the raw-firestore budget is shrink-only).
struct FirestoreTeamRosterReader: TeamRosterReading {
    let gateway: CloudSyncFirestoreGateway

    func rosterSnapshot(teamID: String, uid: String) async throws -> TeamRosterSnapshot? {
        let teamDocument = gateway
            .collection(TeamVaultKeyDistributor.rosterRootCollection)
            .document(teamID)
        guard let team = try await teamDocument.getData(),
              let activeKeyVersion = team["activeKeyVersion"] as? Int else {
            return nil
        }
        let member = try await teamDocument.collection("members").document(uid).getData()
        return TeamRosterSnapshot(
            teamID: teamID,
            activeKeyVersion: activeKeyVersion,
            memberStatusActive: (member?["status"] as? String) == "active"
        )
    }
}

/// Fills this device's key ring from the envelopes an admin addressed to it.
///
/// A seam for the same two reasons `TeamRosterReading` is one — a unit test
/// cannot drive Firestore or a Keychain — and a seam AT ALL because
/// `TeamVaultKeyDistributor.loadKeyRingFromEnvelopes` had **no production
/// caller**. PR 2 wrote and tested the joiner's half of design §3(b)2 and
/// nothing ever invoked it, so a member an admin had just promoted stayed
/// keyless: `prepareTeam` logged `team_memory_sync_awaiting_slug_key` on every
/// cycle for ever, and the envelope sitting on the server addressed to their own
/// device was never read.
///
/// THE CYCLE IS THE RIGHT SEAM FOR IT, not launch. Promotion happens on ANOTHER
/// Mac while this one is running, so a launch-time pickup would mean a member is
/// admitted to a team and then waits for a relaunch — and a second Mac of the
/// same account, enrolled and covered by an admin later, would wait for one too.
/// The cycle already re-reads the roster every beat precisely because membership
/// moves underneath it; the key ring moves on exactly the same schedule.
protocol TeamKeyRingLoading: Sendable {
    /// - Returns: the slots that landed, for logging. An empty result is the
    ///   ordinary "nothing is addressed to this device yet" and never a failure.
    func loadKeyRing(teamID: String, uid: String, deviceId: String) async throws -> [TeamKeySlot]
}

/// Production loader. It holds no Firebase handle of its own: the gateway is the
/// one the cycle already uses, and `FirebaseTeamRosterCallableClient` resolves
/// its `Functions` lazily inside a computed property, so constructing this on a
/// Mac that never syncs a team costs nothing.
///
/// The callables are structurally unreachable from here — `loadKeyRingFromEnvelopes`
/// invokes none of them — and are supplied only because the distributor is one
/// value type carrying every capability. That is worth saying out loud: a pickup
/// must never promote, rotate, abandon or stamp anything, and it does not.
struct TeamVaultEnvelopeKeyRingLoader: TeamKeyRingLoading {
    let gateway: CloudSyncFirestoreGateway
    let keyRing: any TeamVaultKeyRing
    /// Nil in production, where it resolves to this Mac's own Keychain escrow
    /// key. A test supplies a real P-256 keypair: which device can open which
    /// envelope is the property, and a mock of it would test nothing.
    var escrowPrivateKey: (any TeamEscrowPrivateKeyProviding)?

    func loadKeyRing(teamID: String, uid: String, deviceId: String) async throws -> [TeamKeySlot] {
        try await TeamVaultKeyDistributor(
            gateway: gateway,
            uid: uid,
            deviceId: deviceId,
            keyRing: keyRing,
            callables: FirebaseTeamRosterCallableClient(),
            escrowPrivateKey: escrowPrivateKey ?? DeviceTeamEscrowPrivateKey(deviceId: deviceId)
        ).loadKeyRingFromEnvelopes(teamId: teamID)
    }
}

/// Resolves the checked-in `teamProjectId` an engine project publishes to a
/// team, or nil when it publishes nothing to it.
protocol TeamProjectLinkResolving: Sendable {
    func teamProjectID(engineProjectID: String, teamID: String) async -> String?

    /// Every `teamProjectId` ANY repository on this Mac publishes to `teamID`.
    ///
    /// The PUSH asks the question one project at a time (`teamProjectID` above)
    /// because it starts from a row and needs that row's project. The PULL
    /// starts from a document that names a project it has no local handle for,
    /// so it needs the whole admission set at once — which is the same file, the
    /// same rule, and the same fail-closed default read the other way round.
    ///
    /// An empty set means this checkout links nothing to that team, and the pull
    /// refuses the whole team space rather than landing bodies in a partition
    /// nobody committed to sharing (PR3 Cursor ruling, T3).
    func linkedTeamProjectIDs(teamID: String) async -> Set<String>
}

/// Production resolver: the daemon's own recorded root for the project, then
/// that repository's checked-in `.openburnbar/project.json`.
///
/// It resolves nothing and registers nothing — `memoryProjectRecordedRoot` is a
/// plain `SELECT` — so a project this Mac has never indexed contributes to no
/// team rather than being invented at sync time.
struct RecordedRootTeamProjectLinkResolver: TeamProjectLinkResolving {
    let store: ControlPlaneStore

    func teamProjectID(engineProjectID: String, teamID: String) async -> String? {
        do {
            guard let root = try await store.memoryProjectRecordedRoot(engineProjectID: engineProjectID) else {
                return nil
            }
            return TeamProjectLink
                .read(projectRoot: URL(fileURLWithPath: root, isDirectory: true))
                .teamProjectID(forTeam: teamID)
        } catch {
            // A store failure must not be read as "this project publishes to
            // every team". It publishes to none, and the next cycle re-asks.
            AppLogger.sync.error(
                "team_memory_project_link_unreadable",
                metadata: ["error_type": String(describing: type(of: error))]
            )
            return nil
        }
    }

    func linkedTeamProjectIDs(teamID: String) async -> Set<String> {
        do {
            let roots = try await store.memoryProjectRecordedRoots()
            var ids: Set<String> = []
            for root in roots {
                if let id = TeamProjectLink
                    .read(projectRoot: URL(fileURLWithPath: root, isDirectory: true))
                    .teamProjectID(forTeam: teamID) {
                    ids.insert(id)
                }
            }
            return ids
        } catch {
            // Fail CLOSED, exactly as the single-project resolver does: a store
            // failure must never read as "every project is linked". The team's
            // pull refuses this cycle and the next one re-asks.
            AppLogger.sync.error(
                "team_memory_project_links_unreadable",
                metadata: ["error_type": String(describing: type(of: error))]
            )
            return []
        }
    }
}

/// What one team cycle did. Counters only — never a fact, never a doc id.
struct TeamMemorySyncCycleReport: Equatable, Sendable {
    /// Teams the member had opted in this cycle.
    let teamsConsidered: Int
    /// Teams whose gate was open and whose cycle actually ran.
    let teamsSynced: Int
    let uploaded: Int
    /// Rows that did not qualify (`TeamMemoryUploadEligibility`).
    let skippedIneligible: Int
    /// Rows the push did not CONSIDER at all, because their local `updatedAt` is
    /// at or below this `(team, member)`'s push watermark — nothing about them
    /// has changed since the last complete pass, so no body was opened, nothing
    /// was sealed and, above all, **no cloud read was issued**. On a steady team
    /// this is the whole eligible set and every other counter here is zero.
    let skippedUnchanged: Int
    /// Rows whose cloud revision was already at or after the local one.
    let skippedStaleRevision: Int
    /// Rows whose team document ALREADY EXISTS under another member's
    /// authorship — the convergence this lane is built around. Not an error and
    /// not a failure: the fact is in the team space, this member's push has
    /// nothing to add, and the pull half of this same cycle is what brings it
    /// back down. See `pushTeamFacts`.
    ///
    /// Counted whether the convergence was learned from a cloud read this cycle
    /// or recalled from this process's convergence memo, so the number keeps
    /// meaning "documents this member converged on" rather than "reads spent
    /// discovering that".
    let convergedForeignAuthor: Int
    /// Individual documents whose read or write threw. Counted and logged per
    /// document; one refused write never costs the team the rest of its batch,
    /// nor its pull.
    let failedDocuments: Int
    let pullApplied: Int
    let pullUnchanged: Int
    let pullRejected: Int
    /// Teams whose push OR pull threw. Counted, never propagated: one team's
    /// failure must not stop the next team, let alone the personal lane.
    let failedTeams: Int

    static let idle = TeamMemorySyncCycleReport(
        teamsConsidered: 0,
        teamsSynced: 0,
        uploaded: 0,
        skippedIneligible: 0,
        skippedUnchanged: 0,
        skippedStaleRevision: 0,
        convergedForeignAuthor: 0,
        failedDocuments: 0,
        pullApplied: 0,
        pullUnchanged: 0,
        pullRejected: 0,
        failedTeams: 0
    )
}

/// The per-cycle gate for the team half, read on the SAME main-actor hop as the
/// personal one so the two can never disagree about consent.
struct TeamMemoryGateSnapshot: Sendable {
    /// `MemoryDeviceSyncGate.isEnabled(...)` — the four memory levers.
    let deviceSyncGateOpen: Bool
    /// `MemoryDeviceSyncScope.current(...).isOpen` — the account levers.
    let accountLeversOpen: Bool
    /// The teams the member has opted in, from `MemorySettings.teamMemorySyncEnabled`.
    let optedInTeamIDs: Set<String>
    let remoteConfigTeamSyncAllowed: Bool
    let remoteConfigResolved: Bool
}

/// The team half of a memory cycle, behind a seam.
///
/// It exists for exactly one reason, and it is the invariant this whole file is
/// arranged around: **"a team failure leaves the personal cycle green" is a
/// claim about a THROW, and a throw cannot be staged through a concrete final
/// class.** `MemoryCloudSyncDomain` used to hold a `TeamMemorySyncDomain`
/// directly, so the only thing a test could reach was the pure gate — a truth
/// table that says nothing about ordering, failure or the personal watermark.
/// With the seam, `test_team_sync_failing_closed_does_not_affect_member_sync`
/// drives the REAL `sync()` with a team half that throws and asserts on the
/// personal lane's own state, which is what the design's PR 3 acceptance
/// criterion actually asks for.
protocol TeamMemorySyncCycling: Sendable {
    func runCycle(
        uid: String,
        deviceId: String,
        gate: TeamMemoryGateSnapshot,
        now: Date
    ) async throws -> TeamMemorySyncCycleReport

    /// Invalidates one team's three sync records for this member NOW, rather
    /// than at the next cycle that happens to observe the opted-in set.
    ///
    /// The eager half of the same invariant `runCycle` enforces lazily, on the
    /// seam so a UI action — leaving a team, switching the team's toggle off —
    /// can trigger it without holding a concrete domain. Callers treat it as
    /// best-effort: the cycle-time drop is the guarantee, this is the latency.
    func invalidateTeamMemorySync(teamID: String, uid: String) async throws
}

final class TeamMemorySyncDomain: TeamMemorySyncCycling, Sendable {
    private let store: ControlPlaneStore
    private let firestoreGateway: CloudSyncFirestoreGateway
    private let rosterReader: any TeamRosterReading
    private let keyRing: any TeamVaultKeyRing
    private let projectLinks: any TeamProjectLinkResolving
    private let pullService: any TeamMemoryPulling
    private let keyRingLoader: any TeamKeyRingLoading
    private let watermarks: RemoteSyncWatermarkStore

    /// Team documents this PROCESS has already found under another member's
    /// authorship, keyed `"<teamId>/<docId>"`.
    ///
    /// The durable push watermark below is what makes a steady cycle cost zero
    /// cloud reads; this memo is what bounds the cycles that are NOT steady. A
    /// converged document can never be written by this member — `firestore.rules`
    /// makes `uid` immutable on update — so once one cycle has learned that,
    /// re-reading it buys nothing, and without the memo any cycle that keeps the
    /// watermark still (one failed document anywhere in the pass) would re-read
    /// every converged document again.
    ///
    /// KEYED ON THE DOCUMENT ID, WHICH IS WHY THIS IS SAFE RATHER THAN MERELY
    /// CHEAP. The id is `HMAC(teamProjectId | engineScope | bodyHash)`, so an
    /// edit that changes the BODY mints a different id and lands outside the
    /// memo — it is pushed, under this member's own authorship, exactly as
    /// before. An edit that leaves the body alone (`validTo`, `tags`,
    /// `supersededBy`) keeps the id, stays memoised, and is skipped — which
    /// costs nothing that was ever available: a non-author's metadata change has
    /// never been able to reach a converged document (known risk 4). Nothing
    /// that could have been written is suppressed.
    ///
    /// PROCESS-LIFETIME AND DELIBERATELY NOT DURABLE. There is no per-row place
    /// to record "this local memory converged on that team document" without a
    /// new column or table, which this PR may not take (design §3(e)). A relaunch
    /// therefore re-reads each converged document once and then stops. The memo
    /// is never consulted for anything but skipping a read, so losing it can only
    /// cost reads, never correctness.
    private let convergedDocumentKeys = Locked(Set<String>())

    init(
        store: ControlPlaneStore,
        firestoreGateway: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway(),
        rosterReader: (any TeamRosterReading)? = nil,
        keyRing: any TeamVaultKeyRing = KeychainTeamVaultKeyRing(),
        projectLinks: (any TeamProjectLinkResolving)? = nil,
        pullService: (any TeamMemoryPulling)? = nil,
        keyRingLoader: (any TeamKeyRingLoading)? = nil
    ) {
        self.store = store
        self.firestoreGateway = firestoreGateway
        self.rosterReader = rosterReader ?? FirestoreTeamRosterReader(gateway: firestoreGateway)
        self.keyRing = keyRing
        self.projectLinks = projectLinks ?? RecordedRootTeamProjectLinkResolver(store: store)
        self.pullService = pullService
            ?? TeamMemoryPullService(store: store, firestoreGateway: firestoreGateway)
        self.keyRingLoader = keyRingLoader
            ?? TeamVaultEnvelopeKeyRingLoader(gateway: firestoreGateway, keyRing: keyRing)
        self.watermarks = RemoteSyncWatermarkStore(dbQueue: store.dbQueue)
    }

    /// Drops this member's pull cursor, push watermark and project-link record
    /// for ONE team, immediately.
    ///
    /// WHY EAGER AT ALL, when `runCycle` already invalidates every team outside
    /// the opted-in set. Because "already" is up to a refresh interval away.
    /// `BehaviorSettings.refreshInterval` defaults to 600 s, is user-adjustable
    /// to 15 minutes, and `BackgroundCadenceCoordinator` stretches it 5x while
    /// the app is inactive — which a menu-bar app normally is. A member who
    /// leaves a team and re-joins it inside that window would be served by the
    /// stale records the leave was supposed to retire, because no cycle ever
    /// observed the set with the team missing. Acting where the state changes
    /// is the same rule `MemoryDeviceSyncInboxGuard` follows for consent.
    ///
    /// It does NOT touch settings, the roster, the key ring or the cloud: a
    /// leave is not this method's to perform, only the local records the leave
    /// invalidates. Caller keeps its own ordering — invalidating before the
    /// team is removed from `optedInTeamIDs` is harmless, since a cycle in
    /// between would simply find nothing to drop.
    func invalidateTeamMemorySync(teamID: String, uid: String) async throws {
        let dropped = try await watermarks.invalidateTeamMemoryRecords(
            teamID: teamID,
            localUserID: uid
        )
        guard dropped > 0 else { return }
        AppLogger.sync.info(
            "team_memory_sync_records_invalidated",
            metadata: ["team_id": teamID, "rows": String(dropped)]
        )
    }

    /// Runs one cycle for every opted-in team.
    ///
    /// A team that fails is counted and the next one runs, because the
    /// alternative — one unreachable roster stopping every other team AND
    /// (before the nesting in `MemoryCloudSyncDomain`) the personal lane — is
    /// the failure mode this lane was designed around. Today nothing here
    /// actually escapes; `throws` is declared so the caller's `do/catch` is a
    /// real boundary rather than one a later change could quietly demote.
    ///
    /// THE PUSH AND THE PULL ARE SEPARATE FAILURE BOUNDARIES, and that is not
    /// tidiness. They were one `do` block, so anything the upload half threw —
    /// a rules refusal on a single document above all — skipped the team's PULL
    /// for that cycle. On a lane whose whole point is that two members converge
    /// on ONE document, "my write was refused" is an ORDINARY outcome, and
    /// letting it cost the member every fact their teammates wrote turned a
    /// non-event into a permanent, silent read outage. Reading a team's memory
    /// does not depend on being able to write to it.
    func runCycle(
        uid: String,
        deviceId: String,
        gate: TeamMemoryGateSnapshot,
        now: Date
    ) async throws -> TeamMemorySyncCycleReport {
        guard gate.deviceSyncGateOpen, gate.accountLeversOpen else { return .idle }

        // OPT-OUT INVALIDATES THE PUSH WATERMARK, and this is the only place
        // that observes an opt-out at all.
        //
        // A push watermark asserts "everything eligible as of then was
        // resolved". That stops being true the instant a team is switched off:
        // this Mac no longer evaluates that team's eligible set, while memories
        // go on being edited and retired underneath it. Re-opting in above a
        // stale row would push only what changed during the OFF period and skip
        // every memory that was already clean — a member who believes they are
        // sharing and is not. So the row goes, and the next opt-in gets the same
        // full pass a first opt-in gets. See
        // `RemoteSyncWatermarkStore.dropTeamMemoryPushWatermarks`.
        //
        // Runs BEFORE the empty-set return, because opting out of the ONLY team
        // is the case that matters most and it leaves the set empty. It is a
        // local read, and a write only when there is something to drop, so the
        // "dormant by default" promise — no Firestore handle, no Keychain item —
        // is untouched. The two coarser triggers already exist and are not
        // duplicated here: withdrawing device-sync consent and switching account
        // both drop these rows through `ControlPlaneStore`'s purge paths, which
        // is why a closed `deviceSyncGateOpen` above needs no purge of its own.
        try await watermarks.dropTeamMemoryPushWatermarks(
            localUserID: uid,
            keepingTeamIDs: gate.optedInTeamIDs
        )
        // The SAME invalidation, on the same trigger, for the pull lane's
        // project-LINK record. While a team is switched off this Mac stops
        // observing that team's `.openburnbar/project.json` links, so a surviving
        // record would let a repository linked during the OFF period read as
        // "already known" on re-opt-in — and the rewind that recovers documents
        // refused as `.projectNotLinkedToTeam` would never fire. Dropping it
        // makes the next opt-in treat everything linked then as a gain and
        // rewind once, which is the same full pass a first opt-in gets. See
        // `RemoteSyncWatermarkStore.dropTeamMemoryProjectLinkRecords`.
        try await watermarks.dropTeamMemoryProjectLinkRecords(
            localUserID: uid,
            keepingTeamIDs: gate.optedInTeamIDs
        )
        // And the THIRD record, whose absence made the other two a half-measure:
        // the pull CURSOR. It is a floor on everything a later pull can ever
        // see — the scan filter is strictly greater-than — and while a team is
        // switched off, teammates go on writing facts that this Mac never
        // fetches. Re-opting in above the surviving cursor would resume from
        // where the last ON cycle stopped and skip every fact written during
        // the OFF period, permanently: nothing re-offers them, since the cloud
        // will not rewrite the documents and the link-record rewind fires only
        // on a GAINED project link, which a re-join need not involve. Dropping
        // it costs one full re-scan from the epoch floor, exactly what a first
        // opt-in costs, and parking is idempotent. See
        // `RemoteSyncWatermarkStore.dropTeamMemoryPullCursors`.
        try await watermarks.dropTeamMemoryPullCursors(
            localUserID: uid,
            keepingTeamIDs: gate.optedInTeamIDs
        )

        guard !gate.optedInTeamIDs.isEmpty else { return .idle }
        var teamsSynced = 0
        var uploaded = 0
        var skippedIneligible = 0
        var skippedUnchanged = 0
        var skippedStaleRevision = 0
        var convergedForeignAuthor = 0
        var failedDocuments = 0
        var pullApplied = 0
        var pullUnchanged = 0
        var pullRejected = 0
        var failedTeams = 0

        // Sorted, so a cycle's team order is deterministic and a log from two
        // machines can be compared.
        for teamID in gate.optedInTeamIDs.sorted() {
            let prepared: (roster: TeamRosterSnapshot, slugKey: Data)?
            do {
                prepared = try await prepareTeam(teamID: teamID, uid: uid, deviceId: deviceId, gate: gate)
            } catch {
                failedTeams += 1
                logTeamFailure("team_memory_sync_roster_failed", teamID: teamID, error: error)
                continue
            }
            guard let prepared else { continue }

            var teamFailed = false

            // PUSH, in its own boundary.
            do {
                let push = try await pushTeamFacts(
                    teamID: teamID,
                    uid: uid,
                    deviceId: deviceId,
                    roster: prepared.roster,
                    teamSlugKey: prepared.slugKey,
                    now: now
                )
                uploaded += push.uploaded
                skippedIneligible += push.skippedIneligible
                skippedUnchanged += push.skippedUnchanged
                skippedStaleRevision += push.skippedStaleRevision
                convergedForeignAuthor += push.convergedForeignAuthor
                failedDocuments += push.failedDocuments
            } catch {
                teamFailed = true
                logTeamFailure("team_memory_sync_push_failed", teamID: teamID, error: error)
            }

            // PULL, in its own — reached whatever the push did. A member whose
            // active key generation has not arrived contributes nothing this
            // cycle and still READS the team space, which is the behaviour
            // `pushTeamFacts`'s own comment promises.
            do {
                // RETAINED generations only — a pending one, minted here but
                // not yet recorded by the roster authority, must not open a
                // stored fact. See `TeamMemorySyncService.retainedKey`.
                let pulled = try await pullService.pullTeamFacts(
                    teamID: teamID,
                    localUserID: uid,
                    teamSlugKey: prepared.slugKey,
                    // The admission set for the sealed `projectID`, read from
                    // THIS Mac's own checked-in links rather than from the
                    // documents (PR3 Cursor ruling, T3).
                    linkedTeamProjectIDs: await projectLinks.linkedTeamProjectIDs(teamID: teamID),
                    keyForVersion: TeamMemorySyncService.retainedKeySelector(
                        from: keyRing,
                        teamID: teamID
                    ),
                    now: now
                )
                pullApplied += pulled.applied
                pullUnchanged += pulled.unchanged
                pullRejected += pulled.rejected
            } catch {
                teamFailed = true
                logTeamFailure("team_memory_sync_pull_failed", teamID: teamID, error: error)
            }

            if teamFailed {
                failedTeams += 1
            } else {
                teamsSynced += 1
            }
        }

        return TeamMemorySyncCycleReport(
            teamsConsidered: gate.optedInTeamIDs.count,
            teamsSynced: teamsSynced,
            uploaded: uploaded,
            skippedIneligible: skippedIneligible,
            skippedUnchanged: skippedUnchanged,
            skippedStaleRevision: skippedStaleRevision,
            convergedForeignAuthor: convergedForeignAuthor,
            failedDocuments: failedDocuments,
            pullApplied: pullApplied,
            pullUnchanged: pullUnchanged,
            pullRejected: pullRejected,
            failedTeams: failedTeams
        )
    }

    /// The roster read, the gate and the slug key — everything both halves need
    /// before either can run. `nil` means "this team does no work this cycle",
    /// which is not a failure; a throw is a failure.
    private func prepareTeam(
        teamID: String,
        uid: String,
        deviceId: String,
        gate: TeamMemoryGateSnapshot
    ) async throws -> (roster: TeamRosterSnapshot, slugKey: Data)? {
        guard let roster = try await rosterReader.rosterSnapshot(teamID: teamID, uid: uid) else {
            return nil
        }
        guard TeamMemorySyncGate.isEnabled(
            deviceSyncGateOpen: gate.deviceSyncGateOpen,
            accountLeversOpen: gate.accountLeversOpen,
            teamOptIn: gate.optedInTeamIDs.contains(teamID),
            rosterStatusActive: roster.memberStatusActive,
            remoteConfigTeamSyncAllowed: gate.remoteConfigTeamSyncAllowed,
            remoteConfigResolved: gate.remoteConfigResolved
        ) else { return nil }

        // THE KEY PICKUP, AND WHY IT SITS EXACTLY HERE (design §3(b)2).
        //
        // The gate above has just said this member is ACTIVE on the roster,
        // which is the state `promoteTeamMember` refuses to grant until an
        // envelope exists for every pinned device at every retained generation.
        // So "active, and this Mac holds no key" is not an ambiguous state: the
        // envelopes are published and this device has simply never read them.
        // Running the pickup on the far side of the gate is what keeps that
        // true — a PENDING member has no envelopes yet and would spend a query
        // on every beat learning so.
        //
        // ONLY WHEN A SLOT IS MISSING, so a healthy team's cycle costs nothing:
        // in steady state both reads below hit the Keychain and return, and no
        // Firestore query is issued at all. When one is missing this runs ONCE
        // for this team this cycle, and the ring is re-read after it — which is
        // what lets a member promoted between two beats start working without a
        // relaunch, and a second Mac of the same account pick up its own wraps.
        //
        // A FAILED PICKUP IS NOT A FAILED TEAM. It is logged and the pass falls
        // through to the same "no slug key, do nothing this cycle" it would have
        // reached anyway; counting it as `failedTeams` would report an outage
        // for a device that is merely still waiting.
        if try ringIsMissingASlot(teamID: teamID, activeKeyVersion: roster.activeKeyVersion) {
            await loadKeyRing(teamID: teamID, uid: uid, deviceId: deviceId)
        }

        guard let slugKey = try TeamMemorySyncService.retainedKey(
            from: keyRing,
            teamID: teamID,
            slot: .slug
        ) else {
            // No slug key means no document id can be derived at all — the
            // envelope has not landed on this Mac yet. Not a failure: the next
            // cycle asks again.
            AppLogger.sync.info(
                "team_memory_sync_awaiting_slug_key",
                metadata: ["team_id": teamID]
            )
            return nil
        }
        return (roster, slugKey)
    }

    /// Does this device lack either of the two keys a full cycle needs — the
    /// non-rotating slug key that NAMES documents, or the roster's active
    /// generation that SEALS them?
    ///
    /// The active generation is included deliberately. A member who holds the
    /// slug key but not `v(N+1)` reads the team space and contributes nothing,
    /// which `pushTeamFacts` reports as `teamKeyVersionUnavailable` and the
    /// operator sees as a permanently half-working team; the envelope that fixes
    /// it is on the server, addressed to this device, from the moment the
    /// rotating admin published it.
    private func ringIsMissingASlot(teamID: String, activeKeyVersion: Int) throws -> Bool {
        if try TeamMemorySyncService.retainedKey(from: keyRing, teamID: teamID, slot: .slug) == nil {
            return true
        }
        return try TeamMemorySyncService.retainedKey(
            from: keyRing,
            teamID: teamID,
            slot: .vault(version: activeKeyVersion)
        ) == nil
    }

    private func loadKeyRing(teamID: String, uid: String, deviceId: String) async {
        do {
            let loaded = try await keyRingLoader.loadKeyRing(teamID: teamID, uid: uid, deviceId: deviceId)
            guard !loaded.isEmpty else { return }
            // Slot NAMES only — `v2`, `slug`. Never a key, never a byte count,
            // and never an envelope id.
            AppLogger.sync.info(
                "team_memory_sync_key_ring_loaded",
                metadata: [
                    "team_id": teamID,
                    "slots": loaded.map(\.rawValue).sorted().joined(separator: ",")
                ]
            )
        } catch {
            logTeamFailure("team_memory_sync_key_ring_load_failed", teamID: teamID, error: error)
        }
    }

    private func logTeamFailure(_ event: String, teamID: String, error: Error) {
        AppLogger.sync.error(
            event,
            metadata: [
                "team_id": teamID,
                "error_type": String(describing: type(of: error))
            ]
        )
    }

    // MARK: - Push

    private struct TeamPushResult {
        let uploaded: Int
        let skippedIneligible: Int
        let skippedUnchanged: Int
        let skippedStaleRevision: Int
        let convergedForeignAuthor: Int
        let failedDocuments: Int
    }

    private func pushTeamFacts(
        teamID: String,
        uid: String,
        deviceId: String,
        roster: TeamRosterSnapshot,
        teamSlugKey: Data,
        now: Date
    ) async throws -> TeamPushResult {
        // The ROSTER's active generation, read from the ring's retained half.
        // On the Mac that is mid-rotation the new generation is still PENDING
        // locally and the roster still names the old one, so both halves agree
        // to keep sealing under the old key until the authority has recorded
        // the new one — which is exactly what the rules enforce server-side.
        guard let vaultKey = try TeamMemorySyncService.retainedKey(
            from: keyRing,
            teamID: teamID,
            slot: .vault(version: roster.activeKeyVersion)
        ) else {
            // The active generation's envelope has not arrived. Writing under an
            // older key would be refused by the rules anyway
            // (`teamKeyVersion == activeTeamKeyVersion`), so this cycle simply
            // contributes nothing and the pull half still runs — a member
            // mid-rotation keeps READING the team space.
            throw TeamMemorySyncError.teamKeyVersionUnavailable(
                teamId: teamID,
                keyVersion: roster.activeKeyVersion
            )
        }
        let factCollection = firestoreGateway
            .collection(TeamMemorySyncService.factsRootCollection)
            .document(teamID)
            .collection(TeamMemorySyncService.factsSubcollection)

        // THE DIRTY FILTER, AND WHY THE PASS IS BOUNDED RATHER THAN PERPETUAL.
        //
        // Every eligible memory used to be sealed and READ FROM THE CLOUD on
        // every cycle, for every team, for ever — `E` documents times `T` teams
        // per beat on every member's Mac, whether or not a single byte had
        // changed since the last beat. On a team where most facts are already
        // authored by someone else that is a permanent read bill buying a
        // decision the previous cycle had already made.
        //
        // The bound is a per-`(team, member)` PUSH WATERMARK: the instant the
        // last complete, failure-free pass finished, stored beside this team's
        // pull cursor in `remote_sync_watermarks`
        // (`RemoteSyncWatermarkStore.teamMemoryPushCollectionKind`, keyed on the
        // same `team:<teamId>:<uid>` account). A memory is CONSIDERED only when
        // its local `updatedAt` is strictly newer than that instant. In steady
        // state nothing is, so the pass costs zero cloud reads and zero body
        // decryptions; one edited memory costs exactly one read.
        //
        // The watermark is an INSTANT, not a per-row record, so it says
        // "everything as of then was resolved" and nothing about which rows. Two
        // consequences, both deliberate:
        //
        //   * A pass that could not resolve every document it touched records
        //     NOTHING. A failure therefore stays above the bar and is retried
        //     next cycle, rather than being stranded under a watermark it can
        //     never rise above.
        //   * A memory that becomes eligible WITHOUT being edited — the ordinary
        //     case is `.openburnbar/project.json` gaining the team link after
        //     the fact — does not move its own `updatedAt`, so it waits for its
        //     next local edit. Named in the PR body beside this bound; closing
        //     it properly needs the durable per-row team-push record a migration
        //     would buy, which this PR may not take (design §3(e)).
        //   * A SUB-MILLISECOND TIE IS NOT RECONSIDERED, and that is a deliberate
        //     non-fix. `now` is `MemoryCloudSyncDomain`'s `syncStartedAt`,
        //     captured before the personal half; the skip below is `updatedAt <=
        //     watermark`. A local write whose `updated_at` truncates to EXACTLY
        //     that instant and commits after `cloudSyncEligibleChatMemories` has
        //     already run would sit on the bar for ever. Widening the comparison
        //     to `<` would close it at the cost of re-reading the whole boundary
        //     class on every cycle, and the window is one storage tick wide on a
        //     clock the write and the cycle do not share; the personal lane
        //     tracks no push instant at all, so this residual is strictly
        //     narrower than the precedent. Named in the PR body as risk 3's third
        //     residual, with the same operator recovery: delete the team's
        //     push-watermark row.
        let pushWatermark = try await watermarks.fetchTeamMemoryPushInstant(
            accountUid: TeamMemoryPullService.watermarkAccountKey(teamID: teamID, localUserID: uid)
        )

        var uploaded = 0
        var skippedIneligible = 0
        var skippedUnchanged = 0
        var skippedStaleRevision = 0
        var convergedForeignAuthor = 0
        var failedDocuments = 0
        // Resolved once per cycle per engine project: the link file does not
        // change mid-cycle and a repository with a hundred memories should not
        // be read a hundred times.
        var linkCache: [String: String?] = [:]

        for memory in try await store.cloudSyncEligibleChatMemories(userID: uid) {
            // A chat memory can never qualify, and asking the store for an agent
            // body it does not have is wasted work — so the cheap structural
            // check runs before any read.
            guard memory.sourceKind == .agent else {
                skippedIneligible += 1
                continue
            }
            // Ahead of the body read, not merely ahead of the cloud read: a
            // clean memory should cost this pass a date comparison and nothing
            // else.
            if let pushWatermark, memory.updatedAt <= pushWatermark {
                skippedUnchanged += 1
                continue
            }
            guard let body = try await store.openAgentMemoryBody(id: memory.id), !body.isEmpty,
                  let engineID = try await store.engineMemoryID(for: memory.id) else {
                skippedIneligible += 1
                continue
            }
            let attributes = try await store.memoryCloudFactAttributes(id: memory.id)
            let engineProjectID = attributes.projectID ?? ""
            let teamProjectID: String?
            if let cached = linkCache[engineProjectID] {
                teamProjectID = cached
            } else {
                let resolved = engineProjectID.isEmpty
                    ? nil
                    : await projectLinks.teamProjectID(engineProjectID: engineProjectID, teamID: teamID)
                linkCache[engineProjectID] = resolved
                teamProjectID = resolved
            }

            // COST NOTE. `TeamMemoryUploadEligibility` re-runs the whole
            // `MemorySecretPIIGate` corpus over this body, once per eligible
            // memory PER TEAM per cycle — memories × teams regex passes. That is
            // the right trade at one to three teams (the gate is fail-closed and
            // "may this team hold it" is genuinely a different question from
            // "may the member's own vault"), and it is the first thing to
            // memoise per cycle if a member is ever on five.
            guard TeamMemoryUploadEligibility.qualifies(
                // Reached only for a team already in the opted-in set, so this
                // is the same `true` the gate above established. It is passed
                // rather than assumed because the eligibility rule is the thing
                // tests read to learn what qualifies, and a rule with an
                // invisible term is a rule nobody can check.
                teamOptIn: true,
                reviewStatus: memory.reviewStatus,
                sourceKind: memory.sourceKind,
                validTo: memory.validTo,
                bodyHash: attributes.bodyHash,
                engineScope: attributes.engineScope,
                teamProjectID: teamProjectID,
                bodyForSensitivityScan: body
            ), let teamProjectID, let bodyHash = attributes.bodyHash,
               let engineScope = attributes.engineScope else {
                skippedIneligible += 1
                continue
            }

            // THE CONVERGENCE MEMO, CONSULTED BEFORE THE SEAL. The document id
            // is a pure function of `(teamProjectId, engineScope, bodyHash)`, so
            // it is knowable without encrypting anything — and if a previous
            // cycle in this process already found that document under another
            // member's uid, this one has nothing to learn and nothing to write.
            // Skipping here saves the AES seal as well as the cloud read.
            let docID = try TeamMemorySyncService.deriveDocID(
                teamID: teamID,
                teamProjectId: teamProjectID,
                engineScope: engineScope,
                bodyHash: bodyHash,
                teamSlugKey: teamSlugKey
            )
            let convergenceMemoKey = "\(teamID)/\(docID)"
            if convergedDocumentKeys.withLock({ $0.contains(convergenceMemoKey) }) {
                convergedForeignAuthor += 1
                continue
            }

            let payload = TeamMemoryFactPayload(
                teamID: teamID,
                authorUID: uid,
                memoryID: engineID,
                text: body,
                kind: memory.kind,
                confidence: memory.confidence,
                validFrom: memory.validFrom,
                updatedAt: memory.updatedAt,
                validTo: memory.validTo,
                supersededBy: memory.supersededBy,
                tags: attributes.tags.isEmpty ? nil : attributes.tags,
                bodyHash: bodyHash,
                projectID: teamProjectID,
                engineScope: engineScope,
                writerDevice: deviceId
            )
            let encoded = try TeamMemorySyncService.sealTeamFact(
                payload: payload,
                sourceRefs: memory.citations.map(TeamMemorySourceRef.init(citation:)),
                teamVaultKey: vaultKey,
                teamSlugKey: teamSlugKey,
                teamKeyVersion: roster.activeKeyVersion,
                now: now
            )
            // ONE READ, THREE DECISIONS, AND A PER-DOCUMENT FAILURE BOUNDARY.
            //
            // The read is CONDITIONAL exactly as `KnowledgeSyncService` is, for
            // a reason that is sharper here: on the personal lane the racing
            // writers are the member's own Macs; on a team lane they are
            // DIFFERENT PEOPLE who both learned the same fact and therefore both
            // derive the same document id. Without the read, whichever member's
            // cycle ran last would overwrite a newer teammate's revision with
            // their own stale one, every cycle, for ever.
            //
            // AUTHORSHIP IS THE FIRST QUESTION, because it is the one the SERVER
            // will refuse on. `firestore.rules` makes `uid` immutable on update
            // — `request.resource.data.uid == resource.data.uid`, with no admin
            // exception — so a second member writing a converged document sends
            // their own uid against a document holding a teammate's and is
            // refused PERMISSION_DENIED. That refusal is not an error condition
            // to be retried: it is the rules stating the thing this lane wants,
            // which is that the fact is ALREADY in the team space and its author
            // is settled. So the client resolves the convergence instead: the
            // document exists under another author, this member's copy converges
            // onto it, nothing is written, and the PULL half of this same cycle
            // brings that document down and hands it to the engine — which folds
            // it into this member's own lineage under the namespaced
            // `sync_identity:team:<teamID>:<key>` ledger. The convergence record
            // IS that pull; there is no cloud write and no local table.
            //
            // The whole per-document interaction is wrapped, because ONE refused
            // document must never cost the team the rest of its batch. It used
            // to: an unwrapped `setData` escaped to the per-team `catch`, which
            // abandoned every remaining upload AND skipped the team's pull, so a
            // single converged fact whose local revision was newer than the
            // teammate's retried the same refused write every cycle and that
            // member stopped receiving team memory permanently.
            do {
                // `docID` rather than `encoded.docID` — the same string by
                // construction, and using the one the memo was keyed on makes
                // that impossible to break by accident.
                let document = factCollection.document(docID)
                let existingData = try await document.getData()
                if let owner = existingData?["uid"] as? String, owner != uid {
                    convergedForeignAuthor += 1
                    convergedDocumentKeys.withLock { $0.insert(convergenceMemoKey) }
                    // The doc id is an opaque team-wide HMAC and the author uid
                    // is already plaintext on the document to every member, so
                    // both are safe to log; the body never is.
                    AppLogger.sync.info(
                        "team_memory_push_converged_on_existing_author",
                        metadata: ["team_id": teamID, "doc_id": docID]
                    )
                    continue
                }
                if let existing = MemoryCloudPullService.firestoreDate(existingData?["updatedAt"]),
                   existing >= memory.updatedAt {
                    skippedStaleRevision += 1
                    continue
                }
                try await document.setData(encoded.data, merge: true)
                uploaded += 1
            } catch {
                failedDocuments += 1
                AppLogger.sync.error(
                    "team_memory_push_document_failed",
                    metadata: [
                        "team_id": teamID,
                        "doc_id": docID,
                        "error_type": String(describing: type(of: error))
                    ]
                )
            }
        }
        // ONLY A COMPLETE, FAILURE-FREE PASS MOVES THE BAR. `uploaded`,
        // `skippedStaleRevision` and `convergedForeignAuthor` are all RESOLVED
        // outcomes — the document is where it should be and nothing more is owed
        // — so a pass made only of those has genuinely dealt with everything
        // eligible as of `now`. A single `failedDocuments` leaves the watermark
        // untouched, which is what makes the retry of that one document the next
        // cycle's business instead of nobody's.
        if failedDocuments == 0 {
            try await watermarks.recordTeamMemoryPushInstant(
                accountUid: TeamMemoryPullService.watermarkAccountKey(teamID: teamID, localUserID: uid),
                instant: now
            )
        }
        return TeamPushResult(
            uploaded: uploaded,
            skippedIneligible: skippedIneligible,
            skippedUnchanged: skippedUnchanged,
            skippedStaleRevision: skippedStaleRevision,
            convergedForeignAuthor: convergedForeignAuthor,
            failedDocuments: failedDocuments
        )
    }

}
