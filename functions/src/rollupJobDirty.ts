/**
 * Coalesced dirty marker for usage rollup jobs.
 *
 * A 400-event sync burst must not become 400 writes to the hot
 * `users/{uid}/rollup_jobs/current` document. Events inside
 * `ROLLUP_DIRTY_COALESCE_MS` of an existing dirty marker reuse it.
 * Events after that window refresh `dirtiedAt` so an in-flight
 * `writeUserRollups` cannot clear dirty over work that arrived mid-compute.
 */

import type { DocumentData } from "firebase-admin/firestore";

export const ROLLUP_DIRTY_COALESCE_MS = 5_000;

type RollupDirtyMarkResult = "written" | "coalesced";

/** Minimal document shape markRollupJobDirty reads inside the transaction. */
interface RollupDirtySnapshot {
  readonly exists: boolean;
  data(): DocumentData | undefined;
}

/** Doc handle the dirty marker reads and writes. */
interface RollupDirtyDocRef {
  get(): Promise<RollupDirtySnapshot>;
  set(data: DocumentData, options?: { merge?: boolean }): Promise<unknown>;
}

/** Minimal Firestore surface markRollupJobDirty exercises: a doc handle with
 * get/set, plus transactional get/set. Real Firestore satisfies this
 * structurally (Firestore is assignable to it), so tests supply fakes typed
 * against it without any assertion casts. */
export interface RollupDirtyStore {
  doc(path: string): RollupDirtyDocRef;
  runTransaction<T>(
    fn: (transaction: {
      get(ref: RollupDirtyDocRef): Promise<RollupDirtySnapshot>;
      set(ref: RollupDirtyDocRef, data: DocumentData, options?: { merge?: boolean }): unknown;
    }) => Promise<T>,
  ): Promise<T>;
}

function dirtiedAtMillis(value: unknown): number | undefined {
  if (typeof value !== "string" || value.length === 0) return undefined;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export async function markRollupJobDirty(
  db: RollupDirtyStore,
  uid: string,
  nowMs: number = Date.now(),
): Promise<RollupDirtyMarkResult> {
  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  return db.runTransaction(async (transaction) => {
    const snap = await transaction.get(jobRef);
    const existing = snap.exists ? snap.data() : undefined;
    const alreadyDirty = existing?.dirty === true;
    const previousMs = dirtiedAtMillis(existing?.dirtiedAt);
    if (
      alreadyDirty &&
      previousMs !== undefined &&
      nowMs - previousMs >= 0 &&
      nowMs - previousMs < ROLLUP_DIRTY_COALESCE_MS
    ) {
      return "coalesced";
    }
    const dirtiedAt = new Date(nowMs).toISOString();
    transaction.set(jobRef, { dirty: true, dirtiedAt }, { merge: true });
    return "written";
  });
}
