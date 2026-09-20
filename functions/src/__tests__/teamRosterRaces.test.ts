/**
 * Team roster concurrency tests (D16 / P21 — PR 1, Cursor security round).
 *
 * Every callable in `teamRoster.ts` is a read-then-write: read the roster,
 * decide, commit. Three of those decisions were still being made outside the
 * transaction that acted on them, and each window was reachable by a second
 * ordinary caller rather than by an attacker:
 *
 *  - `removeMember`'s last-admin guard counted active admins with a QUERY, so
 *    the last two admins leaving at once both counted two and both left,
 *    freezing the roster and its key-control plane for ever
 *    (`teamRoster.ts:705`).
 *  - `promoteMember` checked `status == "pending"` before a wide coverage
 *    window and then merged `{status: "active"}` blind, so a removal inside the
 *    window was reversed by the promotion — a re-join with no invite
 *    (`teamRoster.ts:674`).
 *  - `rotateTeamKey` snapshotted the ACTIVE members with a query, and Firestore
 *    cannot conflict-detect a query, so a promotion inside the window added an
 *    active member the rotation had required no wrap for and the new generation
 *    published over their head — active but blind, the F3 invariant reached
 *    through membership instead of key state (`teamRoster.ts:747`).
 *
 * Each test lands the concurrent write in the guard's window through the
 * harness hooks and asserts the call is refused with the roster intact. They
 * are in their own file because `teamRoster.test.ts` is at the 600-line lint
 * ceiling; the in-memory Firestore double is shared, in ./teamRosterHarness.ts.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

import { assertActiveBurnBarCloudProEntitlement } from "../callables/shared/entitlements.js";
import { TeamRosterService, requiredTeamKeyEnvelopeIds } from "../teamRoster.js";
import {
  ADMIN_UID,
  DEVICE,
  MEMBER_UID,
  TEAM_ID,
  auditActions,
  caught,
  rosterHarness,
  seed,
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

const SECOND_ADMIN_UID = "roster-second-admin-uid";
const TEAM_PATH = `team_rosters/${TEAM_ID}`;
const memberPath = (uid: string): string => `${TEAM_PATH}/members/${uid}`;

/**
 * Land `effect` exactly once, in the first window this call opens between its
 * decision and its commit — a transaction body or a batch commit, whichever
 * comes first.
 *
 * Registering it on BOTH hooks is deliberate. A guard that still sits outside
 * the transaction commits through `db.batch()`, so a test armed only on
 * `onTransaction` would never fire the race and would pass against the very
 * code it is meant to reject. Armed on both, each test below fails against the
 * pre-fix authority and passes against this one.
 */
function raceOnce(effect: () => void): void {
  let fired = false;
  const once = (): void => {
    if (fired) return;
    fired = true;
    effect();
  };
  rosterHarness.stats.onTransaction = once;
  rosterHarness.stats.onBatchCommit = once;
}

function patch(path: string, fields: Record<string, unknown>): void {
  seed(path, { ...storedDoc(path), ...fields });
}

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

describe("team roster concurrency", () => {
  it("test_removing_the_last_two_admins_cannot_race_a_team_into_zero_admins", async () => {
    // Cursor round, `teamRoster.ts:705`. Sequential last-admin self-leave was
    // already refused; this is the concurrent shape. A team with no active
    // admin is UNRECOVERABLE — `firestore.rules` denies every client write to
    // `team_rosters/**` and every remaining callable requires an active admin,
    // so the roster can never be invited to, promoted in, removed from, or
    // rotated again, including to revoke the departed admins' own wraps.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin" });
    seedMember(SECOND_ADMIN_UID, { role: "admin" });

    // The other admin's self-leave commits inside this call's guard window.
    raceOnce(() => patch(memberPath(SECOND_ADMIN_UID), { status: "removed" }));

    const refused = await caught(() => TeamRosterService.removeMember(ADMIN_UID, TEAM_ID, ADMIN_UID));
    expect(refused.code).toBe("failed-precondition");
    expect(storedDoc(memberPath(ADMIN_UID))).toMatchObject({ status: "active", role: "admin" });
    expect(auditActions()).not.toContain("member_removed");

    // Un-raced, the same removal is legal as long as an admin survives it, and
    // it bumps the membership epoch so an in-flight rotation notices.
    rosterHarness.stats.onTransaction = null;
    rosterHarness.stats.onBatchCommit = null;
    patch(memberPath(SECOND_ADMIN_UID), { status: "active" });
    const removed = await TeamRosterService.removeMember(ADMIN_UID, TEAM_ID, ADMIN_UID);
    expect(removed.keyRotationRequired).toBe(true);
    expect(storedDoc(memberPath(ADMIN_UID))).toMatchObject({ status: "removed" });
    expect(storedDoc(TEAM_PATH)).toMatchObject({ keyRotationRequired: true, membershipEpoch: 1 });
  });

  it("test_promote_refuses_a_member_removed_mid_flight", async () => {
    // Cursor round, `teamRoster.ts:674`. `promoteMember` read `status ==
    // "pending"`, then spent the whole envelope-coverage fan-out outside any
    // transaction, then merged `{status: "active"}`. A `removeMember` landing
    // in that window was invisible, so the merge RESURRECTED an evicted member
    // — an admin race standing in for the burned single-use invite that is
    // supposed to be the only way back onto a roster.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(MEMBER_UID, { status: "pending", escrowDeviceFingerprints: [DEVICE] });
    const required = new Set(
      requiredTeamKeyEnvelopeIds({ uid: MEMBER_UID, devices: [DEVICE], keyVersions: [1], includeSlugKey: true }),
    );
    seedEnvelope(MEMBER_UID, 1);
    seedEnvelope(MEMBER_UID, "slug");

    raceOnce(() => patch(memberPath(MEMBER_UID), { status: "removed", removedAt: "evicted-mid-flight" }));

    const refused = await caught(() => TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, required));
    expect(refused.code).toBe("failed-precondition");
    // Still removed, and still carrying the eviction stamp: the promotion did
    // not write the row at all.
    expect(storedDoc(memberPath(MEMBER_UID))).toMatchObject({
      status: "removed",
      removedAt: "evicted-mid-flight",
    });
    expect(auditActions()).not.toContain("member_promoted");

    // Un-raced, the promotion lands and bumps the membership epoch — the read
    // a concurrent rotation conflict-detects on.
    rosterHarness.stats.onTransaction = null;
    rosterHarness.stats.onBatchCommit = null;
    patch(memberPath(MEMBER_UID), { status: "pending" });
    const promoted = await TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, MEMBER_UID, required);
    expect(promoted.status).toBe("active");
    expect(storedDoc(TEAM_PATH)).toMatchObject({ membershipEpoch: 1 });
  });

  it("test_rotation_refuses_when_a_promotion_lands_mid_flight", async () => {
    // Cursor round, `teamRoster.ts:747`. The rotation's requirement set comes
    // from a QUERY for `status == "active"`, and no Firestore guard can
    // invalidate a query, so a promotion inside the window changed neither
    // `activeKeyVersion` nor `retainedKeyVersions` and sailed past both N-4
    // checks. v(N+1) was then published with no wrap for the freshly-active
    // member: live on the roster by `isTeamMember`, blind to the generation
    // every team document is now sealed under.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(MEMBER_UID, { status: "pending", escrowDeviceFingerprints: [DEVICE] });
    const adminOnly = new Set([seedEnvelope(ADMIN_UID, 2)]);

    // Exactly what `promoteMember`'s transaction commits: the row goes active
    // and the team's membership epoch moves.
    raceOnce(() => {
      patch(memberPath(MEMBER_UID), { status: "active" });
      patch(TEAM_PATH, { membershipEpoch: 1 });
    });

    const aborted = await caught(() => TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, adminOnly));
    expect(aborted.code).toBe("aborted");
    expect(storedDoc(TEAM_PATH)).toMatchObject({ activeKeyVersion: 1, retainedKeyVersions: [1] });
    expect(auditActions()).not.toContain("key_rotated");

    // The retry sees the roster as it actually stands and refuses until the
    // promoted member has a wrap for the new generation too.
    rosterHarness.stats.onTransaction = null;
    rosterHarness.stats.onBatchCommit = null;
    const stillBlind = await caught(() => TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, adminOnly));
    expect(stillBlind.code).toBe("failed-precondition");

    const covered = new Set([...adminOnly, seedEnvelope(MEMBER_UID, 2)]);
    const rotated = await TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, covered);
    expect(rotated.activeKeyVersion).toBe(2);
    expect(storedDoc(memberPath(MEMBER_UID))).toMatchObject({ status: "active", activeTeamKeyVersion: 2 });
  });
});
