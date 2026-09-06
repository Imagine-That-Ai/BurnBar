import Foundation
import OpenBurnBarKernel

// MARK: - Team memory PULL (memory program D16 / P22, PR 3)
//
// The read-back half of `TeamMemorySyncService.sealTeamFact`, and a one-for-one
// mirror of `MemoryCloudPullService`: same verification order, same permanent /
// non-permanent refusal taxonomy, same watermark rule, same landing zone.
//
// It is a mirror rather than a generalisation on purpose. The two lanes differ
// in exactly the places that matter for admission — the AAD carries
// `team:<teamId>` instead of a uid, the key is selected by the document's own
// `keyVersion` from a retained-key ring rather than being the one key this
// device holds, the expected document id derives from the sealed payload's
// `(teamProjectId, engineScope, bodyHash)` under a NON-ROTATING slug key rather
// than from a row id under the vault key, and the field allowlist has three team
// columns and no `vaultGeneration` — and folding those differences into the
// personal service's parameters would have made the one file that decides what
// this product will decrypt harder to read, not easier.
//
// The two properties inherited verbatim:
//
//   1. **Nothing unverified is ever stored.** A document is admitted only if its
//      envelope opens under an AAD naming THIS document in THIS team, its keyed
//      plaintext HMAC matches, its field set stays inside the `firestore.rules`
//      allowlist, the identity sealed inside re-derives the id the document is
//      keyed on, and the unauthenticated outer `updatedAt` matches the sealed
//      one.
//   2. **The watermark never skips a document.** A refusal that could cure —
//      including a key generation whose envelope has not arrived yet — freezes
//      the cursor in front of itself. Only a PERMANENT refusal carrying a
//      VERIFIED instant moves past.
//
// WHICH OUTER FIELDS ARE AUTHENTICATED, AND WHICH ARE NOT. Read this before
// making any new decision from a field on the outer document. Exactly two outer
// fields are bound to the sealed payload and may therefore be trusted:
//
//   * `updatedAt`, bound by `sameSealedInstant` — which is what lets a permanent
//     refusal carry a verified instant and advance the cursor; and
//   * `uid`, bound by the `.authorMismatch` guard below — the rules pin it to
//     `request.auth.uid` on create and freeze it on update, so once it agrees
//     with the sealed `authorUID` the authorship of the row is the one
//     statement about this document the SERVER authenticated.
//
// Everything else on the outer document — `kind`, `sourceKind`, `reviewStatus`,
// `citationCount`, `sourceRefHmacs`, `validFrom`, `schemaVersion`, `docID`,
// `teamKeyVersion`, `rewrapJobId` — is unauthenticated. Nothing here reads them
// for anything but the allowlist-subset check (which is about what a document
// may NOT carry, not about what its values mean), and the client uses the sealed
// copies instead. **PR 4 must not match a forget receipt against the outer
// `sourceRefHmacs` without first binding them**, because a hostile backend can
// rewrite them freely and a receipt matched against a rewritten list retracts
// the wrong fact.

struct TeamMemoryPullResult: Equatable, Sendable {
    let applied: Int
    let unchanged: Int
    let rejected: Int
    /// Documents refused permanently, whose verified instant let the cursor move
    /// past them instead of freezing.
    let rejectedPermanent: Int
    let pagesRead: Int
    /// Whether this cycle DISCARDED an existing pull cursor because a
    /// `teamProjectId` was linked to this checkout that was not linked at the
    /// last successful pull — the recovery half of `.projectNotLinkedToTeam`.
    ///
    /// False on a first-ever cycle even when the record gains ids, because
    /// there was no cursor to discard and calling that a rewind would put one in
    /// every fresh install's log.
    let rewoundForNewProjectLink: Bool

    init(
        applied: Int,
        unchanged: Int,
        rejected: Int,
        rejectedPermanent: Int = 0,
        pagesRead: Int = 1,
        rewoundForNewProjectLink: Bool = false
    ) {
        self.applied = applied
        self.unchanged = unchanged
        self.rejected = rejected
        self.rejectedPermanent = rejectedPermanent
        self.pagesRead = pagesRead
        self.rewoundForNewProjectLink = rewoundForNewProjectLink
    }
}

/// Why a remote TEAM fact was refused. A log dimension only: never a model path,
/// never a UI string a hostile document could therefore steer.
enum TeamMemoryPullRejection: String, Sendable {
    /// A field outside the `firestore.rules` `team_memory_facts` allowlist.
    case disallowedField = "team_disallowed_field"
    /// `sealedMemory` missing or not a blob envelope.
    case malformedEnvelope = "team_malformed_envelope"
    /// This device holds no key for the generation the envelope names. The
    /// envelope may still be in flight, so this is the refusal the design calls
    /// out by name as non-permanent (design §3(a), defect 2).
    case teamKeyVersionUnavailable = "team_key_version_unavailable"
    /// The envelope did not open: wrong key, tampered ciphertext, or an AAD that
    /// names a different team / document / field.
    case sealedOpenFailed = "team_sealed_open_failed"
    /// The opened bytes are not a team-fact payload this build understands.
    case malformedPayload = "team_malformed_payload"
    /// The identity sealed inside does not derive the id the document is keyed
    /// on, so the document and its contents disagree about which fact this is.
    case identityMismatch = "team_identity_mismatch"
    /// The outer document names a different team than the sealed payload does.
    case teamMismatch = "team_mismatch"
    /// The sealed `authorUID` disagrees with the outer, rules-pinned `uid`.
    ///
    /// The outer field is the ONLY authenticated statement about authorship in
    /// the system — `firestore.rules` pins it to `request.auth.uid` on create
    /// and makes it immutable on update, even for an admin — while the sealed
    /// copy is what travels into `payloadJSON`, the engine's `history_meta` and
    /// the "contributed by" badge. Without this comparison a member running a
    /// modified client could seal a colleague's uid into a document the rules
    /// happily accept under their own, and durably attribute an invented fact to
    /// that colleague on every teammate's Mac.
    case authorMismatch = "team_author_mismatch"
    /// The sealed `projectID` is not the bounded token shape a `teamProjectId`
    /// may take. It comes from a file committed to a shared repository, lands in
    /// PLAINTEXT engine state and is reported to the calling model by the
    /// ungated timeline, so it is held to the same shape as every other remote
    /// token (`REMOTE_WRITER_DEVICE_RE` on the engine side).
    case projectIDOutOfShape = "team_project_id_out_of_shape"
    /// The sealed `teamID` is not the bounded token shape a `teamId` may take.
    ///
    /// Round-5 nit 1, the near half of the engine's `INVALID_TEAM_ID`. Unlike
    /// every other bounded string on this lane, `teamID` is not attribution: it
    /// SELECTS THE NAMESPACE the engine merges the document in. A value the
    /// engine cannot read was dropped there, which moved the document onto the
    /// member's PERSONAL lane under the sealer's own chosen `memoryID` — Cursor
    /// T2 reached through the selector. Both ends refuse it now.
    case teamIDOutOfShape = "team_id_out_of_shape"
    /// No usable `updatedAt`, so the row could not be ordered or watermarked.
    case missingUpdatedAt = "team_missing_updated_at"
    /// The unauthenticated outer `updatedAt` disagrees with the verified copy.
    case updatedAtMismatch = "team_updated_at_mismatch"
    /// A payload schema this build cannot read. A newer device sealed it.
    case unsupportedSchema = "team_unsupported_schema"
    /// A document in the FACTS collection carries forget-receipt semantics.
    ///
    /// PR3 Cursor ruling, T1 (HIGH). `verify` decodes a typed
    /// `TeamMemoryFactPayload` — which ignores unknown JSON keys — and then
    /// parks the ORIGINAL sealed plaintext as `payloadJSON`. The engine tells a
    /// receipt from a fact by `entryKind` in that JSON and purges by the inbox's
    /// `engineMemoryID`, so a member running a modified sealer could keep a
    /// perfectly legal fact shape, bolt `entryKind` plus a truthy
    /// `memoryIdHmac` onto it, name a `memoryID` learned from any prior team
    /// document, and DELETE that row on every member who pulled — a personal row
    /// sharing the engine id included.
    ///
    /// The ability is removed rather than narrowed: a fact-lane document may
    /// never carry forget semantics under any circumstances. A team forget
    /// arrives as a `team_memory_facts/{teamId}/forget_receipts/*` document that
    /// passes this same verify chain — AAD, author binding, doc-id
    /// re-derivation — and PR 4 owns reading that collection.
    case factCarriesReceiptSemantics = "team_fact_carries_receipt_semantics"
    /// The sealed `teamProjectId` is not one THIS checkout links to THIS team.
    ///
    /// PR3 Cursor ruling, T3 (MEDIUM). The sealed `projectID` was only
    /// shape-checked, and the engine keys `memories.project_id` — and therefore
    /// the MCP recall partition — on whatever it said. A member who can seal
    /// could land bodies into any well-formed project partition they knew the id
    /// of, on every member who pulls. The value is now required to appear in
    /// `.openburnbar/project.json`'s `teams.<teamId>.teamProjectId` for a
    /// repository this Mac has actually recorded.
    ///
    /// Permanent, and lossless: `pullTeamFacts` records the link set per
    /// `(team, member)` and rewinds this team's cursor the moment that set
    /// gains an id, so a repository cloned and linked LATER still receives what
    /// was refused before the link existed. See `isPermanent` below.
    case projectNotLinkedToTeam = "team_project_not_linked"

    /// Whether a later cycle re-reading this document could ever reach a
    /// different verdict. Same rule as the personal lane, plus the one refusal
    /// that is new here.
    var isPermanent: Bool {
        switch self {
        case .disallowedField, .identityMismatch, .teamMismatch,
             .authorMismatch, .projectIDOutOfShape, .teamIDOutOfShape,
             .factCarriesReceiptSemantics, .projectNotLinkedToTeam:
            // Decided on authenticated data (or on a key set the rules forbid).
            // Only a rewrite changes it, and a rewrite is a new revision.
            //
            // `.factCarriesReceiptSemantics` is PERMANENT for the same reason
            // `.authorMismatch` is: a fact-shaped document carrying a forget is
            // a FORGED document, not a transient state, and freezing on it would
            // hand any member a way to stop their whole team's lane for ever.
            //
            // `.projectNotLinkedToTeam` is permanent AND LOSSLESS. Freezing on
            // it would be strictly worse — one teammate contributing from a
            // repository this Mac has not cloned would stall every OTHER
            // project's team facts indefinitely, which is a denial of service
            // any member could trigger by accident — so the cursor moves past
            // the refusal. What would otherwise be the cost of that (a member
            // who clones and links the repository LATER never sees the
            // documents refused before the link existed) is paid by the
            // REWIND-ON-LINK rule in `pullTeamFacts`: the link set is recorded
            // per `(team, member)` in `remote_sync_watermarks`
            // (`RemoteSyncWatermarkStore.teamMemoryProjectLinkKindPrefix`), and
            // a set that has gained an id since the last successful pull
            // discards that team's cursor so every refused document is
            // re-scanned. Refused until linked, recovered on link.
            //
            // `.authorMismatch` is PERMANENT deliberately: a document whose
            // sealed author disagrees with the uid the rules pinned is a FORGED
            // document, not a transient state. The outer `uid` is immutable
            // after creation, so no later cycle can reach a different verdict —
            // and the alternative, freezing, would let one forged document stop
            // a member's whole team lane for ever.
            return true
        case .teamKeyVersionUnavailable:
            // The whole point of the version label: the envelope for this
            // generation may simply not have landed on this Mac yet. Freezing
            // here is correct — the document becomes readable the moment
            // `TeamVaultKeyDistributor.loadKeyRingFromEnvelopes` runs.
            return false
        case .malformedEnvelope, .sealedOpenFailed:
            // A key state this device may not be in yet, or a rewrap in flight.
            return false
        case .malformedPayload, .unsupportedSchema:
            // A NEWER device sealed it; an app update cures it without touching
            // the document.
            return false
        case .missingUpdatedAt, .updatedAtMismatch:
            // There is no instant to trust. Freezing is the whole point.
            return false
        }
    }
}

/// The team pull, behind a seam, for the same reason `MemoryCloudPulling` is
/// one: the domain runs push then pull inside a single call, so "what does a
/// cycle report when the team PULL fails" is otherwise unreachable from a test.
protocol TeamMemoryPulling: Sendable {
    /// - Parameter linkedTeamProjectIDs: every `teamProjectId` a repository ON
    ///   THIS MAC publishes to this team, from its checked-in
    ///   `.openburnbar/project.json`. The pull's admission set for the sealed
    ///   `projectID` (PR3 Cursor ruling, T3); an empty set means this checkout
    ///   is linked to nothing for this team, and the whole team space is refused
    ///   rather than landed in some other project's recall partition.
    @discardableResult
    func pullTeamFacts(
        teamID: String,
        localUserID: String,
        teamSlugKey: Data,
        linkedTeamProjectIDs: Set<String>,
        keyForVersion: @Sendable (Int) throws -> Data?,
        now: Date
    ) async throws -> TeamMemoryPullResult
}

final class TeamMemoryPullService: TeamMemoryPulling, Sendable {
    /// How far BELOW the stored cursor each cycle re-reads, for the same reason
    /// the personal lane does it: `updatedAt` is authored by whichever member
    /// wrote the document, and a teammate whose clock runs fast would otherwise
    /// drag this collection-wide cursor past writes that have not happened yet.
    /// A team makes that strictly worse than the personal lane — the clocks
    /// belong to different people on different networks — so the window is the
    /// same fifteen minutes and it is still a mitigation, not a fix.
    static let clockSkewRescanWindow: TimeInterval = MemoryCloudPullService.clockSkewRescanWindow

    static let maxPagesPerCycle = 25

    private let store: ControlPlaneStore
    private let firestoreGateway: CloudSyncFirestoreGateway
    private let watermarkStore: RemoteSyncWatermarkStore
    private let pageLimit: Int

    init(
        store: ControlPlaneStore,
        firestoreGateway: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway(),
        pageLimit: Int = 200
    ) {
        self.store = store
        self.firestoreGateway = firestoreGateway
        self.watermarkStore = RemoteSyncWatermarkStore(dbQueue: store.dbQueue)
        self.pageLimit = max(1, pageLimit)
    }

    /// The `remote_sync_watermarks` row key for one team on one account.
    ///
    /// NO NEW TABLE and NO NEW ENUM CASE: `collectionKind` is a closed Swift
    /// enum, but `accountUid` is a free-form text column, so the team cursor
    /// rides there under a namespaced key while `collectionKind` stays
    /// `memory_facts`. It reuses that case's `firstSyncFloor` (the epoch), which
    /// is exactly right here for exactly the same reason: a team fact is state,
    /// not an event, and a member joining today wants the team's whole history.
    ///
    /// The uid is part of the key even though the team id alone would identify
    /// the collection. Two members signing into the same Mac are the ordinary
    /// case on a shared machine, and a cursor keyed on the team alone would let
    /// the first member's progress silently skip documents for the second.
    static func watermarkAccountKey(teamID: String, localUserID: String) -> String {
        "team:\(teamID):\(localUserID)"
    }

    /// The `agent_memory_inbox.doc_id` a team document is parked under on THIS
    /// account, namespaced exactly like the watermark above.
    ///
    /// WHY THE CLOUD ID IS NOT USED DIRECTLY, unlike the personal lane.
    /// `agent_memory_inbox.doc_id` is the table's PRIMARY KEY and
    /// `upsertRemoteMemoryFact` resolves on it alone. That is safe on the
    /// personal lane because a personal document id is an HMAC under the
    /// member's own vault key and is therefore per-uid by construction. A TEAM
    /// document id is SHARED ACROSS MEMBERS by construction — that is the whole
    /// feature — so two members of one team on one Mac would collide on a single
    /// row: the first to sign in parks it under their uid, the engine merges it
    /// (`applied_at` set, so the account-switch purge, which deletes only
    /// unmerged rows, leaves it), and the second member's pull then resolves the
    /// same `doc_id`, sees an equal instant, reports `.unchanged` and advances
    /// its cursor past a fact it never received. The per-team-per-uid watermark
    /// alone cannot fix that; the row key has to carry the uid too.
    ///
    /// Prefixing is what makes that possible WITHOUT a schema change: the inbox
    /// `doc_id` is a purely local handle — the daemon acknowledges by
    /// `(user_id, doc_id)` and the engine treats it as an opaque token — so
    /// nothing downstream needs it to be the cloud id, and this lane resolves no
    /// forget receipts against it (PR 1 review F7). A `(doc_id, user_id)`
    /// composite key would need a migration, which this PR deliberately does not
    /// take.
    static func inboxDocID(teamID: String, localUserID: String, documentID: String) -> String {
        "\(inboxDocIDPrefix)\(teamID):\(localUserID):\(documentID)"
    }

    /// What marks an `agent_memory_inbox` row as TEAM-origin, in SQL as well as
    /// in Swift.
    ///
    /// A personal row's doc id is `pensieveSlugHmac("memory-fact:<engine id>")`
    /// — 64 hex characters — so it can never begin with this, and a query that
    /// excludes the prefix excludes exactly the team rows and nothing else.
    ///
    /// THE REASON THIS HAS TO BE EXCLUDABLE. A team row is parked under the
    /// `engineMemoryID` its payload seals, which on a hostile client is a
    /// teammate's engine id (PR3 Cursor ruling, T2). Any query that joins
    /// `agent_memory_bodies` to `agent_memory_inbox` on `engine_memory_id`
    /// ALONE therefore lets a team document be read as the arrival record of the
    /// member's own private memory. Those queries filter on this prefix; the
    /// isolation invariant is not only the engine's to keep.
    static let inboxDocIDPrefix = "team:"

    /// Reads `team_memory_facts/{teamId}/facts` on the composite
    /// `(updatedAt, documentID)` cursor above this team's watermark, verifies
    /// each document, and parks what survives in `agent_memory_inbox`.
    ///
    /// - Parameter localUserID: the SIGNED-IN member, which is what the parked
    ///   row is scoped to. Not the author: `agent_memory_inbox.user_id` is what
    ///   `MemoryDeviceSyncInboxGuard` and the daemon's consent marker filter on,
    ///   so a team row must be scoped to whoever is signed in on THIS Mac or an
    ///   account switch would hand it to the wrong person. The AUTHOR travels
    ///   inside `payloadJSON` as `authorUID`.
    /// - Parameter linkedTeamProjectIDs: see the protocol. THE LANDING PARTITION
    ///   COMES FROM THIS SET, not from the document: a sealed `projectID` is
    ///   admitted only by being one of these, so the value that reaches
    ///   `memories.project_id` is a project this checkout committed to sharing
    ///   with this team.
    /// - Parameter keyForVersion: the retained-key ring, keyed by generation.
    @discardableResult
    func pullTeamFacts(
        teamID: String,
        localUserID: String,
        teamSlugKey: Data,
        linkedTeamProjectIDs: Set<String>,
        keyForVersion: @Sendable (Int) throws -> Data?,
        now: Date = Date()
    ) async throws -> TeamMemoryPullResult {
        let watermarkKey = Self.watermarkAccountKey(teamID: teamID, localUserID: localUserID)

        // REWIND ON A NEW LINK — the recovery half of `.projectNotLinkedToTeam`.
        //
        // That refusal is PERMANENT, so the cursor moves past a fact whose
        // sealed `teamProjectId` this checkout does not link to the team. On its
        // own that would mean a member who clones and links the repository
        // tomorrow never receives what was refused today: the documents sit
        // below a cursor whose filter is strictly greater-than, and nothing in
        // the cloud changes to bring them back.
        //
        // So the pull remembers which links it saw. When the CURRENT set
        // contains a `teamProjectId` the record does not, something that was
        // unreadable has become readable, and this team's cursor is discarded
        // before the scan — the epoch floor of `memory_facts` then re-reads the
        // whole team space and lands everything that now verifies. Parking is
        // keyed on `(doc_id, remote_updated_at)` and is idempotent, so a rewind
        // costs reads and nothing else.
        //
        // GAINED, not merely CHANGED. Losing a link is deliberately not a
        // rewind: nothing became readable, the facts for that project start
        // being refused again exactly as before, and re-reading the collection
        // to refuse the same documents a second time would be pure cost. And it
        // is a rewind to the BEGINNING rather than to the oldest refused instant
        // because no such instant is recorded — recording one is a column this
        // PR may not take, and the epoch is the safe direction.
        let recordedLinks = try await watermarkStore.fetchTeamMemoryLinkedProjectIDs(accountUid: watermarkKey)
        let newlyLinked = linkedTeamProjectIDs.subtracting(recordedLinks)
        var rewoundForNewProjectLink = false
        if !newlyLinked.isEmpty {
            // Zero rows deleted means there was no cursor to discard — a first
            // cycle — which is a no-op, not a rewind.
            let discarded = try await watermarkStore.clearWatermark(
                accountUid: watermarkKey,
                collectionKind: .memoryFacts
            )
            rewoundForNewProjectLink = discarded > 0
            if rewoundForNewProjectLink {
                // The team id and the COUNT only. A `teamProjectId` is
                // member-authored text from a shared repository, and this log
                // is not the place to widen where it travels.
                AppLogger.sync.info(
                    "team_memory_pull_cursor_rewound_for_new_project_link",
                    metadata: [
                        "team_id": teamID,
                        "newly_linked_count": String(newlyLinked.count)
                    ]
                )
            }
        }

        let watermark = try await watermarkStore.fetchWatermarkOrDefault(
            accountUid: watermarkKey,
            collectionKind: .memoryFacts
        )
        let queryFloor = watermark.addingTimeInterval(-Self.clockSkewRescanWindow)

        let factCollection = firestoreGateway
            .collection(TeamMemorySyncService.factsRootCollection)
            .document(teamID)
            .collection(TeamMemorySyncService.factsSubcollection)

        let transaction = AtomicRemoteSyncTransaction(
            dbQueue: store.dbQueue,
            watermarkStore: watermarkStore,
            accountUid: watermarkKey,
            collectionKind: .memoryFacts
        )

        var applied = 0
        var unchanged = 0
        var rejected = 0
        var rejectedPermanent = 0
        var watermarkFrozen = false
        var rejectionFloor: Date?
        var eligibleStamps: [Date] = []
        var pageCursor: (updatedAt: Date, docID: String)?
        var pagesRead = 0
        var exhaustedCollection = false

        do {
            while pagesRead < Self.maxPagesPerCycle {
                var query: CloudSyncQueryGateway = factCollection
                    .whereField("updatedAt", isGreaterThan: queryFloor)
                    .order(by: "updatedAt", descending: false)
                    .orderByDocumentID(descending: false)
                if let pageCursor {
                    query = query.start(afterOrderedValues: [pageCursor.updatedAt, pageCursor.docID])
                }
                let snapshot = try await query.limit(to: pageLimit).getDocuments()
                pagesRead += 1
                let documents = snapshot.documents
                if documents.isEmpty {
                    exhaustedCollection = true
                    break
                }

                for document in documents {
                    let data = document.data()
                    let verified: VerifiedTeamFact
                    switch Self.verify(
                        document: document.documentID,
                        data: data,
                        teamID: teamID,
                        teamSlugKey: teamSlugKey,
                        linkedTeamProjectIDs: linkedTeamProjectIDs,
                        keyForVersion: keyForVersion
                    ) {
                    case .success(let value):
                        verified = value
                    case .failure(let reason, let verifiedInstant):
                        rejected += 1
                        let advances = reason.isPermanent && verifiedInstant != nil
                        if advances { rejectedPermanent += 1 }
                        if !advances, !watermarkFrozen {
                            watermarkFrozen = true
                            rejectionFloor = MemoryCloudPullService.firestoreDate(data["updatedAt"])
                        }
                        if advances, !watermarkFrozen, let verifiedInstant {
                            eligibleStamps.append(verifiedInstant)
                        }
                        // The doc id is an opaque team-wide HMAC, so logging it
                        // is safe and it is the only way to tell one document
                        // failing every cycle from a hundred failing once.
                        AppLogger.sync.error(
                            "team_memory_pull_document_rejected",
                            metadata: [
                                "reason": reason.rawValue,
                                "doc_id": document.documentID,
                                "permanent": String(advances)
                            ]
                        )
                        continue
                    }

                    let result = try await store.upsertRemoteMemoryFact(
                        // NAMESPACED per account, not the raw cloud id: a team
                        // document id is shared between members by construction
                        // and the inbox's primary key is the doc id alone. See
                        // `inboxDocID`.
                        docID: Self.inboxDocID(
                            teamID: teamID,
                            localUserID: localUserID,
                            documentID: document.documentID
                        ),
                        // The SIGNED-IN member, not the author. See the
                        // parameter's own note.
                        userID: localUserID,
                        engineMemoryID: verified.payload.memoryID,
                        payloadJSON: verified.payloadJSON,
                        remoteUpdatedAt: verified.remoteUpdatedAt,
                        // Deliberately nil. On the personal lane this retro-fits
                        // a parked forget receipt with a plain engine id; a TEAM
                        // receipt is a claim rather than an authority (PR 1
                        // review F7 — the rules cannot tell whose fact an opaque
                        // HMAC names), so this lane does not resolve receipts
                        // and PR 4 owns the honouring path.
                        resolvingReceiptHmac: nil,
                        now: now
                    )
                    switch result.outcome {
                    case .inserted, .replaced:
                        applied += 1
                    case .unchanged:
                        unchanged += 1
                    }
                    if !watermarkFrozen {
                        eligibleStamps.append(verified.remoteUpdatedAt)
                    }
                }

                if documents.count < pageLimit {
                    exhaustedCollection = true
                    break
                }
                guard let last = documents.last,
                      let lastStamp = MemoryCloudPullService.firestoreDate(last.data()["updatedAt"]) else {
                    AppLogger.sync.error("team_memory_pull_page_cursor_unreadable")
                    break
                }
                pageCursor = (lastStamp, last.documentID)
            }
        } catch {
            transaction.rollback()
            throw error
        }

        var eligible = eligibleStamps
        if watermarkFrozen {
            eligible = rejectionFloor.map { floor in eligibleStamps.filter { $0 < floor } } ?? []
        }
        let stoppedShort = !exhaustedCollection && !watermarkFrozen
        if let ceiling = MemoryCloudPullService.watermarkCeiling(
            eligibleStamps: eligible,
            pageWasFull: stoppedShort
        ) {
            for stamp in eligible where stamp <= ceiling {
                transaction.recordProcessedItem(remoteUpdatedAt: stamp)
            }
        }
        try await transaction.commit()

        // Only after the cursor committed, and only when the set actually moved
        // — the steady state costs no write. A pull that THREW never reaches
        // here, which is what it should do: the record stays as it was, and the
        // next cycle is free to decide the same rewind again.
        if recordedLinks != linkedTeamProjectIDs {
            try await watermarkStore.replaceTeamMemoryLinkedProjectIDs(
                accountUid: watermarkKey,
                projectIDs: linkedTeamProjectIDs,
                now: now
            )
        }

        return TeamMemoryPullResult(
            applied: applied,
            unchanged: unchanged,
            rejected: rejected,
            rejectedPermanent: rejectedPermanent,
            pagesRead: pagesRead,
            rewoundForNewProjectLink: rewoundForNewProjectLink
        )
    }

    // MARK: - Verification

    struct VerifiedTeamFact {
        let payload: TeamMemoryFactPayload
        let payloadJSON: String
        let remoteUpdatedAt: Date
    }

    enum TeamVerificationOutcome {
        case success(VerifiedTeamFact)
        /// `verifiedInstant` is the sealed `updatedAt` when the envelope opened
        /// AND the outer field matched it — an instant a backend could not have
        /// chosen. Only a PERMANENT refusal carrying one moves the cursor.
        case failure(TeamMemoryPullRejection, verifiedInstant: Date?)
    }

    /// Pure, side-effect-free admission check.
    ///
    /// ORDER MATTERS and it is not the order the checks were written in, for the
    /// same reason as `MemoryCloudPullService.verify`: the AUTHENTICATED half
    /// runs first — select the key, open the envelope, decode, bind the outer
    /// ordering key to the sealed one — so that every refusal after that point
    /// carries an instant a backend could not have chosen, which is what lets a
    /// permanently invalid document advance the cursor instead of pinning it
    /// below itself for ever.
    static func verify(
        document documentID: String,
        data: [String: Any],
        teamID: String,
        teamSlugKey: Data,
        linkedTeamProjectIDs: Set<String>,
        keyForVersion: (Int) throws -> Data?
    ) -> TeamVerificationOutcome {
        let payload: TeamMemoryFactPayload
        let plaintext: Data
        do {
            let opened = try openAndDecode(
                documentID: documentID,
                sealedMemory: data["sealedMemory"],
                teamID: teamID,
                keyForVersion: keyForVersion
            )
            payload = opened.payload
            plaintext = opened.plaintext
        } catch let outcome as TeamVerificationFailure {
            return .failure(outcome.reason, verifiedInstant: nil)
        } catch {
            return .failure(.sealedOpenFailed, verifiedInstant: nil)
        }
        guard payload.schemaVersion >= 1,
              payload.schemaVersion <= TeamMemoryFactPayload.currentSchemaVersion else {
            return .failure(.unsupportedSchema, verifiedInstant: nil)
        }
        guard let remoteUpdatedAt = MemoryCloudPullService.firestoreDate(data["updatedAt"]) else {
            return .failure(.missingUpdatedAt, verifiedInstant: nil)
        }
        // The outer `updatedAt` is the ordering, watermark and idempotence key
        // and it lives OUTSIDE the AAD, so a hostile backend could rewrite it to
        // skip the cursor past a document or make a stale revision win. The
        // sealed payload carries the same instant; requiring agreement binds the
        // key to authenticated data.
        guard MemoryCloudPullService.sameSealedInstant(remoteUpdatedAt, payload.updatedAt) else {
            return .failure(.updatedAtMismatch, verifiedInstant: nil)
        }
        // From here down the instant is trustworthy, so a refusal may carry it.
        guard Set(data.keys).isSubset(of: TeamMemorySyncService.allowedDocumentFields) else {
            return .failure(.disallowedField, verifiedInstant: remoteUpdatedAt)
        }
        // FORGET SEMANTICS ARE NOT AVAILABLE ON THIS LANE (Cursor T1). The check
        // is on the RAW plaintext, not the decoded payload, because
        // `TeamMemoryFactPayload` is what ignores these keys — decoding it and
        // then asking the struct would ask the one representation that cannot
        // see them, while `payloadJSON` (which the engine reads, and which is
        // the raw bytes) can.
        guard !carriesForgetSemantics(plaintext) else {
            return .failure(.factCarriesReceiptSemantics, verifiedInstant: remoteUpdatedAt)
        }
        // The sealed team id must be the collection this document was read from.
        // The AAD already binds it cryptographically, so this cannot fail on a
        // document any first-party client wrote; it is here because "the two
        // halves agree about which team this is" is worth one comparison rather
        // than a comment claiming the AAD covers it.
        guard payload.teamID == teamID else {
            return .failure(.teamMismatch, verifiedInstant: remoteUpdatedAt)
        }
        // ...AND IT MUST BE A TEAM TOKEN (round-5 nit 1). The equality above
        // only says the two halves AGREE; it says nothing about what they agree
        // on, and `teamID` reaches this function from the roster rather than
        // from a shape check. Past the daemon boundary this value SELECTS THE
        // NAMESPACE the engine merges in, so a value outside the minter's shape
        // is refused here and again by `REMOTE_TEAM_ID_RE` — one enforcement
        // point on a value that crosses a process boundary is one too few, the
        // same argument `projectIDOutOfShape` makes one guard below.
        guard TeamMemorySyncService.isWellFormedTeamID(payload.teamID) else {
            return .failure(.teamIDOutOfShape, verifiedInstant: remoteUpdatedAt)
        }
        // AUTHORSHIP, BOUND END TO END. The rules pin the OUTER `uid` to
        // `request.auth.uid` on create and refuse any update that moves it, so
        // that field — and only that field — is an authenticated statement about
        // who wrote this document. The value that actually TRAVELS is the sealed
        // `authorUID`: it goes into `payloadJSON`, the daemon lifts it, the
        // engine lands it in `history_meta["authorUID"]`, and the "Team fact ·
        // contributed by X" badge reads it. Nothing else compares the two, so
        // without this guard any active member could seal a colleague's uid into
        // a document the rules accept under their own and durably attribute an
        // invented fact to that colleague on every teammate's Mac.
        //
        // Because the comparison is an equality, the `authorUID` this function
        // hands on inside `payloadJSON` IS the outer, rules-pinned uid — byte for
        // byte — which is what makes "authorship is immutable even to an admin"
        // a claim about the field the product reads rather than the one nobody
        // does.
        guard let outerUID = data["uid"] as? String, outerUID == payload.authorUID else {
            return .failure(.authorMismatch, verifiedInstant: remoteUpdatedAt)
        }
        // `projectID` is the one payload field authored by a FILE in a shared
        // repository rather than by this product, and it reaches plaintext
        // `memories.project_id`, an `engine_meta` key and an audit label on every
        // teammate's Mac. Bounded here to the same token shape the engine holds
        // every other remote string to; the engine refuses it a second time
        // (`REMOTE_PROJECT_ID_RE`), because one enforcement point on a value that
        // crosses a process boundary is one process too few.
        guard TeamMemorySyncService.isWellFormedTeamProjectID(payload.projectID) else {
            return .failure(.projectIDOutOfShape, verifiedInstant: remoteUpdatedAt)
        }
        // ...AND IT MUST BE ONE THIS CHECKOUT LINKS TO THIS TEAM (Cursor T3).
        // Shape alone was never an admission decision: the engine keys
        // `memories.project_id` — and therefore the MCP recall partition every
        // model reads — on this token, so a well-formed id the member never
        // agreed to share is a body injected into another project's live recall.
        // The link is a FILE IN A REPOSITORY THIS MAC HAS RECORDED
        // (`.openburnbar/project.json`), so the admission set is the member's
        // own committed decision and no document can widen it.
        guard linkedTeamProjectIDs.contains(payload.projectID) else {
            return .failure(.projectNotLinkedToTeam, verifiedInstant: remoteUpdatedAt)
        }
        // The convergence identity sealed inside must derive the id the document
        // is keyed on. Without this a document could name one fact on the
        // outside and carry another on the inside, and the engine would merge
        // the wrong body under the right id.
        let expectedDocID: String
        do {
            expectedDocID = try TeamMemorySyncService.deriveDocID(
                teamID: teamID,
                teamProjectId: payload.projectID,
                engineScope: payload.engineScope,
                bodyHash: payload.bodyHash,
                teamSlugKey: teamSlugKey
            )
        } catch {
            return .failure(.identityMismatch, verifiedInstant: remoteUpdatedAt)
        }
        guard expectedDocID == documentID else {
            return .failure(.identityMismatch, verifiedInstant: remoteUpdatedAt)
        }
        guard let payloadJSON = String(data: plaintext, encoding: .utf8) else {
            return .failure(.malformedPayload, verifiedInstant: nil)
        }
        return .success(VerifiedTeamFact(
            payload: payload,
            payloadJSON: payloadJSON,
            remoteUpdatedAt: remoteUpdatedAt
        ))
    }

    /// The typed refusal the open/decode step throws, so the caller above reads
    /// as a straight sequence instead of five nested `do/catch` blocks. Never
    /// escapes this file.
    private struct TeamVerificationFailure: Error {
        let reason: TeamMemoryPullRejection
    }

    /// The keys that make a parked payload a FORGET rather than a fact, in the
    /// raw sealed bytes the engine will actually read.
    ///
    /// The engine's own test is narrower — `_is_receipt_entry` looks only at
    /// `entryKind` — and this is deliberately wider than that. A team fact has
    /// never carried any of these, on any schema version, so refusing all of
    /// them costs nothing legitimate and does not have to be revisited each time
    /// the receipt shape gains a field. Presence is enough; the values are never
    /// inspected, because a document that is trying to be a receipt is already
    /// refused whatever it says.
    static func carriesForgetSemantics(_ plaintext: Data) -> Bool {
        // This predicate answers ONE question — "does the raw payload carry
        // receipt keys" — and bytes that are not a JSON object carry none. The
        // typed decode that runs BEFORE this already refused an unparseable
        // payload as `.malformedPayload`, so a `do/catch` here could only
        // re-derive a refusal already made, under a rejection case that would
        // then mean two different things.
        // try?-ok(the failure IS the answer: unparseable bytes carry no receipt keys)
        guard let object = try? JSONSerialization.jsonObject(with: plaintext),
              let fields = object as? [String: Any] else {
            return false
        }
        return !Set(fields.keys).isDisjoint(with: Self.receiptOnlyPayloadKeys)
    }

    /// Never present on a team FACT, on any schema version.
    static let receiptOnlyPayloadKeys: Set<String> = [
        "entryKind",
        "memoryIdHmac",
        "sourceRefHmac",
        "sourceRefHmacs",
        "receiptID",
        "replicatedAt"
    ]

    /// - Parameter sealedMemory: the document's `sealedMemory` field and nothing
    ///   else. It takes the ONE field it opens rather than the whole untyped
    ///   document, because a function handed the whole thing reads as if it
    ///   admitted the rest of it — and every other field's admission decision is
    ///   made by `verify` above, in the order that makes each refusal's instant
    ///   trustworthy. `CloudVaultCrypto.decodeBlobEnvelope` is the typed decoder
    ///   for exactly this value, so the untyped hop ends one line in.
    private static func openAndDecode(
        documentID: String,
        sealedMemory: Any?,
        teamID: String,
        keyForVersion: (Int) throws -> Data?
    ) throws -> (payload: TeamMemoryFactPayload, plaintext: Data) {
        guard let envelope = CloudVaultCrypto.decodeBlobEnvelope(from: sealedMemory) else {
            throw TeamVerificationFailure(reason: .malformedEnvelope)
        }
        let keyData: Data?
        do {
            keyData = try keyForVersion(envelope.keyVersion)
        } catch {
            // A ring that cannot be read is indistinguishable from one that does
            // not hold the version, and both cure the same way.
            throw TeamVerificationFailure(reason: .teamKeyVersionUnavailable)
        }
        guard let keyData else {
            throw TeamVerificationFailure(reason: .teamKeyVersionUnavailable)
        }
        let aad: CloudVaultAADContext
        do {
            aad = try TeamMemorySyncService.teamAADContext(teamID: teamID, docID: documentID)
        } catch {
            // The context refuses ids this document could never legitimately
            // carry, so a throw here IS the admission decision.
            throw TeamVerificationFailure(reason: .sealedOpenFailed)
        }
        let plaintext: Data
        do {
            plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: keyData, aadContext: aad)
        } catch {
            throw TeamVerificationFailure(reason: .sealedOpenFailed)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return (try decoder.decode(TeamMemoryFactPayload.self, from: plaintext), plaintext)
        } catch {
            throw TeamVerificationFailure(reason: .malformedPayload)
        }
    }

}
