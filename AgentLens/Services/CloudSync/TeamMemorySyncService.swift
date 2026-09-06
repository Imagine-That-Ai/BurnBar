import FirebaseFirestore
import Foundation
import OpenBurnBarKernel

// MARK: - Team memory sealing and opening (memory program D16 / P22, PR 3)
//
// The team lane's answer to `MemoryCloudSyncService.encodeMemoryFact` +
// `MemoryCloudPullService.verify`. It seals an approved, engine-mirrored memory
// into `team_memory_facts/{teamId}/facts/{docID}` and opens what comes back.
//
// The lane is BLIND: the server holds ciphertext, opaque 64-hex document ids and
// opaque source HMACs, and never a team key. It is not private BETWEEN members —
// every active member holds the team vault key and can read every team fact.
// Consent here is a contribution and display control, not a confidentiality
// boundary; the roster (server-owned) is what decides who is a member at all.
//
// TWO KEYS, AND THE REASON THE DOCUMENT ID USES THE SECOND ONE (design §3(a),
// defect 2). `teamVaultKey_vN` seals content and rotates on every departure;
// `teamSlugKey` names documents and never rotates. Keying the document id on the
// sealing key — what the held attempt did — meant every rotation re-named every
// document and orphaned the entire team space. Keying it on a permanent key that
// seals nothing costs only what the server already sees: which opaque ids exist.
//
// AND THE REASON THE PRE-IMAGE IS THE ENGINE'S CONVERGENCE IDENTITY. Two members
// who learn the same fact independently mint two different engine memory ids, so
// a doc id derived from a row id would give the team two documents for one fact
// and dedup would never fire. The engine already has an identity that IS the
// same on both machines — `(project_id, scope, body_hash)`, folded to 32 hex by
// `memory_engine/_util.py::_convergence_key` — so the document id derives from
// that, byte for byte, and the two members converge on ONE document.
//
// The project half of that identity is `teamProjectId` from the checked-in
// `.openburnbar/project.json`, NOT the device-local engine project id: the
// engine's `project_identity_fingerprint` hashes the git remote URL, so a member
// who cloned over SSH and one who cloned over HTTPS derive different `proj_` ids
// for the same repository and would silently never converge. See
// `TeamProjectLink`.

/// The plaintext a `team_memory_facts` document seals.
///
/// Its key names are deliberately the ones `MemoryCloudFactPayload` already uses
/// (`memoryID`, `projectID`, `engineScope`, `bodyHash`, …), because this JSON is
/// handed to the Memory MCP engine verbatim through `agent_memory_inbox` and the
/// engine's `_screen_remote_row` reads those names. `teamID` and `authorUID` are
/// the two additions, and they ride INSIDE the ciphertext exactly as
/// `writerDevice` does — provenance the server never sees.
///
/// Two personal-lane fields are deliberately ABSENT:
///
///   * `citations` — a citation names a thread and a message in the member's own
///     chat history. Teammates have no business holding those ids, and the
///     engine never reads them from a remote payload. The outer document still
///     carries their keyed `sourceRefHmacs`, which is what a forget receipt
///     matches on.
///   * `scope` (the app's `MemoryScope`) — it carries the author's local user id
///     and the engine keys convergence on `engineScope` instead.
struct TeamMemoryFactPayload: Codable, Equatable, Sendable {
    /// Bumped only when a new field lands; readers accept every version <= this.
    /// Starts at 2 because `firestore.rules` requires `schemaVersion >= 2` on a
    /// team fact and the engine's `REMOTE_PAYLOAD_SCHEMA_MAX` is 2.
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    /// The team this fact belongs to. Bound by the AAD as well, so a document
    /// spliced into another team's collection cannot open.
    let teamID: String
    /// Who contributed it. The outer `uid` carries the same value in plaintext
    /// (the rules pin authorship to it and make it immutable even for an admin);
    /// this sealed copy is what the receiving engine attributes the row to.
    let authorUID: String
    let memoryID: MemoryID
    let text: String
    let kind: MemoryKind
    let confidence: Double
    let validFrom: Date
    let updatedAt: Date
    let validTo: Date?
    let supersededBy: MemoryID?
    let tags: [String]?
    /// The engine's body hash — one third of the convergence identity.
    let bodyHash: String
    /// The TEAM project id from `.openburnbar/project.json`, not the device's
    /// own engine project id. The other third of the convergence identity, and
    /// what the receiving engine keys the merged row on.
    let projectID: String
    /// `project` | `personal`, from `agent_memories.scope`.
    let engineScope: String
    let previousBodyHash: String?
    let writerDevice: String?

    init(
        schemaVersion: Int = TeamMemoryFactPayload.currentSchemaVersion,
        teamID: String,
        authorUID: String,
        memoryID: MemoryID,
        text: String,
        kind: MemoryKind,
        confidence: Double,
        validFrom: Date,
        updatedAt: Date,
        validTo: Date? = nil,
        supersededBy: MemoryID? = nil,
        tags: [String]? = nil,
        bodyHash: String,
        projectID: String,
        engineScope: String,
        previousBodyHash: String? = nil,
        writerDevice: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.teamID = teamID
        self.authorUID = authorUID
        self.memoryID = memoryID
        self.text = text
        self.kind = kind
        self.confidence = confidence
        self.validFrom = validFrom
        self.updatedAt = updatedAt
        self.validTo = validTo
        self.supersededBy = supersededBy
        self.tags = tags
        self.bodyHash = bodyHash
        self.projectID = projectID
        self.engineScope = engineScope
        self.previousBodyHash = previousBodyHash
        self.writerDevice = writerDevice
    }
}

/// One citation, reduced to what a team document may carry: the three source
/// components the keyed HMAC is computed over. The values never leave this
/// device — only the HMAC does.
struct TeamMemorySourceRef: Equatable, Sendable {
    let threadLogicalID: String
    let messageID: String?
    let contentHash: String?

    init(threadLogicalID: String, messageID: String?, contentHash: String?) {
        self.threadLogicalID = threadLogicalID
        self.messageID = messageID
        self.contentHash = contentHash
    }

    init(citation: MemoryCitation) {
        self.init(
            threadLogicalID: citation.threadLogicalID,
            messageID: citation.messageID,
            contentHash: citation.contentHash
        )
    }
}

/// Why a team fact could not be sealed or opened. A log dimension and an error
/// string; never a model path and never something a hostile document steers.
enum TeamMemorySyncError: LocalizedError, Equatable {
    /// This device holds no key for the version a document names. NOT permanent:
    /// the envelope may still be on its way (`TeamVaultKeyDistributor
    /// .loadKeyRingFromEnvelopes`), so the caller parks and retries.
    case teamKeyVersionUnavailable(teamId: String, keyVersion: Int)
    /// The slug key is missing, so no document id can be derived at all.
    case teamSlugKeyUnavailable(teamId: String)
    /// `sealedMemory` is missing or is not a blob envelope.
    case malformedEnvelope(docID: String)
    /// The row carries no `(teamProjectId, engineScope, bodyHash)`, so it has no
    /// convergence identity and can never key a team document.
    case missingConvergenceIdentity(memoryID: MemoryID)

    var errorDescription: String? {
        switch self {
        case .teamKeyVersionUnavailable(let teamId, let keyVersion):
            return "This device does not hold team \(teamId)'s key generation \(keyVersion) yet."
        case .teamSlugKeyUnavailable(let teamId):
            return "This device does not hold team \(teamId)'s document-naming key yet."
        case .malformedEnvelope(let docID):
            return "Team memory document \(docID) does not carry a readable sealed envelope."
        case .missingConvergenceIdentity(let memoryID):
            return "Memory \(memoryID) carries no team project identity, so it cannot key a team document."
        }
    }
}

/// The sealing and opening half of the team lane. Pure and static: everything
/// here is decided from its arguments, so the whole admission surface is
/// testable without Firestore, a Keychain or an account.
enum TeamMemorySyncService {
    static let factsRootCollection = "team_memory_facts"
    static let factsSubcollection = "facts"

    /// Exactly the keys `firestore.rules` permits on a `team_memory_facts`
    /// document. Kept in lockstep with `validTeamMemoryFact()` there.
    ///
    /// `vaultGeneration` is deliberately absent for the same reason the rules
    /// omit it: it is a personal-vault concept, and admitting it would let the
    /// personal rewrap worker's update shape be read as a valid team document.
    static let allowedDocumentFields: Set<String> = [
        "uid",
        "teamId",
        "docID",
        "schemaVersion",
        "sourceKind",
        "kind",
        "reviewStatus",
        "sealedMemory",
        "sourceRefHmacs",
        "citationCount",
        "validFrom",
        "updatedAt",
        "replicatedAt",
        "teamKeyVersion",
        "rewrapJobId"
    ]

    /// The most source-ref HMACs a document may carry, mirroring the personal
    /// lane and `validMemorySourceRefHmacs` in the rules.
    static let maxSourceRefHmacs = 50

    /// The shape a `teamProjectId` may take, byte-for-byte the engine's
    /// `REMOTE_WRITER_DEVICE_RE` (`^[A-Za-z0-9_.:-]{1,128}$`) and refused by
    /// `REMOTE_PROJECT_ID_RE` on the far side of the daemon boundary.
    ///
    /// WHY THIS FIELD IS BOUNDED WHEN THE PERSONAL LANE'S IS NOT. On the
    /// personal lane `projectID` is minted by the engine on the member's own
    /// Mac, so there is no author to bound. On the TEAM lane it is
    /// member-authored text read out of `.openburnbar/project.json` — a file
    /// committed to a shared repository, so anyone with commit access supplies
    /// it — and it lands in PLAINTEXT as `memories.project_id`, as part of an
    /// `engine_meta` convergence key, and as an audit-event label on every
    /// teammate's Mac, where the ungated timeline reports it to the calling
    /// model. That is a prompt-injection channel and a disclosure channel in one
    /// string, which is the same argument that bounds `teamID`, `authorUID`,
    /// `writerDevice`, `memoryID`, `supersededBy` and `previousBodyHash` — and it
    /// bites harder here, because this is the only one of them that comes from a
    /// file rather than from a machine.
    ///
    /// The token shape is deliberately permissive about CONTENT (a team names
    /// its own projects) and strict about FORM: one line, no whitespace, no
    /// punctuation an instruction could be built from, and a hard length cap.
    static let teamProjectIDPattern = "^[A-Za-z0-9_.:-]{1,128}$"

    /// Whether a `teamProjectId` is inside `teamProjectIDPattern`. Enforced at
    /// BOTH ends of the lane: when the link file is read (a bad entry publishes
    /// nothing) and when a document is pulled (a bad one is refused), because
    /// the reader protects this Mac's uploads and the pull protects this Mac
    /// from a teammate whose reader was older.
    static func isWellFormedTeamProjectID(_ value: String) -> Bool {
        value.range(of: teamProjectIDPattern, options: .regularExpression) != nil
    }

    /// The shape a `teamId` may take, byte-for-byte the engine's
    /// `REMOTE_TEAM_ID_RE` (`\Ateam_[0-9a-f]{16}\Z`) and the only shape
    /// `functions/src/teamRoster.ts::newTeamId` can mint:
    /// `` `team_${randomUUID().replace(/-/gu, "").slice(0, 16)}` `` — a UUID's
    /// canonical text is lowercase hex, so stripping the dashes and taking 16
    /// characters yields exactly this.
    ///
    /// WHY THIS ONE IS NOT MERELY ATTRIBUTION. `teamID` travels into
    /// `payloadJSON` and, past the daemon boundary, SELECTS THE NAMESPACE the
    /// engine merges the document in: a value the engine cannot read used to be
    /// dropped, which silently moved the document onto the member's PERSONAL
    /// lane, keyed on the sealer's own `memoryID`. The engine refuses it now
    /// (`INVALID_TEAM_ID`); this is the near half of the same refusal, so a
    /// document that could only ever be refused never reaches the inbox at all.
    ///
    /// `^`/`$` here are NSRegularExpression's, which — unlike Python's `$` — do
    /// not admit a trailing newline by default, so this is the exact anchor pair
    /// the engine spells `\A`/`\Z`.
    static let teamIDPattern = "^team_[0-9a-f]{16}$"

    /// Whether a `teamId` is inside `teamIDPattern`. Enforced at both ends of
    /// the lane for the same reason `isWellFormedTeamProjectID` is: the reader
    /// protects this Mac's uploads, the pull protects this Mac from a teammate
    /// whose client was modified.
    static func isWellFormedTeamID(_ value: String) -> Bool {
        value.range(of: teamIDPattern, options: .regularExpression) != nil
    }

    // MARK: Identity

    /// The team-bound AAD. `uid: "team:<teamId>"` needs no new primitive:
    /// `CloudVaultAADContext` treats the uid slot as a free-form validated part
    /// and `firestore.rules`'s `validCloudVaultAAD` accepts `[^|]+` there.
    ///
    /// KEPT VERBATIM from the held attempt — this part of it was right.
    static func teamAADContext(teamID: String, docID: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: "team:\(teamID)",
            collection: factsRootCollection,
            docID: docID,
            field: "sealedMemory"
        )
    }

    /// The engine's own convergence identity, folded to 32 hex characters.
    ///
    /// BYTE-IDENTICAL to `memory_engine/_util.py::_convergence_key`:
    /// `sha256_hex(f"{project_id}|{scope}|{body_hash}")[:32]`. Pipes, not
    /// colons; SHA-256, not HMAC; 32 characters, not 64. Pinned from both sides
    /// by `test_the_swift_convergence_key_matches_the_python_one` and its Python
    /// twin, because a one-character drift here would silently give two members
    /// two documents for one fact and no error anywhere.
    static func convergenceKey(teamProjectId: String, engineScope: String, bodyHash: String) -> String {
        String(CloudVaultCrypto.sha256Hex("\(teamProjectId)|\(engineScope)|\(bodyHash)").prefix(32))
    }

    /// The opaque document id, HMAC'd under the NON-ROTATING slug key.
    ///
    /// Two members who learned the same fact independently derive the same id
    /// here — that is the whole point — and a key rotation leaves every id
    /// untouched, so a rewrap re-seals in place instead of orphaning the space.
    static func deriveDocID(teamID: String, convergenceKey: String, teamSlugKey: Data) throws -> String {
        try CloudVaultCrypto.pensieveSlugHmac(
            "team-memory-fact:\(teamID):\(convergenceKey)",
            keyData: teamSlugKey
        )
    }

    /// Convenience over the two steps above, for the ordinary case where the
    /// caller holds the identity components rather than the folded key.
    static func deriveDocID(
        teamID: String,
        teamProjectId: String,
        engineScope: String,
        bodyHash: String,
        teamSlugKey: Data
    ) throws -> String {
        try deriveDocID(
            teamID: teamID,
            convergenceKey: convergenceKey(
                teamProjectId: teamProjectId,
                engineScope: engineScope,
                bodyHash: bodyHash
            ),
            teamSlugKey: teamSlugKey
        )
    }

    /// The keyed HMAC that names one citation's source, under the SLUG key.
    ///
    /// Under the slug key, not the vault key, and that is load-bearing: the
    /// vault key rotates on every departure, so HMACs computed under it would
    /// stop matching the forget receipts already filed against them and a
    /// retraction would silently stop working after the first rotation. The slug
    /// key never rotates, so a receipt filed under v1 still names the same fact
    /// under v7.
    ///
    /// The pre-image is `MemoryCloudSyncService.sourceRefHmac`'s, so the two
    /// lanes agree about what a source reference IS; only the key differs.
    static func sourceRefHmac(_ ref: TeamMemorySourceRef, teamSlugKey: Data) throws -> String {
        try CloudVaultCrypto.pensieveSlugHmac(
            "memory-source:\(ref.threadLogicalID)|\(ref.messageID ?? "")|\(ref.contentHash ?? "")",
            keyData: teamSlugKey
        )
    }

    // MARK: Seal

    /// Seals one team fact into the outer document `firestore.rules` accepts.
    ///
    /// - Parameter teamKeyVersion: the roster's LIVE `activeKeyVersion`. It is
    ///   stamped on the outer document AND inside the envelope, and the rules
    ///   require both to equal the roster's current generation — so a write
    ///   sealed under a superseded key is refused at the door rather than
    ///   landing as a document nobody can open. The label is a key-selection
    ///   hint only; the keyed `plaintextHMAC` inside `validCloudSealedBlob` is
    ///   what actually binds the key.
    static func sealTeamFact(
        payload: TeamMemoryFactPayload,
        sourceRefs: [TeamMemorySourceRef],
        teamVaultKey: Data,
        teamSlugKey: Data,
        teamKeyVersion: Int,
        now: Date
    ) throws -> (docID: String, data: [String: Any]) {
        let docID = try deriveDocID(
            teamID: payload.teamID,
            teamProjectId: payload.projectID,
            engineScope: payload.engineScope,
            bodyHash: payload.bodyHash,
            teamSlugKey: teamSlugKey
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payloadData = try encoder.encode(payload)
        let aad = try teamAADContext(teamID: payload.teamID, docID: docID)
        let sealed = try CloudVaultCrypto.sealBlob(
            payloadData,
            keyData: teamVaultKey,
            keyVersion: teamKeyVersion,
            aadContext: aad
        )
        // REAL HMACs, deduplicated, capped — and the count is DERIVED from the
        // list rather than computed beside it. The held attempt wrote
        // `"a" * 64` placeholders with a real `citationCount`, so the two
        // numbers could disagree; the rules now require
        // `citationCount == sourceRefHmacs.size()`, and deriving one from the
        // other is what makes that impossible to violate by construction.
        var seen = Set<String>()
        let sourceRefHmacs = try Array(
            sourceRefs
                .map { try sourceRefHmac($0, teamSlugKey: teamSlugKey) }
                .filter { seen.insert($0).inserted }
                .prefix(maxSourceRefHmacs)
        )
        return (
            docID,
            [
                "uid": payload.authorUID,
                "teamId": payload.teamID,
                "docID": docID,
                "schemaVersion": TeamMemoryFactPayload.currentSchemaVersion,
                // Only engine-mirrored rows are ever eligible (a chat memory has
                // no convergence identity), so this is always `agent`.
                "sourceKind": MemorySourceKind.agent.rawValue,
                "kind": payload.kind.rawValue,
                "reviewStatus": MemoryReviewStatus.approved.rawValue,
                "sealedMemory": try CloudVaultCrypto.firestoreDictionary(sealed),
                "sourceRefHmacs": sourceRefHmacs,
                "citationCount": sourceRefHmacs.count,
                "validFrom": payload.validFrom,
                "updatedAt": payload.updatedAt,
                "replicatedAt": now,
                "teamKeyVersion": teamKeyVersion
            ]
        )
    }

    // MARK: Key selection

    /// The ONE place the client-held ring is consulted for a key that has to
    /// open or seal stored content.
    ///
    /// RETAINED AND ACTIVE SLOTS ONLY — never pending. PR 2's `TeamVaultKeyRing`
    /// holds two kinds of generation: an ACTIVE one, which the roster authority
    /// has recorded and every member's envelopes carry, and a PENDING one, which
    /// this Mac minted locally before publishing a single envelope so that an
    /// interrupted rotation resumes with the same `v(N+1)` instead of stranding
    /// the members who already received the first attempt's wraps
    /// (`TeamVaultKeyRing.pendingKey`, PR 2 review B1(b)).
    ///
    /// A pending generation must never reach this lane, in either direction:
    ///
    ///   * OPENING. Nothing in the cloud can legitimately be sealed under a
    ///     generation the roster has not recorded — `firestore.rules` pins every
    ///     fact write to `activeTeamKeyVersion(teamId)`. A document that names a
    ///     pending generation is therefore either a rotation this Mac has not
    ///     finished announcing or a document that should not exist, and opening
    ///     it would turn "the authority never confirmed this key" into "this
    ///     content is fine". Refusing is also non-destructive: the refusal is
    ///     `.teamKeyVersionUnavailable`, which parks without advancing the
    ///     cursor, so the fact is admitted the moment the promotion lands.
    ///   * SEALING. Writing under a pending generation would be rejected by the
    ///     rules anyway, but it would first burn a convergence-keyed document id
    ///     on a blob no other member can ever read.
    ///
    /// `TeamVaultKeyRing.key(teamId:slot:)` reads the active account only —
    /// pending lives at a separate address — so the exclusion is structural. This
    /// function exists so that it is stated once, at the boundary that depends on
    /// it, and pinned by `test_a_pending_team_key_generation_neither_opens_nor_seals`.
    static func retainedKey(
        from ring: any TeamVaultKeyRing,
        teamID: String,
        slot: TeamKeySlot
    ) throws -> Data? {
        try ring.key(teamId: teamID, slot: slot)
    }

    /// The opening-key selector `openTeamFact` and `TeamMemoryPullService` take,
    /// built over the retained half of the ring and nothing else.
    static func retainedKeySelector(
        from ring: any TeamVaultKeyRing,
        teamID: String
    ) -> @Sendable (Int) throws -> Data? {
        { version in
            try retainedKey(from: ring, teamID: teamID, slot: .vault(version: version))
        }
    }

    // MARK: Open

    /// Opens a team fact document with the key its OWN `keyVersion` names.
    ///
    /// The held attempt opened every document with whatever key the caller
    /// happened to hold, so a member who had rotated could not read the facts
    /// written before the rotation and the failure looked like corruption. The
    /// version label selects the key; a version this device does not hold is a
    /// NON-PERMANENT refusal (`teamKeyVersionUnavailable`), because the envelope
    /// carrying it may simply not have arrived yet.
    ///
    /// - Parameter keyForVersion: the client-held RETAINED-key set, keyed by
    ///   generation — `retainedKeySelector(from:teamID:)` over a
    ///   `TeamVaultKeyRing` in production, a dictionary in tests. Pending
    ///   generations are deliberately not in it; see `retainedKey` above.
    /// - Parameter sealedMemory: the document's `sealedMemory` field and nothing
    ///   else. This function opens ONE field and admits none of the others —
    ///   the outer allowlist, the authorship binding and the sealed/outer
    ///   `updatedAt` agreement are `TeamMemoryPullService.verify`'s job — so it
    ///   takes that field rather than the whole untyped document, which would
    ///   read as if it had checked the rest. `decodeBlobEnvelope` is the typed
    ///   decoder for exactly this value.
    static func openTeamFact(
        docID: String,
        sealedMemory: Any?,
        teamID: String,
        keyForVersion: (Int) throws -> Data?
    ) throws -> TeamMemoryFactPayload {
        guard let envelope = CloudVaultCrypto.decodeBlobEnvelope(from: sealedMemory) else {
            throw TeamMemorySyncError.malformedEnvelope(docID: docID)
        }
        guard let keyData = try keyForVersion(envelope.keyVersion) else {
            throw TeamMemorySyncError.teamKeyVersionUnavailable(
                teamId: teamID,
                keyVersion: envelope.keyVersion
            )
        }
        // The AAD names THIS document in THIS team. A blob relocated to another
        // slot — or spliced in from another team — fails the AEAD tag here, so
        // no separate string comparison is needed and none is done: the tag is
        // the check, and a comparison beside it would only be a second place to
        // get it wrong.
        let aad = try teamAADContext(teamID: teamID, docID: docID)
        let plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: keyData, aadContext: aad)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TeamMemoryFactPayload.self, from: plaintext)
    }
}
