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
import { errorMessage } from "@openburnbar/functions-shared/guards.js";
import { parseUsageEventDoc } from "./usageEventParse.js";
import { logError } from "@openburnbar/functions-shared/logging.js";
import { runFirestoreTrigger } from "@openburnbar/functions-shared/scheduledOps.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";
import { markRollupJobDirty, type RollupDirtyStore } from "./rollupJobDirty.js";
import type { PendingDeltaStore } from "./rollupPendingDeltas.js";
import type { UsageEventDoc } from "@openburnbar/functions-shared/types.js";

/**
 * Firestore trigger: whenever a usage event is created, updated, or deleted,
 * mark the user's rollup job as dirty so the scheduled worker will rebuild it.
 *
 * We do NOT recompute synchronously to avoid:
 *   - Unbounded trigger latency
 *   - Hot partitions on high-frequency writers
 *   - Runaway Cloud Functions costs
 */
/**
 * Inner usage-written path. Exported so tests drive the shipped trigger
 * logic without wrapping a Cloud Functions event object.
 */
export async function applyUsageWrittenSideEffects(
  db: RollupDirtyStore & PendingDeltaStore,
  uid: string,
  usageDoc: string,
  before: UsageEventDoc | undefined,
  after: UsageEventDoc | undefined,
  nowMs: number = Date.now(),
): Promise<"written" | "coalesced"> {
  const dirtyResult = await markRollupJobDirty(db, uid, nowMs);
  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  try {
    await enqueueUsageCounterDelta(db, uid, usageDoc, before, after);
  } catch (err) {
    logError({
      event: "usage.counter_delta_failed",
      uid,
      usage_doc: usageDoc,
      error: errorMessage(err),
    });
    await jobRef.set(
      {
        lastErrorCode: errorMessage(err),
      },
      { merge: true },
    );
  }
  return dirtyResult;
}

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
      const before = event.data?.before.exists ? parseUsageEventDoc(event.data.before.data()) : undefined;
      const after = event.data?.after.exists ? parseUsageEventDoc(event.data.after.data()) : undefined;
      await applyUsageWrittenSideEffects(db, uid, event.params.usageDoc, before, after);
    }),
);
