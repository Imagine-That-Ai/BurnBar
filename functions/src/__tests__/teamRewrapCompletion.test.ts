/**
 * @fileoverview The rotation-completion marker on the team roster
 * (memory program D16 / P22, PR 4 — promoting PR 2 review N1 from a local
 * `UserDefaults` note to a server-written roster field).
 *
 * Its own file, not another block in `teamRoster.test.ts`: that file is at the
 * 600-line lint ceiling, and these four cases are one coherent claim — that
 * "the key rotated" and "the corpus was actually re-keyed" are different facts,
 * recorded separately, by an admin, only for the generation that is current.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

import { TeamRosterService } from "../teamRoster.js";
import {
  ADMIN_UID,
  DEVICE,
  MEMBER_UID,
  OUTSIDER_UID,
  TEAM_ID,
  auditActions,
  caught,
  rosterHarness,
  seed,
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

beforeEach(() => {
  rosterHarness.store.clear();
  rosterHarness.users.clear();
  rosterHarness.stats.transactions = 0;
  rosterHarness.stats.onTransaction = null;
});

describe("team rewrap completion marker", () => {
  it("test_recording_a_rewrap_stamps_the_roster_for_every_member", async () => {
    // PR 2 kept this in one admin's `UserDefaults`, which answers only "did
    // THAT Mac finish". Whether a team's corpus is actually re-keyed is a TEAM
    // fact, and the roster is the only place every member reads.
    seedTeam({ activeKeyVersion: 3, retainedKeyVersions: [1, 2, 3] });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });

    const result = await TeamRosterService.recordRewrapComplete(ADMIN_UID, TEAM_ID, 3, "job-abc");

    expect(result).toEqual({ teamId: TEAM_ID, rewrapCompletedKeyVersion: 3 });
    expect(storedDoc(`team_rosters/${TEAM_ID}`)).toMatchObject({
      rewrapCompletedKeyVersion: 3,
      rewrapJobId: "job-abc",
      // The marker says nothing about the key state and must not move it.
      activeKeyVersion: 3,
      retainedKeyVersions: [1, 2, 3],
    });
    expect(auditActions()).toContain("rewrap_recorded");
  });

  it("test_a_completion_for_a_superseded_generation_is_refused", async () => {
    // A completion for generation 2 says nothing about a corpus now pinned to
    // 3, and storing it would let the UI read "re-sealed" off a stale claim.
    // A completion for a FUTURE generation is worse: it asserts work the rules
    // would not yet have permitted.
    seedTeam({ activeKeyVersion: 3, retainedKeyVersions: [1, 2, 3] });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });

    const stale = await caught(() => TeamRosterService.recordRewrapComplete(ADMIN_UID, TEAM_ID, 2, "job-old"));
    expect(stale.code).toBe("failed-precondition");
    const ahead = await caught(() => TeamRosterService.recordRewrapComplete(ADMIN_UID, TEAM_ID, 4, "job-new"));
    expect(ahead.code).toBe("failed-precondition");
    expect(storedDoc(`team_rosters/${TEAM_ID}`).rewrapCompletedKeyVersion).toBeNull();
  });

  it("test_only_an_active_admin_can_record_a_rewrap", async () => {
    // The field is public trust copy for the whole team: "your memories have
    // been re-sealed". A plain member — or an outsider naming the team — must
    // not be able to write it, and `firestore.rules` denies every client write
    // to this document, so this callable is the only path at all.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(MEMBER_UID, { role: "member" });

    const byMember = await caught(() => TeamRosterService.recordRewrapComplete(MEMBER_UID, TEAM_ID, 1, "job-x"));
    expect(byMember.code).toBe("permission-denied");
    const byOutsider = await caught(() => TeamRosterService.recordRewrapComplete(OUTSIDER_UID, TEAM_ID, 1, "job-x"));
    expect(byOutsider.code).toBe("permission-denied");
    expect(storedDoc(`team_rosters/${TEAM_ID}`).rewrapCompletedKeyVersion).toBeNull();
  });

  it("test_a_rotation_landing_mid_call_aborts_the_completion", async () => {
    // N-4's guard reaches here too: the decision "generation 3 is current" is
    // read before the write, and a rotation inside that window would otherwise
    // stamp a completion for a generation that is no longer current.
    seedTeam({ activeKeyVersion: 3, retainedKeyVersions: [1, 2, 3] });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });

    rosterHarness.stats.onTransaction = () => {
      seed(`team_rosters/${TEAM_ID}`, {
        ...storedDoc(`team_rosters/${TEAM_ID}`),
        activeKeyVersion: 4,
        retainedKeyVersions: [1, 2, 3, 4],
      });
    };
    const raced = await caught(() => TeamRosterService.recordRewrapComplete(ADMIN_UID, TEAM_ID, 3, "job-raced"));
    rosterHarness.stats.onTransaction = null;

    expect(raced.code).toBe("aborted");
    expect(storedDoc(`team_rosters/${TEAM_ID}`).rewrapCompletedKeyVersion).toBeNull();
  });
});
