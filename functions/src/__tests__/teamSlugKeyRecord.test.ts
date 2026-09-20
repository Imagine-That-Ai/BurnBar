/**
 * @fileoverview The founding slug-key fingerprint on the team roster
 * (memory program D16 — the write the design assigned to PR 4 and PR 4 did not
 * ship).
 *
 * WHY THIS FIELD DECIDES WHETHER TEAM MEMORY WORKS AT ALL. The B6 ruling makes
 * the client's launch/cycle key pickup promote an envelope-sourced slot to the
 * ACTIVE key ring only when the roster names it, and `.slug` is named by
 * `slugKeyId` alone. `createTeam` seeds it `null` and, before this callable,
 * nothing anywhere wrote it — so every joiner's slug envelope landed PENDING,
 * the client's retained-key reader (ACTIVE half only) never saw it, and no
 * member but the founder could derive a single team document id.
 *
 * Its own file, not another block in `teamRoster.test.ts`: that file is at the
 * lint ceiling, and these cases are one coherent claim — the fingerprint is
 * written once by an admin, the same value again is a no-op, and a DIFFERENT
 * one is refused for ever because it would orphan the whole team space.
 *
 * WRITE-ONCE IS A TRANSACTIONAL CLAIM, not a snapshot one (Cursor security
 * round, MEDIUM, `teamSlugKeyRecord.ts:91`). The refusal used to be decided on
 * a snapshot taken BEFORE the guarded commit, and `commitGuardedByTeamState`
 * aborts only when the key state or the membership epoch moves — never when
 * `slugKeyId` itself is written. Two founding Macs could therefore both read an
 * empty field and both merge, making the field that NAMES every team-memory
 * document last-writer-wins. The last three cases below drive that window.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

import { SLUG_KEY_ID_PATTERN, recordTeamSlugKeyId } from "../teamSlugKeyRecord.js";
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

const SLUG_KEY_ID = `v1_${"a1b2c3d4".repeat(4)}`;
const OTHER_SLUG_KEY_ID = `v1_${"f0e1d2c3".repeat(4)}`;
const TEAM_PATH = `team_rosters/${TEAM_ID}`;

function patch(path: string, fields: Record<string, unknown>): void {
  seed(path, { ...storedDoc(path), ...fields });
}

/** Land `effect` in the first guard window this call opens (see teamRosterRaces.test.ts). */
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

function seedFoundingAdmin(): void {
  seedTeam();
  seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
}

beforeEach(() => {
  rosterHarness.store.clear();
  rosterHarness.users.clear();
  rosterHarness.stats.transactions = 0;
  rosterHarness.stats.onTransaction = null;
  rosterHarness.stats.onBatchCommit = null;
});

describe("team slug key record", () => {
  it("test_the_founding_slug_key_fingerprint_is_recorded_for_every_member", async () => {
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });

    const result = await recordTeamSlugKeyId(ADMIN_UID, TEAM_ID, SLUG_KEY_ID);

    expect(result).toEqual({ teamId: TEAM_ID, slugKeyId: SLUG_KEY_ID, alreadyRecorded: false });
    expect(storedDoc(`team_rosters/${TEAM_ID}`)).toMatchObject({
      slugKeyId: SLUG_KEY_ID,
      // It says which key NAMES documents and nothing about which key SEALS
      // them, so it must not move the key state.
      activeKeyVersion: 1,
      retainedKeyVersions: [1],
    });
    expect(auditActions()).toContain("slug_key_recorded");
  });

  it("test_recording_the_same_fingerprint_again_is_a_no_op", async () => {
    // The founder's recovery presses the same button: the client re-runs the
    // whole idempotent bootstrap, which reaches this call with the SAME
    // fingerprint. It has to be a no-op rather than a refusal, or the one
    // recovery path the UI offers would fail on its second use.
    seedTeam({ slugKeyId: SLUG_KEY_ID });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });

    const result = await recordTeamSlugKeyId(ADMIN_UID, TEAM_ID, SLUG_KEY_ID);

    expect(result).toEqual({ teamId: TEAM_ID, slugKeyId: SLUG_KEY_ID, alreadyRecorded: true });
    expect(rosterHarness.stats.transactions).toBe(0);
    expect(auditActions()).not.toContain("slug_key_recorded");
  });

  it("test_a_second_different_fingerprint_is_refused_for_ever", async () => {
    // The slug key NAMES every document this team will ever have and does not
    // rotate. A second, different one means a second founding — which would
    // address the whole space somewhere else and orphan everything already
    // written. There is no state in which accepting it is right.
    seedTeam({ slugKeyId: SLUG_KEY_ID });
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });

    const refused = await caught(() => recordTeamSlugKeyId(ADMIN_UID, TEAM_ID, OTHER_SLUG_KEY_ID));

    expect(refused.code).toBe("failed-precondition");
    // The reason, not the English, is what the Mac app switches on (D16 / P22).
    expect(refused.details).toEqual({ reason: "DIFFERENT_SLUG_KEY_RECORDED" });
    expect(refused.message).toMatch(/already records a different document-naming key/u);
    expect(storedDoc(`team_rosters/${TEAM_ID}`)).toMatchObject({ slugKeyId: SLUG_KEY_ID });
    expect(auditActions()).not.toContain("slug_key_recorded");
  });

  it("test_only_an_active_admin_may_record_it", async () => {
    // The field is read by every member's key pickup to decide which slot is
    // the team's real one, so writing it is an admin authority like every other
    // roster mutation.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    seedMember(MEMBER_UID, { role: "member", escrowDeviceFingerprints: [DEVICE] });

    const byMember = await caught(() => recordTeamSlugKeyId(MEMBER_UID, TEAM_ID, SLUG_KEY_ID));
    expect(byMember.code).toBe("permission-denied");
    const byOutsider = await caught(() => recordTeamSlugKeyId(OUTSIDER_UID, TEAM_ID, SLUG_KEY_ID));
    expect(byOutsider.code).toBe("permission-denied");
    expect(storedDoc(`team_rosters/${TEAM_ID}`).slugKeyId).toBe(null);
  });

  it("test_a_rotation_landing_mid_flight_aborts_the_record", async () => {
    // Same guard every other roster write commits under: the team document is
    // re-read inside the writing transaction, so a decision computed against a
    // stale snapshot is refused rather than committed.
    seedTeam();
    seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
    rosterHarness.stats.onTransaction = () => {
      rosterHarness.store.set(`team_rosters/${TEAM_ID}`, {
        ...storedDoc(`team_rosters/${TEAM_ID}`),
        activeKeyVersion: 2,
        retainedKeyVersions: [1, 2],
      });
    };

    const aborted = await caught(() => recordTeamSlugKeyId(ADMIN_UID, TEAM_ID, SLUG_KEY_ID));

    expect(aborted.code).toBe("aborted");
    expect(storedDoc(`team_rosters/${TEAM_ID}`).slugKeyId).toBe(null);
  });

  it("test_a_second_founding_landing_mid_flight_cannot_overwrite_the_first", async () => {
    // THE MEDIUM. Two Macs of the same account founding at once both read an
    // empty `slugKeyId`; the loser then merges over the winner. The guarded
    // commit does not save this on its own — it aborts on `activeKeyVersion`,
    // the retained/burned lists and `membershipEpoch`, none of which the
    // winner's write moves — so the write-once decision has to be re-made on
    // the team document THIS transaction read.
    seedFoundingAdmin();
    raceOnce(() => patch(TEAM_PATH, { slugKeyId: OTHER_SLUG_KEY_ID, updatedAt: "the-other-mac" }));

    const refused = await caught(() => recordTeamSlugKeyId(ADMIN_UID, TEAM_ID, SLUG_KEY_ID));

    expect(refused.code).toBe("failed-precondition");
    // The same distinct reason the sequential refusal carries: one cause, one
    // code, whether the rival founding landed a minute ago or mid-transaction.
    expect(refused.details).toEqual({ reason: "DIFFERENT_SLUG_KEY_RECORDED" });
    // Exactly one fingerprint survives, and it is the one that got there first.
    expect(storedDoc(TEAM_PATH)).toMatchObject({ slugKeyId: OTHER_SLUG_KEY_ID, updatedAt: "the-other-mac" });
    expect(auditActions()).not.toContain("slug_key_recorded");
  });

  it("test_the_same_fingerprint_landing_mid_flight_is_still_a_no_op", async () => {
    // The other half of the semantics, and the reason this is a compare-and-set
    // rather than a movement guard: the founder's "Finish Setting Up Keys"
    // recovery re-runs the whole idempotent bootstrap, so its OWN earlier pass
    // landing inside the window must succeed as a no-op, not abort.
    seedFoundingAdmin();
    raceOnce(() => patch(TEAM_PATH, { slugKeyId: SLUG_KEY_ID }));

    const result = await recordTeamSlugKeyId(ADMIN_UID, TEAM_ID, SLUG_KEY_ID);

    expect(result).toEqual({ teamId: TEAM_ID, slugKeyId: SLUG_KEY_ID, alreadyRecorded: true });
    expect(storedDoc(TEAM_PATH)).toMatchObject({ slugKeyId: SLUG_KEY_ID });
    // A no-op writes nothing at all, audit row included.
    expect(auditActions()).not.toContain("slug_key_recorded");
  });

  it("test_two_concurrent_foundings_leave_exactly_one_fingerprint", async () => {
    // The same race with no hook at all: two real calls in flight together,
    // both reading the empty field before either commits, serialised only by
    // the transaction queue the way Firestore serialises a contended document.
    seedFoundingAdmin();

    const settled = await Promise.allSettled([
      recordTeamSlugKeyId(ADMIN_UID, TEAM_ID, SLUG_KEY_ID),
      recordTeamSlugKeyId(ADMIN_UID, TEAM_ID, OTHER_SLUG_KEY_ID),
    ]);

    const winners = settled.filter((entry) => entry.status === "fulfilled");
    expect(winners).toHaveLength(1);
    const loser = settled.find((entry) => entry.status === "rejected");
    expect(loser?.status === "rejected" && loser.reason.details).toEqual({ reason: "DIFFERENT_SLUG_KEY_RECORDED" });

    // The surviving fingerprint is the winner's, and it is the only one the
    // roster ever names — a joiner activating a slug envelope against it can
    // only be activating it against the founding key that actually won.
    const survivor = winners[0];
    const recorded = survivor?.status === "fulfilled" ? survivor.value.slugKeyId : null;
    expect(storedDoc(TEAM_PATH).slugKeyId).toBe(recorded);
    expect(auditActions().filter((action) => action === "slug_key_recorded")).toHaveLength(1);
  });

  it("test_the_fingerprint_shape_admits_only_a_vault_key_id", async () => {
    // A DIGEST, NOT A KEY. The pattern is exactly `CloudVaultCrypto.vaultKeyID`'s
    // output — `"v1_" + sha256hex(key)[:32]` — so the field cannot carry key
    // material, and cannot be used to smuggle arbitrary bytes into a document
    // every member of the team reads.
    expect(SLUG_KEY_ID_PATTERN.test(SLUG_KEY_ID)).toBe(true);
    expect(SLUG_KEY_ID_PATTERN.test(`v1_${"a".repeat(31)}`)).toBe(false);
    expect(SLUG_KEY_ID_PATTERN.test(`v1_${"a".repeat(33)}`)).toBe(false);
    expect(SLUG_KEY_ID_PATTERN.test(`v2_${"a".repeat(32)}`)).toBe(false);
    expect(SLUG_KEY_ID_PATTERN.test(`v1_${"A".repeat(32)}`)).toBe(false);
    expect(SLUG_KEY_ID_PATTERN.test(Buffer.alloc(32, 7).toString("base64"))).toBe(false);
  });
});
