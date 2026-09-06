/**
 * @fileoverview Team roster authority for BurnBar team memory (D16 / P21).
 *
 * Team memory is a blind lane: the server holds ciphertext, opaque 64-hex
 * document ids and ECIES-wrapped key envelopes, never plaintext or any team
 * key. What the server DOES own — because clients cannot be trusted to assert
 * it — is membership. `firestore.rules` denies every client write to
 * `team_rosters/**`, so the seven callables below are the only way a roster ever
 * changes, and every mutation lands an append-only `audit_log` row.
 *
 * Invariants this module exists to hold:
 *
 *  - An invite is bound to the invitee's uid at ISSUE time (resolved server
 *    side from a verified email), stored only as `sha256(token)`, single use,
 *    and expires in 7 days. Forwarding the token to someone else grants
 *    nothing.
 *  - No callable accepts a client-supplied escrow public key. Key material is
 *    read from the member's own rules-protected `users/{uid}/escrow_public_keys`
 *    namespace, so a joiner cannot substitute an attacker's recipient key —
 *    and every pinned fingerprint is READ BACK when coverage is verified, so
 *    an envelope wrapped to any other key covers nothing.
 *  - Only an active admin, or a member wrapping for their own uid, may publish
 *    a key envelope (`firestore.rules` pins `wrappedBy` to the author), and
 *    coverage counts only envelopes such an author wrapped — an admin in any
 *    status, because the rules already ruled on authorship at create time and
 *    a departed admin's pre-departure wraps must not strand a joiner.
 *    Envelopes are immutable, so an unrestricted `create` was a permanent
 *    denial-of-key.
 *  - Accepting an invite never demotes a live member row: an `active`,
 *    `pending` or `suspended` row is refused with `already-exists`, so a stale
 *    invite cannot walk around the last-admin guard.
 *  - A member is never active-but-blind: `promoteTeamMember` refuses to flip a
 *    member to `active` until a key envelope exists for every one of that
 *    member's trusted devices, for every retained team key version AND for the
 *    non-rotating slug key. That decision is re-checked, against the member row
 *    AND the team's membership epoch, inside the transaction that writes it.
 *  - "The key rotated" and "the corpus was re-keyed" are DIFFERENT facts, and
 *    the roster records both separately. `rotateTeamKey` must advance
 *    `activeKeyVersion` before a single fact is re-sealed, because
 *    `firestore.rules` pins every fact write to the roster's active generation
 *    — so `recordTeamRewrapComplete` is what an admin's client calls once a
 *    re-seal pass has finished with nothing skipped, and it refuses any
 *    generation but the current one.
 *  - `rotateTeamKey` moves strictly to the next NON-BURNED version, verifies
 *    envelope coverage for every remaining active member's devices (refusing
 *    outright if any active member has no pinned device, the founder included),
 *    appends to `retainedKeyVersions`, and commits in chunks so a large team
 *    does not hit the 500-write batch ceiling.
 *  - A generation an admin minted, published envelopes for and abandoned is
 *    stepped over rather than left to wedge the team: `abandonTeamKeyGeneration`
 *    appends it to `burnedKeyVersions`, and only for the next unclaimed version,
 *    only when it is neither active nor retained, and only when an envelope for
 *    it really exists.
 *  - A team always keeps at least one active admin, and that guard is decided
 *    inside the transaction that evicts the member — a query-then-write guard
 *    let two concurrent removals of the last two admins both see two.
 *
 * Every read-then-write decision here commits through
 * `./teamRosterState.ts`, which re-reads the team state inside the writing
 * transaction. See that module's header for what "state" means and why a
 * membership epoch is the only read a rotation can conflict-detect on.
 */

import { createHash, randomBytes, randomUUID } from "node:crypto";

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { auth, db } from "./adminRuntime.js";
import { assertActiveBurnBarCloudProEntitlement } from "./callables/shared/entitlements.js";
import { logWarn } from "./logging.js";
import {
  MAX_TEAM_MEMBER_DEVICES,
  assertTeamKeyEnvelopeCoverage,
  isEscrowPublicKeyFingerprint,
  isPinnableEscrowKeyVersion,
  readEscrowDeviceFingerprints,
  requiredTeamKeyEnvelopes,
} from "./teamKeyEnvelopes.js";
import {
  TEAM_ROSTER_SCHEMA_VERSION,
  auditEvent,
  auditRef,
  commitChunked,
  commitGuardedByTeamState,
  nextRotatableKeyVersion,
  readMembershipEpoch,
  readTeam,
} from "./teamRosterState.js";

// The key envelope lane lives in ./teamKeyEnvelopes.ts; the names its callers
// need are re-exported here so the callable surface and its tests keep one
// import site for the team roster API.
export {
  MAX_ENVELOPE_IDS,
  MAX_TEAM_MEMBER_DEVICES,
  isEscrowPublicKeyFingerprint,
  requiredTeamKeyEnvelopeIds,
} from "./teamKeyEnvelopes.js";

/**
 * The escrow-device and envelope-requirement shapes ./teamKeyEnvelopes.ts
 * produces. Both are derived rather than imported: the declarations there are
 * module-private (server-internal shapes, not cross-platform schema mirrors),
 * and deriving them here means the two ends cannot drift.
 */
type EscrowDeviceFingerprint = ReturnType<typeof readEscrowDeviceFingerprints>[number];
type EnvelopeRequirement = ReturnType<typeof requiredTeamKeyEnvelopes>[number];

/** Team ids are engine-parseable: `^team_[a-z0-9]{16}$` (memory_engine/_sync.py). */
export const TEAM_ID_PATTERN = /^team_[a-z0-9]{16}$/u;
/** Invite tokens are opaque bearer secrets; only their sha256 is ever stored. */
export const INVITE_TOKEN_PATTERN = /^inv_[A-Za-z0-9_-]{32,64}$/u;
const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
/**
 * `validCloudSealedBlob` caps `keyVersion` at 100 (firestore.rules). Refuse a
 * rotation the rules would then reject rather than stranding the roster one
 * version ahead of every writable document.
 */
export const MAX_TEAM_KEY_VERSION = 100;
/**
 * How many surviving-admin candidates the last-admin guard re-reads inside the
 * eviction transaction. The guard only needs ONE survivor, so reading the first
 * few candidates decides it; a team whose first {@link MAX_ADMIN_GUARD_READS}
 * admins all leave at once gets a refusal it can retry against the fresh
 * candidate set, which is the safe direction.
 */
const MAX_ADMIN_GUARD_READS = 20;
/** A rewrap job id is a client-minted correlation handle (a UUID today). */
export const MAX_REWRAP_JOB_ID_LENGTH = 64;

type TeamMemberRole = "admin" | "member";
type TeamMemberStatus = "pending" | "active" | "suspended" | "removed";

interface TeamMemberDocument {
  uid: string;
  teamId: string;
  role: TeamMemberRole;
  status: TeamMemberStatus;
  escrowDeviceFingerprints: EscrowDeviceFingerprint[];
  activeTeamKeyVersion: number;
  invitedBy: string;
  schemaVersion: number;
  joinedAt: Timestamp | FieldValue;
  updatedAt: Timestamp | FieldValue;
  removedAt?: Timestamp | FieldValue;
}

/**
 * Stored at `team_rosters/{teamId}/invites/{sha256(token)}`. The raw token is
 * returned to the inviting admin exactly once and never persisted; the
 * invitee's email is not persisted either — `inviteeUid` is the binding.
 */
interface TeamInviteDocument {
  teamId: string;
  tokenHash: string;
  inviteeUid: string;
  role: TeamMemberRole;
  status: "pending" | "accepted" | "revoked" | "expired";
  invitedBy: string;
  schemaVersion: number;
  createdAt: Timestamp | FieldValue;
  expiresAt: Timestamp;
}

function sha256Hex(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function newTeamId(): string {
  return `team_${randomUUID().replace(/-/gu, "").slice(0, 16)}`;
}

function newInviteToken(): string {
  return `inv_${randomBytes(24).toString("base64url")}`;
}

/** The commit shape `./teamRosterState.ts` accepts, derived so it cannot drift. */
type PendingWrite = Parameters<typeof commitChunked>[0][number];

/** A row an accept must never write over: `removed` is the one re-joinable state. */
function isLiveMemberStatus(status: unknown): boolean {
  return status === "active" || status === "pending" || status === "suspended";
}

export class TeamRosterService {
  /** Assert the caller is an ACTIVE ADMIN of `teamId`. Pending and removed members are not admins. */
  static async assertActiveAdmin(callerUid: string, teamId: string): Promise<void> {
    const memberSnap = await db.doc(`team_rosters/${teamId}/members/${callerUid}`).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "Caller is not a member of this team.");
    }
    if (memberSnap.get("status") !== "active" || memberSnap.get("role") !== "admin") {
      throw new HttpsError("permission-denied", "Caller must be an active team admin.");
    }
  }

  /**
   * Read the caller's own published escrow device keys and pin their
   * fingerprints. The keys are never taken from the callable payload: a
   * client-supplied recipient public key is a substitution primitive.
   */
  static async pinEscrowDeviceFingerprints(uid: string): Promise<EscrowDeviceFingerprint[]> {
    const [keysSnap, devicesSnap] = await Promise.all([
      db.collection(`users/${uid}/escrow_public_keys`).get(),
      db.collection(`users/${uid}/escrow_devices`).where("trustState", "==", "trusted").get(),
    ]);
    const trustedDeviceIds = new Set(devicesSnap.docs.map((deviceDoc) => deviceDoc.id));
    const fingerprints = keysSnap.docs.flatMap((keyDoc) => {
      const deviceId = keyDoc.get("deviceId");
      const keyVersion = keyDoc.get("keyVersion");
      const publicKeyFingerprint = keyDoc.get("publicKeyFingerprint");
      if (typeof deviceId !== "string") return [];
      // PR1 review N-5. `firestore.rules` requires an envelope's
      // `escrowKeyVersion` to be an int >= 1, so pinning a key published with
      // `0`, a negative or a fractional version would demand an envelope that
      // can never be written — leaving the member permanently unpromotable
      // with no attacker involved. Skip and log rather than pin something
      // unfulfillable; a member whose devices ALL fail falls through to the
      // "publish and trust at least one device" refusal below.
      if (!isPinnableEscrowKeyVersion(keyVersion)) {
        logWarn({
          event: "team_roster.escrow_key_version_unpinnable",
          uid,
          device_id: deviceId,
          key_version: typeof keyVersion === "number" ? keyVersion : null,
        });
        return [];
      }
      // BASE64, NOT HEX (memory program D16 / PR 2 defect fix). An escrow
      // device's `publicKeyFingerprint` is base64(SHA-256(x9.63 public key)) —
      // `CloudVaultDeviceKeypair.publicKeyFingerprint` produces it that way and
      // `EscrowDeviceSafetyCode.isFingerprint` base64-decodes it to verify the
      // binding. The 64-hex filter this replaces matched NO real device, so
      // every `pinEscrowDeviceFingerprints` call fell through to the "publish
      // and trust at least one device" refusal below and no join could ever
      // complete. `isEscrowPublicKeyFingerprint` is the exact shape
      // `firestore.rules` pins on `recipientPublicKeyFingerprint`.
      if (!isEscrowPublicKeyFingerprint(publicKeyFingerprint)) return [];
      if (!trustedDeviceIds.has(deviceId)) return [];
      return [{ deviceId, keyVersion, publicKeyFingerprint }];
    });
    if (fingerprints.length === 0) {
      throw new HttpsError(
        "failed-precondition",
        "Publish and trust at least one device escrow key before joining a team.",
      );
    }
    if (fingerprints.length > MAX_TEAM_MEMBER_DEVICES) {
      // Refuse rather than silently truncating: a dropped device would be a
      // device that can never open this team's documents.
      throw new HttpsError(
        "failed-precondition",
        `Retire some trusted devices before joining a team: at most ${MAX_TEAM_MEMBER_DEVICES} may hold team keys.`,
      );
    }
    return fingerprints;
  }

  /**
   * Every uid that holds the `admin` role on `teamId`, IN ANY STATUS.
   *
   * Deliberately not filtered to `status == "active"` (PR1 review N-2).
   * `firestore.rules` already decides at envelope-CREATE time that the writer
   * was an active admin or the recipient, and that write-time decision is the
   * authority; coverage verification only asks "was this wrap authorised when
   * it was made". Requiring the wrapper to be active NOW would strand a
   * pending joiner permanently whenever the admin who wrapped their envelopes
   * left before the promotion landed, because envelopes are immutable and no
   * surviving admin can re-create an id that already exists. Rotation is what
   * revokes a departed admin's key, not coverage arithmetic.
   */
  static async teamAdminUids(teamId: string): Promise<Set<string>> {
    const snapshot = await db.collection(`team_rosters/${teamId}/members`).where("role", "==", "admin").get();
    return new Set(snapshot.docs.map((memberDoc) => memberDoc.id));
  }

  static async createTeam(callerUid: string, name: string): Promise<{ teamId: string; activeKeyVersion: number }> {
    // The data-vault entitlement is checked SERVER SIDE against the entitlement
    // document; the client's claim about its own tier is never trusted.
    await assertActiveBurnBarCloudProEntitlement(callerUid);

    // The founder is pinned EXACTLY as a joiner is (PR1 review F3). Seeding an
    // empty fingerprint list made the founder permanently invisible to rotation
    // coverage: a second admin could then rotate to v(N+1) with no envelope for
    // the founder at all and leave them active-but-blind with no attacker
    // involved. Founding a team therefore requires a trusted escrow device, and
    // the founder self-wraps their own envelopes (rules allow `d.uid == auth.uid`).
    const escrowDeviceFingerprints = await this.pinEscrowDeviceFingerprints(callerUid);

    const teamId = newTeamId();
    const now = FieldValue.serverTimestamp();

    await commitChunked([
      {
        ref: db.doc(`team_rosters/${teamId}`),
        merge: false,
        data: {
          teamId,
          name,
          activeKeyVersion: 1,
          retainedKeyVersions: [1],
          // Seeded explicitly for the same reason as the epoch below: a guard
          // should never have to tell "no burned list yet" from "nothing
          // burned" on a document it is about to commit under.
          burnedKeyVersions: [],
          slugKeyId: null,
          keyRotationRequired: false,
          // Seeded explicitly so the guard never has to distinguish "no epoch
          // yet" from "epoch zero" on a document it is about to commit under.
          membershipEpoch: 0,
          // No re-seal pass has run, and a fresh team has nothing to re-seal.
          // Seeded explicitly so "never recorded" is a stored null rather than
          // an absent field a reader has to guess about.
          rewrapCompletedKeyVersion: null,
          rewrapJobId: null,
          createdBy: callerUid,
          schemaVersion: TEAM_ROSTER_SCHEMA_VERSION,
          createdAt: now,
          updatedAt: now,
        },
      },
      {
        ref: db.doc(`team_rosters/${teamId}/members/${callerUid}`),
        merge: false,
        data: {
          uid: callerUid,
          teamId,
          role: "admin",
          status: "active",
          escrowDeviceFingerprints,
          activeTeamKeyVersion: 1,
          invitedBy: callerUid,
          schemaVersion: TEAM_ROSTER_SCHEMA_VERSION,
          joinedAt: now,
          updatedAt: now,
        },
      },
      {
        ref: auditRef(teamId),
        merge: false,
        data: auditEvent({ teamId, action: "team_created", actorUid: callerUid }),
      },
    ]);

    return { teamId, activeKeyVersion: 1 };
  }

  static async inviteMember(
    callerUid: string,
    teamId: string,
    inviteeEmail: string,
    role: TeamMemberRole,
  ): Promise<{ teamId: string; inviteToken: string; expiresAtMillis: number }> {
    await this.assertActiveAdmin(callerUid, teamId);

    // Bind the invite to a uid at ISSUE time. A forwarded token is then worth
    // nothing: `acceptTeamInvite` refuses any caller but this one.
    let inviteeUid: string;
    try {
      const record = await auth.getUserByEmail(inviteeEmail);
      inviteeUid = record.uid;
    } catch {
      throw new HttpsError(
        "failed-precondition",
        "The invitee needs an OpenBurnBar account with that email address before they can be invited.",
      );
    }
    if (inviteeUid === callerUid) {
      throw new HttpsError("invalid-argument", "You are already a member of this team.");
    }

    const existingMember = await db.doc(`team_rosters/${teamId}/members/${inviteeUid}`).get();
    if (existingMember.exists && existingMember.get("status") !== "removed") {
      throw new HttpsError("already-exists", "That account is already on this team.");
    }

    const inviteToken = newInviteToken();
    const tokenHash = sha256Hex(inviteToken);
    const expiresAt = Timestamp.fromMillis(Date.now() + INVITE_TTL_MS);

    await commitChunked([
      {
        ref: db.doc(`team_rosters/${teamId}/invites/${tokenHash}`),
        merge: false,
        data: {
          teamId,
          tokenHash,
          inviteeUid,
          role,
          status: "pending",
          invitedBy: callerUid,
          schemaVersion: TEAM_ROSTER_SCHEMA_VERSION,
          createdAt: FieldValue.serverTimestamp(),
          expiresAt,
        } satisfies TeamInviteDocument,
      },
      {
        ref: auditRef(teamId),
        merge: false,
        data: auditEvent({
          teamId,
          action: "member_invited",
          actorUid: callerUid,
          targetUid: inviteeUid,
          detail: { role },
        }),
      },
    ]);

    return { teamId, inviteToken, expiresAtMillis: expiresAt.toMillis() };
  }

  static async acceptInvite(
    callerUid: string,
    emailVerified: boolean,
    teamId: string,
    inviteToken: string,
  ): Promise<{ teamId: string; role: TeamMemberRole; status: TeamMemberStatus }> {
    if (!emailVerified) {
      throw new HttpsError("permission-denied", "Verify your email address before joining a team.");
    }

    const tokenHash = sha256Hex(inviteToken);
    const inviteRef = db.doc(`team_rosters/${teamId}/invites/${tokenHash}`);
    const [inviteSnap, teamSnap] = await Promise.all([inviteRef.get(), db.doc(`team_rosters/${teamId}`).get()]);
    if (!inviteSnap.exists) {
      throw new HttpsError("permission-denied", "This invite is not valid for your account.");
    }
    if (inviteSnap.get("inviteeUid") !== callerUid) {
      throw new HttpsError("permission-denied", "This invite is not valid for your account.");
    }
    if (inviteSnap.get("status") !== "pending") {
      throw new HttpsError("failed-precondition", "This invite has already been used.");
    }
    const expiresAt = inviteSnap.get("expiresAt");
    if (!(expiresAt instanceof Timestamp) || expiresAt.toMillis() < Date.now()) {
      await inviteRef.set({ status: "expired", updatedAt: FieldValue.serverTimestamp() }, { merge: true });
      throw new HttpsError("failed-precondition", "This invite has expired.");
    }
    // ACCEPT MUST NEVER DEMOTE (PR1 review F4). `inviteMember` refuses to ISSUE
    // an invite over a live member row, but a second invite issued before the
    // first was redeemed used to overwrite that row on accept — so an active
    // admin could redeem a stale `role: "member"` invite and demote themselves
    // to `{status: "pending", role: "member"}`. When that admin was the last
    // one, the team was permanently frozen: no client may write the roster and
    // every remaining callable needs an active admin, so the last-admin guard
    // in `removeMember` was walked straight around without a removal.
    //
    // A live row is therefore untouchable here. `removed` may re-join (as
    // `pending`, and only with a fresh invite — this one is still burned below,
    // single use), which is the one case where a row already exists and a write
    // is correct.
    // Cheap pre-check so an obvious re-accept is refused before any escrow
    // read; the AUTHORITY is the identical check inside the transaction below.
    const memberRef = db.doc(`team_rosters/${teamId}/members/${callerUid}`);
    const existingMember = await memberRef.get();
    if (isLiveMemberStatus(existingMember.exists ? existingMember.get("status") : undefined)) {
      throw new HttpsError("already-exists", "You are already on this team.");
    }

    const team = readTeam(teamSnap.data(), teamId);
    const role: TeamMemberRole = inviteSnap.get("role") === "admin" ? "admin" : "member";
    const rawInvitedBy = inviteSnap.get("invitedBy");
    const invitedBy = typeof rawInvitedBy === "string" ? rawInvitedBy : "";

    const escrowDeviceFingerprints = await this.pinEscrowDeviceFingerprints(callerUid);
    const now = FieldValue.serverTimestamp();

    // ONE TRANSACTION FOR THE GUARD AND THE WRITE (PR1 review N-3). The invite
    // burn was already transactional, but the live-row guard and the member
    // write sat on either side of it, so two accepts of two DIFFERENT live
    // invites for the same uid could both clear the guard and both write the
    // row (last write won the role), and an accept could interleave with a
    // removal. Reading the member row inside the same transaction that burns
    // the invite serialises them: Firestore aborts a transaction whose read
    // set changed under it, so the loser re-runs, sees the row the winner
    // wrote, and is refused `already-exists` with its own invite unburned.
    await db.runTransaction(async (transaction) => {
      const freshInvite = await transaction.get(inviteRef);
      if (!freshInvite.exists || freshInvite.get("status") !== "pending") {
        throw new HttpsError("failed-precondition", "This invite has already been used.");
      }
      const freshMember = await transaction.get(memberRef);
      if (isLiveMemberStatus(freshMember.exists ? freshMember.get("status") : undefined)) {
        throw new HttpsError("already-exists", "You are already on this team.");
      }
      transaction.set(
        inviteRef,
        { status: "accepted", acceptedBy: callerUid, acceptedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
      transaction.set(
        memberRef,
        {
          uid: callerUid,
          teamId,
          role,
          // PENDING, not active: an admin must hand this member key envelopes
          // for every retained version first (see promoteTeamMember).
          status: "pending",
          escrowDeviceFingerprints,
          activeTeamKeyVersion: team.activeKeyVersion,
          invitedBy,
          schemaVersion: TEAM_ROSTER_SCHEMA_VERSION,
          joinedAt: now,
          updatedAt: now,
          removedAt: FieldValue.delete(),
        } satisfies TeamMemberDocument,
        // MERGE, never overwrite: the only row that can exist here is a
        // `removed` one, and merging with an explicit `removedAt` delete leaves
        // no stale eviction stamp behind.
        { merge: true },
      );
      transaction.set(
        auditRef(teamId),
        auditEvent({
          teamId,
          action: "invite_accepted",
          actorUid: callerUid,
          targetUid: callerUid,
          detail: { role, deviceCount: escrowDeviceFingerprints.length },
        }),
      );
    });

    return { teamId, role, status: "pending" };
  }

  static async promoteMember(
    callerUid: string,
    teamId: string,
    targetUid: string,
    envelopeIds: Set<string>,
  ): Promise<{ teamId: string; targetUid: string; status: TeamMemberStatus }> {
    await this.assertActiveAdmin(callerUid, teamId);

    const memberRef = db.doc(`team_rosters/${teamId}/members/${targetUid}`);
    const [memberSnap, teamSnap] = await Promise.all([memberRef.get(), db.doc(`team_rosters/${teamId}`).get()]);
    if (!memberSnap.exists) {
      throw new HttpsError("not-found", "That account has not accepted an invite to this team.");
    }
    if (memberSnap.get("status") !== "pending") {
      // DOWNSTREAM READER: `TeamJoinerKeyIssueFailure.classify`
      // (AgentLens/Services/CloudSync/TeamRosterDirectory.swift) matches the
      // fragment "pending member can be promoted" to tell this refusal apart
      // from the escrow-device one below — they share a status code and differ
      // only in wording. Rewording either message downgrades the admin's copy to
      // the generic "nothing was shared" notice; changing the CODE is fine.
      // The permanent fix is a structured `details.reason` on both, mirrored in
      // `TeamRosterPromotionRefusal`.
      throw new HttpsError("failed-precondition", "Only a pending member can be promoted.");
    }
    const team = readTeam(teamSnap.data(), teamId);
    const devices = readEscrowDeviceFingerprints(memberSnap.get("escrowDeviceFingerprints"));
    if (devices.length === 0) {
      // DOWNSTREAM READER: the same `classify`, matching "escrow device". See
      // the note on the refusal above.
      throw new HttpsError("failed-precondition", "That member has no trusted escrow device to receive team keys.");
    }

    const requirements = requiredTeamKeyEnvelopes({
      uid: targetUid,
      devices,
      keyVersions: team.retainedKeyVersions,
      includeSlugKey: true,
    });
    await assertTeamKeyEnvelopeCoverage(teamId, requirements, envelopeIds, await this.teamAdminUids(teamId));

    const now = FieldValue.serverTimestamp();
    // Three things decided this promotion, and all three are re-checked inside
    // the transaction that writes it:
    //   - the team's KEY state, which the requirement set was computed from (N-4);
    //   - the MEMBER ROW, which must still be `pending` (Cursor round,
    //     `teamRoster.ts:674`). Without it, a `removeMember` merge of
    //     `status: "removed"` landing in the coverage window was invisible here
    //     and the blind `{status: "active"}` merge below resurrected a member
    //     the admin had just evicted — a re-join with no live invite, which is
    //     exactly the boundary `acceptInvite`'s single-use burn exists to hold;
    //   - the MEMBERSHIP EPOCH, bumped below, which is what lets a concurrent
    //     rotation notice that its active-member snapshot went stale.
    await commitGuardedByTeamState({
      teamId,
      expected: team,
      stillPendingMemberRef: memberRef,
      bumpMembershipEpoch: true,
      writes: [
        {
          ref: memberRef,
          merge: true,
          data: { status: "active", activeTeamKeyVersion: team.activeKeyVersion, updatedAt: now },
        },
        {
          ref: auditRef(teamId),
          merge: false,
          data: auditEvent({
            teamId,
            action: "member_promoted",
            actorUid: callerUid,
            targetUid,
            detail: { envelopeCount: requirements.length, retainedKeyVersions: team.retainedKeyVersions },
          }),
        },
      ],
    });

    return { teamId, targetUid, status: "active" };
  }

  static async removeMember(
    callerUid: string,
    teamId: string,
    targetUid: string,
  ): Promise<{ teamId: string; targetUid: string; keyRotationRequired: boolean }> {
    if (callerUid !== targetUid) {
      await this.assertActiveAdmin(callerUid, teamId);
    }

    const memberRef = db.doc(`team_rosters/${teamId}/members/${targetUid}`);
    const teamRef = db.doc(`team_rosters/${teamId}`);
    const memberSnap = await memberRef.get();
    if (!memberSnap.exists || memberSnap.get("status") === "removed") {
      throw new HttpsError("not-found", "Member not found in team.");
    }
    // Candidate survivors, read here and RE-READ inside the transaction below.
    const activeAdmins = await db
      .collection(`team_rosters/${teamId}/members`)
      .where("status", "==", "active")
      .where("role", "==", "admin")
      .get();
    const survivorRefs = activeAdmins.docs
      .filter((adminDoc) => adminDoc.id !== targetUid)
      .slice(0, MAX_ADMIN_GUARD_READS)
      .map((adminDoc) => adminDoc.ref);

    const now = FieldValue.serverTimestamp();
    // THE LAST-ADMIN GUARD DECIDES INSIDE THE EVICTION TRANSACTION (Cursor
    // round, `teamRoster.ts:705`). As a query-then-write it was a count both
    // halves of a race could satisfy: the last two active admins leaving at the
    // same moment each observed the other and each committed `removed`, and the
    // team was then frozen for ever — clients may not write `team_rosters/**`
    // and every remaining callable needs an active admin, so nobody could
    // invite, promote, remove, or rotate away the departed admins' wraps. Both
    // the target row and the surviving-admin candidates are re-read here, so
    // the loser of that race sees the winner's eviction and is refused; the
    // team-document write makes the two transactions contend on one document
    // as well.
    await db.runTransaction(async (transaction) => {
      const [freshMember, freshTeam] = await Promise.all([transaction.get(memberRef), transaction.get(teamRef)]);
      if (!freshMember.exists || freshMember.get("status") === "removed") {
        throw new HttpsError("not-found", "Member not found in team.");
      }
      const evictsAnActiveAdmin = freshMember.get("role") === "admin" && freshMember.get("status") === "active";
      if (evictsAnActiveAdmin) {
        const survivors = await Promise.all(survivorRefs.map((ref) => transaction.get(ref)));
        const stillActive = survivors.filter((snap) => snap.get("status") === "active" && snap.get("role") === "admin");
        if (stillActive.length === 0) {
          throw new HttpsError("failed-precondition", "A team must keep at least one active admin.");
        }
      }
      transaction.set(memberRef, { status: "removed", removedAt: now, updatedAt: now }, { merge: true });
      // The rules cut the ex-member off on the NEXT read or write; the flag
      // tells a remaining admin client that the shared key must now rotate.
      // The epoch bump is what makes a rotation racing this removal abort
      // rather than publish a new generation and clear the flag we just set.
      // NOT via `readTeam`: that refuses a team document with malformed key
      // state, and a team nobody can leave is the freeze this guard prevents.
      const membershipEpoch = readMembershipEpoch(freshTeam.data()) + 1;
      transaction.set(teamRef, { keyRotationRequired: true, membershipEpoch, updatedAt: now }, { merge: true });
      transaction.set(
        auditRef(teamId),
        auditEvent({
          teamId,
          action: "member_removed",
          actorUid: callerUid,
          targetUid,
          detail: { selfLeave: callerUid === targetUid },
        }),
      );
    });

    return { teamId, targetUid, keyRotationRequired: true };
  }

  /**
   * Burn a key generation an admin minted, published envelopes for, and
   * abandoned — the only way a team gets past one.
   *
   * THE DEADLOCK THIS EXISTS TO BREAK. Admin A mints `v(N+1)`, publishes some of
   * its envelopes and never reaches {@link rotateTeamKey}. The roster still
   * records `N`; `K_A` exists only in A's Keychain; `v(N+1)`'s envelope ids are
   * occupied and, because `firestore.rules` says `allow update, delete: if false`
   * on an envelope, unrepairable. The strict-sequence rule then allows exactly
   * one version to be minted — `N+1` — and that is the one no other admin can
   * complete, because nothing publishable says which key a wrap carries. The
   * team cannot rotate at all, so it cannot revoke a departed member either.
   *
   * Burning `N+1` moves {@link nextRotatableKeyVersion} past it and the team
   * rotates to `N+2` instead, leaving the abandoned envelopes in place —
   * harmless, because the rules pin every fact write to the roster's ACTIVE key
   * version, so no document can ever name a generation this authority did not
   * record.
   *
   * THREE PRECONDITIONS, so this is not a way to skip version numbers at will:
   *
   *  - `version` must be exactly the next non-burned version. An admin cannot
   *    reach forward and burn a generation nobody has tried to mint.
   *  - `version` must not be the active one, nor in `retainedKeyVersions`. A
   *    version the team actually published is never abandoned; the check is
   *    reachable rather than decorative, because a malformed team document can
   *    carry a retained version ahead of `activeKeyVersion`.
   *  - at least one envelope for `v{version}` must exist. That is what makes it
   *    a real abandoned rotation rather than a hole punched in the sequence.
   *
   * The append commits through {@link commitGuardedByTeamState}, so a promotion,
   * a removal or a concurrent rotation landing in the window aborts it. Every
   * call that BURNS lands an `audit_log` row naming the actor and the version.
   *
   * IDEMPOTENT FOR A VERSION ALREADY BURNED (PR 2 review round 4, B8). The
   * client's recovery is two calls — burn, then rotate — and the retry after a
   * failed rotation re-presents the SAME version. Reporting that as
   * `invalid-argument` ("only the next unclaimed version can be abandoned")
   * would be true of the sequence rule and useless to the caller, whose burn has
   * in fact already landed; worse, it is indistinguishable from an admin
   * reaching forward. So an already-burned version returns the roster's current
   * state, writes nothing and logs no audit row, and the client goes straight to
   * the rotation. Admin-only still applies: the check above this line runs
   * first.
   */
  static async abandonKeyGeneration(
    callerUid: string,
    teamId: string,
    version: number,
  ): Promise<{ teamId: string; activeKeyVersion: number; burnedKeyVersions: number[] }> {
    await this.assertActiveAdmin(callerUid, teamId);

    const teamRef = db.doc(`team_rosters/${teamId}`);
    const team = readTeam((await teamRef.get()).data(), teamId);
    if (team.activeKeyVersion === version || team.retainedKeyVersions.includes(version)) {
      throw new HttpsError("failed-precondition", `Key version ${version} is recorded by this team and is not abandoned.`);
    }
    if (team.burnedKeyVersions.includes(version)) {
      return { teamId, activeKeyVersion: team.activeKeyVersion, burnedKeyVersions: team.burnedKeyVersions };
    }
    const expectedVersion = nextRotatableKeyVersion(team);
    if (version !== expectedVersion) {
      throw new HttpsError(
        "invalid-argument",
        `Only the next unclaimed key version (${expectedVersion}) can be abandoned, got ${version}.`,
      );
    }
    const published = await db
      .collection(`team_key_envelopes/${teamId}/envelopes`)
      .where("keySlot", "==", `v${version}`)
      .limit(1)
      .get();
    if (published.empty) {
      throw new HttpsError(
        "failed-precondition",
        `No key envelope was ever published for version ${version}, so there is no abandoned rotation to burn.`,
      );
    }

    const burnedKeyVersions = [...new Set([...team.burnedKeyVersions, version])].sort((a, b) => a - b);
    const now = FieldValue.serverTimestamp();
    await commitGuardedByTeamState({
      teamId,
      expected: team,
      writes: [
        { ref: teamRef, merge: true, data: { burnedKeyVersions, updatedAt: now } },
        {
          ref: auditRef(teamId),
          merge: false,
          data: auditEvent({
            teamId,
            action: "key_generation_abandoned",
            actorUid: callerUid,
            detail: { version, abandonedEnvelopeId: published.docs[0]?.id ?? null },
          }),
        },
      ],
    });

    return { teamId, activeKeyVersion: team.activeKeyVersion, burnedKeyVersions };
  }

  static async rotateTeamKey(
    callerUid: string,
    teamId: string,
    newKeyVersion: number,
    envelopeIds: Set<string>,
  ): Promise<{ teamId: string; activeKeyVersion: number; retainedKeyVersions: number[] }> {
    await this.assertActiveAdmin(callerUid, teamId);

    const teamRef = db.doc(`team_rosters/${teamId}`);
    const teamSnap = await teamRef.get();
    const team = readTeam(teamSnap.data(), teamId);
    // STRICTLY THE NEXT NON-BURNED VERSION. Still one generation at a time —
    // `burnedKeyVersions` only ever grows through `abandonKeyGeneration`, which
    // proves the version it burns was really claimed by an abandoned rotation.
    const expectedKeyVersion = nextRotatableKeyVersion(team);
    if (newKeyVersion !== expectedKeyVersion) {
      throw new HttpsError(
        "invalid-argument",
        `Expected newKeyVersion to be ${expectedKeyVersion}, got ${newKeyVersion}.`,
      );
    }
    if (newKeyVersion > MAX_TEAM_KEY_VERSION) {
      throw new HttpsError("failed-precondition", "This team has exhausted its supported key versions.");
    }

    const activeMembers = await db.collection(`team_rosters/${teamId}/members`).where("status", "==", "active").get();
    // Admins in ANY status may have wrapped these envelopes (PR1 review N-2),
    // so the wrapper set is queried rather than filtered out of the active
    // roster scan below.
    const authorizedWrapperUids = await this.teamAdminUids(teamId);
    const requirements: EnvelopeRequirement[] = [];
    for (const memberDoc of activeMembers.docs) {
      const devices = readEscrowDeviceFingerprints(memberDoc.get("escrowDeviceFingerprints"));
      // NO SILENT SKIPPING (PR1 review F3). A member with no pinned device used
      // to contribute zero requirements, so a rotation "covered" them by
      // covering nothing and left them active-but-blind. Every active member —
      // the founder included, who is now pinned at createTeam — must have at
      // least one pinned device or the rotation is refused outright.
      if (devices.length === 0) {
        throw new HttpsError(
          "failed-precondition",
          `Active member ${memberDoc.id} has no pinned escrow device, so this rotation cannot cover them.`,
        );
      }
      requirements.push(
        ...requiredTeamKeyEnvelopes({
          uid: memberDoc.id,
          devices,
          keyVersions: [newKeyVersion],
          includeSlugKey: false,
        }),
      );
    }
    await assertTeamKeyEnvelopeCoverage(teamId, requirements, envelopeIds, authorizedWrapperUids);

    const now = FieldValue.serverTimestamp();
    const retainedKeyVersions = [...new Set([...team.retainedKeyVersions, newKeyVersion])].sort((a, b) => a - b);
    const writes: PendingWrite[] = activeMembers.docs.map((memberDoc) => ({
      ref: memberDoc.ref,
      merge: true,
      data: { activeTeamKeyVersion: newKeyVersion, updatedAt: now },
    }));
    // NOT ATOMIC ACROSS THE TWO COMMITS, deliberately (PR1 review F5). Member
    // rows are chunked so a team larger than the 500-write batch ceiling still
    // rotates, and the team document is committed last. If a middle chunk
    // fails, some member rows carry `activeTeamKeyVersion: N+1` while the team
    // document still says `N`. That is safe and recoverable, not a partial
    // rotation: `firestore.rules` reads `activeKeyVersion` from the TEAM
    // DOCUMENT alone, so writes stay pinned to `N`; `keyRotationRequired` stays
    // `true`, which is the operator signal; and a retry is idempotent because
    // the team document is unchanged, so `newKeyVersion === activeKeyVersion + 1`
    // still validates and the member rows merge to the same values.
    // `test_rotate_retry_converges_after_a_failed_middle_batch` proves it.
    await commitChunked(writes);
    // The team document is written inside a transaction that re-reads it, so a
    // rotation racing another rotation loses instead of overwriting the winner's
    // key state (N-4). The member-row chunks above stay outside it, unchanged:
    // that ordering is the F5 recovery contract, and a loser's rows carry the
    // same `activeTeamKeyVersion` the winner just published anyway.
    //
    // `team.membershipEpoch` is the half that covers MEMBERSHIP (Cursor round,
    // `teamRoster.ts:747`). The requirement set above came from a QUERY, and
    // Firestore cannot conflict-detect a query: a `promoteTeamMember` landing
    // between the scan and this commit added an active member without touching
    // `activeKeyVersion` or `retainedKeyVersions`, so both N-4 guards passed
    // and the rotation published v(N+1) with no wrap for the new member — live
    // on the roster, blind to the current generation, which is precisely the F3
    // invariant. Promotion and removal both bump the epoch, so this commit now
    // aborts and the retry covers the roster as it actually stands.
    await commitGuardedByTeamState({
      teamId,
      expected: team,
      writes: [
        {
          ref: teamRef,
          merge: true,
          data: { activeKeyVersion: newKeyVersion, retainedKeyVersions, keyRotationRequired: false, updatedAt: now },
        },
        {
          ref: auditRef(teamId),
          merge: false,
          data: auditEvent({
            teamId,
            action: "key_rotated",
            actorUid: callerUid,
            detail: { newKeyVersion, envelopeCount: requirements.length, memberCount: activeMembers.size },
          }),
        },
      ],
    });

    return { teamId, activeKeyVersion: newKeyVersion, retainedKeyVersions };
  }

  /**
   * Record that a re-seal pass finished with NOTHING skipped, at
   * `keyVersion` (memory program D16 / P22, PR 4 — promoting PR 2 review N1
   * from a local `UserDefaults` note).
   *
   * WHY THIS IS NOT PART OF `rotateTeamKey`. `rotateTeamKey` has to advance
   * `activeKeyVersion` and clear `keyRotationRequired` BEFORE any fact is
   * re-sealed, because `firestore.rules` pins every fact write to the roster's
   * active generation. So the roster alone cannot tell "re-keyed" from "the
   * rotation callable ran and the pass then died on document four": both look
   * identical. Folding the marker into the rotation would stamp "re-keyed" on a
   * corpus nothing had touched — the precise claim N1 exists to stop the roster
   * making. It is a separate call, made after the pass, by the admin who ran it.
   *
   * WHY IT REFUSES ANY GENERATION BUT THE CURRENT ONE. A completion for a
   * SUPERSEDED generation is meaningless (that corpus has since moved), and a
   * completion for a FUTURE one is a claim about work the rules would not have
   * allowed yet. Both are refused rather than stored and reasoned about later.
   *
   * The write goes through {@link commitGuardedByTeamState}, so a rotation
   * landing between the read and the write makes this `aborted` instead of
   * stamping a completion against a generation that is no longer current.
   *
   * GUARDED ON MEMBERSHIP TOO, not only on key state (PR 4 review L8, closed by
   * PR 2's C-4 round). `commitGuardedByTeamState` re-reads `membershipEpoch`
   * along with the key state, and this call passes the whole team document as
   * its expectation — so a promotion landing mid-pass aborts the completion
   * rather than recording "re-keyed" for an active set the pass never wrapped
   * for. It does NOT bump the epoch: recording a completion changes no
   * membership.
   */
  static async recordRewrapComplete(
    callerUid: string,
    teamId: string,
    keyVersion: number,
    rewrapJobId: string,
  ): Promise<{ teamId: string; rewrapCompletedKeyVersion: number }> {
    await this.assertActiveAdmin(callerUid, teamId);

    const teamRef = db.doc(`team_rosters/${teamId}`);
    const team = readTeam((await teamRef.get()).data(), teamId);
    if (keyVersion !== team.activeKeyVersion) {
      throw new HttpsError(
        "failed-precondition",
        `This team is on key version ${team.activeKeyVersion}; a completion for ${keyVersion} says nothing about it.`,
      );
    }

    const now = FieldValue.serverTimestamp();
    await commitGuardedByTeamState({
      teamId,
      expected: team,
      writes: [
        {
          ref: teamRef,
          merge: true,
          data: { rewrapCompletedKeyVersion: keyVersion, rewrapJobId, updatedAt: now },
        },
        {
          ref: auditRef(teamId),
          merge: false,
          data: auditEvent({
            teamId,
            action: "rewrap_recorded",
            actorUid: callerUid,
            detail: { keyVersion, rewrapJobId },
          }),
        },
      ],
    });

    return { teamId, rewrapCompletedKeyVersion: keyVersion };
  }
}
