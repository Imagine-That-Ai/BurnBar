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
import { computeUserRollupsFromCounters, writeUserRollups } from "./rollups.js";
import {
  refreshUserProviderAccountQuota,
  refreshUserProviderQuota,
} from "./quota.js";
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
        const rollups = await computeUserRollupsFromCounters(db, uid);
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
 * Iterates over first-class provider_accounts with status === "connected",
 * refreshes each cloud-refreshable account in a bounded batch, and updates
 * account/quota metadata. Legacy provider_connections remain as a fallback
 * for older installs that have not produced account docs yet.
 */
export const refreshAllProviderQuotas = onSchedule(
  {
    schedule: "every 15 minutes",
    region: "us-central1",
  },
  async (_event) => {
    const db = getFirestore();
    const { quotaRefreshBatchSize } = getConfig();

    const accountQuery = db
      .collectionGroup("provider_accounts")
      .where("status", "==", "connected")
      .where("storageScope", "in", ["cloud_refreshable", "server_private"])
      .orderBy("lastRefreshAt", "asc")
      .limit(quotaRefreshBatchSize);

    const accountSnapshot = await accountQuery.get();
    const refreshedLegacyKeys = new Set<string>();
    const refreshedAccountRefs = new Set<string>();

    for (const doc of accountSnapshot.docs) {
      // Path: users/{uid}/provider_accounts/{accountID}
      const parts = doc.ref.path.split("/");
      const uid = parts[1];
      const accountID = parts[3];
      const data = doc.data();
      refreshedAccountRefs.add(doc.ref.path);
      refreshedLegacyKeys.add(`${uid}/${data.providerID}`);

      try {
        await refreshUserProviderAccountQuota(db, uid, accountID);
      } catch (err) {
        console.error(`Quota refresh failed for ${uid}/${accountID}:`, err);
        // Update account doc with error state but do NOT disconnect
        // automatically — transient failures should not punish the user.
        await doc.ref.update({
          lastErrorCode: (err as Error).message,
          lastRefreshAt: new Date().toISOString(),
        });
      }
    }

    const missingRefreshAtRemaining = Math.max(0, quotaRefreshBatchSize - refreshedAccountRefs.size);
    if (missingRefreshAtRemaining > 0) {
      const missingRefreshAtSnapshot = await db
        .collectionGroup("provider_accounts")
        .where("status", "==", "connected")
        .where("storageScope", "in", ["cloud_refreshable", "server_private"])
        .limit(missingRefreshAtRemaining)
        .get();

      for (const doc of missingRefreshAtSnapshot.docs) {
        if (refreshedAccountRefs.has(doc.ref.path) || doc.get("lastRefreshAt") != null) {
          continue;
        }

        const parts = doc.ref.path.split("/");
        const uid = parts[1];
        const accountID = parts[3];
        const data = doc.data();
        refreshedAccountRefs.add(doc.ref.path);
        refreshedLegacyKeys.add(`${uid}/${data.providerID}`);

        try {
          await refreshUserProviderAccountQuota(db, uid, accountID);
        } catch (err) {
          console.error(`Quota refresh failed for ${uid}/${accountID}:`, err);
          await doc.ref.update({
            lastErrorCode: (err as Error).message,
            lastRefreshAt: new Date().toISOString(),
          });
        }
      }
    }

    const legacyRemaining = Math.max(0, quotaRefreshBatchSize - refreshedAccountRefs.size);
    if (legacyRemaining === 0) {
      return;
    }

    const connSnapshot = await db
      .collectionGroup("provider_connections")
      .where("status", "==", "connected")
      .orderBy("lastRefreshAt", "asc")
      .limit(legacyRemaining)
      .get();

    for (const doc of connSnapshot.docs) {
      // Path: users/{uid}/provider_connections/{provider}
      const parts = doc.ref.path.split("/");
      const uid = parts[1];
      const provider = parts[3] as Provider;
      if (refreshedLegacyKeys.has(`${uid}/${provider}`)) {
        continue;
      }

      try {
        await refreshUserProviderQuota(db, uid, provider);
      } catch (err) {
        console.error(`Legacy quota refresh failed for ${uid}/${provider}:`, err);
        await doc.ref.update({
          lastErrorCode: (err as Error).message,
          lastRefreshAt: new Date().toISOString(),
        });
      }
    }
  }
);
