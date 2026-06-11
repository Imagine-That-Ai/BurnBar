/**
 * @fileoverview Firestore background triggers for OpenBurnBar.
 *
 * The usage-document trigger maintains compact per-window counter inputs and
 * marks the user's rollup job dirty. Heavy rollup projection still happens in
 * scheduled workers to keep trigger latency bounded and costs predictable.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { getFirestore } from "firebase-admin/firestore";
import { enqueueUsageCounterDelta } from "./rollups.js";
import { errorMessage, parseUsageEventDoc } from "./guards.js";
import { logError } from "./logging.js";
import { runFirestoreTrigger } from "./scheduledOps.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

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
    region: FUNCTIONS_REGION,
    // No App Check enforcement needed for background triggers; they are
    // backend-internal and already authenticated via the service account.
  },
  async (event) =>
    runFirestoreTrigger("onUsageWritten", async () => {
      const uid = event.params.uid;
      const db = getFirestore();
      const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
      const before = event.data?.before.exists ? parseUsageEventDoc(event.data.before.data()) : undefined;
      const after = event.data?.after.exists ? parseUsageEventDoc(event.data.after.data()) : undefined;

      // Mark dirty BEFORE enqueueing the counter delta so that even if the
      // enqueue fails (quota, infra, etc.), the scheduled rebuildRollups
      // worker still picks up this user and recomputes from whatever counter
      // state exists. Refresh `dirtiedAt` on EVERY event — not just the
      // false→true transition — so a rebuild that is already mid-compute
      // cannot clear the flag over this event: writeUserRollups only clears
      // `dirty` when `dirtiedAt` is unchanged since compute start.
      const now = new Date().toISOString();
      await jobRef.set({ dirty: true, dirtiedAt: now }, { merge: true });

      try {
        // One append-only queue doc per event — no shared write locks, so
        // session-end sync bursts (up to 400 events per batch commit) no
        // longer serialize on the user's day/all_time counter docs. The
        // 5-minute worker drains the queue with coalesced increments; see
        // drainPendingCounterDeltas in rollups.ts.
        await enqueueUsageCounterDelta(db, uid, event.params.usageDoc, before, after);
      } catch (err) {
        logError({
          event: "usage.counter_delta_failed",
          uid,
          usage_doc: event.params.usageDoc,
          error: errorMessage(err),
        });
        await jobRef.set(
          {
            lastErrorCode: errorMessage(err),
          },
          { merge: true },
        );
        // Dirty flag is already set — the scheduled worker will pick this up
        // and fall back to a raw-usage rebuild instead of trusting counters
        // (a failed enqueue means a lost delta, so the queue cannot repair
        // this event on its own). We intentionally do NOT re-throw: the
        // trigger has done its job (queued the rollup job). Letting it throw
        // would cause unnecessary retries that just re-attempt the same
        // failing write.
      }
    }),
);
