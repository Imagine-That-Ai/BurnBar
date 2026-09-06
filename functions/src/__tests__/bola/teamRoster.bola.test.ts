/**
 * BOLA proofs for the team roster authority (D16 / P21).
 *
 * The victim tenant is a team Bob administers. Alice is a signed-in stranger
 * who names Bob's teamId — and, where the callable takes one, Bob's uid — in
 * her payload. Every callable must refuse with `permission-denied` because the
 * roster has no ACTIVE row for her, and Bob's roster rows must be byte
 * identical afterwards.
 */
import { describe, it, vi } from "vitest";

import { BOB_UID, callableRunner, pathKeyedFirestore, tier2CallableProof } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map<string, Record<string, unknown>>());
vi.mock("../../adminRuntime.js", () => ({
  db: pathKeyedFirestore(bolaStore),
  auth: {
    // Never reached: the roster check runs before any directory lookup. If it
    // ever were reached, resolving the victim would be the bug under test.
    getUserByEmail: vi.fn(async () => {
      throw new Error("the roster authority must refuse before resolving a directory entry");
    }),
  },
}));
vi.mock("../../callables/publicRateLimit.js", () => ({
  checkTeamRosterMutationRateLimit: vi.fn(async () => undefined),
  checkTeamInviteRateLimit: vi.fn(async () => undefined),
  checkTeamInviteAcceptRateLimit: vi.fn(async () => undefined),
}));

/** Matches PROBE.teamId in functions/scripts/generate-bola-victim-seeds.mjs. */
const VICTIM_TEAM_ID = "team_bbbbbbbbbbbbbbbb";
const CROSS_TENANT_DENIAL = "permission-denied";

export const BOLA_MANIFEST = {
  inviteTeamMember: ["inviteTeamMember rejects cross-user object access"],
  acceptTeamInvite: ["acceptTeamInvite rejects cross-user object access"],
  promoteTeamMember: ["promoteTeamMember rejects cross-user object access"],
  removeTeamMember: ["removeTeamMember rejects cross-user object access"],
  rotateTeamKey: ["rotateTeamKey rejects cross-user object access"],
  abandonTeamKeyGeneration: ["abandonTeamKeyGeneration rejects cross-user object access"],
} as const;

async function teamRosterCallables() {
  return import("../../callables/teamRosterCallables.js");
}

describe("BOLA - team roster authority", () => {
  it("inviteTeamMember rejects cross-user object access", async () => {
    const mod = await teamRosterCallables();
    await tier2CallableProof(bolaStore, {
      exportedName: "inviteTeamMember",
      run: callableRunner(mod.inviteTeamMember),
      expectedOutcome: "throws",
      payload: { teamId: VICTIM_TEAM_ID, inviteeEmail: "victim@example.test", role: "admin" },
    });
  });

  it("acceptTeamInvite rejects cross-user object access", async () => {
    const mod = await teamRosterCallables();
    await tier2CallableProof(bolaStore, {
      exportedName: "acceptTeamInvite",
      run: callableRunner(mod.acceptTeamInvite),
      expectedOutcome: "throws",
      // `email_verified` is asserted so the refusal comes from the INVITE
      // BINDING, not from `acceptInvite`'s cheaper first line (PR1 review F10).
      tokenClaims: { email_verified: true },
      // A token that WAS issued — to Bob. `generate-bola-victim-seeds.mjs`
      // seeds `team_rosters/{VICTIM_TEAM_ID}/invites/sha256(this token)` with
      // `inviteeUid: BOB_UID`, so the call gets past `!inviteSnap.exists` and
      // is refused by the `inviteeUid !== callerUid` comparison this proof is
      // named for (PR1 review N-6). Keep this literal in sync with
      // `PROBE.inviteToken` in that generator. No `expiresAt` is seeded, so a
      // weakened uid comparison would fall through to the expiry check and
      // fail this proof with `failed-precondition` instead of passing.
      payload: { teamId: VICTIM_TEAM_ID, inviteToken: `inv_${"a".repeat(40)}` },
    });
  });

  it("promoteTeamMember rejects cross-user object access", async () => {
    const mod = await teamRosterCallables();
    await tier2CallableProof(bolaStore, {
      exportedName: "promoteTeamMember",
      run: callableRunner(mod.promoteTeamMember),
      expectedOutcome: "throws",
      payload: { teamId: VICTIM_TEAM_ID, uid: BOB_UID, envelopeIds: [] },
    });
  });

  it("removeTeamMember rejects cross-user object access", async () => {
    const mod = await teamRosterCallables();
    await tier2CallableProof(bolaStore, {
      exportedName: "removeTeamMember",
      run: callableRunner(mod.removeTeamMember),
      expectedOutcome: "throws",
      // Evicting the victim team's only admin would be the worst outcome here.
      payload: { teamId: VICTIM_TEAM_ID, targetUid: BOB_UID },
    });
  });

  it("rotateTeamKey rejects cross-user object access", async () => {
    const mod = await teamRosterCallables();
    await tier2CallableProof(bolaStore, {
      exportedName: "rotateTeamKey",
      run: callableRunner(mod.rotateTeamKey),
      expectedOutcome: "throws",
      expectedCode: CROSS_TENANT_DENIAL,
      payload: { teamId: VICTIM_TEAM_ID, newKeyVersion: 2, envelopeIds: [] },
    });
  });

  it("abandonTeamKeyGeneration rejects cross-user object access", async () => {
    const mod = await teamRosterCallables();
    await tier2CallableProof(bolaStore, {
      exportedName: "abandonTeamKeyGeneration",
      run: callableRunner(mod.abandonTeamKeyGeneration),
      expectedOutcome: "throws",
      expectedCode: CROSS_TENANT_DENIAL,
      // Burning the victim team's next key version would leave them unable to
      // rotate to it — a denial of their revocation primitive, from outside.
      payload: { teamId: VICTIM_TEAM_ID, version: 2 },
    });
  });
});
