/**
 * @fileoverview Firestore background triggers for OpenBurnBar.
 *
 * The usage-document trigger is intentionally lightweight: it only marks the
 * user's rollup job as dirty.  All heavy computation happens in scheduled
 * workers to keep trigger latency bounded and costs predictable.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { getFirestore } from "firebase-admin/firestore";
import type { RollupJobDoc } from "./types.js";

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

    // Conditional write: only flip dirty if not already dirty.
    // This reduces Firestore write volume for burst ingestion.
    const snap = await jobRef.get();
    const existing = snap.exists ? (snap.data() as RollupJobDoc) : null;
    if (existing?.dirty) {
      return; // Already queued.
    }

    const now = new Date().toISOString();
    const update: Partial<RollupJobDoc> = {
      dirty: true,
      dirtiedAt: now,
    };

    await jobRef.set(update, { merge: true });
  }
);
