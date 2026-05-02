/**
 * @fileoverview Scheduled background workers.
 *
 * Two jobs run on a schedule:
 *   1. rebuildRollups — scans dirty rollup jobs, rebuilds usage_rollups in
 *      bounded batches, and clears dirty markers.
 *   2. refreshAllProviderQuotas — scans active provider connections and
 *      refreshes their quota snapshots in bounded batches.
 *
 * Schedules are defined in `index.ts` where these functions are exported.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore } from "firebase-admin/firestore";
import { getConfig } from "./config.js";
import { computeUserRollups, writeUserRollups } from "./rollups.js";
import { refreshUserProviderQuota } from "./quota.js";
import type { Provider } from "./types.js";

/**
 * Scheduled worker: rebuild dirty usage rollups.
 *
 * Queries the `rollup_jobs` collection group for dirty markers, processes
 * a bounded batch, and clears the marker on success.
 */
export const rebuildRollups = onSchedule(
  {
    schedule: "every 5 minutes",
    region: "us-central1",
    // Use the default compute service account; no special invoker needed.
  },
  async (_event) => {
    const db = getFirestore();
    const { rollupBatchSize } = getConfig();

    // Collection group query for dirty jobs.
    const dirtyQuery = db
      .collectionGroup("rollup_jobs")
      .where("dirty", "==", true)
      .limit(rollupBatchSize);

    const snapshot = await dirtyQuery.get();
    if (snapshot.empty) {
      return;
    }

    // Each doc path: users/{uid}/rollup_jobs/current
    const jobs = snapshot.docs.map((doc) => {
      const parts = doc.ref.path.split("/");
      const uid = parts[1];
      return uid;
    });

    // Deduplicate in case of racing writes.
    const uniqueUids = [...new Set(jobs)];

    for (const uid of uniqueUids) {
      try {
        const rollups = await computeUserRollups(db, uid);
        await writeUserRollups(db, uid, rollups);
      } catch (err) {
        console.error(`Rollup failed for ${uid}:`, err);
        // Mark error so we don't infinitely retry every 5 minutes without
        // backoff.  A simple approach: leave dirty=true but set lastErrorCode.
        const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
        await jobRef.set(
          {
            lastErrorCode: (err as Error).message,
          },
          { merge: true }
        );
      }
    }
  }
);

/**
 * Scheduled worker: refresh provider quotas for all active connections.
 *
 * Iterates over provider_connections documents with status === "connected",
 * refreshes each in a bounded batch, and updates the connection metadata.
 */
export const refreshAllProviderQuotas = onSchedule(
  {
    schedule: "every 15 minutes",
    region: "us-central1",
  },
  async (_event) => {
    const db = getFirestore();
    const { quotaRefreshBatchSize } = getConfig();

    // We cannot filter collectionGroup by a sub-field with a simple query
    // unless we add a composite index.  Instead, query all connections
    // and filter in-memory.  For moderate scale this is fine; at scale
    // shard by status into a top-level collection or use Datastore.
    const connQuery = db
      .collectionGroup("provider_connections")
      .where("status", "==", "connected")
      .limit(quotaRefreshBatchSize);

    const snapshot = await connQuery.get();
    if (snapshot.empty) {
      return;
    }

    for (const doc of snapshot.docs) {
      // Path: users/{uid}/provider_connections/{provider}
      const parts = doc.ref.path.split("/");
      const uid = parts[1];
      const provider = parts[3] as Provider;

      try {
        await refreshUserProviderQuota(db, uid, provider);
      } catch (err) {
        console.error(`Quota refresh failed for ${uid}/${provider}:`, err);
        // Update connection doc with error state but do NOT disconnect
        // automatically — transient failures should not punish the user.
        await doc.ref.update({
          lastErrorCode: (err as Error).message,
          lastRefreshAt: new Date().toISOString(),
        });
      }
    }
  }
);
