/**
 * @fileoverview Team roster state plumbing: the team document, the audit row,
 * and the two commit shapes the roster authority is allowed to use (D16 / P21).
 *
 * `teamRoster.ts` owns the POLICY — who may invite, promote, remove, rotate.
 * This module owns the MECHANISM those decisions commit through, because every
 * roster decision in that file is a read-then-write and the window between the
 * two is where this lane's races live:
 *
 *  - {@link commitChunked} is the unguarded path, for writes whose correctness
 *    does not depend on state read earlier (an invite, a team creation).
 *  - {@link commitGuardedByTeamState} is the guarded path. It re-reads the team
 *    document inside the transaction that writes, and refuses if the state the
 *    caller's decision was computed against has moved — the KEY state
 *    (`activeKeyVersion` / `retainedKeyVersions`, PR1 review N-4) and now also
 *    the MEMBERSHIP state (`membershipEpoch`, Cursor round thread
 *    `teamRoster.ts:747`). It can additionally re-read one member row and
 *    require it to still be `pending`, which is what stops a promotion from
 *    resurrecting a member a concurrent removal just evicted (Cursor round
 *    thread `teamRoster.ts:674`).
 *
 * `membershipEpoch` is a monotonic counter on the team document, bumped by
 * every callable that adds to or removes from the ACTIVE member set. Firestore
 * cannot conflict-detect a query, so a rotation that snapshots the active
 * roster has no read whose invalidation would tell it that a promotion landed
 * behind its back. The epoch is that read: rotation captures it with the
 * snapshot and commits under it, so a promotion inside the window aborts the
 * rotation instead of publishing a generation the new member has no wrap for.
 *
 * Types here are deliberately module-private. `teamRoster.ts` derives the two
 * it needs from these functions' signatures, so the two ends cannot drift and
 * the hand-maintained exported-schema budget is untouched.
 */

import { randomUUID } from "node:crypto";

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { db } from "./adminRuntime.js";

export const TEAM_ROSTER_SCHEMA_VERSION = 1;
/** Firestore batches cap at 500 writes; leave headroom for the roster + audit row. */
const ROSTER_BATCH_CHUNK = 400;

interface TeamDocument {
  teamId: string;
  name: string;
  activeKeyVersion: number;
  /** Every key version a joiner must still be able to open. Append-only. */
  retainedKeyVersions: number[];
  /**
   * Key versions an admin minted, published envelopes for, and abandoned before
   * `rotateTeamKey` ever recorded them. Append-only, server-written only, and
   * skipped by {@link nextRotatableKeyVersion} — see `abandonKeyGeneration` in
   * `./teamRoster.ts` for why a team otherwise cannot rotate at all once one
   * generation is burned.
   */
  burnedKeyVersions: number[];
  /** Opaque fingerprint of the non-rotating slug key; the server never sees the key. */
  slugKeyId: string | null;
  keyRotationRequired: boolean;
  /** Bumped on every change to the ACTIVE member set. See the file header. */
  membershipEpoch: number;
  createdBy: string;
  schemaVersion: number;
  createdAt: Timestamp | FieldValue;
  updatedAt: Timestamp | FieldValue;
}

interface PendingWrite {
  ref: FirebaseFirestore.DocumentReference;
  data: Record<string, unknown>;
  merge: boolean;
}

type TeamAuditAction =
  | "team_created"
  | "member_invited"
  | "invite_accepted"
  | "member_promoted"
  | "member_removed"
  | "key_rotated"
  | "key_generation_abandoned";

/**
 * The team's membership epoch, defaulting to 0 for anything that is not a
 * finite number.
 *
 * Exported because `removeMember` must bump the epoch WITHOUT going through
 * {@link readTeam}: eviction is the one roster mutation that has to keep
 * working on a team document whose key state is malformed, or a bad team
 * document becomes the very freeze this guard exists to prevent.
 */
export function readMembershipEpoch(raw: FirebaseFirestore.DocumentData | undefined): number {
  const value = raw?.membershipEpoch;
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

/** Whole key versions >= 1, in the order the roster stored them. */
function readKeyVersionList(raw: unknown): number[] {
  return Array.isArray(raw)
    ? raw.filter((value): value is number => typeof value === "number" && Number.isInteger(value) && value >= 1)
    : [];
}

/**
 * The next generation a rotation may mint: the first version after the active
 * one that has NOT been burned.
 *
 * A burned version is one an admin minted, published envelopes for, and
 * abandoned; its envelope ids are occupied by wraps of a key only that admin
 * holds, and envelopes are create-only and immutable. Without this skip, the one
 * version the strict-sequence rule allows is the one nobody can complete, and
 * the team loses its ability to rotate — which is its ability to revoke a
 * departed member. `TeamVaultKeyDistributor.nextRotatableKeyVersion` computes
 * the same number client side so a rotation knows which version it is minting
 * before it wraps anything; THIS one is the authority.
 */
export function nextRotatableKeyVersion(team: { activeKeyVersion: number; burnedKeyVersions: number[] }): number {
  const burned = new Set(team.burnedKeyVersions);
  let candidate = team.activeKeyVersion + 1;
  while (burned.has(candidate)) candidate += 1;
  return candidate;
}

export function readTeam(raw: FirebaseFirestore.DocumentData | undefined, teamId: string): TeamDocument {
  if (!raw) {
    throw new HttpsError("not-found", "Team not found.");
  }
  const activeKeyVersion = typeof raw.activeKeyVersion === "number" ? raw.activeKeyVersion : 0;
  const retained = readKeyVersionList(raw.retainedKeyVersions);
  if (activeKeyVersion < 1 || retained.length === 0) {
    throw new HttpsError("failed-precondition", "Team roster is missing its key state.");
  }
  return {
    teamId,
    name: typeof raw.name === "string" ? raw.name : "",
    activeKeyVersion,
    retainedKeyVersions: retained,
    burnedKeyVersions: readKeyVersionList(raw.burnedKeyVersions),
    slugKeyId: typeof raw.slugKeyId === "string" ? raw.slugKeyId : null,
    keyRotationRequired: raw.keyRotationRequired === true,
    membershipEpoch: readMembershipEpoch(raw),
    createdBy: typeof raw.createdBy === "string" ? raw.createdBy : "",
    schemaVersion: typeof raw.schemaVersion === "number" ? raw.schemaVersion : TEAM_ROSTER_SCHEMA_VERSION,
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
  };
}

export function auditRef(teamId: string): FirebaseFirestore.DocumentReference {
  return db.doc(`team_rosters/${teamId}/audit_log/${randomUUID().replace(/-/gu, "")}`);
}

export function auditEvent(options: {
  teamId: string;
  action: TeamAuditAction;
  actorUid: string;
  targetUid?: string;
  detail?: Record<string, unknown>;
}): Record<string, unknown> {
  return {
    teamId: options.teamId,
    action: options.action,
    actorUid: options.actorUid,
    targetUid: options.targetUid ?? null,
    detail: options.detail ?? {},
    schemaVersion: TEAM_ROSTER_SCHEMA_VERSION,
    at: FieldValue.serverTimestamp(),
  };
}

/**
 * Commit `writes` in chunks of {@link ROSTER_BATCH_CHUNK}. A single
 * `db.batch()` dies at 500 writes, which on a large team turns a rotation into
 * a hard failure exactly when the roster most needs to move.
 */
export async function commitChunked(writes: PendingWrite[]): Promise<void> {
  for (let index = 0; index < writes.length; index += ROSTER_BATCH_CHUNK) {
    const batch = db.batch();
    for (const write of writes.slice(index, index + ROSTER_BATCH_CHUNK)) {
      if (write.merge) {
        batch.set(write.ref, write.data, { merge: true });
      } else {
        batch.set(write.ref, write.data);
      }
    }
    await batch.commit();
  }
}

/** The team state a roster decision was computed against. */
interface TeamGuardState {
  activeKeyVersion: number;
  retainedKeyVersions: number[];
  /**
   * Guarded too, because it decides which version a rotation is allowed to mint
   * (see {@link nextRotatableKeyVersion}). An `abandonTeamKeyGeneration` landing
   * inside a rotation's window moves that target, so the rotation must abort and
   * recompute rather than record a generation nobody agreed on.
   */
  burnedKeyVersions: number[];
  membershipEpoch: number;
}

function listMoved(fresh: number[], expected: number[]): boolean {
  return fresh.length !== expected.length || fresh.some((value, index) => value !== expected[index]);
}

function teamStateMoved(raw: FirebaseFirestore.DocumentData | undefined, expected: TeamGuardState): boolean {
  if (!raw) return true;
  const activeKeyVersion = typeof raw.activeKeyVersion === "number" ? raw.activeKeyVersion : 0;
  return (
    activeKeyVersion !== expected.activeKeyVersion ||
    readMembershipEpoch(raw) !== expected.membershipEpoch ||
    listMoved(readKeyVersionList(raw.retainedKeyVersions), expected.retainedKeyVersions) ||
    listMoved(readKeyVersionList(raw.burnedKeyVersions), expected.burnedKeyVersions)
  );
}

/**
 * Commit `writes` in one transaction that first RE-READS the team document and
 * refuses if the state the caller decided against has moved.
 *
 * `promoteMember` and `rotateTeamKey` both compute an envelope requirement set
 * from the team's key state AND from a membership snapshot, verify coverage
 * against it with a fan-out of reads, and only then write. Anything that moves
 * either input inside that window makes the decision stale:
 *
 *  - a rotation landing during a promotion promotes against the pre-rotation
 *    retained list, so the member holds no envelope for v(N+1) — active but
 *    blind (N-4);
 *  - a promotion landing during a rotation adds an active member the rotation
 *    never required a wrap for, publishing v(N+1) over their head — the same
 *    invariant, reached through membership instead of key state (Cursor round,
 *    `teamRoster.ts:747`);
 *  - a removal landing during a promotion would otherwise see the promotion's
 *    blind `{status: "active"}` merge resurrect a member with no live invite
 *    (Cursor round, `teamRoster.ts:674`), which `stillPendingMemberRef` closes
 *    by re-reading the row inside the same transaction.
 *
 * All three become an error the caller retries against current state rather
 * than a silently wrong commit.
 */
export async function commitGuardedByTeamState(options: {
  teamId: string;
  expected: TeamGuardState;
  writes: PendingWrite[];
  /** Promotion only: the row that must still be `pending` when the write lands. */
  stillPendingMemberRef?: FirebaseFirestore.DocumentReference;
  /** True when this commit changes the ACTIVE member set. */
  bumpMembershipEpoch?: boolean;
}): Promise<void> {
  const teamRef = db.doc(`team_rosters/${options.teamId}`);
  await db.runTransaction(async (transaction) => {
    const fresh = await transaction.get(teamRef);
    const freshData = fresh.data();
    if (teamStateMoved(freshData, options.expected)) {
      throw new HttpsError(
        "aborted",
        "This team's roster or key state changed while the call was in flight; retry against the current state.",
      );
    }
    if (options.stillPendingMemberRef) {
      const member = await transaction.get(options.stillPendingMemberRef);
      if (!member.exists || member.get("status") !== "pending") {
        throw new HttpsError("failed-precondition", "Only a pending member can be promoted.");
      }
    }
    for (const write of options.writes) {
      if (write.merge) {
        transaction.set(write.ref, write.data, { merge: true });
      } else {
        transaction.set(write.ref, write.data);
      }
    }
    if (options.bumpMembershipEpoch === true) {
      transaction.set(
        teamRef,
        { membershipEpoch: readMembershipEpoch(freshData) + 1, updatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
    }
  });
}
