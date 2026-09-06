/**
 * Every team-roster refusal reaches the client with its machine-readable reason
 * (memory program D16 / P22 — the structured-reason follow-up).
 *
 * WHAT THESE PROVE, and why it is not the same as the tests next door.
 * `teamRoster.test.ts` proves that each refusal HAPPENS and carries the right
 * gRPC status. This file proves the other half of the contract: that the refusal
 * arrives at a client with `details.reason` set to the one code that names its
 * cause — so the Mac app can switch on it instead of matching English, which is
 * what `TeamJoinerKeyIssueFailure.classify` used to do.
 *
 * THE ASSERTION IS ON `toJSON()`, NOT ON THE THROWN OBJECT. `HttpsError.toJSON`
 * returns the exact wire body the Firebase client SDKs parse — `{status,
 * message, details}` — and the Apple SDK lifts `details` straight out of it into
 * `NSError.userInfo[FunctionsErrorDetailsKey]`. Asserting on the server-side
 * `error.details` field alone would pass even if the value were something JSON
 * could not carry, so the wire body is what each case checks.
 *
 * COMPLETENESS IS ENFORCED, not hoped for: the final test compares the reasons
 * this file exercises against `TEAM_ROSTER_REASON` and fails if the server grew
 * a code nothing drives. `scripts/ci/verify-team-roster-reason-codes.sh` closes
 * the matching gap on the Swift side.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { Timestamp } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { assertActiveBurnBarCloudProEntitlement } from "../callables/shared/entitlements.js";
import { TeamRosterService, requiredTeamKeyEnvelopeIds } from "../teamRoster.js";
import { TEAM_ROSTER_REASON } from "../teamRosterReasons.js";
import {
  ADMIN_UID,
  DEVICE,
  MEMBER_UID,
  OUTSIDER_UID,
  TEAM_ID,
  caught,
  escrowFingerprint,
  rosterHarness,
  seed,
  seedEnvelope,
  seedInvite,
  seedMember,
  seedTeam,
  seedTrustedDevice,
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
const JOINER_UID = "roster-joiner-uid";
const ADMIN_EMAIL = "admin@example.test";
const MEMBER_EMAIL = "member@example.test";
const INVITE_TOKEN = `inv_${"a".repeat(40)}`;

async function callables(): Promise<typeof import("../callables/teamRosterCallables.js")> {
  return import("../callables/teamRosterCallables.js");
}

/** Drive one exported callable the way `onCallProduction` hands it a request. */
async function callCallable(exportedName: string, request: unknown): Promise<unknown> {
  const module: Record<string, unknown> = await callables();
  const callable = module[exportedName];
  if (callable === null || (typeof callable !== "object" && typeof callable !== "function") || !("run" in callable)) {
    throw new Error(`callable ${exportedName} is missing run()`);
  }
  const run = Reflect.get(callable, "run");
  if (typeof run !== "function") throw new Error(`callable ${exportedName} run is not callable`);
  return run.call(callable, request);
}

function authed(data: Record<string, unknown>, uid = ADMIN_UID): Record<string, unknown> {
  return { auth: { uid, token: { email_verified: true } }, data };
}

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

/** An admin who may act, a team that exists, and nothing else. */
function seedAdminTeam(): void {
  seedTeam();
  seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
}

/** A pending joiner with one pinned device — the promotion happy path's precondition. */
function seedPendingJoiner(): void {
  seedAdminTeam();
  seedMember(JOINER_UID, { status: "pending", escrowDeviceFingerprints: [DEVICE] });
  seedTrustedDevice(JOINER_UID);
}

function joinerEnvelopeIds(): Set<string> {
  return new Set(
    requiredTeamKeyEnvelopeIds({ uid: JOINER_UID, devices: [DEVICE], keyVersions: [1], includeSlugKey: true }),
  );
}

/**
 * The slots a JOIN must cover: every retained generation plus the non-rotating
 * slug key. Declared with its type rather than asserted at each loop — the
 * unsafe-cast ratchet (`scripts/debt/check-unsafe-cast-budget.sh`) is assert-zero
 * and counts test sources too.
 */
const JOIN_SLOTS: Array<number | "slug"> = [1, "slug"];

async function promoteJoiner(envelopeIds = joinerEnvelopeIds()): Promise<unknown> {
  return TeamRosterService.promoteMember(ADMIN_UID, TEAM_ID, JOINER_UID, envelopeIds);
}

/**
 * Every reason the roster lane can raise, with a call that actually raises it.
 *
 * One entry per (reason, distinct producing site). Two entries may share a
 * reason where the SAME cause is checked twice — a cheap pre-check and its
 * authoritative re-check inside a transaction — and each is listed so the
 * transactional half cannot silently stop carrying the code.
 */
const REFUSALS: Array<{ name: string; reason: string; run: () => Promise<unknown> }> = [
  // ── Callable payload validation ───────────────────────────────────────────
  {
    name: "an unauthenticated caller",
    reason: TEAM_ROSTER_REASON.UNAUTHENTICATED.reason,
    run: () => callCallable("createTeam", { data: { name: "Core Platform" } }),
  },
  {
    name: "a teamId that is not a team identifier",
    reason: TEAM_ROSTER_REASON.INVALID_TEAM_ID.reason,
    run: () => callCallable("removeTeamMember", authed({ teamId: "team_nope", targetUid: MEMBER_UID })),
  },
  {
    name: "a missing teamId, refused by the shared validator",
    reason: TEAM_ROSTER_REASON.INVALID_TEAM_ID.reason,
    run: () => callCallable("removeTeamMember", authed({ targetUid: MEMBER_UID })),
  },
  {
    name: "a missing team name",
    reason: TEAM_ROSTER_REASON.INVALID_TEAM_NAME.reason,
    run: () => callCallable("createTeam", authed({})),
  },
  {
    name: "a uid that is not an account identifier",
    reason: TEAM_ROSTER_REASON.INVALID_ACCOUNT_ID.reason,
    run: () => callCallable("removeTeamMember", authed({ teamId: TEAM_ID, targetUid: "not a uid" })),
  },
  {
    name: "a role that is neither admin nor member",
    reason: TEAM_ROSTER_REASON.INVALID_ROLE.reason,
    run: () => callCallable("inviteTeamMember", authed({ teamId: TEAM_ID, inviteeEmail: MEMBER_EMAIL, role: "owner" })),
  },
  {
    name: "an invitee address that is not an email",
    reason: TEAM_ROSTER_REASON.INVALID_INVITEE_EMAIL.reason,
    run: () => callCallable("inviteTeamMember", authed({ teamId: TEAM_ID, inviteeEmail: "nope", role: "member" })),
  },
  {
    name: "an envelope id that is not a document id",
    reason: TEAM_ROSTER_REASON.INVALID_ENVELOPE_ID.reason,
    run: () =>
      callCallable("promoteTeamMember", authed({ teamId: TEAM_ID, uid: JOINER_UID, envelopeIds: ["not/an/id"] })),
  },
  {
    name: "an envelopeIds payload that is not an array",
    reason: TEAM_ROSTER_REASON.INVALID_ENVELOPE_IDS.reason,
    run: () =>
      callCallable("promoteTeamMember", authed({ teamId: TEAM_ID, uid: JOINER_UID, envelopeIds: "everything" })),
  },
  {
    name: "a key version outside the range the roster accepts",
    reason: TEAM_ROSTER_REASON.INVALID_KEY_VERSION.reason,
    run: () => callCallable("rotateTeamKey", authed({ teamId: TEAM_ID, newKeyVersion: 9_999, envelopeIds: [] })),
  },
  {
    name: "an invite token of the wrong shape",
    reason: TEAM_ROSTER_REASON.INVALID_INVITE_TOKEN.reason,
    run: () => callCallable("acceptTeamInvite", authed({ teamId: TEAM_ID, inviteToken: "hunter2" }, MEMBER_UID)),
  },
  {
    name: "a rewrap job id that is not a correlation handle",
    reason: TEAM_ROSTER_REASON.INVALID_REWRAP_JOB_ID.reason,
    run: () => callCallable("recordTeamRewrapComplete", authed({ teamId: TEAM_ID, keyVersion: 1, rewrapJobId: "a b" })),
  },

  // ── Caller authority ──────────────────────────────────────────────────────
  {
    name: "a caller with no row on the roster",
    reason: TEAM_ROSTER_REASON.CALLER_NOT_A_TEAM_MEMBER.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.inviteMember(OUTSIDER_UID, TEAM_ID, MEMBER_EMAIL, "member");
    },
  },
  {
    name: "a caller who is a member but not an active admin",
    reason: TEAM_ROSTER_REASON.CALLER_NOT_AN_ACTIVE_ADMIN.reason,
    run: () => {
      seedAdminTeam();
      seedMember(MEMBER_UID);
      return TeamRosterService.inviteMember(MEMBER_UID, TEAM_ID, "someone@example.test", "member");
    },
  },

  // ── The caller's own escrow devices ───────────────────────────────────────
  {
    name: "a founder with no trusted escrow device",
    reason: TEAM_ROSTER_REASON.CALLER_HAS_NO_TRUSTED_ESCROW_DEVICE.reason,
    run: () => TeamRosterService.createTeam(ADMIN_UID, "Core Platform"),
  },
  {
    name: "a founder pinning more devices than may hold team keys",
    reason: TEAM_ROSTER_REASON.CALLER_HAS_TOO_MANY_TRUSTED_DEVICES.reason,
    run: () => {
      for (let index = 0; index < 21; index += 1) {
        seedTrustedDevice(ADMIN_UID, {
          deviceId: `device-${index}`,
          keyVersion: 1,
          publicKeyFingerprint: escrowFingerprint("a"),
        });
      }
      return TeamRosterService.createTeam(ADMIN_UID, "Core Platform");
    },
  },

  // ── Invites ───────────────────────────────────────────────────────────────
  {
    name: "an invitee with no OpenBurnBar account",
    reason: TEAM_ROSTER_REASON.INVITEE_HAS_NO_ACCOUNT.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, "ghost@example.test", "member");
    },
  },
  {
    name: "an admin inviting themselves",
    reason: TEAM_ROSTER_REASON.CANNOT_INVITE_YOURSELF.reason,
    run: () => {
      seedAdminTeam();
      rosterHarness.users.set(ADMIN_EMAIL, { uid: ADMIN_UID });
      return TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, ADMIN_EMAIL, "member");
    },
  },
  {
    name: "an invitee who already holds a live row",
    reason: TEAM_ROSTER_REASON.INVITEE_ALREADY_ON_TEAM.reason,
    run: () => {
      seedAdminTeam();
      seedMember(MEMBER_UID);
      rosterHarness.users.set(MEMBER_EMAIL, { uid: MEMBER_UID });
      return TeamRosterService.inviteMember(ADMIN_UID, TEAM_ID, MEMBER_EMAIL, "member");
    },
  },
  {
    name: "an accepting caller whose email is unverified",
    reason: TEAM_ROSTER_REASON.EMAIL_NOT_VERIFIED.reason,
    run: () => TeamRosterService.acceptInvite(MEMBER_UID, false, TEAM_ID, INVITE_TOKEN),
  },
  {
    name: "an invite token no invite document matches",
    reason: TEAM_ROSTER_REASON.INVITE_NOT_VALID_FOR_ACCOUNT.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, INVITE_TOKEN);
    },
  },
  {
    name: "an invite bound to somebody else's uid",
    reason: TEAM_ROSTER_REASON.INVITE_NOT_VALID_FOR_ACCOUNT.reason,
    run: () => {
      seedAdminTeam();
      seedInvite(MEMBER_UID, INVITE_TOKEN, "member");
      return TeamRosterService.acceptInvite(OUTSIDER_UID, true, TEAM_ID, INVITE_TOKEN);
    },
  },
  {
    name: "an invite that has already been redeemed",
    reason: TEAM_ROSTER_REASON.INVITE_ALREADY_USED.reason,
    run: () => {
      seedAdminTeam();
      seedInvite(MEMBER_UID, INVITE_TOKEN, "member");
      const invitePath = [...rosterHarness.store.keys()].filter((key) => key.includes("/invites/"))[0] ?? "";
      patch(invitePath, { status: "accepted" });
      return TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, INVITE_TOKEN);
    },
  },
  {
    name: "an invite past its expiry",
    reason: TEAM_ROSTER_REASON.INVITE_EXPIRED.reason,
    run: () => {
      seedAdminTeam();
      seedInvite(MEMBER_UID, INVITE_TOKEN, "member");
      const invitePath = [...rosterHarness.store.keys()].filter((key) => key.includes("/invites/"))[0] ?? "";
      patch(invitePath, { expiresAt: Timestamp.fromMillis(Date.now() - 60_000) });
      return TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, INVITE_TOKEN);
    },
  },
  {
    name: "an accepting caller who already holds a live row",
    reason: TEAM_ROSTER_REASON.ALREADY_ON_THIS_TEAM.reason,
    run: () => {
      seedAdminTeam();
      seedInvite(MEMBER_UID, INVITE_TOKEN, "member");
      seedMember(MEMBER_UID);
      return TeamRosterService.acceptInvite(MEMBER_UID, true, TEAM_ID, INVITE_TOKEN);
    },
  },

  // ── Promotion and removal ─────────────────────────────────────────────────
  {
    name: "a promotion target that never accepted an invite",
    reason: TEAM_ROSTER_REASON.MEMBER_HAS_NOT_ACCEPTED_INVITE.reason,
    run: () => {
      seedAdminTeam();
      return promoteJoiner();
    },
  },
  {
    name: "a promotion target that is no longer pending",
    reason: TEAM_ROSTER_REASON.MEMBER_NOT_PENDING.reason,
    run: () => {
      seedPendingJoiner();
      patch(`${TEAM_PATH}/members/${JOINER_UID}`, { status: "active" });
      return promoteJoiner();
    },
  },
  {
    name: "a promotion target removed inside the coverage window",
    reason: TEAM_ROSTER_REASON.MEMBER_NOT_PENDING.reason,
    run: () => {
      seedPendingJoiner();
      for (const slot of JOIN_SLOTS) seedEnvelope(JOINER_UID, slot);
      // The row moves after the pre-check and before the guarded commit, so the
      // refusal comes from `commitGuardedByTeamState`'s in-transaction re-read.
      raceOnce(() => patch(`${TEAM_PATH}/members/${JOINER_UID}`, { status: "removed" }));
      return promoteJoiner();
    },
  },
  {
    name: "a promotion target with no pinned escrow device",
    reason: TEAM_ROSTER_REASON.MEMBER_HAS_NO_TRUSTED_ESCROW_DEVICE.reason,
    run: () => {
      seedAdminTeam();
      seedMember(JOINER_UID, { status: "pending", escrowDeviceFingerprints: [] });
      return promoteJoiner();
    },
  },
  {
    name: "a removal target with no row",
    reason: TEAM_ROSTER_REASON.MEMBER_NOT_FOUND_IN_TEAM.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.removeMember(ADMIN_UID, TEAM_ID, MEMBER_UID);
    },
  },
  {
    name: "a removal that would leave the team with no active admin",
    reason: TEAM_ROSTER_REASON.LAST_ACTIVE_ADMIN.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.removeMember(ADMIN_UID, TEAM_ID, ADMIN_UID);
    },
  },

  // ── Key generations ───────────────────────────────────────────────────────
  {
    name: "burning a key version the roster still records",
    reason: TEAM_ROSTER_REASON.KEY_VERSION_STILL_RECORDED.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 1);
    },
  },
  {
    name: "burning a key version nobody has tried to mint",
    reason: TEAM_ROSTER_REASON.KEY_VERSION_NOT_NEXT_UNCLAIMED.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 5);
    },
  },
  {
    name: "burning a key version no envelope was ever published for",
    reason: TEAM_ROSTER_REASON.NO_ABANDONED_ROTATION_TO_BURN.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.abandonKeyGeneration(ADMIN_UID, TEAM_ID, 2);
    },
  },
  {
    name: "a rotation that skips a generation",
    reason: TEAM_ROSTER_REASON.KEY_VERSION_NOT_SEQUENTIAL.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 7, new Set());
    },
  },
  {
    name: "a rotation past the last supported key version",
    reason: TEAM_ROSTER_REASON.KEY_VERSIONS_EXHAUSTED.reason,
    run: () => {
      seedTeam({ activeKeyVersion: 100, retainedKeyVersions: [100] });
      seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
      return TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 101, new Set());
    },
  },
  {
    name: "a rotation over an active member with no pinned device",
    reason: TEAM_ROSTER_REASON.ACTIVE_MEMBER_HAS_NO_PINNED_DEVICE.reason,
    run: () => {
      seedAdminTeam();
      seedMember(MEMBER_UID, { escrowDeviceFingerprints: [] });
      return TeamRosterService.rotateTeamKey(ADMIN_UID, TEAM_ID, 2, new Set());
    },
  },
  {
    name: "a re-seal completion for a generation that is not current",
    reason: TEAM_ROSTER_REASON.REWRAP_KEY_VERSION_NOT_CURRENT.reason,
    run: () => {
      seedAdminTeam();
      return TeamRosterService.recordRewrapComplete(ADMIN_UID, TEAM_ID, 2, "job-1");
    },
  },

  // ── Envelope coverage ─────────────────────────────────────────────────────
  {
    name: "more envelopes than one call may verify",
    reason: TEAM_ROSTER_REASON.TOO_MANY_KEY_ENVELOPES.reason,
    run: () => {
      seedTeam({ retainedKeyVersions: Array.from({ length: 5_001 }, (_unused, index) => index + 1) });
      seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
      seedMember(JOINER_UID, { status: "pending", escrowDeviceFingerprints: [DEVICE] });
      return promoteJoiner(new Set());
    },
  },
  {
    name: "a promotion that claims none of the envelopes it needs",
    reason: TEAM_ROSTER_REASON.KEY_ENVELOPE_COVERAGE_INCOMPLETE.reason,
    run: () => {
      seedPendingJoiner();
      return promoteJoiner(new Set());
    },
  },
  {
    name: "a claimed envelope that was never published",
    reason: TEAM_ROSTER_REASON.KEY_ENVELOPE_NOT_PUBLISHED.reason,
    run: () => {
      seedPendingJoiner();
      return promoteJoiner();
    },
  },
  {
    name: "an envelope addressed to a different member device",
    reason: TEAM_ROSTER_REASON.KEY_ENVELOPE_ADDRESSED_ELSEWHERE.reason,
    run: () => {
      seedPendingJoiner();
      for (const slot of JOIN_SLOTS) {
        seedEnvelope(JOINER_UID, slot, DEVICE, { deviceId: "some-other-device" });
      }
      return promoteJoiner();
    },
  },
  {
    name: "an envelope wrapped to a key the member never published",
    reason: TEAM_ROSTER_REASON.KEY_ENVELOPE_WRAPPED_TO_UNKNOWN_KEY.reason,
    run: () => {
      seedPendingJoiner();
      for (const slot of JOIN_SLOTS) {
        seedEnvelope(JOINER_UID, slot, DEVICE, { recipientPublicKeyFingerprint: escrowFingerprint("z") });
      }
      return promoteJoiner();
    },
  },
  {
    name: "an envelope published by neither an admin nor its recipient",
    reason: TEAM_ROSTER_REASON.KEY_ENVELOPE_WRAPPER_NOT_AUTHORIZED.reason,
    run: () => {
      seedPendingJoiner();
      for (const slot of JOIN_SLOTS) {
        seedEnvelope(JOINER_UID, slot, DEVICE, { wrappedBy: OUTSIDER_UID });
      }
      return promoteJoiner();
    },
  },

  // ── Team document and in-flight state ─────────────────────────────────────
  {
    name: "a call against a team document that does not exist",
    reason: TEAM_ROSTER_REASON.TEAM_NOT_FOUND.reason,
    run: () => {
      seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
      return TeamRosterService.recordRewrapComplete(ADMIN_UID, TEAM_ID, 1, "job-1");
    },
  },
  {
    name: "a team document carrying no usable key state",
    reason: TEAM_ROSTER_REASON.TEAM_KEY_STATE_MISSING.reason,
    run: () => {
      seedTeam({ activeKeyVersion: 0, retainedKeyVersions: [] });
      seedMember(ADMIN_UID, { role: "admin", escrowDeviceFingerprints: [DEVICE] });
      return TeamRosterService.recordRewrapComplete(ADMIN_UID, TEAM_ID, 1, "job-1");
    },
  },
  {
    name: "roster state that moves between the decision and the commit",
    reason: TEAM_ROSTER_REASON.ROSTER_STATE_MOVED_IN_FLIGHT.reason,
    run: () => {
      seedAdminTeam();
      // A promotion elsewhere bumps the membership epoch inside this call's
      // guard window, so the guarded commit aborts instead of stamping a
      // completion against a roster it never saw.
      raceOnce(() => patch(TEAM_PATH, { membershipEpoch: 7 }));
      return TeamRosterService.recordRewrapComplete(ADMIN_UID, TEAM_ID, 1, "job-1");
    },
  },
];

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

describe("team roster refusal reason codes", () => {
  it.each(REFUSALS)("test_reason_code_reaches_the_client_for_$name", async ({ reason, run }) => {
    const refused = await caught(run);

    // The wire body a Firebase client SDK parses. `details` is what the Apple
    // SDK lifts into `NSError.userInfo["details"]`, which is the field
    // `TeamJoinerKeyIssueFailure.classify` now switches on.
    const wire = refused.toJSON();
    expect(wire.details).toEqual({ reason });

    // And nothing but the reason: an error path is not a place to hand a client
    // fields it did not ask for.
    expect(Object.keys(wire.details ?? {})).toEqual(["reason"]);

    // The status code still matches the one declared alongside the reason, so a
    // client that only knows status codes is unaffected by this change.
    const declared = Object.values(TEAM_ROSTER_REASON).find((entry) => entry.reason === reason);
    expect(refused.code).toBe(declared?.code);

    // The human message is untouched and still says something an operator can
    // act on — it is simply no longer the thing a client parses.
    expect(refused.message.length).toBeGreaterThan(0);
  });

  it("test_every_declared_reason_has_a_call_that_raises_it", () => {
    // A reason nobody can produce is a claim, not a contract — and the Swift
    // mirror would have to carry a case for it. Declared and driven must match.
    const declared = Object.values(TEAM_ROSTER_REASON)
      .map((entry) => entry.reason)
      .sort();
    const driven = [...new Set(REFUSALS.map((refusal) => refusal.reason))].sort();
    expect(driven).toEqual(declared);
  });

  it("test_every_reason_key_equals_the_code_it_declares", () => {
    // The CI mirror gate greps `REASON.<KEY>` to find throw sites and compares
    // the KEYS against the Swift enum's raw values. That only tells the truth
    // while key and value are the same string.
    for (const [key, entry] of Object.entries(TEAM_ROSTER_REASON)) {
      expect(entry.reason).toBe(key);
    }
  });

  it("test_the_swift_mirror_knows_every_reason_this_server_can_send", () => {
    // THE CROSS-LANGUAGE PIN, IN PROCESS. `scripts/ci/verify-team-roster-reason-codes.sh`
    // makes the same comparison as a shell gate wired into the fast-feedback
    // workflow; this one runs wherever the functions tests run, so a server code
    // added without a Swift case fails here too rather than only in the lane
    // somebody might forget to keep wired.
    //
    // Reading the Swift file is the ONLY mechanism available: there is no
    // generated binding for these codes (`tools/schema-sync/` emits Firestore
    // document schemas, not error taxonomies) and the hand-maintained TS surface
    // budget has no headroom for one. `teamRoster.test.ts` already reads a source
    // file this way to pin the callable surface, so this follows that precedent.
    const swiftPath = resolve(__dirname, "../../../AgentLens/Services/CloudSync/TeamRosterDirectory.swift");
    const swift = readFileSync(swiftPath, "utf8");
    const enumBody = /enum TeamRosterReasonCode: String[^{]*\{([\s\S]*?)\n\}/u.exec(swift)?.[1] ?? "";
    expect(enumBody.length).toBeGreaterThan(0);

    const mirrored = [...enumBody.matchAll(/^\s*case [A-Za-z0-9_]+ = "([A-Z_]+)"/gmu)].map((match) => match[1]).sort();
    const declared = Object.values(TEAM_ROSTER_REASON)
      .map((entry) => entry.reason)
      .sort();

    // Both directions: a server code with no Swift case ships as generic copy
    // without anybody noticing, and a Swift case for a code the server no longer
    // raises is a dead branch that reads like a handled one.
    expect(mirrored).toEqual(declared);
  });

  it("test_a_refusal_from_outside_the_lane_is_left_unreasoned", async () => {
    // `withRosterReason` re-labels a bare shared-validator refusal, and MUST
    // leave anything that already carries details alone — otherwise a nested
    // roster refusal would be overwritten by the outer field's reason and the
    // client would be told the wrong cause with full confidence.
    seedAdminTeam();
    seedMember(JOINER_UID, { status: "pending", escrowDeviceFingerprints: [] });
    const refused = await caught(() =>
      callCallable("promoteTeamMember", authed({ teamId: TEAM_ID, uid: JOINER_UID, envelopeIds: [] })),
    );
    expect(refused.toJSON().details).toEqual({
      reason: TEAM_ROSTER_REASON.MEMBER_HAS_NO_TRUSTED_ESCROW_DEVICE.reason,
    });
  });
});
