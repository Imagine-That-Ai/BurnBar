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

/// The two `promoteTeamMember` refusals this client is able to tell apart, as
/// the SERVER words them.
///
/// SOURCE OF TRUTH IS `functions/src/teamRoster.ts` — `promoteMember` raises
/// both, three lines apart, as bare `HttpsError("failed-precondition", …)` with
/// no `details` payload. There is nothing structured to switch on, so the
/// message text is the only separator, and these are the two fragments that
/// separate it. Kept HERE, in one place, rather than inline in `classify`, so a
/// server reword has exactly one Swift site to update.
///
/// FOLLOW-UP, and it is the real fix: have `promoteMember` attach a structured
/// reason (`details.reason = "no_trusted_device" | "member_not_pending"`) and
/// switch on that instead. PR 2 round 3 owns the roster service; whoever lands
/// it should carry this. Until then a server-side reword degrades the
/// classification to `.other` — generic, honest copy, never wrong-specific copy
/// — which is why `classify` matches POSITIVELY on both and defaults to
/// `.other` rather than guessing.
enum TeamRosterPromotionRefusal {
    /// `teamRoster.ts`: "That member has no trusted escrow device to receive team keys."
    static let noTrustedEscrowDevice = "escrow device"
    /// `teamRoster.ts`: "Only a pending member can be promoted."
    static let memberNotPending = "pending member can be promoted"
}

/// Why "Share Team Keys" did not complete, in terms an admin can act on.
///
/// PR 4 owns this taxonomy: the PR 2 review round-2 ruling that introduced the
/// two-admin fork refusal ends "PR 4 owns … the operator-facing wording for
/// `rotationConflict`".
///
/// It CLASSIFIES, it does not render. A callable's message can carry a uid or an
/// email, so the raw text is read for exactly one purpose — telling the roster's
/// two different `failed-precondition`s apart, which share a status code and
/// differ only in their message — and is never put on screen.
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
            case .missingKeyForSlot, .rotationNotSequential, .malformedEnvelope:
                // This admin's own device is missing a key, or an envelope it
                // wrote is unreadable. Real, but not something the copy above
                // can tell them to do anything about.
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
        guard nsError.domain == FunctionsErrorDomain else { return .other }
        switch FunctionsErrorCode(rawValue: nsError.code) {
        case .aborted:
            return .rosterStateMovedInFlight
        case .failedPrecondition:
            // POSITIVE MATCHES ONLY, AND `.other` FOR EVERYTHING ELSE (PR 4
            // review M1). Two roster refusals share this code and differ only in
            // wording, so the message is READ here — and rendered nowhere.
            //
            // But they are not the only two. `promoteMember` also reaches
            // `readTeam` ("Team roster is missing its key state.") and
            // `assertTeamKeyEnvelopeCoverage`, which raises four more
            // `failed-precondition`s of its own — too many envelopes, missing
            // envelope ids, an envelope not published yet, an envelope addressed
            // to a different device or key (`functions/src/teamKeyEnvelopes.ts`).
            // A partial or stale coverage failure is the single most likely
            // refusal an admin will meet, and defaulting it to "no longer
            // pending" would print a specific claim the member list directly
            // below contradicts, and would tell them to stop instead of retry.
            // An unrecognised refusal is `.other`, whose copy says only that
            // nothing was shared and to try again.
            let text = nsError.localizedDescription.lowercased()
            if text.contains(TeamRosterPromotionRefusal.noTrustedEscrowDevice) {
                return .joinerHasNoTrustedDevice
            }
            if text.contains(TeamRosterPromotionRefusal.memberNotPending) {
                return .memberNoLongerPending
            }
            return .other
        case .notFound:
            // "That account has not accepted an invite to this team." The row
            // is gone, which is the same thing to an admin as "not pending".
            return .memberNoLongerPending
        default:
            return .other
        }
    }
}
