import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarKernel
import os

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

    /// Promote a mint this Mac made — but ONLY if no other key has taken the
    /// slot in the meantime, and decide that INSIDE the same critical section
    /// that writes (D16 bootstrap-wiring ruling, clauses 2 and 3).
    ///
    /// ``promotePendingKey(teamId:slot:)`` answers "is there a pending key",
    /// which is the wrong question for a FOUNDING slot. A founding generation is
    /// immutable and create-only, so the slot may hold exactly one key for the
    /// life of the team; and this Mac's pending mint is not evidence that it is
    /// the one, because ``TeamVaultKeyDistributor/loadKeyRingFromEnvelopes(teamId:)``
    /// can have adopted the team's REAL key into the active half — from another
    /// Mac of this same account, whose envelopes carry this same `wrappedBy` and
    /// so sail through the B4 claim. Promoting over that adoption is the silent,
    /// permanent vault split: this Mac seals under its own mint while every
    /// published envelope and every other device hold the adopted one.
    ///
    /// ADOPTION WINS, ALWAYS. A pending mint that disagrees with an occupied
    /// active slot is DESTROYED, never promoted, and the caller is told so it
    /// can say so out loud.
    ///
    /// AND THE CHECK IS NOT SEPARABLE FROM THE WRITE. The adoption runs on the
    /// sync cycle (``TeamMemorySyncDomain``) while the Settings action runs this,
    /// against the same Keychain ring, so a check made earlier in the bootstrap
    /// — before the envelopes were published, say — can be true when it is made
    /// and false by the time the promotion happens. Conformances MUST read the
    /// active half and write it under one lock.
    func promotePendingMintUnlessAdopted(teamId: String, slot: TeamKeySlot) throws -> TeamKeyMintPromotion
}

/// What ``TeamVaultKeyRing/promotePendingMintUnlessAdopted(teamId:slot:)`` did
/// with the mint this Mac was holding.
enum TeamKeyMintPromotion: Equatable, Sendable {
    /// The active half was empty and this Mac's mint now occupies it — the
    /// ordinary first-time founding, and the resume of one.
    case promoted
    /// The active half already held these exact bytes: an earlier press of the
    /// same idempotent action already promoted them. Nothing changed.
    case alreadyActive
    /// The active half held a DIFFERENT key — one adopted from the team's
    /// published envelopes — so the local mint was destroyed. The member
    /// continues with the adopted key; re-minting is never the remedy.
    case discardedInFavourOfAdoptedKey
    /// There was no pending mint at all. Nothing to promote and nothing to
    /// discard.
    case nothingPending
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

    /// Serialises every WRITE to this ring across the whole process, so
    /// ``promotePendingMintUnlessAdopted(teamId:slot:)`` can read the active
    /// half and write it as one indivisible step.
    ///
    /// PROCESS-WIDE AND STATIC BECAUSE THE RACERS ARE DIFFERENT INSTANCES. The
    /// ring is a value type, constructed fresh at each call site: the Settings
    /// founding action builds one, `TeamMemorySyncDomain`'s cycle holds another,
    /// and it is precisely those two — a bootstrap promoting, an envelope pickup
    /// adopting — that must not interleave. A per-instance lock would guard
    /// nothing they share. The Keychain items themselves are the shared state,
    /// and this is the only writer of them in this process.
    ///
    /// READS ARE DELIBERATELY UNLOCKED. `key`/`pendingKey` answer a question
    /// that is stale the instant it returns however it is taken, so locking them
    /// would buy no guarantee and would let a slow Keychain read block the
    /// promotion that is the whole point of the lock. Every decision that
    /// depends on a read being still-true takes the lock and re-reads inside it.
    private static let writeLock = NSLock()

    private let store: CloudVaultKeyStore

    init(service: String = KeychainTeamVaultKeyRing.keychainService) {
        self.store = CloudVaultKeyStore(service: service)
    }

    func key(teamId: String, slot: TeamKeySlot) throws -> Data? {
        try store.loadKey(uid: Self.account(teamId: teamId, slot: slot))
    }

    func store(_ keyData: Data, teamId: String, slot: TeamKeySlot) throws {
        try Self.writeLock.withLock {
            try store.saveKey(keyData, uid: Self.account(teamId: teamId, slot: slot))
        }
    }

    func pendingKey(teamId: String, slot: TeamKeySlot) throws -> Data? {
        try store.loadKey(uid: Self.pendingAccount(teamId: teamId, slot: slot))
    }

    func storePending(_ keyData: Data, teamId: String, slot: TeamKeySlot) throws {
        try Self.writeLock.withLock {
            try store.saveKey(keyData, uid: Self.pendingAccount(teamId: teamId, slot: slot))
        }
    }

    func promotePendingKey(teamId: String, slot: TeamKeySlot) throws {
        try Self.writeLock.withLock {
            guard let pending = try store.loadKey(uid: Self.pendingAccount(teamId: teamId, slot: slot)) else { return }
            try store.saveKey(pending, uid: Self.account(teamId: teamId, slot: slot))
        }
    }

    func deletePendingKey(teamId: String, slot: TeamKeySlot) throws {
        try Self.writeLock.withLock {
            try store.deleteKey(uid: Self.pendingAccount(teamId: teamId, slot: slot))
        }
    }

    func promotePendingMintUnlessAdopted(teamId: String, slot: TeamKeySlot) throws -> TeamKeyMintPromotion {
        try Self.writeLock.withLock {
            let pendingAccount = Self.pendingAccount(teamId: teamId, slot: slot)
            let activeAccount = Self.account(teamId: teamId, slot: slot)
            guard let pending = try store.loadKey(uid: pendingAccount) else { return .nothingPending }
            // THE RE-READ IS THE POINT. Inside the lock, so an adoption cannot
            // land between deciding and writing.
            guard let active = try store.loadKey(uid: activeAccount) else {
                try store.saveKey(pending, uid: activeAccount)
                return .promoted
            }
            if active == pending { return .alreadyActive }
            try store.deleteKey(uid: pendingAccount)
            return .discardedInFavourOfAdoptedKey
        }
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

    /// Record the founding `teamSlugKey`'s FINGERPRINT on the roster — never the
    /// key (D16 bootstrap wiring).
    ///
    /// The B6 ruling promotes an envelope-sourced slot to the ACTIVE ring only
    /// when the roster names it, and `.slug` is named by exactly this field. It
    /// was seeded `null` by `createTeam` and written by nothing, so every
    /// joiner's slug key landed PENDING — invisible to
    /// ``TeamMemorySyncService/retainedKey(from:teamID:slot:)`` — and no member
    /// but the founder could derive a document id. This is the write the design
    /// assigned to PR 4 and PR 4 did not ship.
    ///
    /// Write-once server side: the same fingerprint again is a no-op, a
    /// different one is refused for ever. The slug key names every document this
    /// team will ever have, and a second one would address the whole space
    /// somewhere else.
    func recordTeamSlugKeyId(teamId: String, slugKeyId: String) async throws
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

    func recordTeamSlugKeyId(teamId: String, slugKeyId: String) async throws {
        _ = try await functions.httpsCallable("recordTeamSlugKeyId").call([
            "teamId": teamId,
            "slugKeyId": slugKeyId
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
    /// The roster already names a DIFFERENT founding `slugKeyId`, so another
    /// founding owns this generation and this pass published nothing (D16
    /// founding-claim ruling, clause 2).
    case foundingGenerationClaimedElsewhere(teamId: String)
    /// The postcondition that makes the founding invariant enforced rather than
    /// argued: this pass published wraps of one key for a founding slot and
    /// ended holding a different one (clause 1). Refused rather than recorded.
    case foundingGenerationForked(teamId: String, slot: String)
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
        case .foundingGenerationClaimedElsewhere(let teamId):
            return """
            Team \(teamId)'s founding keys were already claimed on the roster under a different key, so this Mac \
            published nothing and threw away the keys it had minted. One generation may carry exactly one key. \
            Finish the founding on the Mac that claimed it; this Mac receives the team's keys like any other \
            device.
            """
        case .foundingGenerationForked(let teamId, let slot):
            return """
            Team \(teamId)'s \(slot) key ring no longer holds the key this pass published wraps of, so the \
            founding was not completed and no fingerprint was recorded for it. The published envelopes and the \
            roster still name one key; run the setup again and this Mac will pick that key up.
            """
        case .malformedEnvelope(let envelopeId):
            return "Team key envelope \(envelopeId) is malformed and was not opened."
        }
    }
}

/// One resolved recipient device: the pin the roster made, plus the public key
/// bytes that pin was verified against. Only this type reaches a wrap.
struct TeamWrapTarget {
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
    ///
    /// It is a fingerprint of the key this pass CLAIMED on the roster and then
    /// published wraps of — one value, used for the claim, returned here, and
    /// checked against the ring before the pass completes (D16 founding-claim
    /// ruling). Read-back and remembered used to be able to differ; they cannot
    /// any more, because the pass refuses to finish when they do rather than
    /// choosing between them.
    let slugKeyId: String
    let envelopeIds: [String]
    /// Founding slots whose LOCAL mint was thrown away because the team's real
    /// key had already arrived from the published envelopes.
    ///
    /// Empty on every ordinary founding. When it is not empty the pass still
    /// SUCCEEDED — this Mac holds the team's key and can seal — but the member
    /// is owed the truth that the keys they made here were not the ones adopted,
    /// so the surface says so rather than letting it look like a plain success
    /// (ruling clause 4). Their next action is to continue, never to re-mint.
    ///
    /// A DISCARD REPORTED HERE IS ALWAYS OF A MINT NOTHING PUBLISHED. The
    /// discarded key was shadowed by the adopted one before the pass resolved
    /// what to publish, so no envelope carries it. A mint that WAS published and
    /// then lost its slot does not reach this field: it raises
    /// ``TeamVaultKeyDistributionError/foundingGenerationForked(teamId:slot:)``
    /// and the pass does not complete.
    let discardedLocalMintSlots: [TeamKeySlot]

    init(
        teamKeyVersion: Int,
        slugKeyId: String,
        envelopeIds: [String],
        discardedLocalMintSlots: [TeamKeySlot] = []
    ) {
        self.teamKeyVersion = teamKeyVersion
        self.slugKeyId = slugKeyId
        self.envelopeIds = envelopeIds
        self.discardedLocalMintSlots = discardedLocalMintSlots
    }
}
