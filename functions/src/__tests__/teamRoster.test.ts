/**
 * Team roster authority tests (D16 / P21 — PR 1).
 *
 * The roster is the ONLY thing the server owns in the team memory lane, so
 * these tests are about authority, not storage: an invite that a third party
 * cannot redeem, an invite that burns on first use, an expiry that is actually
 * enforced, a non-admin who cannot mutate the roster, a rotation that refuses
 * to skip a generation, a rotation that survives a team larger than the 500
 * write batch ceiling, and a promotion that refuses to make a member "active"
 * before that member can decrypt every retained key generation.
 *
 * The final block is the PR 1 security review's fix round: envelope binding,
 * founder coverage, invite re-accept, and the chunked-rotation retry contract.
 * The in-memory Firestore double lives in ./teamRosterHarness.ts.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { assertActiveBurnBarCloudProEntitlement } from "../callables/shared/entitlements.js";
import {
  MAX_TEAM_MEMBER_DEVICES,
  TeamRosterService,
  isEscrowPublicKeyFingerprint,
  requiredTeamKeyEnvelopeIds,
} from "../teamRoster.js";
import {
  ADMIN_UID,
  DEVICE,
  MEMBER_UID,
  OUTSIDER_UID,
  TEAM_ID,
  auditActions,
  caught,
  escrowFingerprint,
  inviteDocs,
  rosterHarness,
  seed,
  seedEnvelope,
  seedInvite,
  seedMember,
  seedTeam,
  seedTrustedDevice,
  storedDoc,
} from "./teamRosterHarness.js";

// The mock factory runs during THIS file's import phase, before its top-level
// statements, so the double is reached through an async import of the module
// that owns it rather than through a binding this file has not initialised yet.
vi.mock("../adminRuntime.js", async () => {
  const { rosterHarness } = await import("./teamRosterHarness.js");
  return { db: rosterHarness.db, auth: rosterHarness.auth };
});
vi.mock("../callables/shared/entitlements.js", () => ({
  assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined),
}));
vi.mock("../callables/publicRateLimit.js", () => ({
  checkTeamRosterMutationRateLimit: vi.fn(async () => undefined),
  checkTeamInviteRateLimit: vi.fn(async () => undefined),
  checkTeamInviteAcceptRateLimit: vi.fn(async () => undefined),
}));

beforeEach(() => {
  rosterHarness.store.clear();
  rosterHarness.users.clear();
  rosterHarness.stats.batches = 0;
  rosterHarness.stats.maxBatchSize = 0;
  rosterHarness.stats.failCommitAtBatch.clear();
  rosterHarness.stats.writesByPath.clear();
  rosterHarness.stats.transactions = 0;
  rosterHarness.stats.onTransaction = null;
  vi.mocked(assertActiveBurnBarCloudProEntitlement).mockClear();
});

describe("team roster authority", () => {
  it("test_an_invite_is_bound_to_the_invitee_uid", async () => {
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin" });
    rosterHarness.users.set("member@example.test", { uid: MEMBER_UID });
    seedTrustedDevice(MEMBER_UID);

    const { inviteToken } = await TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, "member@example.test", "member");

    // The token is a bearer secret, but the invite is bound to a uid at ISSUE
    // time — so forwarding it to anyone else is worth exactly nothing.
    const [[invitePath, invite]] = inviteDocs();
    expect(invite.inviteeUid).toBe(MEMBER_UID);
    expect(invite.tokenHash).toBe(invitePath.split("/").pop());
    // The raw token is returned once and never stored.
    expect(JSON.stringify(invite)).not.toContain(inviteToken);

    const forwarded = await caught(() => TeamRosterService.acceptInvite(OUTSIDER_UID, true, TEAM_ID, inviteToken));
    expect(forwarded.code).toBe("permission-denied");
    expect(rosterHarness.store.has(`team_rosters/${TEAM_ID}/members/${OUTSIDER_UID}`)).toBe(false);

    // An unverified email is refused even for the bound invitee.
    const unverified = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, false, TEAM_ID, inviteToken));
    expect(unverified.code).toBe("permission-denied");

    const accepted = await TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken);
    // A joiner lands PENDING: an admin must hand over key envelopes first.
    expect(accepted.status).toBe("pending");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({
      status: "pending",
      role: "member",
      escrowDeviceFingerprints: [DEVICE],
    });
    expect(auditActions()).toEqual(["member_invited", "invite_accepted"]);
  });

  it("test_an_invite_is_single_use", async () => {
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin" });
    rosterHarness.users.set("member@example.test", { uid: MEMBER_UID });
    seedTrustedDevice(MEMBER_UID);

    const { inviteToken } = await TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, "member@example.test", "member");
    await TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken);

    const replayed = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken));
    expect(replayed.code).toBe("failed-precondition");
    const [[, invite]] = inviteDocs();
    expect(invite.status).toBe("accepted");
  });

  it("test_an_expired_invite_is_refused", async () => {
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin" });
    rosterHarness.users.set("member@example.test", { uid: MEMBER_UID });
    seedTrustedDevice(MEMBER_UID);

    const { inviteToken, expiresAtMillis } = await TeamRosterService.inviteMember(
      ADMIN_UID,
      TEAM_ID,
      "member@example.test",
      "member",
    );
    // 7 days, per the design; assert the window rather than trusting the constant.
    expect(expiresAtMillis - Date.now()).toBeGreaterThan(6.9 * 24 * 60 * 60 * 1000);
    expect(expiresAtMillis - Date.now()).toBeLessThanOrEqual(7 * 24 * 60 * 60 * 1000);

    const [[invitePath, invite]] = inviteDocs();
    rosterHarness.store.set(invitePath, { ...invite, expiresAt: Timestamp.fromMillis(Date.now() - 1000) });

    const expired = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken));
    expect(expired.code).toBe("failed-precondition");
    expect(rosterHarness.store.get(invitePath)).toMatchObject({ status: "expired" });
    expect(rosterHarness.store.has(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toBe(false);
  });

  it("test_a_non_admin_cannot_invite_or_remove", async () => {
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin" });
    seedMember(MEMBER_UID);
    seedMember("roster-pending-admin", { role: "admin", status: "pending" });
    seedMember("roster-removed-admin", { role: "admin", status: "removed" });
    rosterHarness.users.set("target@example.test", { uid: OUTSIDER_UID });

    for (const uid of [MEMBER_UID, OUTSIDER_UID, "roster-pending-admin", "roster-removed-admin"]) {
      const invite = await caught(() => TeamRosterService.inviteMember(uid, TEAM_ID, "target@example.test", "member"));
      expect(invite.code, `${uid} must not be able to invite`).toBe("permission-denied");
      const remove = await caught(() => TeamRosterService.removeMember(uid, TEAM_ID, ADMIN_UID));
      expect(remove.code, `${uid} must not be able to remove`).toBe("permission-denied");
      const promote = await caught(() => TeamRosterService.promoteMember(uid, TEAM_ID, MEMBER_UID, new Set()));
      expect(promote.code, `${uid} must not be able to promote`).toBe("permission-denied");
      const rotate = await caught(() => TeamRosterService.rotateTeamKey(uid, TEAM_ID, 2, new Set()));
      expect(rotate.code, `${uid} must not be able to rotate`).toBe("permission-denied");
    }
    expect(inviteDocs()).toEqual([]);

    // Self-leave is the one roster mutation a plain member may perform.
    const left = await TeamRosterService.removeMember(MEMBER_UID, TEAM_ID, MEMBER_UID);
    expect(left.keyRotationRequired).toBe(true);
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({ status: "removed" });
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}`)).toMatchObject({ keyRotationRequired: true });

    // ...and the last active admin cannot strand the team.
    const lastAdmin = await caught(() => TeamRosterService.removeMember(ADMIN_UID, TEAM_ID, ADMIN_UID));
    expect(lastAdmin.code).toBe("failed-precondition");
  });

  it("test_rotate_rejects_a_non_sequential_key_version", async () => {
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });

    for (const version of [1, 3, 4, 100]) {
      const error = await caught(() => TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, version, new Set()));
      expect(error.code, `v${version} must not be accepted from v1`).toBe("invalid-argument");
    }
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}`)).toMatchObject({ activeKeyVersion: 1 });

    // v2 is the only legal successor, and retained versions are append-only so
    // a joiner can still open everything sealed under v1. The rotating admin
    // is covered like everybody else — including for their own devices.
    const adminEnvelopes = new Set([seedEnvelope(ADMIN_UID, 2)]);
    const rotated = await TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, adminEnvelopes);
    expect(rotated.activeKeyVersion).toBe(2);
    expect(rotated.retainedKeyVersions).toEqual([1, 2]);
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}`)).toMatchObject({
      activeKeyVersion: 2,
      retainedKeyVersions: [1, 2],
      keyRotationRequired: false,
    });
    expect(auditActions()).toEqual(["key_rotated"]);
  });

  it("test_rotate_batches_beyond_five_hundred_writes", async () => {
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin" });
    seedTrustedDevice(ADMIN_UID);
    seed(`team_rosters/${TEAM_ID}/members/${ADMIN_UID}`, {
      ...storedDoc(`team_rosters/${TEAM_ID}/members/${ADMIN_UID}`),
      escrowDeviceFingerprints: [DEVICE],
    });

    const envelopeIds = new Set<string>([seedEnvelope(ADMIN_UID, 2)]);
    const memberCount = 900;
    for (let index = 0; index < memberCount; index += 1) {
      const uid = `bulk-member-${index}`;
      seedMember(uid, { escrowDeviceFingerprints: [DEVICE] });
      envelopeIds.add(seedEnvelope(uid, 2));
    }

    rosterHarness.stats.batches = 0;
    rosterHarness.stats.maxBatchSize = 0;
    const rotated = await TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, envelopeIds);

    expect(rotated.activeKeyVersion).toBe(2);
    // 901 member writes cannot ride one batch: Firestore stops at 500. They
    // land in ceil(901 / 400) = 3 chunks; the team document and its audit row
    // are NOT among them — since N-4 they commit in a transaction that
    // re-reads the team's key state, which is why this count is exactly 3.
    expect(rosterHarness.stats.maxBatchSize).toBeLessThanOrEqual(400);
    expect(rosterHarness.stats.batches).toBe(3);
    expect(rosterHarness.stats.transactions).toBe(1);
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/bulk-member-899`)).toMatchObject({
      activeTeamKeyVersion: 2,
    });
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/bulk-member-0`)).toMatchObject({
      activeTeamKeyVersion: 2,
    });
  });

  it("test_promote_refuses_without_envelope_coverage_for_every_retained_version", async () => {
    // A team that has already rotated twice: a joiner needs v1, v2, v3 AND the
    // non-rotating slug key before it can read anything at all.
    seedTeam({ activeKeyVersion: 3, retainedKeyVersions: [1, 2, 3] });
    seedMember(ADMIN_UID, { role: "admin", activeTeamKeyVersion: 3 });
    seedMember(MEMBER_UID, { status: "pending", escrowDeviceFingerprints: [DEVICE] });

    const required = requiredTeamKeyEnvelopeIds({
      uid: MEMBER_UID,
      devices: [DEVICE],
      keyVersions: [1, 2, 3],
      includeSlugKey: true,
    });
    expect(required).toHaveLength(4);

    // Claiming the ids without publishing them is refused...
    for (const id of required) seedEnvelope(MEMBER_UID, id.endsWith("_slug") ? "slug" : Number(id.slice(-1)));
    const partial = new Set(required.slice(0, 3));
    const missing = await caught(() => TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, partial));
    expect(missing.code).toBe("failed-precondition");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({ status: "pending" });

    // ...and so is an envelope that exists but is addressed to someone else.
    rosterHarness.store.set(`team_key_envelopes/${TEAM_ID}/envelopes/${required[0]}`, {
      teamId: TEAM_ID,
      uid: OUTSIDER_UID,
    });
    const misaddressed = await caught(() =>
      TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(required)),
    );
    expect(misaddressed.code).toBe("failed-precondition");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({ status: "pending" });

    // Full coverage promotes, and pins the member to the live key generation.
    seedEnvelope(MEMBER_UID, 1);
    const promoted = await TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(required));
    expect(promoted.status).toBe("active");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({
      status: "active",
      activeTeamKeyVersion: 3,
    });
  });

  it("test_create_team_checks_the_data_vault_entitlement_server_side", async () => {
    // Founding a team requires a trusted escrow device, exactly as joining one
    // does: the founder's fingerprints are pinned here so rotation coverage can
    // see them (F3). Without one, the team cannot be created at all.
    const unenrolled = await caught(() => TeamRosterService.createTeam(ADMIN_UID, "Core Platform"));
    expect(unenrolled.code).toBe("failed-precondition");

    seedTrustedDevice(ADMIN_UID);
    const { teamId, activeKeyVersion } = await TeamRosterService.createTeam(ADMIN_UID, "Core Platform");

    expect(assertActiveBurnBarCloudProEntitlement).toHaveBeenCalledWith(ADMIN_UID);
    // The engine parses team ids out of sealed payloads; keep the shape it expects.
    expect(teamId).toMatch(/^team_[a-z0-9]{16}$/u);
    expect(activeKeyVersion).toBe(1);
    expect(rosterHarness.store.get(`team_rosters/${teamId}`)).toMatchObject({
      activeKeyVersion: 1,
      retainedKeyVersions: [1],
      createdBy: ADMIN_UID,
    });
    expect(rosterHarness.store.get(`team_rosters/${teamId}/members/${ADMIN_UID}`)).toMatchObject({
      role: "admin",
      status: "active",
      // NOT an empty list: an unpinned founder is invisible to rotation
      // coverage and can be rotated into blindness by a second admin.
      escrowDeviceFingerprints: [DEVICE],
    });

    vi.mocked(assertActiveBurnBarCloudProEntitlement).mockRejectedValueOnce(
      new HttpsError("permission-denied", "no entitlement"),
    );
    const denied = await caught(() => TeamRosterService.createTeam(OUTSIDER_UID, "Second Team"));
    expect(denied.code).toBe("permission-denied");
  });

  it("test_no_callable_accepts_a_client_supplied_escrow_public_key", async () => {
    // A client-supplied recipient public key is a substitution primitive: a
    // compromised joiner could publish an attacker's key and be handed
    // envelopes for it. Key material comes only from the member's own
    // rules-protected users/{uid}/escrow_public_keys namespace.
    const source = [
      readFileSync(resolve(__dirname, "../teamRoster.ts"), "utf8"),
      readFileSync(resolve(__dirname, "../teamKeyEnvelopes.ts"), "utf8"),
      readFileSync(resolve(__dirname, "../callables/teamRosterCallables.ts"), "utf8"),
    ].join("\n");
    expect(source).not.toMatch(/escrowPublicKey/u);
    expect(source).not.toMatch(/publicKeyData/u);
    expect(source).toContain("escrow_public_keys");

    seedTeam();
    seedMember(ADMIN_UID, { role: "admin" });
    rosterHarness.users.set("member@example.test", { uid: MEMBER_UID });
    const { inviteToken } = await TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, "member@example.test", "member");

    // With no trusted escrow device the join is refused outright rather than
    // producing a member who is on the roster but cannot decrypt anything.
    const blind = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken));
    expect(blind.code).toBe("failed-precondition");

    // An untrusted device does not count either.
    seed(`users/${MEMBER_UID}/escrow_public_keys/device-x_1`, {
      deviceId: "device-x",
      keyVersion: 1,
      publicKeyFingerprint: escrowFingerprint("c"),
    });
    seed(`users/${MEMBER_UID}/escrow_devices/device-x`, { trustState: "pending" });
    const untrusted = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken));
    expect(untrusted.code).toBe("failed-precondition");

    // Nor does an unbounded device set: envelope coverage costs one read per
    // (device, retained key version) pair, so the fan-out is capped at the door.
    for (let index = 0; index <= MAX_TEAM_MEMBER_DEVICES; index += 1) {
      seedTrustedDevice(MEMBER_UID, {
        deviceId: `device-${index}`,
        keyVersion: 1,
        publicKeyFingerprint: escrowFingerprint(String(index % 10)),
      });
    }
    const tooManyDevices = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken));
    expect(tooManyDevices.code).toBe("failed-precondition");
  });

  // --- PR 1 security review, fix round 1 -------------------------------------

  it("test_promote_refuses_a_substituted_recipient_fingerprint", async () => {
    // F2. `acceptTeamInvite` pins the joiner's own escrow key fingerprints so a
    // client-supplied recipient key cannot be substituted — but a fingerprint
    // nobody reads back is bookkeeping, not a control. Coverage now binds the
    // envelope to the PINNED fingerprint, so an envelope wrapped to any other
    // key covers nothing.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(MEMBER_UID, { status: "pending", escrowDeviceFingerprints: [DEVICE] });

    const required = requiredTeamKeyEnvelopeIds({
      uid: MEMBER_UID,
      devices: [DEVICE],
      keyVersions: [1],
      includeSlugKey: true,
    });
    // Both envelopes exist, are addressed to the right member, name the right
    // device and slot — and are wrapped to a key this member never published.
    seedEnvelope(MEMBER_UID, 1, DEVICE, { recipientPublicKeyFingerprint: escrowFingerprint("0") });
    seedEnvelope(MEMBER_UID, "slug", DEVICE, { recipientPublicKeyFingerprint: escrowFingerprint("0") });

    const substituted = await caught(() =>
      TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(required)),
    );
    expect(substituted.code).toBe("failed-precondition");
    expect(substituted.message).toMatch(/never published/u);
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({ status: "pending" });

    // A device/slot mismatch is refused for the same reason: the id is not the
    // authority, the fields the id encodes are.
    seedEnvelope(MEMBER_UID, 1, DEVICE, { deviceId: "device-somebody-else" });
    seedEnvelope(MEMBER_UID, "slug");
    const misdeviced = await caught(() =>
      TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(required)),
    );
    expect(misdeviced.code).toBe("failed-precondition");
    expect(misdeviced.message).toMatch(/expected member device/u);

    // And a wrap published by a PLAIN MEMBER for somebody else never counts,
    // even though it is otherwise perfectly formed (F1's server-side half).
    seedMember("roster-mallory-uid");
    seedEnvelope(MEMBER_UID, 1, DEVICE, { wrappedBy: "roster-mallory-uid" });
    const squatted = await caught(() =>
      TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(required)),
    );
    expect(squatted.code).toBe("failed-precondition");
    expect(squatted.message).toMatch(/team admin or by its recipient/u);
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({ status: "pending" });

    // A member's wrap for THEMSELVES is legitimate (that is how a second Mac
    // is enrolled), and full, correctly bound coverage promotes.
    seedEnvelope(MEMBER_UID, 1, DEVICE, { wrappedBy: MEMBER_UID });
    const promoted = await TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(required));
    expect(promoted.status).toBe("active");
  });

  it("test_rotation_refuses_to_leave_an_active_member_uncovered", async () => {
    // F3. The founding admin used to carry an EMPTY fingerprint list for the
    // life of the team, so a rotation "covered" them by requiring nothing —
    // a second admin could rotate the founder into blindness with no attacker
    // involved. Rotation now refuses while any active member is unpinned.
    seedTeam();
    const founderUid = "roster-founder-uid";
    seedMember(founderUid, { role: "admin", escrowDeviceFingerprints: [] });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });

    const uncovered = await caught(() =>
      TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, new Set([seedEnvelope(ADMIN_UID, 2)])),
    );
    expect(uncovered.code).toBe("failed-precondition");
    expect(uncovered.message).toMatch(/no pinned escrow device/u);
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}`)).toMatchObject({ activeKeyVersion: 1 });

    // Pin the founder and the rotation still refuses until an envelope for the
    // founder's device actually exists.
    const founderDevice = { deviceId: "device-founder", keyVersion: 1, publicKeyFingerprint: escrowFingerprint("f") };
    seedMember(founderUid, { role: "admin", escrowDeviceFingerprints: [founderDevice] });
    const stillUncovered = await caught(() =>
      TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, new Set([seedEnvelope(ADMIN_UID, 2)])),
    );
    expect(stillUncovered.code).toBe("failed-precondition");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}`)).toMatchObject({ activeKeyVersion: 1 });

    const covered = new Set([seedEnvelope(ADMIN_UID, 2), seedEnvelope(founderUid, 2, founderDevice)]);
    const rotated = await TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, covered);
    expect(rotated.activeKeyVersion).toBe(2);
  });

  it("test_a_stale_invite_cannot_demote_a_live_member", async () => {
    // F4. Two invites issued before the first was redeemed: the admin invite is
    // accepted and promoted, then the older `member` invite is clicked. That
    // used to overwrite the live row with {status: "pending", role: "member"}
    // — stranding a team with zero active admins and no way back, walking
    // straight around the last-admin guard without a removal.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    rosterHarness.users.set("alice@example.test", { uid: MEMBER_UID });
    seedTrustedDevice(MEMBER_UID);

    const stale = await TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, "alice@example.test", "member");
    const fresh = await TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, "alice@example.test", "admin");
    await TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, fresh.inviteToken);
    await TeamRosterService.promoteMember(
      ADMIN_UID,
      TEAM_ID,
      MEMBER_UID,
      new Set([seedEnvelope(MEMBER_UID, 1), seedEnvelope(MEMBER_UID, "slug")]),
    );
    // Alice is now the only active admin.
    await TeamRosterService.removeMember(ADMIN_UID, TEAM_ID, ADMIN_UID);
    const before = { ...storedDoc(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`) };
    expect(before).toMatchObject({ status: "active", role: "admin" });

    const demotion = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, stale.inviteToken));
    expect(demotion.code).toBe("already-exists");
    // The row is untouched, byte for byte.
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toEqual(before);
    // ...and the team still has an admin, so the roster is not frozen.
    await expect(TeamRosterService.assertActiveAdmin(MEMBER_UID, TEAM_ID)).resolves.toBeUndefined();

    // A PENDING member cannot be walked backwards either. `inviteMember` will
    // not ISSUE over a live row, so this is the invite that was issued first
    // and redeemed second — seeded directly, exactly as it would have persisted.
    const pendingUid = "roster-pending-uid";
    const pendingToken = `inv_${"p".repeat(40)}`;
    seedInvite(pendingUid, pendingToken, "member");
    seedMember(pendingUid, { status: "pending", escrowDeviceFingerprints: [DEVICE] });
    seedTrustedDevice(pendingUid);
    const pendingRow = { ...storedDoc(`team_rosters/${TEAM_ID}/members/${pendingUid}`) };
    const rePend = await caught(() => TeamRosterService.acceptInvite(pendingUid, true, TEAM_ID, pendingToken));
    expect(rePend.code).toBe("already-exists");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${pendingUid}`)).toEqual(pendingRow);

    // A REMOVED member may re-join with a fresh invite, as `pending`, and the
    // eviction stamp does not survive the re-join.
    const leaverUid = "roster-leaver-uid";
    seedMember(leaverUid, { status: "removed", removedAt: "2026-09-01" });
    rosterHarness.users.set("leaver@example.test", { uid: leaverUid });
    seedTrustedDevice(leaverUid);
    const rejoin = await TeamRosterService.inviteMember(MEMBER_UID, TEAM_ID, "leaver@example.test", "member");
    const rejoined = await TeamRosterService.acceptInvite(leaverUid, true, TEAM_ID, rejoin.inviteToken);
    expect(rejoined.status).toBe("pending");
    const leaverRow = storedDoc(`team_rosters/${TEAM_ID}/members/${leaverUid}`);
    expect(leaverRow).toMatchObject({ status: "pending", role: "member" });
    expect(leaverRow.removedAt).toBeUndefined();
  });

  it("test_rotate_retry_converges_after_a_failed_middle_batch", async () => {
    // F5. `rotateTeamKey` commits member rows in chunks and the team document
    // last, so a mid-rotation failure is possible. It is safe and recoverable:
    // the rules read `activeKeyVersion` from the TEAM DOCUMENT alone, so writes
    // stay pinned to N, `keyRotationRequired` stays true, and a retry is
    // idempotent. This test kills the second chunk and proves the retry lands.
    seedTeam({ keyRotationRequired: true });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    const envelopeIds = new Set<string>([seedEnvelope(ADMIN_UID, 2)]);
    for (let index = 0; index < 500; index += 1) {
      const uid = `bulk-member-${index}`;
      seedMember(uid, { escrowDeviceFingerprints: [DEVICE] });
      envelopeIds.add(seedEnvelope(uid, 2));
    }

    rosterHarness.stats.batches = 0;
    rosterHarness.stats.failCommitAtBatch.add(2);
    await expect(TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, envelopeIds)).rejects.toThrow(
      /simulated batch failure/u,
    );

    // Partial state: chunk 1 landed, chunk 2 did not, the team document is
    // untouched — which is what keeps every WRITE pinned to v1.
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}`)).toMatchObject({
      activeKeyVersion: 1,
      retainedKeyVersions: [1],
      keyRotationRequired: true,
    });
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/bulk-member-0`)).toMatchObject({
      activeTeamKeyVersion: 2,
    });
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/bulk-member-499`)).toMatchObject({
      activeTeamKeyVersion: 1,
    });

    // The retry converges: same arguments, no manual repair.
    rosterHarness.stats.failCommitAtBatch.clear();
    const rotated = await TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, envelopeIds);
    expect(rotated.activeKeyVersion).toBe(2);
    expect(rotated.retainedKeyVersions).toEqual([1, 2]);
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}`)).toMatchObject({
      activeKeyVersion: 2,
      keyRotationRequired: false,
    });
    for (const uid of [ADMIN_UID, "bulk-member-0", "bulk-member-499"]) {
      expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${uid}`)).toMatchObject({ activeTeamKeyVersion: 2 });
    }
  });

  // --- PR 1 security review, fix round 2 (nits) ------------------------------

  it("test_a_departed_admins_wrap_still_covers_a_pending_joiner", async () => {
    // N-2. Coverage asks "was this wrap authorised when it was made", and
    // `firestore.rules` already answered that at create time. Requiring the
    // wrapper to be active NOW stranded a joiner whose wrapping admin left
    // before the promotion landed: envelopes are immutable, so no surviving
    // admin could re-create those ids. Rotation revokes a departed admin's
    // key; coverage arithmetic must not try to.
    const wrapperUid = "roster-departing-admin";
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(wrapperUid, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(MEMBER_UID, { status: "pending", escrowDeviceFingerprints: [DEVICE] });

    const required = requiredTeamKeyEnvelopeIds({
      uid: MEMBER_UID,
      devices: [DEVICE],
      keyVersions: [1],
      includeSlugKey: true,
    });
    seedEnvelope(MEMBER_UID, 1, DEVICE, { wrappedBy: wrapperUid });
    seedEnvelope(MEMBER_UID, "slug", DEVICE, { wrappedBy: wrapperUid });

    await TeamRosterService.removeMember(ADMIN_UID, TEAM_ID, wrapperUid);
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${wrapperUid}`)).toMatchObject({ status: "removed" });

    const promoted = await TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(required));
    expect(promoted.status).toBe("active");

    // A wrap by someone who was NEVER an admin still counts for nothing.
    const outsiderPending = "roster-second-joiner";
    seedMember(outsiderPending, { status: "pending", escrowDeviceFingerprints: [DEVICE] });
    seedEnvelope(outsiderPending, 1, DEVICE, { wrappedBy: MEMBER_UID });
    seedEnvelope(outsiderPending, "slug", DEVICE, { wrappedBy: MEMBER_UID });
    const stillRefused = await caught(() =>
      TeamRosterService.promoteMember(
        ADMIN_UID,
        TEAM_ID,
        outsiderPending,
        new Set(
          requiredTeamKeyEnvelopeIds({
            uid: outsiderPending,
            devices: [DEVICE],
            keyVersions: [1],
            includeSlugKey: true,
          }),
        ),
      ),
    );
    expect(stillRefused.code).toBe("failed-precondition");
    expect(stillRefused.message).toMatch(/team admin or by its recipient/u);
  });

  it("test_two_concurrent_accepts_write_exactly_one_member_row", async () => {
    // N-3. The live-row guard and the member write used to sit on either side
    // of the invite-burn transaction, so two accepts of two DIFFERENT live
    // invites for the same uid both cleared the guard and both wrote the row —
    // last write won the role. Both are now inside the transaction that burns
    // the invite, so the loser re-reads, sees the winner's row and is refused.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedTrustedDevice(MEMBER_UID);
    const memberToken = `inv_${"m".repeat(40)}`;
    const adminToken = `inv_${"n".repeat(40)}`;
    seedInvite(MEMBER_UID, memberToken, "member");
    seedInvite(MEMBER_UID, adminToken, "admin");

    const memberPath = `team_rosters/${TEAM_ID}/members/${MEMBER_UID}`;
    rosterHarness.stats.writesByPath.clear();
    const settled = await Promise.allSettled([
      TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, memberToken),
      TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, adminToken),
    ]);

    const rejected = settled.filter((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected");
    const winner = settled.find((outcome) => outcome.status === "fulfilled");
    expect(rejected).toHaveLength(1);
    if (winner?.status !== "fulfilled") throw new Error("expected exactly one accept to win the race");
    const loser = rejected[0]?.reason;
    if (!(loser instanceof HttpsError)) throw new Error(`expected an HttpsError, got ${String(loser)}`);
    expect(loser.code).toBe("already-exists");
    // Exactly ONE row write, not two: the losing accept never reached the row.
    expect(rosterHarness.stats.writesByPath.get(memberPath)).toBe(1);

    expect(rosterHarness.store.get(memberPath)).toMatchObject({ status: "pending", role: winner.value.role });
    // The loser's invite is NOT burned, so it can still be redeemed later (or
    // revoked) rather than being silently spent on a refused accept.
    const burned = inviteDocs().filter(([, invite]) => invite.status === "accepted");
    expect(burned).toHaveLength(1);
  });

  it("test_promote_aborts_when_the_team_key_state_moves_under_it", async () => {
    // N-4. `promoteMember` computes its envelope requirements from the team's
    // retained versions and only then writes. A rotation landing inside that
    // window would flip the member to `active` against a stale requirement set
    // — active-but-blind for v(N+1), the F3 shape reached by concurrency. The
    // key state is now re-read inside the transaction that writes the row.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(MEMBER_UID, { status: "pending", escrowDeviceFingerprints: [DEVICE] });
    const required = requiredTeamKeyEnvelopeIds({
      uid: MEMBER_UID,
      devices: [DEVICE],
      keyVersions: [1],
      includeSlugKey: true,
    });
    seedEnvelope(MEMBER_UID, 1);
    seedEnvelope(MEMBER_UID, "slug");

    // A concurrent rotation lands between the coverage decision and the commit.
    rosterHarness.stats.onTransaction = () => {
      seed(`team_rosters/${TEAM_ID}`, {
        ...storedDoc(`team_rosters/${TEAM_ID}`),
        activeKeyVersion: 2,
        retainedKeyVersions: [1, 2],
      });
    };
    const aborted = await caught(() =>
      TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(required)),
    );
    expect(aborted.code).toBe("aborted");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({ status: "pending" });

    // The retry against the NEW state demands the v2 envelope the stale run
    // would have skipped, and only then promotes.
    rosterHarness.stats.onTransaction = null;
    const afterRotation = requiredTeamKeyEnvelopeIds({
      uid: MEMBER_UID,
      devices: [DEVICE],
      keyVersions: [1, 2],
      includeSlugKey: true,
    });
    const stillBlind = await caught(() =>
      TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(afterRotation)),
    );
    expect(stillBlind.code).toBe("failed-precondition");
    seedEnvelope(MEMBER_UID, 2);
    const promoted = await TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, new Set(afterRotation));
    expect(promoted.status).toBe("active");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({
      status: "active",
      activeTeamKeyVersion: 2,
    });
  });

  it("test_rotate_aborts_when_another_rotation_wins_the_race", async () => {
    // N-4, the other half: two rotations to the same version. The loser must
    // not overwrite the winner's key state on the team document.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    const envelopeIds = new Set([seedEnvelope(ADMIN_UID, 2)]);

    rosterHarness.stats.onTransaction = () => {
      seed(`team_rosters/${TEAM_ID}`, {
        ...storedDoc(`team_rosters/${TEAM_ID}`),
        activeKeyVersion: 2,
        retainedKeyVersions: [1, 2],
        slugKeyId: "written-by-the-winner",
      });
    };
    const aborted = await caught(() => TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, envelopeIds));
    expect(aborted.code).toBe("aborted");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}`)).toMatchObject({
      activeKeyVersion: 2,
      retainedKeyVersions: [1, 2],
      slugKeyId: "written-by-the-winner",
    });
    expect(auditActions()).not.toContain("key_rotated");
  });

  it("test_an_unpinnable_escrow_key_version_is_skipped_not_pinned", async () => {
    // N-5. `firestore.rules` requires an envelope's `escrowKeyVersion` to be an
    // int >= 1. Pinning a key published with 0, a negative or a fractional
    // version demanded an envelope that could never be written, leaving the
    // member permanently unpromotable. Such devices are skipped and logged.
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    rosterHarness.users.set("member@example.test", { uid: MEMBER_UID });
    const { inviteToken } = await TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, "member@example.test", "member");

    const unpinnableKeyVersions: Array<[string, number]> = [
      ["zero", 0],
      ["negative", -1],
      ["fractional", 1.5],
    ];
    for (const [suffix, keyVersion] of unpinnableKeyVersions) {
      seed(`users/${MEMBER_UID}/escrow_devices/device-${suffix}`, { trustState: "trusted" });
      seed(`users/${MEMBER_UID}/escrow_public_keys/device-${suffix}`, {
        deviceId: `device-${suffix}`,
        keyVersion,
        publicKeyFingerprint: escrowFingerprint("b"),
      });
    }

    // Every device is unpinnable, so the join is refused outright rather than
    // producing a member nobody can ever hand a key to.
    const unpinnable = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken));
    expect(unpinnable.code).toBe("failed-precondition");
    expect(unpinnable.message).toMatch(/at least one device escrow key/u);
    const logged = warn.mock.calls.map(([line]) => String(line)).join("\n");
    expect(logged).toContain("team_roster.escrow_key_version_unpinnable");
    expect(warn.mock.calls).toHaveLength(3);

    // One valid device is enough, and ONLY it is pinned.
    seedTrustedDevice(MEMBER_UID);
    const accepted = await TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken);
    expect(accepted.status).toBe("pending");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({
      escrowDeviceFingerprints: [DEVICE],
    });
    warn.mockRestore();
  });

  it("test_a_real_base64_escrow_fingerprint_is_pinned_and_a_hex_one_is_not", async () => {
    // Memory program D16 / PR 2 defect fix. An escrow device publishes
    // base64(SHA-256(public key)) — 43 base64 chars plus `=`. PR 1 filtered pins
    // with `^[a-f0-9]{64}$`, a shape NO device has ever published, so every
    // device was dropped and every join died on the "publish and trust at least
    // one device" refusal. This pins both halves of the fix: the real shape is
    // accepted, and the hex shape the old filter demanded is rejected — so the
    // regex can never be flipped back without a red test.
    expect(isEscrowPublicKeyFingerprint(escrowFingerprint("a"))).toBe(true);
    expect(isEscrowPublicKeyFingerprint("a".repeat(64))).toBe(false);
    expect(isEscrowPublicKeyFingerprint(`${"a".repeat(44)}=`)).toBe(false);
    expect(isEscrowPublicKeyFingerprint(42)).toBe(false);

    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    rosterHarness.users.set("member@example.test", { uid: MEMBER_UID });
    const { inviteToken } = await TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, "member@example.test", "member");

    // A device whose published fingerprint is 64 hex is not a real device shape
    // and must not be pinned; on its own it leaves the joiner with no device.
    seed(`users/${MEMBER_UID}/escrow_devices/device-hex`, { trustState: "trusted" });
    seed(`users/${MEMBER_UID}/escrow_public_keys/device-hex`, {
      deviceId: "device-hex",
      keyVersion: 1,
      publicKeyFingerprint: "a".repeat(64),
    });
    const hexOnly = await caught(() => TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken));
    expect(hexOnly.code).toBe("failed-precondition");
    expect(hexOnly.message).toMatch(/at least one device escrow key/u);

    // The real base64 shape pins, and ONLY it — the hex device is still ignored.
    seedTrustedDevice(MEMBER_UID);
    const accepted = await TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, inviteToken);
    expect(accepted.status).toBe("pending");
    expect(rosterHarness.store.get(`team_rosters/${TEAM_ID}/members/${MEMBER_UID}`)).toMatchObject({
      escrowDeviceFingerprints: [DEVICE],
    });
  });
});
