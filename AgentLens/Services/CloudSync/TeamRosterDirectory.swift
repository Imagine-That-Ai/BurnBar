import FirebaseFunctions
import Foundation

// MARK: - Team roster directory and administration (memory program D16 / P22, PR 4)
//
// The production halves of the two seams `TeamMemorySectionModel` reads and
// writes through. Both are thin on purpose: the roster is server-owned, so the
// read is a fetch and the writes are callables, and there is no client-side
// membership logic here to get out of step with `functions/src/teamRoster.ts`.

/// Reads `team_rosters/{teamId}` plus its `members` subcollection through
/// `CloudSyncFirestoreGateway` — never a raw `Firestore.firestore()` handle, the
/// raw-Firestore ratchet is shrink-only.
///
/// The member list is a plain read of a collection whose rule is
/// `allow write: if false`. Nothing here can change it, and the copy on the row
/// (`TeamMemoryCopy.memberListCaption`) says so rather than implying an edit
/// would stick.
struct FirestoreTeamRosterDirectory: TeamRosterDirectoryReading {
    let gateway: CloudSyncFirestoreGateway

    func rosterDetail(teamID: String, uid: String) async throws -> TeamRosterDetail? {
        let teamDocument = gateway
            .collection(TeamVaultKeyDistributor.rosterRootCollection)
            .document(teamID)
        guard let team = try await teamDocument.getData() else { return nil }
        let memberSnapshot = try await teamDocument.collection("members").getDocuments()
        let members: [TeamRosterDetail.Member] = memberSnapshot.documents.compactMap { snapshot in
            let data = snapshot.data()
            guard let role = data["role"] as? String, let status = data["status"] as? String else { return nil }
            return TeamRosterDetail.Member(uid: snapshot.documentID, role: role, status: status)
        }
        let me = members.first { $0.uid == uid }
        return TeamRosterDetail(
            teamID: teamID,
            name: (team["name"] as? String) ?? teamID,
            activeKeyVersion: (team["activeKeyVersion"] as? Int) ?? 0,
            retainedKeyVersions: (team["retainedKeyVersions"] as? [Int]) ?? [],
            burnedKeyVersions: (team["burnedKeyVersions"] as? [Int]) ?? [],
            // A missing or empty `slugKeyId` is "the founding is not finished",
            // which is the safe reading: it offers the founder the recovery and
            // tells everyone else the truth. `createTeam` seeds it null.
            slugKeyRecorded: ((team["slugKeyId"] as? String) ?? "").isEmpty == false,
            keyRotationRequired: (team["keyRotationRequired"] as? Bool) ?? false,
            rewrapCompletedKeyVersion: team["rewrapCompletedKeyVersion"] as? Int,
            rewrapJobId: team["rewrapJobId"] as? String,
            myRole: me?.role,
            myStatus: me?.status,
            members: members.sorted { $0.uid < $1.uid }
        )
    }
}

// The four membership callables the Settings section drives. Promotion and
// rotation are NOT here: both must publish key envelopes first, which is
// `TeamVaultKeyDistributor`'s job, and a UI shortcut that called them without
// the wraps would leave a member active-but-blind — the exact failure PR 1's
// coverage check exists to refuse.
//
// AUDIT(@unchecked Sendable): wraps a non-Sendable Firebase `Functions` instance;
// the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
final class FirebaseTeamMemoryAdministrator: TeamMemoryAdministering, @unchecked Sendable {
    private let injectedFunctions: Functions?

    init(functions: Functions? = nil) {
        self.injectedFunctions = functions
    }

    private var functions: Functions {
        injectedFunctions ?? Functions.functions(region: "us-central1")
    }

    func createTeam(name: String) async throws -> String {
        let result = try await functions.httpsCallable("createTeam").call(["name": name])
        guard let payload = result.data as? [String: Any], let teamID = payload["teamId"] as? String else {
            throw TeamMemoryAdministrationError.malformedResponse(callable: "createTeam")
        }
        return teamID
    }

    func acceptInvite(teamID: String, inviteToken: String) async throws {
        _ = try await functions.httpsCallable("acceptTeamInvite").call([
            "teamId": teamID,
            "inviteToken": inviteToken
        ])
    }

    func inviteMember(teamID: String, email: String, role: String) async throws -> String {
        let result = try await functions.httpsCallable("inviteTeamMember").call([
            "teamId": teamID,
            "inviteeEmail": email,
            "role": role
        ])
        guard let payload = result.data as? [String: Any], let token = payload["inviteToken"] as? String else {
            throw TeamMemoryAdministrationError.malformedResponse(callable: "inviteTeamMember")
        }
        return token
    }

    func removeMember(teamID: String, targetUid: String) async throws {
        _ = try await functions.httpsCallable("removeTeamMember").call([
            "teamId": teamID,
            "targetUid": targetUid
        ])
    }
}

enum TeamMemoryAdministrationError: LocalizedError, Equatable {
    case malformedResponse(callable: String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse(let callable):
            "\(callable) returned a response this client could not read."
        }
    }
}

/// Production "rotate now": the full sequence, never the bare callable.
///
/// `TeamVaultKeyDistributor.rotateTeamKey` mints `v(N+1)` (once — the ring holds
/// it pending until the callable succeeds), wraps it for every remaining active
/// member's pinned devices, calls `rotateTeamKey`, and only then re-seals the
/// corpus, because the rules pin fact writes to the roster's active generation.
struct TeamVaultKeyRotator: TeamKeyRotating {
    let gateway: CloudSyncFirestoreGateway
    let uid: String
    let deviceId: String
    let keyRing: TeamVaultKeyRing
    let callables: TeamRosterCallableInvoking

    func rotate(
        teamID: String,
        activeKeyVersion: Int,
        burnedKeyVersions: [Int],
        activeMemberUids: [String]
    ) async throws -> TeamCloudVaultRewrapProgress {
        var worker = TeamCloudVaultRewrapWorker(gateway: gateway)
        worker.completionPublisher = TeamRosterCallableCompletionPublisher(callables: callables)
        // NOT `activeKeyVersion + 1`. Once a generation is burned, the roster
        // authority refuses that number outright, so the client has to compute
        // the same next-rotatable version the server will accept — which is what
        // `nextRotatableKeyVersion` is, and why the roster detail mirrors
        // `burnedKeyVersions` at all.
        return try await distributor().rotateTeamKey(
            teamId: teamID,
            activeKeyVersion: activeKeyVersion,
            newKeyVersion: TeamVaultKeyDistributor.nextRotatableKeyVersion(
                activeKeyVersion: activeKeyVersion,
                burnedKeyVersions: burnedKeyVersions
            ),
            activeMemberUids: activeMemberUids,
            burnedKeyVersions: burnedKeyVersions,
            rewrapWorker: worker,
            rewrapJobId: UUID().uuidString
        )
    }

    /// The `rotationConflict` recovery, handed straight to PR 2's implementation.
    ///
    /// Nothing is re-decided here: `abandonConflictingGenerationAndRotate` burns
    /// the generation on the roster, clears this Mac's pending slot for it, and
    /// rotates to the next non-burned version, in that order and idempotently.
    /// The UI's job is to have asked first.
    func abandonConflictingGenerationAndRotate(
        teamID: String,
        conflictingVersion: Int,
        activeKeyVersion: Int,
        burnedKeyVersions: [Int],
        activeMemberUids: [String]
    ) async throws -> TeamCloudVaultRewrapProgress {
        var worker = TeamCloudVaultRewrapWorker(gateway: gateway)
        worker.completionPublisher = TeamRosterCallableCompletionPublisher(callables: callables)
        return try await distributor().abandonConflictingGenerationAndRotate(
            teamId: teamID,
            conflictingVersion: conflictingVersion,
            activeKeyVersion: activeKeyVersion,
            burnedKeyVersions: burnedKeyVersions,
            activeMemberUids: activeMemberUids,
            rewrapWorker: worker,
            rewrapJobId: UUID().uuidString
        )
    }

    private func distributor() -> TeamVaultKeyDistributor {
        TeamVaultKeyDistributor(
            gateway: gateway,
            uid: uid,
            deviceId: deviceId,
            keyRing: keyRing,
            callables: callables,
            escrowPrivateKey: DeviceTeamEscrowPrivateKey(deviceId: deviceId)
        )
    }
}

/// Production "share team keys": PR 2's whole join sequence, never the bare
/// callable — the same reason `TeamVaultKeyRotator` exists.
///
/// `TeamVaultKeyDistributor.issueJoinerKeys` enumerates the retained
/// generations, wraps each one PLUS the non-rotating slug key to every device
/// the joiner's roster row pins, publishes the envelopes, and only then calls
/// `promoteTeamMember` with the exact id set. Calling `promoteTeamMember` from
/// the UI directly would be refused by the coverage check on a good day and, on
/// a bad one, is precisely the active-but-blind member design §3(b)2 exists to
/// make impossible.
struct TeamVaultJoinerKeyIssuer: TeamJoinerKeyIssuing {
    let gateway: CloudSyncFirestoreGateway
    let uid: String
    let deviceId: String
    let keyRing: TeamVaultKeyRing
    let callables: TeamRosterCallableInvoking

    func issueKeys(teamID: String, joinerUid: String, retainedKeyVersions: [Int]) async throws {
        let distributor = TeamVaultKeyDistributor(
            gateway: gateway,
            uid: uid,
            deviceId: deviceId,
            keyRing: keyRing,
            callables: callables,
            escrowPrivateKey: DeviceTeamEscrowPrivateKey(deviceId: deviceId)
        )
        _ = try await distributor.issueJoinerKeys(
            teamId: teamID,
            joinerUid: joinerUid,
            retainedKeyVersions: retainedKeyVersions
        )
    }
}

/// Production "finish setting up this team's keys": the founder bootstrap of
/// design §3(b)1, which until this seam existed had **no production caller at
/// all** — `bootstrapTeamKeys` was written, reviewed and unit-tested in PR 2 and
/// then never invoked, so no Mac ever minted `teamVaultKey_v1` or the
/// non-rotating `teamSlugKey` and every team created by the shipped app had no
/// keys whatsoever.
///
/// THREE STEPS, AND THE FIRST TWO ARE WHY THIS IS A TYPE RATHER THAN A ONE-LINE
/// CALL.
///
///   1. ADOPT. `loadKeyRingFromEnvelopes` runs first, so a retry picks up
///      whatever a previous attempt already published for THIS device instead of
///      reasoning about it. On the ordinary first run it finds nothing and costs
///      one query; on a resume it is what makes step 3 reuse the published bytes
///      rather than the Keychain's memory of them.
///   2. REFUSE A SECOND FOUNDING EARLY. `bootstrapTeamKeys` passes both slots as
///      `mintedInThisPass`, and that guard admits an existing envelope when
///      `wrappedBy == uid` — correct against another ADMIN, and blind to another
///      MAC OF THE SAME ACCOUNT, whose envelopes carry the same `wrappedBy`. A
///      founder whose first Mac published its own envelope and died before
///      publishing the second Mac's would, on a bootstrap from that second Mac,
///      claim the first envelope and publish a DIFFERENT key beside it: two keys
///      under one immutable generation, which is the silent, permanent,
///      unrepairable split the B4 ruling exists to prevent. So if this account
///      already holds an envelope for `v1` or `slug` under another device and
///      this Mac holds neither key, nothing is minted and the refusal says which
///      Mac has to finish.
///
///      IT IS A CHEAP PRE-CHECK, NOT THE AUTHORITY, and the D16 founding-claim
///      ruling is explicit about why: two Macs starting from an EMPTY team both
///      pass it honestly, because at the moment each one asks, neither has
///      written anything. Its value is a fast, well-worded refusal on the common
///      case; what actually serialises two foundings is step 3's roster claim.
///   3. BOOTSTRAP. `bootstrapTeamKeys` mints (or reuses) both keys as PENDING,
///      CLAIMS the generation on the roster with the fingerprint of the key it is
///      about to publish — write-once, decided inside the transaction that
///      writes, so exactly one Mac's claim survives — and only then self-wraps to
///      every device the founder's roster row pins, publishes the envelopes and
///      promotes the ring. A Mac that loses the claim publishes nothing at all.
///      Every step is idempotent by the pending-slot machinery, so a partial
///      failure is resumed by calling this again — which is exactly what the
///      Settings action does.
protocol TeamFounderKeyBootstrapping: Sendable {
    func bootstrapKeys(teamID: String) async throws -> TeamKeyBootstrap
}

/// Why a founder bootstrap refused before it minted anything.
enum TeamFounderKeyBootstrapError: LocalizedError, Equatable {
    /// Another founding owns this team's generation and this Mac holds neither
    /// key. Raised by BOTH refusals that mean it — step 2's envelope pre-check,
    /// and step 3's roster claim coming back `DIFFERENT_SLUG_KEY_RECORDED` — on
    /// purpose: they differ in how early they fire, never in what the member has
    /// to do about it, and giving them separate copy would ask a member to tell
    /// two indistinguishable situations apart.
    case keysMintedOnAnotherDevice(teamID: String)

    var errorDescription: String? {
        switch self {
        case .keysMintedOnAnotherDevice(let teamID):
            return """
            Team \(teamID)'s founding keys were already published from another Mac on this account, and this Mac \
            holds neither of them. Minting a second set here would leave one generation carrying two different \
            keys, which nothing can repair. Finish the hand-off from the Mac that created the team.
            """
        }
    }
}

struct TeamVaultFounderKeyBootstrapper: TeamFounderKeyBootstrapping {
    let gateway: CloudSyncFirestoreGateway
    let uid: String
    let deviceId: String
    let keyRing: TeamVaultKeyRing
    let callables: TeamRosterCallableInvoking
    /// Opens the envelopes step 1 adopts. Nil in production, where it resolves to
    /// this Mac's own Keychain escrow key; a test supplies a real P-256 keypair
    /// instead, because "this device adopted the wrap addressed to IT" is a
    /// property that has to be exercised with real crypto rather than mocked
    /// around.
    var escrowPrivateKey: (any TeamEscrowPrivateKeyProviding)?

    /// The two slots a founding bootstrap mints, and the only two the C-1 rules
    /// clause lets a self-wrap publish at `activeKeyVersion == 1`.
    private static let foundingSlots: [TeamKeySlot] = [.vault(version: 1), .slug]

    func bootstrapKeys(teamID: String) async throws -> TeamKeyBootstrap {
        let distributor = TeamVaultKeyDistributor(
            gateway: gateway,
            uid: uid,
            deviceId: deviceId,
            keyRing: keyRing,
            callables: callables,
            escrowPrivateKey: escrowPrivateKey ?? DeviceTeamEscrowPrivateKey(deviceId: deviceId)
        )
        // 1. Adopt whatever is already addressed to this device. A failure here
        //    is fatal on purpose: the whole point is not to mint over a founding
        //    that already happened, and a pickup this pass could not complete
        //    tells us nothing about whether one did.
        //
        //    THE RESULT IS THE PROVENANCE SIGNAL, and it is why this is no
        //    longer discarded (D16 bootstrap-wiring ruling, clause 1). The slots
        //    this returns are the slots whose key came out of the TEAM's
        //    published envelopes; every other key on this Mac is something this
        //    Mac made up, and the two must never be confused when deciding
        //    whether minting is safe.
        let adoptedSlots = Set(try await distributor.loadKeyRingFromEnvelopes(teamId: teamID))
        // 2. Refuse a second founding from a second Mac.
        guard try await !anotherDeviceAlreadyFounded(teamID: teamID, adoptedSlots: adoptedSlots) else {
            throw TeamFounderKeyBootstrapError.keysMintedOnAnotherDevice(teamID: teamID)
        }
        // 3. Claim the generation, mint (or resume), publish, promote.
        //
        // THE ROSTER NOTE IS NOT A STEP 4 ANY MORE, and moving it is this
        // round's whole fix. It used to run after the envelopes: "tell the roster
        // which slug key this team uses" — without which the B6 ruling leaves
        // every joiner's slug envelope PENDING, `TeamMemorySyncService.retainedKey`
        // (ACTIVE half only) returns nil, and every member but the founder parks
        // on `team_memory_sync_awaiting_slug_key` for ever. It still does exactly
        // that. But writing it LAST made it a report of what had happened, and a
        // report cannot arbitrate; two Macs could publish two foundings and then
        // argue about which fingerprint to file. Written FIRST, inside
        // `bootstrapTeamKeys`, the same write-once field becomes the permit that
        // decides which Mac may publish at all.
        //
        // Its recoverability is unchanged and its failure is now strictly safer:
        // a claim that does not land leaves NOTHING published, the founder's Mac
        // reads `.setupIncomplete` off its own pending mints, and the Settings
        // action re-runs this whole method — which resumes with the same bytes.
        return try await bootstrapKeysMappingClaimRefusal(distributor: distributor, teamID: teamID)
    }

    /// The claim's refusal, in the vocabulary the founder surface already has.
    ///
    /// `foundingGenerationClaimedElsewhere` and the step 2 pre-check are the
    /// same fact — another founding owns this generation, this Mac must receive
    /// rather than mint — reached a few hundred milliseconds apart, so they
    /// reach the member as one refusal with one remedy. Everything else is
    /// rethrown exactly as it came, because the generation is still unclaimed
    /// and a retry is the right advice.
    private func bootstrapKeysMappingClaimRefusal(
        distributor: TeamVaultKeyDistributor,
        teamID: String
    ) async throws -> TeamKeyBootstrap {
        do {
            return try await distributor.bootstrapTeamKeys(teamId: teamID)
        } catch TeamVaultKeyDistributionError.foundingGenerationClaimedElsewhere {
            throw TeamFounderKeyBootstrapError.keysMintedOnAnotherDevice(teamID: teamID)
        }
    }

    /// True when this ACCOUNT already has a founding envelope on the server
    /// under another device, and this pass did not adopt the team's own key for
    /// every founding slot from those envelopes.
    ///
    /// PROVENANCE, NOT PRESENCE (D16 bootstrap-wiring ruling, clause 1). This
    /// used to return false — "carry on, nothing to refuse" — the moment the
    /// ring held ANY key for a founding slot, active or pending. Both halves of
    /// that were wrong, and each was its own fork:
    ///
    ///   * A PENDING key is a key this Mac invented. A member whose earlier
    ///     attempt on THIS Mac minted and died holds one; so does a second Mac
    ///     that started a founding of its own. Treating it as evidence that this
    ///     Mac is the team's founder let exactly that second Mac walk past this
    ///     guard, claim the first Mac's envelope through the B4 `wrappedBy ==
    ///     uid` predicate — same account, same uid — and publish a DIFFERENT key
    ///     to the devices the first Mac had not covered yet.
    ///   * An ACTIVE key can equally be one this pass has just ADOPTED from the
    ///     other Mac's envelopes, which is the good case and must not refuse.
    ///
    /// Only the adoption result tells those apart, so only the adoption result
    /// is asked. A pass that adopted every founding slot agrees with the team by
    /// construction and proceeds; anything less, with another device's founding
    /// envelope on the server, is refused with nothing minted and nothing
    /// written. That refusal is deliberately wider than the fork itself: a
    /// partially adopted founding could sometimes be finished safely, but "this
    /// Mac holds the team's key for every founding slot" is a property this code
    /// can actually verify, and the remedy — finish on the Mac that founded —
    /// costs the member a press on a machine they own.
    ///
    /// It does not weaken B6: nothing here promotes anything, and the adopted
    /// slots reached the ring through the pickup's own roster-recorded test.
    private func anotherDeviceAlreadyFounded(
        teamID: String,
        adoptedSlots: Set<TeamKeySlot>
    ) async throws -> Bool {
        if Self.foundingSlots.allSatisfy({ adoptedSlots.contains($0) }) { return false }
        let snapshot = try await gateway
            .collection(TeamVaultKeyDistributor.envelopesRootCollection)
            .document(teamID)
            .collection(TeamVaultKeyDistributor.envelopesSubcollection)
            .whereField("uid", isEqualTo: uid)
            .getDocuments()
        let foundingSlotNames = Set(Self.foundingSlots.map(\.rawValue))
        return snapshot.documents.contains { document in
            let data = document.data()
            guard let slot = data["keySlot"] as? String, foundingSlotNames.contains(slot) else { return false }
            return (data["deviceId"] as? String) != deviceId
        }
    }
}

/// The server's refusal enumeration, mirrored.
///
/// SOURCE OF TRUTH IS `functions/src/teamRosterReasons.ts`. Every `HttpsError`
/// the nine team-roster callables raise carries `details.reason` set to one of
/// these strings, and `scripts/ci/verify-team-roster-reason-codes.sh` fails the
/// build if this enum and that file stop agreeing in EITHER direction — a server
/// code with no Swift case, or a Swift case for a code the server no longer
/// raises. There is no runtime discovery here and no partial mirror: the whole
/// enumeration is present so `switch` can be exhaustive and so the gate has
/// something total to compare against.
///
/// WHY A FULL MIRROR WHEN ONLY FIVE CODES DRIVE COPY. The alternative — mirror
/// only the codes this screen reacts to — makes the completeness question
/// unanswerable: nothing could then tell a NEW server code that should drive
/// copy from one that should not. With the mirror total, adding a server code
/// breaks the gate, and adding a case here breaks `classify`'s exhaustive
/// switch, so a human decides which copy it deserves. Both breaks are the point.
///
/// This is the replacement for the message-substring matching that used to live
/// in `TeamRosterPromotionRefusal`: two of these refusals share a status code
/// and differed only in their English, so the English was the separator. It is
/// not any more.
enum TeamRosterReasonCode: String, CaseIterable {
    // Callable payload validation.
    case unauthenticated = "UNAUTHENTICATED"
    case invalidTeamID = "INVALID_TEAM_ID"
    case invalidTeamName = "INVALID_TEAM_NAME"
    case invalidAccountID = "INVALID_ACCOUNT_ID"
    case invalidRole = "INVALID_ROLE"
    case invalidInviteeEmail = "INVALID_INVITEE_EMAIL"
    case invalidEnvelopeID = "INVALID_ENVELOPE_ID"
    case invalidEnvelopeIDs = "INVALID_ENVELOPE_IDS"
    case invalidKeyVersion = "INVALID_KEY_VERSION"
    case invalidInviteToken = "INVALID_INVITE_TOKEN"
    case invalidRewrapJobID = "INVALID_REWRAP_JOB_ID"

    // Caller authority.
    case callerNotATeamMember = "CALLER_NOT_A_TEAM_MEMBER"
    case callerNotAnActiveAdmin = "CALLER_NOT_AN_ACTIVE_ADMIN"

    // The caller's own escrow devices.
    case callerHasNoTrustedEscrowDevice = "CALLER_HAS_NO_TRUSTED_ESCROW_DEVICE"
    case callerHasTooManyTrustedDevices = "CALLER_HAS_TOO_MANY_TRUSTED_DEVICES"

    // Invites.
    case inviteeHasNoAccount = "INVITEE_HAS_NO_ACCOUNT"
    case cannotInviteYourself = "CANNOT_INVITE_YOURSELF"
    case inviteeAlreadyOnTeam = "INVITEE_ALREADY_ON_TEAM"
    case emailNotVerified = "EMAIL_NOT_VERIFIED"
    case inviteNotValidForAccount = "INVITE_NOT_VALID_FOR_ACCOUNT"
    case inviteAlreadyUsed = "INVITE_ALREADY_USED"
    case inviteExpired = "INVITE_EXPIRED"
    case alreadyOnThisTeam = "ALREADY_ON_THIS_TEAM"

    // Promotion and removal.
    case memberHasNotAcceptedInvite = "MEMBER_HAS_NOT_ACCEPTED_INVITE"
    case memberNotPending = "MEMBER_NOT_PENDING"
    case memberHasNoTrustedEscrowDevice = "MEMBER_HAS_NO_TRUSTED_ESCROW_DEVICE"
    case memberNotFoundInTeam = "MEMBER_NOT_FOUND_IN_TEAM"
    case lastActiveAdmin = "LAST_ACTIVE_ADMIN"

    // Key generations.
    case keyVersionStillRecorded = "KEY_VERSION_STILL_RECORDED"
    case keyVersionNotNextUnclaimed = "KEY_VERSION_NOT_NEXT_UNCLAIMED"
    case noAbandonedRotationToBurn = "NO_ABANDONED_ROTATION_TO_BURN"
    case keyVersionNotSequential = "KEY_VERSION_NOT_SEQUENTIAL"
    case keyVersionsExhausted = "KEY_VERSIONS_EXHAUSTED"
    case activeMemberHasNoPinnedDevice = "ACTIVE_MEMBER_HAS_NO_PINNED_DEVICE"
    case rewrapKeyVersionNotCurrent = "REWRAP_KEY_VERSION_NOT_CURRENT"

    // The founding slug key.
    case invalidSlugKeyID = "INVALID_SLUG_KEY_ID"
    case differentSlugKeyRecorded = "DIFFERENT_SLUG_KEY_RECORDED"

    // Envelope coverage.
    case tooManyKeyEnvelopes = "TOO_MANY_KEY_ENVELOPES"
    case keyEnvelopeCoverageIncomplete = "KEY_ENVELOPE_COVERAGE_INCOMPLETE"
    case keyEnvelopeNotPublished = "KEY_ENVELOPE_NOT_PUBLISHED"
    case keyEnvelopeAddressedElsewhere = "KEY_ENVELOPE_ADDRESSED_ELSEWHERE"
    case keyEnvelopeWrappedToUnknownKey = "KEY_ENVELOPE_WRAPPED_TO_UNKNOWN_KEY"
    case keyEnvelopeWrapperNotAuthorized = "KEY_ENVELOPE_WRAPPER_NOT_AUTHORIZED"

    // Team document and in-flight state.
    case teamNotFound = "TEAM_NOT_FOUND"
    case teamKeyStateMissing = "TEAM_KEY_STATE_MISSING"
    case rosterStateMovedInFlight = "ROSTER_STATE_MOVED_IN_FLIGHT"

    /// Read the reason a roster callable attached, or `nil` when there is none.
    ///
    /// `nil` covers three real cases and they are all handled the same way by the
    /// caller — generic copy, never a guess: an error from outside this lane
    /// (App Check, a rate limit, the entitlement check, a transport failure); a
    /// deployed backend older than this enumeration; and a code this build has
    /// never heard of, which `init(rawValue:)` rejects.
    ///
    /// `NSDictionary`, not `[String: Any]`: the Apple Functions SDK decodes the
    /// wire body's `details` with `JSONSerialization`, so the bridged dictionary
    /// is what arrives, and reading it this way keeps the untyped-boundary
    /// ratchet (`scripts/debt/check-string-any-boundary-budget.sh`) unmoved.
    static func read(from error: NSError) -> TeamRosterReasonCode? {
        guard error.domain == FunctionsErrorDomain,
              let details = error.userInfo[FunctionsErrorDetailsKey] as? NSDictionary,
              let raw = details["reason"] as? String else { return nil }
        return TeamRosterReasonCode(rawValue: raw)
    }
}

/// Why "Share Team Keys" did not complete, in terms an admin can act on.
///
/// PR 4 owns this taxonomy: the PR 2 review round-2 ruling that introduced the
/// two-admin fork refusal ends "PR 4 owns … the operator-facing wording for
/// `rotationConflict`".
///
/// It CLASSIFIES, it does not render, and IT NO LONGER READS THE MESSAGE. Two
/// roster refusals share `failed-precondition` and used to be told apart by
/// matching substrings of the server's English, which made every operator
/// message a wire contract: rewording one silently changed the admin's copy.
/// `classify` now switches on `details.reason`
/// (`functions/src/teamRosterReasons.ts`, mirrored in `TeamRosterReasonCode`),
/// and the message — which can carry a uid or an email — is neither parsed nor
/// put on screen.
enum TeamJoinerKeyIssueFailure: Equatable, Sendable {
    /// A second admin's wrap already occupies an envelope id this pass needs, or
    /// occupies it addressed to a different device or key. Envelope documents
    /// are create-only and immutable, so a concurrent or abandoned distribution
    /// pass is refused, never claimed (design, PR 2 review round 2).
    case rotationConflict
    /// `commitGuardedByTeamState` (`functions/src/teamRosterState.ts`) re-read
    /// the team document inside the writing transaction and found the KEY state
    /// (PR 1 review N-4) or the MEMBERSHIP epoch (PR 1 Cursor round C-4) had
    /// moved since the coverage requirement set was computed, so the promotion
    /// `aborted`. The retry is against a fresh snapshot and is the caller's to
    /// make.
    case rosterStateMovedInFlight
    /// Coverage cannot be built at all: the joiner has published no trusted
    /// escrow device, or the key they published does not match the fingerprint
    /// the roster pinned. Nothing was wrapped and nothing was promoted.
    case joinerHasNoTrustedDevice
    /// C-3: `promoteMember` re-reads `status == "pending"` and refuses anything
    /// else, so a member removed or already promoted while this admin was
    /// wrapping comes back `failed-precondition`. A removed member returns only
    /// through a fresh invite, never through an admin race.
    case memberNoLongerPending
    case other

    func message(member: String) -> String {
        switch self {
        case .rotationConflict, .rosterStateMovedInFlight:
            TeamMemoryCopy.shareKeysConflictNotice
        case .joinerHasNoTrustedDevice:
            TeamMemoryCopy.shareKeysNoTrustedDevice(member: member)
        case .memberNoLongerPending:
            TeamMemoryCopy.shareKeysNoLongerPendingNotice
        case .other:
            TeamMemoryCopy.shareKeysFailedNotice
        }
    }

    static func classify(_ error: Error) -> TeamJoinerKeyIssueFailure {
        if let distribution = error as? TeamVaultKeyDistributionError {
            switch distribution {
            case .envelopeAddressedElsewhere:
                return .rotationConflict
            case .memberHasNoPinnedDevice,
                 .escrowPublicKeyUnavailable,
                 .fingerprintNotPinned,
                 .fingerprintNotBoundToKey:
                return .joinerHasNoTrustedDevice
            case .rotationConflict:
                // THE REAL PRODUCER, and it arrives from PR 2's pre-scan rather
                // than from this PR's `.envelopeAddressedElsewhere` fallback:
                // another admin's Mac already published a wrap for a generation
                // this pass minted, so the envelope carries a key this Mac does
                // not hold. Nothing was written — the pass checks every id it
                // would have to claim before writing any of them — so the
                // conflict copy's "nothing was shared, try again in a moment" is
                // literally true of a JOIN.
                //
                // NOT offered the burn-and-rotate recovery here, deliberately.
                // That recovery spends a key generation on the whole team; it
                // belongs to the ROTATION surface, where the admin is already
                // acting on the team's key, and not to a single member's
                // hand-off. Re-pressing "Share Team Keys" after the other
                // admin's pass finishes is the correct move on this surface.
                return .rotationConflict
            case .rosterStateMovedInFlight:
                // `commitGuardedByTeamState` re-read the team inside the writing
                // transaction and found the key state or the membership epoch
                // had moved. Same instruction as above and for the same reason:
                // nothing landed, and the retry is against a fresh snapshot.
                return .rosterStateMovedInFlight
            case .missingKeyForSlot,
                 .rotationNotSequential,
                 .malformedEnvelope,
                 .foundingGenerationClaimedElsewhere,
                 .foundingGenerationForked:
                // This admin's own device is missing a key, or an envelope it
                // wrote is unreadable. Real, but not something the copy above
                // can tell them to do anything about.
                //
                // The two FOUNDING refusals are here for a stronger reason than
                // "nothing better fits": "Share Team Keys" never founds. Both
                // are raised only by `bootstrapTeamKeys`, which this surface
                // does not call and which reports its own outcome through
                // `TeamKeyReadiness` and `founderBootstrapMessage(for:)`. Either
                // one arriving HERE is a client bug, and there is nothing this
                // admin could do about it — the same reasoning the two slug-key
                // reason codes get below.
                return .other
            // NO `default`, DELIBERATELY, AND IT STAYS THAT WAY. A new
            // `TeamVaultKeyDistributionError` case must break this build so it
            // is routed on purpose rather than silently becoming "unknown
            // failure", and every case above is routed to copy an admin can act
            // on. Extend `test_each_share_keys_failure_maps_to_its_own_plain_copy`
            // with the new case in the same commit.
            }
        }
        let nsError = error as NSError
        if let reason = TeamRosterReasonCode.read(from: nsError) {
            return classify(reason: reason)
        }
        // NO REASON ON THE ERROR. Three shapes reach here and none of them is a
        // roster refusal this build understands: an error from outside the lane
        // (App Check, a rate limit, the entitlement check, a transport failure),
        // a deployed backend older than `functions/src/teamRosterReasons.ts`, or
        // a reason string this build has never seen.
        //
        // THE MESSAGE IS NOT READ. It used to be — two refusals shared
        // `failed-precondition` and differed only in their English — and that is
        // exactly the contract this change removes, so the fallback is decided
        // by STATUS CODE alone. `aborted` and `not-found` each have one meaning
        // in this lane whoever produced them, so they keep their copy; every
        // other status, `failed-precondition` very much included, gets the
        // generic notice. Generic-but-true beats specific-and-possibly-wrong:
        // printing "that member is no longer waiting to join" while the member
        // list directly below still shows them PENDING is a false claim that
        // also tells the admin to stop instead of retry (PR 4 review M1).
        guard nsError.domain == FunctionsErrorDomain else { return .other }
        switch FunctionsErrorCode(rawValue: nsError.code) {
        case .aborted:
            return .rosterStateMovedInFlight
        case .notFound:
            // The roster row or the team is gone, which is the same thing to an
            // admin as "not pending".
            return .memberNoLongerPending
        default:
            return .other
        }
    }

    /// Route one server reason to the copy an admin can act on.
    ///
    /// EXHAUSTIVE, WITH NO `default`. A new `TeamRosterReasonCode` case must
    /// break this build so somebody decides what an admin should be told, rather
    /// than the code quietly becoming "unknown failure". The unrecognised-code
    /// fallback is NOT here — it is `TeamRosterReasonCode.read` returning `nil`
    /// above, which is the single explicit place a code this build does not know
    /// becomes generic copy.
    ///
    /// Most of the enumeration lands on `.other`, and that is correct rather
    /// than lazy: "Share Team Keys" publishes envelopes and calls
    /// `promoteTeamMember`, so a caller-authority refusal or a malformed-payload
    /// refusal on this surface is a client bug, not something the admin in front
    /// of the screen can do anything about. Only the refusals with a real
    /// operator remedy get their own line.
    private static func classify(reason: TeamRosterReasonCode) -> TeamJoinerKeyIssueFailure {
        switch reason {
        case .memberHasNoTrustedEscrowDevice:
            // The joiner has published no trusted device, so nothing can be
            // wrapped for them. Their move, not this admin's.
            return .joinerHasNoTrustedDevice
        case .memberNotPending, .memberHasNotAcceptedInvite, .memberNotFoundInTeam:
            // C-3: the row is re-read inside the writing transaction, so a
            // member removed or already promoted mid-pass is a precondition
            // failure. A row that is simply GONE means the same thing to an
            // admin — the member is not waiting to join any more.
            return .memberNoLongerPending
        case .rosterStateMovedInFlight:
            // `commitGuardedByTeamState` re-read the team inside the writing
            // transaction and the key state or the membership epoch had moved.
            // Nothing landed; the retry is against a fresh snapshot.
            return .rosterStateMovedInFlight
        case .unauthenticated,
             .invalidTeamID,
             .invalidTeamName,
             .invalidAccountID,
             .invalidRole,
             .invalidInviteeEmail,
             .invalidEnvelopeID,
             .invalidEnvelopeIDs,
             .invalidKeyVersion,
             .invalidInviteToken,
             .invalidRewrapJobID,
             .callerNotATeamMember,
             .callerNotAnActiveAdmin,
             .callerHasNoTrustedEscrowDevice,
             .callerHasTooManyTrustedDevices,
             .inviteeHasNoAccount,
             .cannotInviteYourself,
             .inviteeAlreadyOnTeam,
             .emailNotVerified,
             .inviteNotValidForAccount,
             .inviteAlreadyUsed,
             .inviteExpired,
             .alreadyOnThisTeam,
             .lastActiveAdmin,
             .keyVersionStillRecorded,
             .keyVersionNotNextUnclaimed,
             .noAbandonedRotationToBurn,
             .keyVersionNotSequential,
             .keyVersionsExhausted,
             .activeMemberHasNoPinnedDevice,
             .rewrapKeyVersionNotCurrent,
             .invalidSlugKeyID,
             .differentSlugKeyRecorded,
             .tooManyKeyEnvelopes,
             .keyEnvelopeCoverageIncomplete,
             .keyEnvelopeNotPublished,
             .keyEnvelopeAddressedElsewhere,
             .keyEnvelopeWrappedToUnknownKey,
             .keyEnvelopeWrapperNotAuthorized,
             .teamNotFound,
             .teamKeyStateMissing:
            // Everything else: a coverage refusal (the most likely one an admin
            // will meet — a partial or stale pass), a roster the caller may not
            // act on, or a payload this client should never have sent. All of
            // them mean "nothing was shared, try again"; none of them has a
            // more specific instruction that would be TRUE on this screen.
            //
            // The two slug-key reasons are here deliberately rather than by
            // omission: "Share Team Keys" never calls `recordTeamSlugKeyId` —
            // only the founder bootstrap does, and it reports its own outcome
            // through `TeamKeyReadiness` — so either code arriving HERE is a
            // client bug, and there is nothing this admin could do about it.
            return .other
        // NO `default`. See the note above.
        }
    }
}
