import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarKernel
import os

// MARK: - Team vault key distribution (memory program D16 / P21, PR 2)
//
// A team vault key never reaches the server. It is generated on a member's Mac,
// held in that Mac's Keychain, and handed to other members ONE WRAP PER
// RECIPIENT DEVICE — because the escrow private key that opens a wrap is
// per-device (`CloudVaultDeviceKeypair(account: "cloud-vault-device:<deviceId>")`),
// so a member's second Mac cannot open a wrap made for their first. That is the
// whole reason the roster pins `escrowDeviceFingerprints` per device rather than
// one public key per member.
//
// TWO KEYS, ONE OF THEM PERMANENT (design §3(a), defect 2):
//
//   * `teamVaultKey_vN` SEALS content. It rotates on every departure, and every
//     retained version stays in the key ring so a joiner can open a fact written
//     before they arrived and nobody is stranded mid-rotation.
//   * `teamSlugKey` NAMES documents (the doc-id HMAC) and NEVER rotates. It
//     seals nothing, so a departed member who keeps it learns only which opaque
//     ids exist — which the server already sees. Rotating it instead would give
//     every fact a new document id and orphan the entire team space.
//
// WHAT THE SERVER IS TRUSTED WITH, AND WHAT IT IS NOT. Membership is
// server-owned: a client cannot assert who is on a roster. Key material is not:
// no callable here accepts a key or a recipient public key, and the roster
// authority never sees one. A recipient's public key is read from that
// member's OWN rules-protected `users/{uid}/escrow_public_keys` namespace and
// re-verified against the fingerprint the roster pinned at accept time AND
// against the key's own bytes, exactly as
// `CloudSyncTrustedDeviceChainVerifier` does before a personal wrap
// (`SessionLogSyncService+VaultKeyPublishing.swift`). A client-supplied
// recipient key would be a substitution primitive; there is nowhere to supply
// one.
//
// NO RETROACTIVE PLAINTEXT. Rotation protects FUTURE writes only. A departed
// member keeps `teamVaultKey_v1…vN` and every fact already replicated to their
// device. Rotation makes facts sealed under `v(N+1)` undecryptable to them and
// the roster cutoff makes the collection unreadable to them; neither retracts
// bits already sent.

/// Which key an envelope carries. The raw value is the tail of the envelope
/// document id, so it is also what `firestore.rules` pins through
/// `envelopeId == d.uid + "_" + d.deviceId + "_" + string(d.escrowKeyVersion) + "_" + d.keySlot`.
enum TeamKeySlot: Hashable, Sendable {
    /// One generation of the content-sealing team vault key.
    case vault(version: Int)
    /// The non-rotating document-naming key. Issued once, on join.
    case slug

    var rawValue: String {
        switch self {
        case .vault(let version): return "v\(version)"
        case .slug: return "slug"
        }
    }

    init?(rawValue: String) {
        if rawValue == "slug" {
            self = .slug
            return
        }
        guard rawValue.hasPrefix("v"), let version = Int(rawValue.dropFirst()), version >= 1 else {
            return nil
        }
        self = .vault(version: version)
    }
}

/// One recipient device, as the roster pinned it at accept time: an id, the
/// escrow key generation, and the fingerprint of the public key that generation
/// published. Fingerprints only — the member row never holds key bytes.
struct TeamEscrowDevicePin: Equatable, Sendable {
    let deviceId: String
    let escrowKeyVersion: Int
    let publicKeyFingerprint: String

    /// Reads the pin list off a `team_rosters/{teamId}/members/{uid}` document.
    /// Malformed entries are dropped rather than trusted: a pin that cannot be
    /// read is a pin that cannot bind anything.
    static func pins(from memberDocument: [String: Any]) -> [TeamEscrowDevicePin] {
        guard let raw = memberDocument["escrowDeviceFingerprints"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let deviceId = entry["deviceId"] as? String, !deviceId.isEmpty,
                  let keyVersion = entry["keyVersion"] as? Int, keyVersion >= 1,
                  let fingerprint = entry["publicKeyFingerprint"] as? String, !fingerprint.isEmpty else {
                return nil
            }
            return TeamEscrowDevicePin(
                deviceId: deviceId,
                escrowKeyVersion: keyVersion,
                publicKeyFingerprint: fingerprint
            )
        }
    }
}

/// The client-held set of team keys: one Keychain item per `(teamId, slot)`.
///
/// A seam, not an abstraction for its own sake — a unit test cannot drive the
/// Keychain, and `openTeamFact` (PR 3) selects a key by the `keyVersion` label
/// on the sealed blob, so the ring has to be addressable by slot.
/// PENDING SLOTS (PR 2 review B1). A generation is minted locally BEFORE any
/// network write, and it must never be minted twice. A rotation that dies half
/// way through publishing envelopes has to resume with the SAME `v(N+1)`:
/// envelopes are create-only and immutable, so a second, different `v(N+1)`
/// could never overwrite the first one's documents, and the members who already
/// received envelopes would hold a key nobody else will ever seal with. A fresh
/// generation is therefore written to the ring as PENDING before the first
/// wrap, REUSED verbatim by every retry, and promoted to the active ring only
/// after the roster authority has recorded it.
protocol TeamVaultKeyRing: Sendable {
    func key(teamId: String, slot: TeamKeySlot) throws -> Data?
    func store(_ keyData: Data, teamId: String, slot: TeamKeySlot) throws
    /// A generation minted locally whose distribution is not confirmed yet.
    func pendingKey(teamId: String, slot: TeamKeySlot) throws -> Data?
    func storePending(_ keyData: Data, teamId: String, slot: TeamKeySlot) throws
    /// Make the pending generation for this slot the active one. A no-op when
    /// there is nothing pending, so a promotion is itself an idempotent retry.
    func promotePendingKey(teamId: String, slot: TeamKeySlot) throws
    /// Destroy a pending generation the roster authority has BURNED
    /// (`abandonTeamKeyGeneration`). A burned version is never rotated to
    /// again, so its key can open nothing that will ever exist; keeping it
    /// would leave a slot whose bytes no member but this Mac holds and which
    /// ``TeamVaultKeyDistributor/requireKey(teamId:slot:)`` would still hand
    /// out. A no-op when there is nothing pending.
    func deletePendingKey(teamId: String, slot: TeamKeySlot) throws
}

/// Production ring: `CloudVaultKeyStore` under its own Keychain service, so a
/// team key can never be confused with — or overwrite — the personal vault key.
///
/// The store's `uid:` parameter is a free-form account discriminator, and the
/// account it derives is `vault-key:<teamId>#<slot>` inside the team-only
/// service. Reusing the shipped, audited Keychain accessor is deliberate: this
/// file adds no new Keychain code and no new Kernel file.
///
/// `#` joins the parts rather than `:` (PR 2 review INFO-2): the store already
/// prefixes `vault-key:`, and a delimiter that cannot occur in EITHER part —
/// team ids are `team_<hex>` and slots are `v<N>` or `slug` — makes
/// `(teamId, slot)` unambiguous by construction rather than by an argument
/// about what team ids happen to look like today.
struct KeychainTeamVaultKeyRing: TeamVaultKeyRing {
    static let keychainService = "com.openburnbar.team-vault-key"

    private let store: CloudVaultKeyStore

    init(service: String = KeychainTeamVaultKeyRing.keychainService) {
        self.store = CloudVaultKeyStore(service: service)
    }

    func key(teamId: String, slot: TeamKeySlot) throws -> Data? {
        try store.loadKey(uid: Self.account(teamId: teamId, slot: slot))
    }

    func store(_ keyData: Data, teamId: String, slot: TeamKeySlot) throws {
        try store.saveKey(keyData, uid: Self.account(teamId: teamId, slot: slot))
    }

    func pendingKey(teamId: String, slot: TeamKeySlot) throws -> Data? {
        try store.loadKey(uid: Self.pendingAccount(teamId: teamId, slot: slot))
    }

    func storePending(_ keyData: Data, teamId: String, slot: TeamKeySlot) throws {
        try store.saveKey(keyData, uid: Self.pendingAccount(teamId: teamId, slot: slot))
    }

    func promotePendingKey(teamId: String, slot: TeamKeySlot) throws {
        guard let pending = try pendingKey(teamId: teamId, slot: slot) else { return }
        try store(pending, teamId: teamId, slot: slot)
    }

    func deletePendingKey(teamId: String, slot: TeamKeySlot) throws {
        try store.deleteKey(uid: Self.pendingAccount(teamId: teamId, slot: slot))
    }

    private static func account(teamId: String, slot: TeamKeySlot) -> String {
        "\(teamId)#\(slot.rawValue)"
    }

    /// A separate account, not a flag inside the item: `CloudVaultKeyStore`
    /// stores exactly 32 key bytes and nothing else, so "pending" has to be
    /// part of the address. The stale entry a promotion leaves behind is
    /// harmless — every read consults the ACTIVE slot first.
    private static func pendingAccount(teamId: String, slot: TeamKeySlot) -> String {
        "pending#\(teamId)#\(slot.rawValue)"
    }
}

/// The roster callables this lane drives. All are Admin-SDK authorities and
/// none ever receives a key. `promoteTeamMember` and `rotateTeamKey` verify
/// envelope COVERAGE (an envelope per pinned device per retained key version,
/// bound to the pinned fingerprint) before they will move a member to `active`
/// or record a new key generation; `recordTeamRewrapComplete` stamps a
/// completion the roster refuses for any generation but the current one.
///
/// `abandonTeamKeyGeneration` is the ESCAPE HATCH from a burned generation. An
/// admin who mints `v(N+1)`, publishes envelopes and never reaches
/// `rotateTeamKey` leaves those ids occupied by wraps of a key only their
/// Keychain holds — immutable, unrecoverable, and blocking the one version the
/// strict-sequence rule allows anyone else to mint. The callable records
/// `N+1` in the roster's `burnedKeyVersions`, after which `rotateTeamKey`'s
/// next-version rule skips it and the team rotates to `N+2` instead. It is
/// admin-only, it refuses any version the roster has recorded as active or
/// retained, and it refuses a version no envelope was ever published for, so it
/// cannot be used to skip version numbers at will.
///
/// EVERY CONFORMER, IN ONE LIST — adding a requirement here breaks each of them,
/// and a missing one is a build failure in a target the merge queue may not
/// compile (PR 4 review §5, hazard 4):
///
///   * `FirebaseTeamRosterCallableClient` — this file, directly below.
///   * `RecordingTeamRosterCallables` —
///     `AgentLensTests/Active/Security/TeamVaultKeyDistributionTests.swift`.
///
/// Keep that list exhaustive: a double a later PR introduces belongs on this
/// list rather than in a third place nobody greps for.
protocol TeamRosterCallableInvoking: Sendable {
    func promoteTeamMember(teamId: String, uid: String, envelopeIds: [String]) async throws
    func rotateTeamKey(teamId: String, newKeyVersion: Int, envelopeIds: [String]) async throws
    func abandonTeamKeyGeneration(teamId: String, version: Int) async throws
    /// Stamp "the corpus is actually re-keyed at this generation" on the roster
    /// (memory program D16 / P22, PR 4 — the promotion PR 2 review N1 deferred
    /// to the PR that ships a surface to read it).
    ///
    /// Separate from `rotateTeamKey` on purpose, and it must stay separate:
    /// `rotateTeamKey` runs BEFORE a single fact is re-sealed — it has to,
    /// because the rules pin fact writes to the roster's active generation — so
    /// folding the marker into it would stamp "re-keyed" on a corpus nothing had
    /// touched yet, which is precisely the claim N1 exists to stop the roster
    /// making.
    func recordTeamRewrapComplete(teamId: String, keyVersion: Int, rewrapJobId: String) async throws
}

// AUDIT(@unchecked Sendable): wraps a non-Sendable Firebase `Functions` instance;
// the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
final class FirebaseTeamRosterCallableClient: TeamRosterCallableInvoking, @unchecked Sendable {
    private let injectedFunctions: Functions?

    init(functions: Functions? = nil) {
        self.injectedFunctions = functions
    }

    private var functions: Functions {
        injectedFunctions ?? Functions.functions(region: "us-central1")
    }

    func promoteTeamMember(teamId: String, uid: String, envelopeIds: [String]) async throws {
        _ = try await functions.httpsCallable("promoteTeamMember").call([
            "teamId": teamId,
            "uid": uid,
            "envelopeIds": envelopeIds
        ])
    }

    func rotateTeamKey(teamId: String, newKeyVersion: Int, envelopeIds: [String]) async throws {
        _ = try await functions.httpsCallable("rotateTeamKey").call([
            "teamId": teamId,
            "newKeyVersion": newKeyVersion,
            "envelopeIds": envelopeIds
        ])
    }

    func abandonTeamKeyGeneration(teamId: String, version: Int) async throws {
        _ = try await functions.httpsCallable("abandonTeamKeyGeneration").call([
            "teamId": teamId,
            "version": version
        ])
    }

    func recordTeamRewrapComplete(teamId: String, keyVersion: Int, rewrapJobId: String) async throws {
        _ = try await functions.httpsCallable("recordTeamRewrapComplete").call([
            "teamId": teamId,
            "keyVersion": keyVersion,
            "rewrapJobId": rewrapJobId
        ])
    }
}

/// Opens envelopes addressed to THIS device. The escrow private key is
/// per-device and never leaves this Mac's Keychain.
protocol TeamEscrowPrivateKeyProviding: Sendable {
    func unwrapTeamKey(_ wrapped: Data) throws -> Data
}

struct DeviceTeamEscrowPrivateKey: TeamEscrowPrivateKeyProviding {
    let deviceId: String

    func unwrapTeamKey(_ wrapped: Data) throws -> Data {
        let keypair = try CloudVaultDeviceKeypair(account: "cloud-vault-device:\(deviceId)")
        return try keypair.decrypt(wrapped)
    }
}

enum TeamVaultKeyDistributionError: LocalizedError, Equatable {
    case missingKeyForSlot(teamId: String, slot: String)
    case memberHasNoPinnedDevice(uid: String)
    case escrowPublicKeyUnavailable(uid: String, deviceId: String, keyVersion: Int)
    case fingerprintNotPinned(uid: String, deviceId: String)
    case fingerprintNotBoundToKey(uid: String, deviceId: String)
    case rotationNotSequential(active: Int, expected: Int, requested: Int)
    case envelopeAddressedElsewhere(envelopeId: String)
    case rotationConflict(slot: String, envelopeId: String, wrappedBy: String)
    /// The roster authority refused a guarded commit because the team's KEY
    /// state or its MEMBERSHIP state moved while the call was in flight
    /// (`commitGuardedByTeamState` -> `aborted`). Retryable by construction;
    /// see the doc comment on ``TeamVaultKeyDistributor/rotateTeamKey(teamId:activeKeyVersion:newKeyVersion:activeMemberUids:rewrapWorker:rewrapJobId:)``.
    case rosterStateMovedInFlight(teamId: String, operation: String)
    case malformedEnvelope(envelopeId: String)

    var errorDescription: String? {
        switch self {
        case .missingKeyForSlot(let teamId, let slot):
            return "This device does not hold the \(slot) key for team \(teamId) yet."
        case .memberHasNoPinnedDevice(let uid):
            return "Member \(uid) has no pinned escrow device, so no team key can be wrapped for them."
        case .escrowPublicKeyUnavailable(let uid, let deviceId, let keyVersion):
            return "Escrow public key \(deviceId)_\(keyVersion) for \(uid) is missing or malformed."
        case .fingerprintNotPinned(let uid, let deviceId):
            return "The published escrow key for \(uid)/\(deviceId) does not match the fingerprint the roster pinned."
        case .fingerprintNotBoundToKey(let uid, let deviceId):
            return "The escrow fingerprint for \(uid)/\(deviceId) is not the digest of the key bytes it names."
        case .rotationNotSequential(let active, let expected, let requested):
            return """
            A team key rotates to the next generation the roster has not burned: \(active) -> \(expected), \
            not \(requested).
            """
        case .envelopeAddressedElsewhere(let envelopeId):
            return "Team key envelope \(envelopeId) already exists and is addressed to a different device or key."
        case .rotationConflict(let slot, let envelopeId, let wrappedBy):
            return """
            Another admin (\(wrappedBy)) is already distributing the \(slot) team key: envelope
            \(envelopeId) is their wrap of a key this Mac does not hold. Nothing was written — this pass
            pre-scanned every envelope it would have to claim before writing any of them. Wait for that
            rotation to finish. If it was abandoned, run "abandon this generation and rotate past it":
            the roster authority records \(slot) in burnedKeyVersions, after which it is never rotated
            to again, and this Mac mints the NEXT version for the whole team. Pressing that a second
            time is safe — the recovery burns \(slot) and nothing else, so an interrupted attempt
            resumes at the rotation instead of spending another generation.
            """
        case .rosterStateMovedInFlight(let teamId, let operation):
            return """
            Team \(teamId) changed while \(operation) was in flight — a key rotation, a promotion or a
            removal landed inside the window — so the roster authority refused the write rather than
            commit a decision computed against stale state. Nothing was published beyond the envelopes,
            which are already claimed and will be reused. Re-read the roster and retry.
            """
        case .malformedEnvelope(let envelopeId):
            return "Team key envelope \(envelopeId) is malformed and was not opened."
        }
    }
}

/// One resolved recipient device: the pin the roster made, plus the public key
/// bytes that pin was verified against. Only this type reaches a wrap.
private struct TeamWrapTarget {
    let pin: TeamEscrowDevicePin
    let publicKeyData: Data
}

/// Everything the caller needs after a wrap pass: which envelope ids were
/// written, so they can be handed to `promoteTeamMember` / `rotateTeamKey`.
struct TeamKeyEnvelopePublication: Equatable, Sendable {
    let envelopeIds: [String]
}

/// The team creation bootstrap: the two keys a founding admin generates, and the
/// envelopes it self-wrapped so its own devices can open the space.
struct TeamKeyBootstrap: Equatable, Sendable {
    let teamKeyVersion: Int
    /// Opaque `vaultKeyID`-style fingerprint of the slug key. Safe to publish:
    /// it lets a client notice it holds the wrong slug key without the server
    /// learning the key.
    let slugKeyId: String
    let envelopeIds: [String]
}

/// Writes and reads `team_key_envelopes/{teamId}/envelopes/{envelopeId}`, and
/// drives the two roster callables that depend on them.
struct TeamVaultKeyDistributor: Sendable {
    static let envelopeAlgorithm = "ECIES-P256-AESGCM"
    static let envelopesRootCollection = "team_key_envelopes"
    static let rosterRootCollection = "team_rosters"
    static let envelopesSubcollection = "envelopes"

    private static let logger = Logger(subsystem: "com.openburnbar.cloudsync", category: "TeamVaultKeyDistribution")

    let gateway: CloudSyncFirestoreGateway
    /// The signed-in account doing the wrapping. `wrappedBy` is pinned to this
    /// by `firestore.rules`, so it is also the identity the roster authority
    /// counts coverage against.
    let uid: String
    let deviceId: String
    let keyRing: TeamVaultKeyRing
    let callables: TeamRosterCallableInvoking
    let escrowPrivateKey: TeamEscrowPrivateKeyProviding

    // MARK: Team creation

    /// Generate `teamVaultKey_v1` + the non-rotating `teamSlugKey`, hold both in
    /// this device's key ring, and self-wrap both to every device the founder's
    /// OWN roster row pins.
    ///
    /// "Pinned on the roster row", not "trusted on this account" (PR 2 review
    /// INFO-3): the two sets differ exactly when a device is trusted locally but
    /// was not pinned by `createTeam`, and that difference is the "member with a
    /// blind second Mac" failure this lane exists to prevent. Enrol the second
    /// Mac, let the roster pin it, then ``selfWrapKeys(teamId:slots:)`` covers
    /// it — for the CURRENT generation and the slug key, which is all the rules
    /// let a non-admin self-wrap since C-1; see that method's own note.
    ///
    /// The founder is pinned and covered exactly like every joiner (PR 1 review
    /// F3): `createTeam` pins the founder's fingerprints server-side, and
    /// `rotateTeamKey` later refuses outright while any active member has zero
    /// pinned devices. The founder's own envelopes are SELF-wraps, which
    /// `firestore.rules` allows (`request.resource.data.uid == request.auth.uid`)
    /// and coverage counts (`wrappedBy == recipient`).
    ///
    /// LEGAL UNDER C-1 TWICE OVER, and neither reason is an accident.
    /// `createTeam` commits the team document and the founder's member row in ONE
    /// batch (`functions/src/teamRoster.ts:279-320`), seeding
    /// `activeKeyVersion: 1` alongside `role: "admin", status: "active"`. So by
    /// the time this runs — it needs the `teamId` that call returns — the founder
    /// satisfies `isTeamAdmin(teamId)`, the first disjunct of the envelope
    /// `create` rule, which is unconstrained in `keySlot`. And INDEPENDENTLY, the
    /// only two slots below are `.vault(version: 1)` and `.slug`, exactly the two
    /// the non-admin disjunct permits at `activeKeyVersion == 1`. A bootstrap
    /// that minted `v2`, or that ran before `createTeam`, would be denied at the
    /// door;
    /// `test_the_founder_bootstrap_self_wraps_only_slots_the_rules_permit`
    /// pins the slot set so that cannot drift in silently.
    ///
    /// IDEMPOTENT (PR 2 review B1). Both keys are minted as PENDING before the
    /// first envelope is written and promoted only once every envelope is
    /// published, so a bootstrap interrupted between the two writes resumes with
    /// the same `v1` and the same slug key instead of stranding a team whose
    /// published envelopes carry keys this device has thrown away.
    func bootstrapTeamKeys(teamId: String) async throws -> TeamKeyBootstrap {
        let slugKey = try mintKey(teamId: teamId, slot: .slug)
        _ = try mintKey(teamId: teamId, slot: .vault(version: 1))

        // BOTH slots are minted-in-this-pass, unconditionally (PR 2 review
        // round 3, B6). The question the guard asks is "has the team already
        // published this generation", and at bootstrap the answer is no for
        // both: this Mac generated them moments ago and no other writer can
        // legitimately hold their bytes. Deriving the answer from the ring's
        // PENDING flag instead — which is what this used to do — asked a
        // different question ("is this key still unpromoted on THIS Mac"), and
        // a ring populated from envelopes could answer it wrongly.
        let publication = try await selfWrapKeys(
            teamId: teamId,
            slots: [.vault(version: 1), .slug],
            mintedInThisPass: [.vault(version: 1), .slug]
        )
        try keyRing.promotePendingKey(teamId: teamId, slot: .vault(version: 1))
        try keyRing.promotePendingKey(teamId: teamId, slot: .slug)
        return TeamKeyBootstrap(
            teamKeyVersion: 1,
            slugKeyId: try CloudVaultCrypto.vaultKeyID(for: slugKey),
            envelopeIds: publication.envelopeIds
        )
    }

    /// Wrap team keys for THIS account's own devices — a founder bootstrapping,
    /// or a member enrolling a second Mac.
    ///
    /// The recipient is pinned to `uid` STRUCTURALLY: this entry point takes no
    /// recipient, so there is no argument a caller could pass to retarget it at
    /// a third party. (PR 2 review N4 deleted the runtime `isSelfWrap` assertion
    /// that used to sit in ``wrapKeys(teamId:recipientUids:slots:mintedInThisPass:)`` — every
    /// caller made it true by construction, so nothing could ever reach it, and
    /// a guard that cannot fire documents a boundary it does not enforce. Same
    /// argument PR 1 used to delete the dead rules negations.) A wrap for
    /// someone else goes through ``wrapKeysForMember(teamId:recipientUid:slots:)``,
    /// which `firestore.rules` permits only for an active admin.
    ///
    /// `mintedInThisPass` defaults to empty because the ordinary caller — a
    /// member enrolling a second Mac — hands out generations the roster already
    /// recorded. Only ``bootstrapTeamKeys(teamId:)`` passes a non-empty set.
    ///
    /// WHICH SLOTS THIS ENTRY POINT MAY ACTUALLY PASS (PR 1 Cursor round C-1).
    /// The rules confine a NON-ADMIN self-wrap to `keySlot == "slug"` or
    /// `keySlot == "v" + string(activeTeamKeyVersion(teamId))`
    /// (`firestore.rules:5123-5128`), because an immutable, create-only envelope
    /// id let an ordinary member squat the exact ids the next rotation would
    /// demand of them and deny the team its only revocation primitive for ever.
    /// So a member on this path may self-wrap the CURRENT generation and the
    /// slug key — not every RETAINED generation, and never a future one. A
    /// second Mac that also needs `v1…v(N-1)` to open older facts must be
    /// covered by an admin through
    /// ``wrapKeysForMember(teamId:recipientUid:slots:)``, which the rules permit
    /// for an active admin at any slot. An ADMIN calling this entry point is
    /// unconstrained for the same reason — `isTeamAdmin(teamId)` is the first
    /// disjunct — which is what makes the founder bootstrap below legal.
    func selfWrapKeys(
        teamId: String,
        slots: [TeamKeySlot],
        mintedInThisPass: Set<TeamKeySlot> = []
    ) async throws -> TeamKeyEnvelopePublication {
        try await wrapKeys(
            teamId: teamId,
            recipientUids: [uid],
            slots: slots,
            mintedInThisPass: mintedInThisPass
        )
    }

    // MARK: Join

    /// Wrap every retained key version PLUS the slug key for a pending joiner,
    /// then promote them.
    ///
    /// A member is never active-but-blind (design §3(b)2): the envelopes are
    /// published first and `promoteTeamMember` refuses to flip `pending ->
    /// active` until it has verified one envelope per pinned device per retained
    /// version, each bound to that device's pinned fingerprint.
    func issueJoinerKeys(
        teamId: String,
        joinerUid: String,
        retainedKeyVersions: [Int]
    ) async throws -> TeamKeyEnvelopePublication {
        let slots = retainedKeyVersions.sorted().map { TeamKeySlot.vault(version: $0) } + [.slug]
        let publication = try await wrapKeysForMember(teamId: teamId, recipientUid: joinerUid, slots: slots)
        try await Self.mappingRosterStateConflict(teamId: teamId, operation: "promoteTeamMember") {
            try await callables.promoteTeamMember(
                teamId: teamId,
                uid: joinerUid,
                envelopeIds: publication.envelopeIds
            )
        }
        return publication
    }

    /// Wrap team keys for another member's devices. Admin-only at the rules.
    func wrapKeysForMember(
        teamId: String,
        recipientUid: String,
        slots: [TeamKeySlot]
    ) async throws -> TeamKeyEnvelopePublication {
        // Every slot here comes out of the ring: a joiner is issued the
        // generations the roster already retains, never a freshly minted one.
        try await wrapKeys(teamId: teamId, recipientUids: [recipientUid], slots: slots, mintedInThisPass: [])
    }

    // MARK: Rotation

    /// Rotate the team key one generation and re-seal the team's facts in place.
    ///
    /// ORDER MATTERS, and it is not the order the design sketch listed. The
    /// rules pin every fact write to `d.teamKeyVersion == activeTeamKeyVersion(teamId)`,
    /// so a rewrap that ran BEFORE `rotateTeamKey` recorded `v(N+1)` would have
    /// every single one of its writes denied. The sequence is therefore:
    ///
    ///   1. generate `v(N+1)` and hold it locally;
    ///   2. wrap it for every remaining active member's pinned devices;
    ///   3. call `rotateTeamKey`, which verifies that coverage, appends
    ///      `N+1` to `retainedKeyVersions`, sets `activeKeyVersion` and clears
    ///      `keyRotationRequired`;
    ///   4. walk the facts and re-seal them under `v(N+1)`.
    ///
    /// Every member holds both `vN` and `v(N+1)` from step 2 on, so between
    /// steps 3 and 4 the space stays fully READABLE (a fact is opened by the key
    /// its own `keyVersion` label names) — only writes to a not-yet-rewrapped
    /// fact are refused. That matches the F5 recovery contract: the team
    /// document is the sole authority for `activeKeyVersion`.
    ///
    /// EVERY STEP IS AN IDEMPOTENT RETRY, and that is a property of the code,
    /// not a hope (PR 2 review B1/B2):
    ///
    ///   * `v(N+1)` is minted ONCE. It is written to the ring as PENDING before
    ///     the first envelope and reused verbatim by every later attempt, so a
    ///     rotation interrupted after half the envelopes resumes and publishes
    ///     wraps of the SAME key. Regenerating it would strand the members who
    ///     already have envelopes, permanently: envelope documents are
    ///     create-only and immutable, so the second key's envelopes could never
    ///     replace the first key's.
    ///   * Envelope publication is READ-BEFORE-WRITE. An id that already exists
    ///     and is addressed to the same device and slot is claimed and skipped;
    ///     an update is never attempted, because the rules deny it outright.
    ///   * The rewrap picks each fact's opening key from that fact's OWN key
    ///     version, so a corpus left spread across three generations by an
    ///     earlier interruption still converges on the active one.
    ///
    /// STEP 2 IS ONE PASS OVER EVERY MEMBER, NOT ONE PASS PER MEMBER (PR 2
    /// review round 3, B5). `activeMemberUids` is caller-supplied and has no
    /// ordering contract, so a per-member loop detected a conflicting envelope
    /// only when it happened to REACH one: two admins iterating the same roster
    /// in different orders each wrote their own key to the members the other had
    /// not covered yet, and the generation was then wedged for both. The whole
    /// member set therefore goes to ``wrapKeys(teamId:recipientUids:slots:mintedInThisPass:)``
    /// in a single call, which resolves and PRE-SCANS every
    /// `(member, device, slot)` before it writes any of them — so "nothing was
    /// written" is a property of the code and not of the order the caller
    /// happened to pass.
    ///
    /// THE ROTATOR PUBLISHES AS AN ADMIN, INCLUDING FOR ITS OWN MACS (PR 1
    /// Cursor round C-1). Step 2 passes `activeMemberUids` straight through, the
    /// rotator's own uid among them — it deliberately does NOT route its own
    /// devices through ``selfWrapKeys(teamId:slots:)``. Those two produce the
    /// same document either way, but the rule that admits it is not the same:
    /// `v(N+1)` is by definition a generation the roster has not published yet,
    /// and since C-1 a non-admin self-wrap is confined to `slug` or
    /// `v{activeKeyVersion}` (`firestore.rules:5123-5128`). The write is legal
    /// only through `isTeamAdmin(teamId)`, which `rotateTeamKey` already requires
    /// server-side anyway (`functions/src/teamRoster.ts:657` -> `:172-180`). A future
    /// refactor that "tidies" the self case onto `selfWrapKeys` would still
    /// compile, still pass every fake-gateway test, and be denied by the rules in
    /// production against the rotator's own Macs only —
    /// `test_the_rotating_admin_may_self_wrap_the_next_generation` in
    /// `functions/scripts/test-firestore-rules.mjs` is the rules-side pin, and
    /// `test_rotation_wraps_the_rotating_admins_own_devices_through_the_admin_path`
    /// is the client-side one.
    ///
    /// A CONCURRENT PROMOTION ABORTS THIS, BY DESIGN (C-4). `membershipEpoch` is
    /// captured by the callable with the active-member snapshot and re-read in
    /// the transaction that writes, so a `promoteTeamMember` landing between this
    /// client's roster read and step 3 refuses the rotation rather than
    /// publishing `v(N+1)` over the new member's head. It surfaces here as
    /// ``TeamVaultKeyDistributionError/rosterStateMovedInFlight(teamId:operation:)``,
    /// and the retry is clean because the pending key is promoted only AFTER the
    /// callable returns — see ``mappingRosterStateConflict(teamId:operation:_:)``.
    func rotateTeamKey(
        teamId: String,
        activeKeyVersion: Int,
        newKeyVersion: Int,
        activeMemberUids: [String],
        burnedKeyVersions: [Int] = [],
        rewrapWorker: TeamCloudVaultRewrapWorker,
        rewrapJobId: String
    ) async throws -> TeamCloudVaultRewrapProgress {
        let expectedKeyVersion = Self.nextRotatableKeyVersion(
            activeKeyVersion: activeKeyVersion,
            burnedKeyVersions: burnedKeyVersions
        )
        guard newKeyVersion == expectedKeyVersion else {
            throw TeamVaultKeyDistributionError.rotationNotSequential(
                active: activeKeyVersion,
                expected: expectedKeyVersion,
                requested: newKeyVersion
            )
        }
        // The rotating admin must hold the retiring generation before anything
        // is published: without it the rewrap could not open a single existing
        // fact, and the failure would land AFTER `rotateTeamKey` had already
        // recorded the new generation.
        _ = try requireKey(teamId: teamId, slot: .vault(version: activeKeyVersion))
        let newSlot = TeamKeySlot.vault(version: newKeyVersion)
        let newKey = try mintKey(teamId: teamId, slot: newSlot)
        // MINTED-IN-THIS-PASS IS A FACT ABOUT THE ROSTER, NOT ABOUT THIS
        // KEYCHAIN (PR 2 review round 3, B6). `newKeyVersion` is by construction
        // the next generation the roster has NOT recorded — the guard above says
        // so — therefore nobody else can legitimately have published an envelope
        // for it and every one of its envelopes must be this account's own.
        //
        // This used to read `minted.isPending`, a property of THIS Mac's ring,
        // and the two questions come apart exactly when it matters:
        // `loadKeyRingFromEnvelopes` could land an abandoned rotation's
        // `v(N+1)` in the ACTIVE ring, `mintKey` would then report
        // `isPending == false`, and the guard switched itself off on the one
        // pass it exists to protect. The ring can no longer do that (see that
        // method), and this no longer asks it to.
        let mintedInThisPass: Set<TeamKeySlot> = [newSlot]

        // The slug key is NOT re-issued: it never rotates, so a rotation that
        // re-derived document ids would orphan the whole team space.
        let publication = try await wrapKeys(
            teamId: teamId,
            recipientUids: activeMemberUids,
            slots: [newSlot],
            mintedInThisPass: mintedInThisPass
        )
        let envelopeIds = publication.envelopeIds

        try await Self.mappingRosterStateConflict(teamId: teamId, operation: "rotateTeamKey") {
            try await callables.rotateTeamKey(
                teamId: teamId,
                newKeyVersion: newKeyVersion,
                envelopeIds: envelopeIds
            )
        }
        // Promoted only now: until the roster authority has recorded `N+1`, the
        // active generation is still `N` and a crash must resume the SAME
        // pending key rather than mint a second one.
        try keyRing.promotePendingKey(teamId: teamId, slot: newSlot)

        return try await rewrapWorker.runRewrap(
            teamId: teamId,
            jobId: rewrapJobId,
            keyRing: keyRing,
            newKeyData: newKey,
            newTeamKeyVersion: newKeyVersion
        )
    }

    /// The generation a rotation may mint: the first version after the active
    /// one that the roster has not BURNED.
    ///
    /// `functions/src/teamRosterState.ts` computes the identical number
    /// (`nextRotatableKeyVersion`) and `rotateTeamKey` refuses anything else, so
    /// this is a fast local refusal, not the authority. Two implementations of
    /// one rule is deliberate: the client must be able to say WHICH version it
    /// is about to mint before it wraps a single envelope.
    static func nextRotatableKeyVersion(activeKeyVersion: Int, burnedKeyVersions: [Int]) -> Int {
        let burned = Set(burnedKeyVersions)
        var candidate = activeKeyVersion + 1
        while burned.contains(candidate) { candidate += 1 }
        return candidate
    }

    /// Move a team PAST a generation another admin minted, published envelopes
    /// for, and abandoned — the recovery from
    /// ``TeamVaultKeyDistributionError/rotationConflict(slot:envelopeId:wrappedBy:)``.
    ///
    /// WHY THERE HAS TO BE A SERVER STEP. When admin A mints `v(N+1)`, publishes
    /// envelopes and never reaches `rotateTeamKey`, the roster still records `N`
    /// and `K_A` exists only in A's Keychain. `v(N+1)`'s envelope ids are
    /// occupied and immutable, nothing publishable says which key a wrap
    /// carries, and both the client and the callable refuse to mint anything but
    /// the next version — which is `N+1`. A team in that state cannot rotate at
    /// all, so it cannot revoke a departed member either: the primitive is dead.
    /// "Just rotate to `N+2`" is not something either side would accept.
    ///
    /// So the roster authority learns to skip. `abandonTeamKeyGeneration`
    /// appends `N+1` to `burnedKeyVersions` — admin-only, refused for any
    /// version the roster recorded as active or retained, and refused unless at
    /// least one envelope for it actually exists, so it burns a real abandoned
    /// rotation rather than skipping version numbers at will. `rotateTeamKey`'s
    /// next-version rule then reads past it and this pass mints `N+2` for the
    /// whole team.
    ///
    /// `v(N+1)`'s envelopes are left where they are. They are harmless: the
    /// rules pin every fact write to the roster's active version, so no document
    /// can ever name a generation the callable did not record. The one thing
    /// that is NOT left behind is this Mac's own pending `v(N+1)` — a burned
    /// generation's key can open nothing that will ever exist, so it is deleted
    /// from the ring rather than kept as a slot ``requireKey(teamId:slot:)``
    /// would still hand out.
    ///
    /// THE GENERATION TO BURN IS AN ARGUMENT, NEVER RE-DERIVED (PR 2 review
    /// round 4, B8). `conflictingVersion` is the generation the refusal named,
    /// and the caller already holds it:
    /// ``TeamVaultKeyDistributionError/rotationConflict(slot:envelopeId:wrappedBy:)``
    /// carries the `slot` it refused on.
    ///
    /// This method used to compute the burn target from `activeKeyVersion` and
    /// `burnedKeyVersions` on every call, which made its own retry story false.
    /// On the second press the caller's refreshed `burnedKeyVersions` already
    /// contains `N+1`, so the derivation returned `N+2` — either a
    /// `failed-precondition` (nothing was ever published for `N+2`) or, on the
    /// ordinary path where this Mac's own inner rotation had already published
    /// `N+2`'s envelopes and then aborted, a burn of the generation it had just
    /// minted. Two of a hard-capped 100 key versions per press, unrecoverably,
    /// on the retry path three shipped surfaces prescribe.
    ///
    /// The abandon and the rotation are two calls, not one transaction, and the
    /// order is the safe one: a crash between them leaves `N+1` burned and the
    /// roster at `N`, which is exactly the state a plain retry of this method
    /// resumes from. It resumes rather than burning again in both directions:
    ///
    ///   * the caller's refreshed `burnedKeyVersions` already carries
    ///     `conflictingVersion`, so the callable is not invoked at all and the
    ///     pass goes straight to the rotation;
    ///   * and if that list is stale, `abandonKeyGeneration`
    ///     (`functions/src/teamRoster.ts`) returns WITHOUT writing for a version
    ///     it has already burned, so the retry still ends in the rotation rather
    ///     than an `invalid-argument` about a version number.
    ///
    /// A ``TeamVaultKeyDistributionError/rosterStateMovedInFlight(teamId:operation:)``
    /// from the INNER rotation — the C-4 abort, and the ordinary outcome when a
    /// promotion or a removal lands in that window — is therefore retried as a
    /// ROTATION ONLY. `N+2`'s envelopes are already on the server and its key is
    /// still PENDING in this ring, so the retry reuses the same bytes, claims its
    /// own envelopes through the read-before-write branch of
    /// ``wrapKeys(teamId:recipientUids:slots:mintedInThisPass:)``, and consumes
    /// no further versions.
    ///
    /// WHICH VERSIONS MAY BE BURNED IS THE ROSTER AUTHORITY'S CALL, not this
    /// method's. `abandonKeyGeneration` refuses any version the roster recorded
    /// as active or retained, any version that is not the next unclaimed one,
    /// and any version no envelope was ever published for. A nonsense
    /// `conflictingVersion` is refused there, server side, rather than guessed
    /// at here.
    func abandonConflictingGenerationAndRotate(
        teamId: String,
        conflictingVersion: Int,
        activeKeyVersion: Int,
        burnedKeyVersions: [Int] = [],
        activeMemberUids: [String],
        rewrapWorker: TeamCloudVaultRewrapWorker,
        rewrapJobId: String
    ) async throws -> TeamCloudVaultRewrapProgress {
        let alreadyBurned = burnedKeyVersions.contains(conflictingVersion)
        if !alreadyBurned {
            try await Self.mappingRosterStateConflict(teamId: teamId, operation: "abandonTeamKeyGeneration") {
                try await callables.abandonTeamKeyGeneration(teamId: teamId, version: conflictingVersion)
            }
            Self.logger.notice(
                "Team \(teamId, privacy: .public) abandoned key generation v\(conflictingVersion, privacy: .public); rotating past it."
            )
        }
        // Outside the branch above on purpose, and idempotent: a first press
        // whose burn succeeded and whose ROTATION then failed must still be able
        // to clear the burned generation's pending slot on the retry.
        try keyRing.deletePendingKey(teamId: teamId, slot: .vault(version: conflictingVersion))

        let burned = alreadyBurned ? burnedKeyVersions : burnedKeyVersions + [conflictingVersion]
        return try await rotateTeamKey(
            teamId: teamId,
            activeKeyVersion: activeKeyVersion,
            newKeyVersion: Self.nextRotatableKeyVersion(
                activeKeyVersion: activeKeyVersion,
                burnedKeyVersions: burned
            ),
            activeMemberUids: activeMemberUids,
            burnedKeyVersions: burned,
            rewrapWorker: rewrapWorker,
            rewrapJobId: rewrapJobId
        )
    }

    /// Turn the roster authority's guarded-commit refusal into a NAMED,
    /// RETRYABLE error instead of a raw `NSError` the caller has to pattern-match
    /// on itself.
    ///
    /// `commitGuardedByTeamState` (`functions/src/teamRosterState.ts`) re-reads the
    /// team document inside the transaction that writes and throws `aborted` when
    /// the state the decision was computed against has moved. Two things move it:
    ///
    ///   * KEY state — `activeKeyVersion` / `retainedKeyVersions` (PR 1 review N-4);
    ///   * MEMBERSHIP state — `membershipEpoch`, bumped by `promoteMember` and
    ///     `removeMember` inside their own transactions (PR 1 Cursor round C-4).
    ///     A rotation's requirement set comes from a QUERY for active members and
    ///     Firestore cannot conflict-detect a query, so the epoch is the read the
    ///     rotation CAN conflict-detect on. A promotion landing between this
    ///     client's roster scan and its commit now aborts the rotation rather than
    ///     publishing `v(N+1)` over the new member's head.
    ///
    /// Both are the same instruction to this client: *your snapshot is stale, take
    /// a fresh one and run again*. That is why they map to one case rather than
    /// two, and why the case is a sibling of — not a synonym for —
    /// ``TeamVaultKeyDistributionError/rotationConflict(slot:envelopeId:wrappedBy:)``:
    /// `rotationConflict` means another admin holds a key this Mac does not, which
    /// no retry of THIS generation can fix — the way out is
    /// ``abandonConflictingGenerationAndRotate(teamId:conflictingVersion:activeKeyVersion:burnedKeyVersions:activeMemberUids:rewrapWorker:rewrapJobId:)``,
    /// which burns that generation on the roster and mints the next one. A stale
    /// snapshot, by contrast, is fixed by retrying exactly what was refused.
    ///
    /// THE RETRY IS NOT POISONED, and that is a property of the ORDER above, not
    /// of this mapping. `v(N+1)` is still PENDING in the ring — it is promoted only
    /// on the line after a successful callable — so the retry's `mintKey` returns
    /// the SAME bytes, `mintedInThisPass` still guards it, and every envelope this
    /// pass already published is claimed by the read-before-write branch of
    /// ``wrapKeys(teamId:recipientUids:slots:mintedInThisPass:)`` and re-listed for
    /// the callable. The member promoted inside the window simply appears in the
    /// caller's refreshed `activeMemberUids` and gets their wrap of that same key.
    ///
    /// Anything that is NOT this refusal is rethrown untouched: a
    /// `failed-precondition` from C-3's `stillPendingMemberRef` re-read means the
    /// member was REMOVED mid-flight, and retrying a promotion of a removed member
    /// is exactly the live/removed re-join violation C-3 exists to stop.
    private static func mappingRosterStateConflict(
        teamId: String,
        operation: String,
        _ call: () async throws -> Void
    ) async throws {
        do {
            try await call()
        } catch {
            let nsError = error as NSError
            guard nsError.domain == FunctionsErrorDomain,
                  FunctionsErrorCode(rawValue: nsError.code) == .aborted else {
                throw error
            }
            logger.error(
                "Roster authority aborted \(operation, privacy: .public) for team \(teamId, privacy: .public): the team's key or membership state moved in flight. Retry against a fresh roster snapshot."
            )
            throw TeamVaultKeyDistributionError.rosterStateMovedInFlight(teamId: teamId, operation: operation)
        }
    }

    // MARK: Unwrap

    /// Populate the key ring from every envelope this uid can read, this device
    /// is the pinned recipient of, an authorised wrapper wrote, and this device
    /// can open — and report the slots that landed.
    ///
    /// The query is constrained to `uid == self.uid` because the rules grant a
    /// member read on their OWN envelopes only — an unconstrained list of the
    /// collection is denied. Envelopes addressed to this account's other Macs
    /// are filtered out here: their wraps are for a different escrow private
    /// key and this device cannot open them.
    ///
    /// THREE CHECKS BEYOND "IT DECRYPTED" (PR 2 review N3). Successful
    /// decryption proves only that the wrap was made for this device's escrow
    /// key; it says nothing about who made it or which key it carries. So:
    ///
    ///   1. `recipientPublicKeyFingerprint` must be a fingerprint THIS device's
    ///      own roster row pins, at the escrow generation the envelope names.
    ///      Without it, two envelopes for one slot under different escrow
    ///      generations resolve by iteration order.
    ///   2. `wrappedBy` must be this account itself (a self-wrap) or a uid with
    ///      an `admin` member row on this team — the client mirror of the rules'
    ///      create clause, so a rules bypass or a compromised backend cannot
    ///      plant a key this device would then seal future facts under. Status
    ///      is deliberately NOT required to be active (PR 1 amendment N-2): a
    ///      departed admin's pre-departure wraps stay valid, and rotation, not
    ///      coverage arithmetic, is what revokes them.
    ///   3. Ties are resolved by the HIGHEST escrow generation, deterministically,
    ///      rather than by whichever document the query returned last.
    ///
    /// None of this is reachable by a plain member today — the rules confine
    /// `create` to an admin or a self-wrap — so it is defence in depth, on the
    /// one path that decides which key this device will seal with.
    ///
    /// A LOADED SLOT IS ACTIVE ONLY IF THE ROSTER RECORDED IT (PR 2 review round
    /// 3, B6). The envelope collection is not a record of what the team agreed
    /// on: an abandoned rotation leaves `v(N+1)` envelopes behind that no
    /// callable ever confirmed, and this method WILL find them, because it is
    /// the launch-time key pickup. Storing such a slot in the ACTIVE ring made
    /// the ring's active/pending distinction mean "did this Mac mint it" instead
    /// of "did the roster record it", and `rotateTeamKey`'s B4 guard used to be
    /// keyed on exactly that distinction. So the team document is read first and
    /// a slot it does not name — `activeKeyVersion`, a member of
    /// `retainedKeyVersions`, or the slug key once `slugKeyId` is published — is
    /// stored PENDING. It is still usable: ``requireKey(teamId:slot:)`` falls
    /// back to pending, so nothing this method can open is thrown away. It is
    /// simply not promoted to the status "the team published this".
    @discardableResult
    func loadKeyRingFromEnvelopes(teamId: String) async throws -> [TeamKeySlot] {
        let recorded = try await rosterRecordedSlots(teamId: teamId)
        let pinnedFingerprints = try await ownPinnedFingerprints(teamId: teamId)
        let snapshot = try await envelopeCollection(teamId: teamId)
            .whereField("uid", isEqualTo: uid)
            .getDocuments()

        var wrapperIsAuthorised: [String: Bool] = [uid: true]
        var candidates: [(escrowKeyVersion: Int, slot: TeamKeySlot, wrapped: Data, documentID: String)] = []
        for document in snapshot.documents {
            let data = document.data()
            guard data["deviceId"] as? String == deviceId else { continue }
            guard let slotRaw = data["keySlot"] as? String,
                  let slot = TeamKeySlot(rawValue: slotRaw),
                  let escrowKeyVersion = data["escrowKeyVersion"] as? Int,
                  let wrappedBy = data["wrappedBy"] as? String,
                  let wrappedBase64 = data["wrappedKeyBase64"] as? String,
                  let wrapped = Data(base64Encoded: wrappedBase64) else {
                Self.logger.warning("Skipping malformed team key envelope \(document.documentID, privacy: .public)")
                continue
            }
            guard let pinned = pinnedFingerprints[escrowKeyVersion],
                  data["recipientPublicKeyFingerprint"] as? String == pinned else {
                Self.logger.warning(
                    "Team key envelope \(document.documentID, privacy: .public) names a fingerprint this device does not pin; skipped."
                )
                continue
            }
            let authorised: Bool
            if let known = wrapperIsAuthorised[wrappedBy] {
                authorised = known
            } else {
                authorised = try await isTeamAdmin(teamId: teamId, uid: wrappedBy)
                wrapperIsAuthorised[wrappedBy] = authorised
            }
            guard authorised else {
                Self.logger.warning(
                    "Team key envelope \(document.documentID, privacy: .public) was not wrapped by an admin or by this account; skipped."
                )
                continue
            }
            candidates.append((escrowKeyVersion, slot, wrapped, document.documentID))
        }

        var loaded: [TeamKeySlot] = []
        for candidate in candidates.sorted(by: { $0.escrowKeyVersion < $1.escrowKeyVersion }) {
            do {
                let keyData = try escrowPrivateKey.unwrapTeamKey(candidate.wrapped)
                if recorded.contains(candidate.slot) {
                    try keyRing.store(keyData, teamId: teamId, slot: candidate.slot)
                } else {
                    Self.logger.notice(
                        "Team key envelope \(candidate.documentID, privacy: .public) names a generation the roster has not recorded; held PENDING."
                    )
                    try keyRing.storePending(keyData, teamId: teamId, slot: candidate.slot)
                }
                if !loaded.contains(candidate.slot) { loaded.append(candidate.slot) }
            } catch {
                // A wrap this device cannot open is not fatal: a superseded
                // escrow key, say. The caller's key ring is simply missing that
                // slot, which `openTeamFact` reports as a NON-PERMANENT refusal
                // rather than a poisoned cursor.
                Self.logger.warning(
                    "Could not open team key envelope \(candidate.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return loaded
    }

    // MARK: - Internals

    /// Publish one envelope per (recipient × target device × slot), skipping the
    /// ones that are already there.
    ///
    /// THREE PHASES, AND THE ORDER IS THE CONTRACT (PR 2 review round 3, B5).
    /// The pass RESOLVES every recipient's targets, then PRE-SCANS every
    /// envelope id it would have to claim, and only then WRITES. Nothing is
    /// written until every id has been read and accepted, so a refusal FROM THE
    /// PRE-SCAN — ``TeamVaultKeyDistributionError/envelopeAddressedElsewhere``
    /// or ``TeamVaultKeyDistributionError/rotationConflict`` — leaves the server
    /// exactly as it found it, whatever order the caller passed its recipients
    /// in.
    ///
    /// That guarantee is about the pre-scan, not about the whole method (PR 2
    /// review round 4, N2). The pre-scan is a SNAPSHOT, not a transaction: two
    /// admins whose phase-3 writes genuinely interleave can each claim ids the
    /// other's scan saw as free, and a transport failure on the fifth of ten
    /// `setData` calls leaves the first four written. A generation split that
    /// way wedges both admins — which is precisely the state
    /// ``abandonConflictingGenerationAndRotate(teamId:conflictingVersion:activeKeyVersion:burnedKeyVersions:activeMemberUids:rewrapWorker:rewrapJobId:)``
    /// exists to unstick, and why it is a recovery rather than a nicety.
    ///
    /// That used to be true only per member, and `rotateTeamKey` called this
    /// once per member over a caller-supplied `[String]` with no ordering
    /// contract. Two admins iterating the same roster in different orders each
    /// reached an uncovered member before reaching the other's envelope, wrote
    /// their own key there, and only then refused: the generation ended up
    /// carrying two different keys, both admins were blocked, and the doc
    /// comment and the operator-facing error text both said "nothing was
    /// written" while the opposite had just happened. The property is now
    /// structural rather than a property of the order the caller passed.
    ///
    /// READ BEFORE WRITE (PR 2 review B1). `firestore.rules` says
    /// `allow update, delete: if false` on an envelope, and Firestore classifies
    /// a `setData(merge: false)` over an existing document as an UPDATE — so a
    /// blind re-publication does not overwrite the old envelope, it is denied,
    /// and the retry dies on the first id a previous attempt had already
    /// written. Every id is therefore fetched first: an envelope already
    /// addressed to this recipient, device, escrow generation and slot is
    /// counted toward coverage and skipped, and a mismatch is raised rather than
    /// papered over, because it means somebody else's wrap is sitting on an id
    /// this pass believes it owns. An update is never attempted.
    ///
    /// WHO WROTE IT MATTERS, BUT ONLY FOR A KEY THIS PASS MINTED (PR 2 review
    /// B4). The five fields the claim predicate compares are all functions of
    /// the recipient's roster pin, so they say nothing about WHICH KEY the
    /// existing envelope wraps — the server never sees key bytes and neither
    /// does this check.
    ///
    ///   * For a RING-SOURCED slot (a retained generation, the slug key) that is
    ///     exactly right. Every admin holds identical bytes for it, so any
    ///     admin's wrap is this admin's wrap, and claiming it is what lets a
    ///     surviving admin finish a promote a departed admin started (PR 1
    ///     amendment N-2). Requiring `wrappedBy == uid` here would break that.
    ///   * For a slot MINTED IN THIS PASS it is catastrophically wrong. Admin A
    ///     mints `K_A` for `v(N+1)`, writes one envelope and dies before the
    ///     callable; the roster is still at `N`. Admin B rotates, mints a
    ///     DIFFERENT `K_B`, and — without this guard — claims A's envelope
    ///     because all five fields match, then publishes `K_B` to everyone
    ///     else. `rotateTeamKey` counts coverage and cannot see the fork.
    ///     A then seals future facts under `K_A` while labelling them
    ///     `teamKeyVersion: N+1`, which the rules accept because they check the
    ///     label, not the key. Nobody can read them, and no later rotation
    ///     repairs it. Silent, permanent, partial data loss.
    ///
    /// So for minted slots the existing envelope is accepted ONLY when this
    /// account wrote it (our own earlier attempt at this same pass). Any other
    /// writer means a concurrent or abandoned rotation by another admin, and
    /// the pass STOPS with ``TeamVaultKeyDistributionError/rotationConflict``
    /// having written nothing.
    ///
    /// TAKING OVER AN ABANDONED ROTATION NEEDS A NEW GENERATION, NOT THIS ONE.
    /// If the pending version's envelopes on the server are all `wrappedBy` one
    /// other admin and that admin is gone, `v(N+1)` cannot be FINISHED by anyone
    /// else: its envelope documents are create-only and immutable, so the ids
    /// that were never written can be filled only with the key those that WERE
    /// written already carry, and nothing publishable identifies which key a
    /// wrap carries.
    ///
    /// The key itself is not always out of reach, and the doc comment used to
    /// claim it was (PR 2 review round 3, nit 4). An admin whose OWN device
    /// received one of A's `v(N+1)` envelopes does open `K_A` through
    /// ``loadKeyRingFromEnvelopes(teamId:)``. What that admin gets is a PENDING
    /// ring slot, not an active one, so `rotateTeamKey` still treats `v(N+1)` as
    /// minted-in-this-pass and still refuses to publish over A's wraps. Turning
    /// that recovery into a deliberate takeover would first have to prove the
    /// server holds no `v(N+1)` envelope under a DIFFERENT key, which is exactly
    /// the `wrappedKeyId` work below. Until then the answer is to step over the
    /// generation, not to adopt it.
    ///
    /// The way past it is
    /// ``abandonConflictingGenerationAndRotate(teamId:conflictingVersion:activeKeyVersion:burnedKeyVersions:activeMemberUids:rewrapWorker:rewrapJobId:)``:
    /// the roster authority records `N+1` in `burnedKeyVersions`, its
    /// next-version rule reads past it, and the team rotates to `N+2` with
    /// `N+1`'s partial envelopes left abandoned in place — harmless, because the
    /// rules pin every fact write to the roster's active version, so no document
    /// can name a generation the callable never recorded. (RECOVERING `N+1`,
    /// rather than stepping over it, would need an opaque `wrappedKeyId` on the
    /// envelope, which touches the rules `hasOnly` list and the callable's field
    /// allowlist; that is PR 4 design work, named as a known risk in the PR body
    /// rather than attempted here.)
    private func wrapKeys(
        teamId: String,
        recipientUids: [String],
        slots: [TeamKeySlot],
        mintedInThisPass: Set<TeamKeySlot>
    ) async throws -> TeamKeyEnvelopePublication {
        // PHASE 1 — resolve EVERY recipient's targets and EVERY key. An envelope
        // is create-only and immutable, so a half-written set could never be
        // repaired; verifying first means a rejected fingerprint, a missing
        // escrow key or an unheld slot produces zero documents rather than a
        // permanently broken id set.
        let keysBySlot = try slots.reduce(into: [TeamKeySlot: Data]()) { keys, slot in
            keys[slot] = try requireKey(teamId: teamId, slot: slot)
        }
        var plan: [(recipientUid: String, target: TeamWrapTarget, slot: TeamKeySlot, envelopeId: String)] = []
        for recipientUid in recipientUids {
            for target in try await resolveWrapTargets(teamId: teamId, recipientUid: recipientUid) {
                for slot in slots {
                    plan.append((
                        recipientUid,
                        target,
                        slot,
                        Self.envelopeId(uid: recipientUid, pin: target.pin, slot: slot)
                    ))
                }
            }
        }

        // PHASE 2 — pre-scan every id this pass would claim, BEFORE writing any
        // of them. This is what makes "nothing was written" true regardless of
        // the order `recipientUids` arrived in (B5).
        var alreadyPublished: Set<String> = []
        for step in plan {
            guard let existing = try await envelopeCollection(teamId: teamId).document(step.envelopeId).getData() else {
                continue
            }
            guard Self.envelope(
                existing,
                addresses: step.recipientUid,
                pin: step.target.pin,
                slot: step.slot
            ) else {
                throw TeamVaultKeyDistributionError.envelopeAddressedElsewhere(envelopeId: step.envelopeId)
            }
            if mintedInThisPass.contains(step.slot) {
                let writer = existing["wrappedBy"] as? String ?? "an unidentified writer"
                guard writer == uid else {
                    Self.logger.error(
                        "Refusing to claim team key envelope \(step.envelopeId, privacy: .public): it was written by \(writer, privacy: .public) and wraps a generation this Mac minted, so it carries a key this Mac does not hold."
                    )
                    throw TeamVaultKeyDistributionError.rotationConflict(
                        slot: step.slot.rawValue,
                        envelopeId: step.envelopeId,
                        wrappedBy: writer
                    )
                }
            }
            // Already published — by an earlier attempt at this same pass, or
            // (for a ring-sourced slot) by another admin whose bytes are
            // identical by construction. It wraps the generation this slot
            // names, so it covers the recipient and the id is still claimed for
            // `promoteTeamMember` / `rotateTeamKey`.
            alreadyPublished.insert(step.envelopeId)
        }

        // PHASE 3 — write the ids nobody holds yet, in the plan's order.
        var envelopeIds: [String] = []
        for step in plan {
            if alreadyPublished.contains(step.envelopeId) {
                envelopeIds.append(step.envelopeId)
                continue
            }
            guard let keyData = keysBySlot[step.slot] else {
                throw TeamVaultKeyDistributionError.missingKeyForSlot(teamId: teamId, slot: step.slot.rawValue)
            }
            let wrapped = try CloudVaultCrypto.wrapVaultKey(keyData, recipientPublicKey: step.target.publicKeyData)
            try await envelopeCollection(teamId: teamId).document(step.envelopeId).setData([
                "teamId": teamId,
                "uid": step.recipientUid,
                "deviceId": step.target.pin.deviceId,
                "escrowKeyVersion": step.target.pin.escrowKeyVersion,
                "keySlot": step.slot.rawValue,
                "algorithm": Self.envelopeAlgorithm,
                "wrappedKeyBase64": wrapped.base64EncodedString(),
                "recipientPublicKeyFingerprint": step.target.pin.publicKeyFingerprint,
                // Pinned by the rules to `request.auth.uid`, so the
                // roster authority can tell whose wrap this is.
                "wrappedBy": uid,
                "createdAt": FieldValue.serverTimestamp()
            ], merge: false)
            envelopeIds.append(step.envelopeId)
        }
        return TeamKeyEnvelopePublication(envelopeIds: envelopeIds)
    }

    /// Does an already-published envelope carry exactly the wrap this pass was
    /// about to write? The id pins the first four; the fingerprint is the one
    /// field the id does not carry, and it is the field that decides WHICH key
    /// can open the wrap.
    private static func envelope(
        _ data: [String: Any],
        addresses recipientUid: String,
        pin: TeamEscrowDevicePin,
        slot: TeamKeySlot
    ) -> Bool {
        data["uid"] as? String == recipientUid
            && data["deviceId"] as? String == pin.deviceId
            && data["escrowKeyVersion"] as? Int == pin.escrowKeyVersion
            && data["keySlot"] as? String == slot.rawValue
            && data["recipientPublicKeyFingerprint"] as? String == pin.publicKeyFingerprint
    }

    /// The envelope document id `firestore.rules` pins:
    /// `{uid}_{deviceId}_{escrowKeyVersion}_{keySlot}`.
    static func envelopeId(uid: String, pin: TeamEscrowDevicePin, slot: TeamKeySlot) -> String {
        "\(uid)_\(pin.deviceId)_\(pin.escrowKeyVersion)_\(slot.rawValue)"
    }

    /// Read the recipient's pinned devices off the roster, then fetch and VERIFY
    /// each device's published escrow public key.
    ///
    /// Two independent checks, both required (PR 1 review F2):
    ///
    ///   1. the published `publicKeyFingerprint` equals the fingerprint the
    ///      roster pinned at accept time — so a key swapped in after the pin is
    ///      refused; and
    ///   2. that fingerprint is provably the digest OF THESE KEY BYTES
    ///      (`EscrowDeviceSafetyCode.isFingerprint(_:boundTo:)`) — so a backend
    ///      that rewrote the key bytes while keeping the fingerprint string is
    ///      refused too. Check 1 alone would be trusting the server to have
    ///      stored a self-consistent document.
    ///
    /// A failure throws. It does NOT skip the device, because a skipped device
    /// is a device that can never open this team's facts and a member that can
    /// never be promoted; the operator has to see it.
    private func resolveWrapTargets(teamId: String, recipientUid: String) async throws -> [TeamWrapTarget] {
        let memberDocument = try await memberDocument(teamId: teamId, uid: recipientUid)
        let pins = TeamEscrowDevicePin.pins(from: memberDocument ?? [:])
        guard !pins.isEmpty else {
            throw TeamVaultKeyDistributionError.memberHasNoPinnedDevice(uid: recipientUid)
        }

        var targets: [TeamWrapTarget] = []
        for pin in pins {
            let keyDocument = try await gateway
                .collection("users")
                .document(recipientUid)
                .collection("escrow_public_keys")
                .document("\(pin.deviceId)_\(pin.escrowKeyVersion)")
                .getData()
            guard let keyDocument,
                  keyDocument["deviceId"] as? String == pin.deviceId,
                  keyDocument["keyVersion"] as? Int == pin.escrowKeyVersion,
                  let publicKeyBase64 = keyDocument["publicKeyData"] as? String,
                  let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
                throw TeamVaultKeyDistributionError.escrowPublicKeyUnavailable(
                    uid: recipientUid,
                    deviceId: pin.deviceId,
                    keyVersion: pin.escrowKeyVersion
                )
            }
            guard keyDocument["publicKeyFingerprint"] as? String == pin.publicKeyFingerprint else {
                throw TeamVaultKeyDistributionError.fingerprintNotPinned(
                    uid: recipientUid,
                    deviceId: pin.deviceId
                )
            }
            guard EscrowDeviceSafetyCode.isFingerprint(pin.publicKeyFingerprint, boundTo: publicKeyBase64) else {
                throw TeamVaultKeyDistributionError.fingerprintNotBoundToKey(
                    uid: recipientUid,
                    deviceId: pin.deviceId
                )
            }
            targets.append(TeamWrapTarget(pin: pin, publicKeyData: publicKeyData))
        }
        return targets
    }

    /// The slots the ROSTER has recorded — the only ones an envelope may
    /// populate the ACTIVE ring with (B6).
    ///
    /// `activeKeyVersion` and every entry in `retainedKeyVersions` are
    /// generations `rotateTeamKey` / `promoteTeamMember` committed. The slug key
    /// is recorded by `slugKeyId`, which is the roster's publishable fingerprint
    /// of it; PR 2 seeds that field `null` (nothing writes it until PR 4 carries
    /// the bootstrap's `slugKeyId` back to the roster), so today a slug key
    /// picked up from an envelope is held pending — usable through
    /// ``requireKey(teamId:slot:)``, but not claimed as published.
    ///
    /// A MISSING or MALFORMED team document yields an EMPTY set, which is the
    /// safe direction: everything lands pending, nothing is lost, and no
    /// unrecorded generation is ever promoted on the strength of a document that
    /// says nothing.
    ///
    /// A document this client may not READ is a different outcome and the doc
    /// comment used to conflate the two (PR 2 review round 4, N4):
    /// `getData()` propagates the `permission-denied`, so
    /// ``loadKeyRingFromEnvelopes(teamId:)`` fails outright rather than
    /// continuing with an empty set. That is the same safe direction taken
    /// further — the pickup does not run at all, so nothing is promoted — and it
    /// costs nothing, because the roster read is gated by the same
    /// `isTeamMember` rule as the envelope query the next line makes.
    private func rosterRecordedSlots(teamId: String) async throws -> Set<TeamKeySlot> {
        let team = try await gateway
            .collection(Self.rosterRootCollection)
            .document(teamId)
            .getData()
        var slots: Set<TeamKeySlot> = []
        if let activeKeyVersion = team?["activeKeyVersion"] as? Int, activeKeyVersion >= 1 {
            slots.insert(.vault(version: activeKeyVersion))
        }
        for version in (team?["retainedKeyVersions"] as? [Int] ?? []) where version >= 1 {
            slots.insert(.vault(version: version))
        }
        if let slugKeyId = team?["slugKeyId"] as? String, !slugKeyId.isEmpty {
            slots.insert(.slug)
        }
        return slots
    }

    /// The fingerprints THIS device is pinned under on its own member row, by
    /// escrow key generation. An empty map means no envelope is accepted, which
    /// is the correct refusal: an unpinned device is a device the roster
    /// authority never promised anything to.
    private func ownPinnedFingerprints(teamId: String) async throws -> [Int: String] {
        let memberDocument = try await memberDocument(teamId: teamId, uid: uid)
        return TeamEscrowDevicePin.pins(from: memberDocument ?? [:])
            .filter { $0.deviceId == deviceId }
            .reduce(into: [Int: String]()) { pins, pin in
                pins[pin.escrowKeyVersion] = pin.publicKeyFingerprint
            }
    }

    /// Does this uid hold an `admin` row on this roster, in ANY status? See the
    /// N-2 note on ``loadKeyRingFromEnvelopes(teamId:)`` for why status is not
    /// part of the question.
    private func isTeamAdmin(teamId: String, uid wrapperUid: String) async throws -> Bool {
        let memberDocument = try await memberDocument(teamId: teamId, uid: wrapperUid)
        return memberDocument?["role"] as? String == "admin"
    }

    private func memberDocument(teamId: String, uid memberUid: String) async throws -> [String: Any]? {
        try await gateway
            .collection(Self.rosterRootCollection)
            .document(teamId)
            .collection("members")
            .document(memberUid)
            .getData()
    }

    private func requireKey(teamId: String, slot: TeamKeySlot) throws -> Data {
        guard let existing = try requireExistingKey(teamId: teamId, slot: slot) else {
            throw TeamVaultKeyDistributionError.missingKeyForSlot(teamId: teamId, slot: slot.rawValue)
        }
        return existing
    }

    /// Mint a generation for a slot AT MOST ONCE across every retry (PR 2 review
    /// B1). An existing active key wins; otherwise a pending one is reused
    /// verbatim; only when neither exists is a key generated, and it is
    /// persisted as pending BEFORE the caller writes anything to the network.
    ///
    /// It deliberately reports NOTHING about where the key came from. It used to
    /// return an `isPending` flag that doubled as the B4 minted-in-this-pass
    /// signal, and that flag is now gone (PR 2 review round 3, B6): "is this
    /// slot still unpromoted on THIS Mac" and "has the ROSTER recorded this
    /// generation" are different questions, and a ring populated from envelopes
    /// could answer the first one wrongly. Callers derive
    /// minted-in-this-pass from the roster state they already hold — for a
    /// rotation it is the newly minted version, always.
    private func mintKey(teamId: String, slot: TeamKeySlot) throws -> Data {
        if let existing = try requireExistingKey(teamId: teamId, slot: slot) { return existing }
        let fresh = try CloudVaultCrypto.generateVaultKey()
        try keyRing.storePending(fresh, teamId: teamId, slot: slot)
        return fresh
    }

    /// The key this device already holds for a slot, ACTIVE first: a stale
    /// pending entry must never shadow a generation the roster published.
    private func requireExistingKey(teamId: String, slot: TeamKeySlot) throws -> Data? {
        if let active = try keyRing.key(teamId: teamId, slot: slot) { return active }
        return try keyRing.pendingKey(teamId: teamId, slot: slot)
    }

    private func envelopeCollection(teamId: String) -> CloudSyncCollectionGateway {
        gateway
            .collection(Self.envelopesRootCollection)
            .document(teamId)
            .collection(Self.envelopesSubcollection)
    }
}
