/**
 * @fileoverview Firestore background triggers for OpenBurnBar.
 *
 * The usage-document trigger maintains compact per-window counter inputs and
 * marks the user's rollup job dirty. Heavy rollup projection still happens in
 * scheduled workers to keep trigger latency bounded and costs predictable.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { getFirestore } from "firebase-admin/firestore";
import { applyUsageCounterDelta } from "./rollups.js";
import type { RollupJobDoc, UsageEventDoc } from "./types.js";

/**
 * Firestore trigger: whenever a usage event is created, updated, or deleted,
 * mark the user's rollup job as dirty so the scheduled worker will rebuild it.
 *
 * We do NOT recompute synchronously to avoid:
 *   - Unbounded trigger latency
 *   - Hot partitions on high-frequency writers
 *   - Runaway Cloud Functions costs
 */
export const onUsageWritten = onDocumentWritten(
  {
    document: "users/{uid}/usage/{usageDoc}",
    region: "us-central1",
    // No App Check enforcement needed for background triggers; they are
    // backend-internal and already authenticated via the service account.
  },
  async (event) => {
    const uid = event.params.uid;
    const db = getFirestore();
    const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
    const before = event.data?.before.exists
      ? (event.data.before.data() as UsageEventDoc)
      : undefined;
    const after = event.data?.after.exists
      ? (event.data.after.data() as UsageEventDoc)
      : undefined;

    // Mark dirty BEFORE attempting the counter delta so that even if the
    // transaction fails (contention, quota, etc.), the scheduled
    // rebuildRollups worker still picks up this user and recomputes from
    // whatever counter state exists.
    const now = new Date().toISOString();
    const snap = await jobRef.get();
    const existing = snap.exists ? (snap.data() as RollupJobDoc) : null;
    if (!existing?.dirty) {
      await jobRef.set({ dirty: true, dirtiedAt: now }, { merge: true });
    }

    try {
      await applyUsageCounterDelta(db, uid, event.params.usageDoc, before, after);
    } catch (err) {
      console.error(
        `Counter delta failed for ${uid}/${event.params.usageDoc}:`,
        err
      );
      await jobRef.set(
        {
          lastErrorCode: (err as Error).message,
        },
        { merge: true }
      );
      // Dirty flag is already set — the scheduled worker will pick this up
      // and fall back to a raw-usage rebuild instead of trusting counters.
      // We intentionally do NOT re-throw: the trigger has done its job
      // (queued the rollup job). Letting it throw would cause unnecessary
      // retries that just re-attempt the same failing transaction.
    }
  }
);
