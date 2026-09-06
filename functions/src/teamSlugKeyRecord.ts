/**
 * @fileoverview The founding `teamSlugKey` fingerprint on the team roster
 * (memory program D16 — the write the design assigned to PR 4 and PR 4 did not
 * ship).
 *
 * WHY THIS ONE FIELD DECIDES WHETHER TEAM MEMORY WORKS FOR ANYONE BUT ITS
 * FOUNDER. The B6 ruling makes the client's key pickup
 * (`TeamVaultKeyDistributor.loadKeyRingFromEnvelopes`) promote an
 * envelope-sourced slot to the ACTIVE key ring only when the roster names it —
 * `activeKeyVersion`, a member of `retainedKeyVersions`, or `.slug` **once
 * `slugKeyId` is a non-empty string**. `createTeam` seeds it `null` and nothing
 * anywhere ever wrote it, so a joiner's slug envelope landed PENDING, the
 * client's retained-key reader sees only the ACTIVE half, and no member but the
 * founder could derive a single team document id. The lane looked implemented
 * and could not reach a second person.
 *
 * ITS ONE REFUSAL CARRIES A REASON, like every other refusal this lane decides
 * (`./teamRosterReasons.ts`): a second, different fingerprint raises
 * `DIFFERENT_SLUG_KEY_RECORDED` rather than a bare `failed-precondition` whose
 * only distinguishing feature is its English. That refusal is decided INSIDE
 * the transaction that writes — the movement guard every roster write commits
 * under does not fire on a write-once field being filled, so a snapshot taken
 * before the commit is not an authority two concurrent founders can share.
 *
 * ITS OWN MODULE, not another method on `TeamRosterService`: `teamRoster.ts` is
 * at the 600-line lint ceiling, which is also why the rotation-completion marker
 * has its own test file. Everything here goes through the same exported roster
 * primitives every other mutation uses — the active-admin assertion, the guarded
 * commit and the audit log — so there is no second authority model to keep in
 * step.
 */
import { FieldValue } from "firebase-admin/firestore";

import { db } from "./adminRuntime.js";
import { TeamRosterService } from "./teamRoster.js";
import { TEAM_ROSTER_REASON as REASON, rosterError } from "./teamRosterReasons.js";
import { auditEvent, auditRef, commitGuardedByTeamState, readTeam } from "./teamRosterState.js";

/**
 * The shape `CloudVaultCrypto.vaultKeyID` produces: `"v1_" + sha256hex(key)[:32]`.
 *
 * PUBLISHABLE, AND ONLY BECAUSE IT IS A DIGEST. `slugKeyId` is a fingerprint of
 * `teamSlugKey`, never the key: it lets a client notice it holds the WRONG slug
 * key — and lets `loadKeyRingFromEnvelopes` tell "the team published a slug key"
 * from "an envelope claims one" — without the server learning a single key byte.
 * The pattern is pinned rather than merely length-bounded so the field cannot be
 * used to smuggle arbitrary bytes into a document every member reads.
 */
export const SLUG_KEY_ID_PATTERN = /^v1_[0-9a-f]{32}$/u;

/**
 * The fingerprint this roster document records, with every "unset" shape — an
 * absent field, `createTeam`'s seeded `null`, an empty string — flattened to
 * `""`. One reader, used by the cheap pre-check and by the transactional
 * compare-and-set below, so the two can never disagree about what "unrecorded"
 * means.
 */
function recordedSlugKeyId(raw: FirebaseFirestore.DocumentData | undefined): string {
  const value = raw?.slugKeyId;
  return typeof value === "string" ? value : "";
}

/** The one refusal a second, DIFFERENT founding raises, wherever it is caught. */
function refuseSecondFounding(): never {
  throw rosterError(
    REASON.DIFFERENT_SLUG_KEY_RECORDED,
    "This team already records a different document-naming key. A second one would orphan every memory it has.",
  );
}

/**
 * Record the founding `teamSlugKey`'s fingerprint on the roster.
 *
 * WRITE-ONCE, AND THE REFUSAL IS THE POINT. The slug key NAMES every document
 * this team will ever have; it does not rotate and there is exactly one of it
 * per team. A second, different fingerprint would mean a second founding —
 * which would address the whole team space somewhere else and orphan everything
 * already written. Recording the SAME value again is a no-op, so the founder's
 * retry (the Settings "Finish Setting Up Keys" action re-runs the whole
 * idempotent bootstrap and reaches this call again) succeeds rather than
 * refusing; recording a different one is `failed-precondition`, for ever.
 *
 * WRITE-ONCE IS DECIDED INSIDE THE TRANSACTION THAT WRITES (Cursor security
 * round, MEDIUM). The check below the admin assertion is a CHEAP PRE-CHECK, not
 * the authority: it reads a snapshot taken before the commit, and
 * `commitGuardedByTeamState`'s movement guard aborts only when the key state or
 * the membership epoch moves — a field going from unset to set moves neither.
 * Two Macs of the same account founding at once (the very case this PR's
 * bootstrap makes reachable) could therefore both see an empty field and both
 * merge, leaving the field that names every team-memory document
 * last-writer-wins: joiners would activate slug envelopes against whichever
 * fingerprint landed last while the other founding key addressed a different
 * document space. `decideOnFreshTeam` re-reads the field on the document the
 * writing transaction itself read and re-decides there, so the loser is refused
 * with the SAME distinct reason rather than overwriting the winner.
 *
 * Admin-only, and committed under the same team-state guard as every other
 * roster write, so a rotation landing in the window aborts this rather than
 * stamping a decision computed against a stale snapshot.
 */
export async function recordTeamSlugKeyId(
  callerUid: string,
  teamId: string,
  slugKeyId: string,
): Promise<{ teamId: string; slugKeyId: string; alreadyRecorded: boolean }> {
  await TeamRosterService.assertActiveAdmin(callerUid, teamId);

  const teamRef = db.doc(`team_rosters/${teamId}`);
  const snapshot = (await teamRef.get()).data();
  const team = readTeam(snapshot, teamId);
  const alreadyRecorded = recordedSlugKeyId(snapshot);
  if (alreadyRecorded !== "") {
    if (alreadyRecorded === slugKeyId) {
      return { teamId, slugKeyId, alreadyRecorded: true };
    }
    refuseSecondFounding();
  }

  const now = FieldValue.serverTimestamp();
  const { committed } = await commitGuardedByTeamState({
    teamId,
    expected: team,
    // THE AUTHORITY. Same three outcomes as the pre-check, re-decided on the
    // team document this transaction read: write it, stand down because the
    // same fingerprint is already there, or refuse a second founding.
    decideOnFreshTeam: (fresh) => {
      const recorded = recordedSlugKeyId(fresh);
      if (recorded === "") return "commit";
      if (recorded === slugKeyId) return "skip";
      return refuseSecondFounding();
    },
    writes: [
      {
        ref: teamRef,
        merge: true,
        data: { slugKeyId, updatedAt: now },
      },
      {
        ref: auditRef(teamId),
        merge: false,
        data: auditEvent({
          teamId,
          action: "slug_key_recorded",
          actorUid: callerUid,
          detail: { slugKeyId },
        }),
      },
    ],
  });

  return { teamId, slugKeyId, alreadyRecorded: !committed };
}
