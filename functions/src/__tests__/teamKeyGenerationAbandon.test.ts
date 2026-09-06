/**
 * Abandoning a burned team key generation (D16 / P21 — PR 2, review round 3 B7).
 *
 * A team can deadlock without an attacker. Admin A mints `v(N+1)`, publishes
 * some of its envelopes and never reaches `rotateTeamKey`: the roster still
 * records `N`, `K_A` exists only in A's Keychain, and `v(N+1)`'s envelope ids
 * are occupied by documents `firestore.rules` forbids anyone to update or
 * delete. The strict-sequence rule then admits exactly one version — `N+1` —
 * and that is the one nobody else can complete. A team in that state cannot
 * rotate, so it cannot revoke a departed member either: the revocation
 * primitive is dead.
 *
 * `abandonKeyGeneration` is the way out, and these tests are about the three
 * things that stop it becoming a way to skip version numbers at will: it burns
 * only the next unclaimed version, never one the roster recorded, and never one
 * no envelope was ever published for. Plus the two properties every roster
 * mutation has: admin only, and audit logged.
 *
 * Its own file because `teamRoster.test.ts` sits at the 600-line lint ceiling;
 * the in-memory Firestore double is shared, in ./teamRosterHarness.ts.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

import { assertActiveBurnBarCloudProEntitlement } from "../callables/shared/entitlements.js";
import { TeamRosterService } from "../teamRoster.js";
import {
  ADMIN_UID,
  DEVICE,
  MEMBER_UID,
  TEAM_ID,
  auditActions,
  caught,
  rosterHarness,
  seedEnvelope,
  seedMember,
  seedTeam,
  storedDoc,
} from "./teamRosterHarness.js";

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

const TEAM_PATH = `team_rosters/${TEAM_ID}`;

beforeEach(() => {
  rosterHarness.store.clear();
  rosterHarness.users.clear();
  rosterHarness.stats.batches = 0;
  rosterHarness.stats.maxBatchSize = 0;
  rosterHarness.stats.failCommitAtBatch.clear();
  rosterHarness.stats.writesByPath.clear();
  rosterHarness.stats.transactions = 0;
  rosterHarness.stats.onTransaction = null;
  rosterHarness.stats.onBatchCommit = null;
  vi.mocked(assertActiveBurnBarCloudProEntitlement).mockClear();
});

describe("team key generation abandonment", () => {
  it("test_abandoning_a_burned_generation_lets_the_team_rotate_past_it", async () => {
    // The whole point, end to end. A's abandoned v2 envelope is on the server;
    // v2 is the only version `rotateTeamKey` would accept, and A's wrap of it is
    // immutable, so B is stuck. After the burn, v2 is never offered again and v3
    // is the version the team rotates to.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedEnvelope(ADMIN_UID, 2, DEVICE, { wrappedBy: MEMBER_UID });

    const burned = await TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 2);
    expect(burned.burnedKeyVersions).toEqual([2]);
    expect(burned.activeKeyVersion).toBe(1);
    expect(storedDoc(TEAM_PATH)).toMatchObject({
      activeKeyVersion: 1,
      retainedKeyVersions: [1],
      burnedKeyVersions: [2],
    });
    expect(auditActions()).toEqual(["key_generation_abandoned"]);

    // v2 is now refused BY THE VERSION RULE, not by coverage: it is no longer
    // the next version, so the team never tries to publish over A's envelopes
    // again.
    const stale = await caught(() => TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, new Set()));
    expect(stale.code).toBe("invalid-argument");
    expect(stale.message).toMatch(/Expected newKeyVersion to be 3/u);

    const rotated = await TeamRosterService.rotateTeamKey(
      ADMIN_UID,
      TEAM_ID,
      3,
      new Set([seedEnvelope(ADMIN_UID, 3)]),
    );
    expect(rotated.activeKeyVersion).toBe(3);
    // v2 is NOT retained: nothing was ever sealed under it, and a retained
    // version is a generation every joiner must be issued an envelope for.
    expect(rotated.retainedKeyVersions).toEqual([1, 3]);
    expect(storedDoc(TEAM_PATH)).toMatchObject({ burnedKeyVersions: [2] });
  });

  it("test_abandon_refuses_a_version_the_roster_recorded", async () => {
    // A version the team actually published is never "abandoned" — burning one
    // would tell every later rotation to skip a generation whose facts and
    // envelopes are real. The active version and every retained version are
    // both refused, and neither reaches the envelope probe.
    seedTeam({ activeKeyVersion: 2, retainedKeyVersions: [1, 2] });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedEnvelope(ADMIN_UID, 2);

    for (const version of [1, 2]) {
      const error = await caught(() => TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, version));
      expect(error.code, `v${version} is recorded`).toBe("failed-precondition");
      expect(error.message).toMatch(/is recorded by this team/u);
    }
    expect(storedDoc(TEAM_PATH).burnedKeyVersions).toEqual([]);
    expect(auditActions()).toEqual([]);
  });

  it("test_abandon_refuses_a_version_no_envelope_was_published_for", async () => {
    // The check that keeps this from being "skip a version number because I
    // feel like it". A generation nobody tried to mint has no envelope, so
    // there is no abandoned rotation to step over — and burning it would move
    // the whole team's sequence forward for nothing.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    // An envelope exists — for a DIFFERENT slot. The probe is keyed on `keySlot`,
    // so the slug key's envelope must not be mistaken for a v2 rotation.
    seedEnvelope(ADMIN_UID, "slug");

    const error = await caught(() => TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 2));
    expect(error.code).toBe("failed-precondition");
    expect(error.message).toMatch(/No key envelope was ever published for version 2/u);
    expect(storedDoc(TEAM_PATH).burnedKeyVersions).toEqual([]);
    expect(auditActions()).toEqual([]);
  });

  it("test_abandon_refuses_a_non_sequential_version", async () => {
    // Only the NEXT unclaimed version. Reaching forward would let one admin
    // burn generations the team has not reached, each burn permanently
    // shortening the 100-version lifetime `validCloudSealedBlob` caps.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedEnvelope(ADMIN_UID, 3);
    seedEnvelope(ADMIN_UID, 4);

    for (const version of [3, 4]) {
      const error = await caught(() => TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, version));
      expect(error.code, `v${version} is not the next unclaimed version`).toBe("invalid-argument");
      expect(error.message).toMatch(/Only the next unclaimed key version \(2\)/u);
    }

    // And once v2 IS burned, v3 becomes the next unclaimed one — the rule reads
    // past every burn rather than counting from the active version alone.
    seedEnvelope(ADMIN_UID, 2);
    await TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 2);
    await TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 3);
    expect(storedDoc(TEAM_PATH).burnedKeyVersions).toEqual([2, 3]);
    const rotationTarget = await caught(() => TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, new Set()));
    expect(rotationTarget.message).toMatch(/Expected newKeyVersion to be 4/u);
  });

  it("test_abandon_is_admin_only", async () => {
    // Burning a generation is a key-control-plane mutation: an ordinary member
    // who could do it would be able to walk the team's version counter forward
    // at will. Same gate as every other roster mutation, and nothing is written.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(MEMBER_UID);
    seedEnvelope(ADMIN_UID, 2);

    const member = await caught(() => TeamRosterService.abandonKeyGeneration(MEMBER_UID, TEAM_ID, 2));
    expect(member.code).toBe("permission-denied");

    // A PENDING admin is not an active admin either.
    seedMember("roster-pending-admin", { role: "admin", status: "pending" });
    const pending = await caught(() => TeamRosterService.abandonKeyGeneration("roster-pending-admin", TEAM_ID, 2));
    expect(pending.code).toBe("permission-denied");

    const outsider = await caught(() => TeamRosterService.abandonKeyGeneration("roster-nobody", TEAM_ID, 2));
    expect(outsider.code).toBe("permission-denied");

    expect(storedDoc(TEAM_PATH).burnedKeyVersions).toEqual([]);
    expect(auditActions()).toEqual([]);
  });

  it("test_abandoning_an_already_burned_generation_is_a_no_op", async () => {
    // PR 2 review round 4, B8. The client's recovery is two calls — burn, then
    // rotate — so the retry after a failed rotation re-presents the SAME
    // version. It must resume at the rotation, not be told that only v3 can be
    // abandoned now (true of the sequence rule, useless here) and not burn a
    // second generation out of a hard-capped 100.
    seedTeam({ burnedKeyVersions: [2] });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedEnvelope(ADMIN_UID, 2);

    const repeat = await TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 2);
    expect(repeat.burnedKeyVersions).toEqual([2]);
    expect(repeat.activeKeyVersion).toBe(1);
    // Nothing written, and no second audit row for a burn that already happened.
    expect(rosterHarness.stats.transactions).toBe(0);
    expect(auditActions()).toEqual([]);
    expect(storedDoc(TEAM_PATH).burnedKeyVersions).toEqual([2]);

    // The admin gate still runs first: idempotence is not an authorization hole.
    seedMember(MEMBER_UID);
    const member = await caught(() => TeamRosterService.abandonKeyGeneration(MEMBER_UID, TEAM_ID, 2));
    expect(member.code).toBe("permission-denied");
  });

  it("test_two_concurrent_burns_do_not_both_land", async () => {
    // PR 2 review round 4, N1. `burnedKeyVersions` is part of the guard state
    // `commitGuardedByTeamState` re-reads, and this is the case that proves it:
    // neither admin's read sees the other's burn, so only the transaction can
    // catch it. Drop `burnedKeyVersions` from `teamStateMoved` and both burns
    // land, walking the version counter two steps for one abandoned rotation.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedEnvelope(ADMIN_UID, 2);

    let fired = false;
    rosterHarness.stats.onTransaction = () => {
      if (fired) return;
      fired = true;
      // The other admin's burn of the same generation lands inside the window.
      rosterHarness.store.set(TEAM_PATH, { ...storedDoc(TEAM_PATH), burnedKeyVersions: [2] });
    };

    const error = await caught(() => TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 2));
    expect(error.code).toBe("aborted");
    // The winner's burn stands, unduplicated, and this caller's audit row is
    // rolled back with the write it guarded.
    expect(storedDoc(TEAM_PATH).burnedKeyVersions).toEqual([2]);
    expect(auditActions()).toEqual([]);
  });

  it("test_a_burn_landing_inside_a_rotation_aborts_the_rotation", async () => {
    // The other half of the same guard (N1). A burn moves the version
    // `nextRotatableKeyVersion` hands the rotation, so a rotation whose target
    // was computed before the burn must abort and recompute rather than record
    // a generation the roster no longer agrees on.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    const envelopeId = seedEnvelope(ADMIN_UID, 2);

    let fired = false;
    rosterHarness.stats.onTransaction = () => {
      if (fired) return;
      fired = true;
      rosterHarness.store.set(TEAM_PATH, { ...storedDoc(TEAM_PATH), burnedKeyVersions: [2] });
    };

    const error = await caught(() =>
      TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, new Set([envelopeId])),
    );
    expect(error.code).toBe("aborted");
    expect(storedDoc(TEAM_PATH)).toMatchObject({ activeKeyVersion: 1, retainedKeyVersions: [1] });
    expect(auditActions()).toEqual([]);
  });

  it("test_a_membership_change_mid_abandon_aborts_the_burn", async () => {
    // The burn moves the version every later rotation targets, so it commits
    // through the same guarded transaction as a rotation: a promotion or a
    // removal landing in the window aborts it rather than letting one admin's
    // stale view of the roster shift the sequence.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedEnvelope(ADMIN_UID, 2);

    let fired = false;
    rosterHarness.stats.onTransaction = () => {
      if (fired) return;
      fired = true;
      rosterHarness.store.set(TEAM_PATH, { ...storedDoc(TEAM_PATH), membershipEpoch: 7 });
    };

    const error = await caught(() => TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 2));
    expect(error.code).toBe("aborted");
    expect(storedDoc(TEAM_PATH).burnedKeyVersions).toEqual([]);
    expect(auditActions()).toEqual([]);
  });
});
