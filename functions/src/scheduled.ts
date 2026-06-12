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
import { getFirestore, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { getConfig } from "./config.js";
import { HOSTED_RUNNER_SECRETS } from "./hostedRunnerConfig.js";
import {
  beginFullRebuildAttempt,
  computeUserRollups,
  computeUserRollupsFromCounters,
  drainPendingCounterDeltas,
  recordRollupRebuildFailure,
  writeUserRollups,
} from "./rollups.js";
import { refreshUserProviderAccountQuota, refreshUserProviderQuota } from "./quota.js";
import { runQuotaRefreshSweep } from "./quotaRefreshSweep.js";
import { collectModelLandscapeBenchmarks, writeModelLandscapeBenchmarks } from "./modelLandscape.js";
import { buildAndPersistRouterRundown } from "./routerRundown.js";
import { anchorAuditHeads } from "./callables/auditLog.js";
import type { Provider } from "./types.js";
import { errorMessage, parseProvider, parseRollupJobDoc } from "./guards.js";
import { logError } from "./logging.js";
import { runScheduledJob, scheduledFirestore } from "./scheduledOps.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const ARTIFICIAL_ANALYSIS_API_KEY = defineSecret("ARTIFICIAL_ANALYSIS_API_KEY");

/**
 * Scheduled worker: rebuild dirty usage rollups.
 *
 * Queries the `rollup_jobs` collection group for dirty markers, processes
 * a bounded batch, and clears the marker on success.
 */
export const rebuildRollups = onSchedule(
  {
    schedule: "every 5 minutes",
    region: FUNCTIONS_REGION,
    // Use the default compute service account; no special invoker needed.
    // The repair path replays a user's FULL usage history (recursiveDelete of
    // four counter collections + a paginated raw-usage rescan held in memory)
    // and must outlive the 60 s / 256 MiB scheduler defaults: a timeout here
    // used to kill the rebuild mid-flight, leaving users deleted-but-unrebuilt
    // with the kill invisible to the in-process circuit breaker.
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async (_event) =>
    runScheduledJob("rebuildRollups", async () => {
      const db = getFirestore();
      const {
        rollupBatchSize,
        rollupRepairPageSize,
        rollupMaxConsecutiveFullRebuildFailures,
        rollupFullRebuildCircuitBreakerMinutes,
        rollupPendingDeltaDrainMaxPages,
      } = getConfig();

      const snapshot = await scheduledFirestore("rollup_jobs.dirty", () =>
        db.collectionGroup("rollup_jobs").where("dirty", "==", true).limit(rollupBatchSize).get(),
      );
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
        // True once this iteration claimed the full-rebuild gate (and thus
        // owns an in-flight attempt marker the failure path must clear).
        let claimedFullRebuildGate = false;
        try {
          // If a previous incremental attempt failed, the counters may be
          // corrupt. Fall back to a full rebuild that re-reads all raw usage
          // events and reconstructs counters from scratch.
          const jobSnap = await db.doc(`users/${uid}/rollup_jobs/current`).get();
          const job = jobSnap.exists ? parseRollupJobDoc(jobSnap.data()) : null;
          const needsFullRebuild = job?.lastErrorCode != null;

          let rollups;
          if (needsFullRebuild) {
            // The gate persists the attempt marker BEFORE the destructive
            // rebuild starts, so even a timeout/OOM-killed invocation
            // advances the breaker on the next pass (see
            // beginFullRebuildAttempt); a fresh marker from a still-running
            // invocation dedupes concurrent rebuilds.
            const gate = await beginFullRebuildAttempt(db, uid, {
              maxConsecutiveFullRebuildFailures: rollupMaxConsecutiveFullRebuildFailures,
              circuitBreakerMinutes: rollupFullRebuildCircuitBreakerMinutes,
            });
            if (gate.status === "circuit_open") {
              // Stable jsonPayload.event key — GCP log metrics/alerts are
              // wired to exactly this string. Do not rename.
              logError({
                event: "rollup.full_rebuild_circuit_open",
                uid,
                error: `full rebuild paused until ${gate.openUntil}`,
              });
              continue;
            }
            if (gate.status !== "started") {
              continue;
            }
            claimedFullRebuildGate = true;
            // computeUserRollups purges the pending-delta queue as part of
            // the raw-usage counter rebuild.
            rollups = await computeUserRollups(db, uid, { repairPageSize: rollupRepairPageSize });
            // `dirtiedAt` observed before compute: events that land
            // mid-compute refresh it, which keeps the job dirty for the next
            // pass. Success clears this invocation's attempt marker.
            await writeUserRollups(db, uid, rollups, job?.dirtiedAt, { clearFullRebuildAttempt: true });
          } else {
            // Fold queued trigger deltas into the counters, then project.
            // A drain failure lands in the catch below, which records
            // `lastErrorCode` and routes the next pass to the full rebuild.
            const drain = await drainPendingCounterDeltas(db, uid, { maxPages: rollupPendingDeltaDrainMaxPages });
            rollups = await computeUserRollupsFromCounters(db, uid);
            // A capped drain left queue docs behind: keep the job dirty so
            // the next 5-minute tick resumes the queue.
            await writeUserRollups(db, uid, rollups, job?.dirtiedAt, { keepDirty: drain.capped });
          }
        } catch (err) {
          // Stable jsonPayload.event key — GCP log metrics/alerts are wired
          // to exactly this string. Do not rename.
          logError({ event: "rollup.rebuild_failed", uid, error: errorMessage(err) });
          await recordRollupRebuildFailure(db, uid, errorMessage(err), {
            maxConsecutiveFullRebuildFailures: rollupMaxConsecutiveFullRebuildFailures,
            circuitBreakerMinutes: rollupFullRebuildCircuitBreakerMinutes,
            // A cheap-path failure never wrote an attempt marker; clearing
            // one here could erase a CONCURRENT full rebuild's marker and
            // hide its kill from the breaker.
            clearAttemptMarker: claimedFullRebuildGate,
          });
        }
      }
    }),
);

/**
 * Scheduled worker: refresh provider quotas for all active connections.
 *
 * Iterates over first-class provider_accounts with status === "connected",
 * refreshes each cloud-refreshable account in a bounded batch, and updates
 * account/quota metadata. Legacy provider_connections remain as a fallback
 * for older installs that have not produced account docs yet.
 *
 * Selection, budget accounting, the bounded-concurrency refresh pool, and
 * the one-time `lastRefreshAt` backfill live in `runQuotaRefreshSweep`
 * (quotaRefreshSweep.ts) — see that module for why missing-field legacy docs
 * can never be served by a `lastRefreshAt` filter or orderBy and must be
 * stamped explicit null instead.
 */
export const refreshAllProviderQuotas = onSchedule(
  {
    schedule: "every 15 minutes",
    region: FUNCTIONS_REGION,
    secrets: HOSTED_RUNNER_SECRETS,
    // Each refresh is an outbound provider HTTP call (1-3 s). The pool runs
    // them 5-wide, so a default batch of 20 finishes in ~4-12 s; 120 s gives
    // slow providers and retries headroom the old 60 s default lacked.
    timeoutSeconds: 120,
  },
  async (_event) =>
    runScheduledJob("refreshAllProviderQuotas", async () => {
      const db = getFirestore();
      const { quotaRefreshBatchSize } = getConfig();

      await runQuotaRefreshSweep<QueryDocumentSnapshot>(db, {
        batchSize: quotaRefreshBatchSize,

        refreshAccountDoc: async (doc) => {
          // Path: users/{uid}/provider_accounts/{accountID}
          const parts = doc.ref.path.split("/");
          const uid = parts[1];
          const accountID = parts[3];

          try {
            await refreshUserProviderAccountQuota(db, uid, accountID);
          } catch (err) {
            logError({
              event: "quota.refresh_account_failed",
              uid,
              account_id: accountID,
              error: errorMessage(err),
            });
            // Update account doc with error state but do NOT disconnect
            // automatically — transient failures should not punish the user.
            await doc.ref.update({
              lastErrorCode: errorMessage(err),
              lastRefreshAt: new Date().toISOString(),
            });
          }
        },

        legacyKeyForAccountDoc: (doc) => {
          const parts = doc.ref.path.split("/");
          const uid = parts[1];
          return `${uid}/${doc.data().providerID}`;
        },

        refreshLegacyConnectionDoc: async (doc) => {
          // Path: users/{uid}/provider_connections/{provider}
          const parts = doc.ref.path.split("/");
          const uid = parts[1];
          const provider = parseProvider(parts[3]);
          if (!provider) {
            return;
          }

          try {
            await refreshUserProviderQuota(db, uid, provider);
          } catch (err) {
            logError({
              event: "quota.refresh_legacy_failed",
              uid,
              provider,
              error: errorMessage(err),
            });
            await doc.ref.update({
              lastErrorCode: errorMessage(err),
              lastRefreshAt: new Date().toISOString(),
            });
          }
        },

        legacyKeyForConnectionDoc: (doc) => {
          const parts = doc.ref.path.split("/");
          const uid = parts[1];
          const provider = parseProvider(parts[3]);
          return provider ? `${uid}/${provider}` : undefined;
        },
      });
    }),
);

/**
 * Scheduled worker: refresh public model-landscape benchmark snapshots.
 *
 * The source adapters use documented/public APIs or cached/manual fixtures.
 * Failures write source-status docs but do not block routing; benchmark data is
 * advisory and never overrides user pinning, auth, quota, safety, or availability.
 */
export const refreshModelLandscapeBenchmarks = onSchedule(
  {
    schedule: "every 24 hours",
    region: FUNCTIONS_REGION,
    secrets: [ARTIFICIAL_ANALYSIS_API_KEY],
    // The bench fetch (AA + HF + Design Arena) plus retry/backoff can take
    // 30-60 s; the rundown re-score adds a few more reads/writes. Give the
    // function 5 minutes of headroom so a single transient 429 doesn't
    // starve the rundown write at the end.
    timeoutSeconds: 300,
  },
  async (_event) =>
    runScheduledJob("refreshModelLandscapeBenchmarks", async () => {
      const db = getFirestore();
      const now = new Date();
      const result = await collectModelLandscapeBenchmarks(
        {
          ...process.env,
          ARTIFICIAL_ANALYSIS_API_KEY: ARTIFICIAL_ANALYSIS_API_KEY.value() || process.env.ARTIFICIAL_ANALYSIS_API_KEY,
        },
        now,
      );
      await scheduledFirestore("model_landscape.write", () => writeModelLandscapeBenchmarks(db, result));
      await scheduledFirestore("router_rundown.build", () => buildAndPersistRouterRundown(db, now));
    }),
);

/**
 * Scheduled worker: daily OpenTimestamps anchor of every user's audit head.
 *
 * Stamps `audit_meta/head.headHash` for each head that advanced since its last
 * anchor (B-SEC-3 truncation hardening). The anchor lets `verifyAuditLog` reject
 * a truncated tail even against a colluding server that also rewrites the head
 * pointer. Best-effort per user; reuses the existing OTS infra.
 */
export const anchorAuditLogHeads = onSchedule(
  {
    schedule: "every 24 hours",
    region: FUNCTIONS_REGION,
    // Each head stamp shells out to / round-trips the OTS calendar; give the
    // sweep room for a bounded batch without starving on slow calendars.
    timeoutSeconds: 300,
  },
  async (_event) => {
    await runScheduledJob("anchorAuditLogHeads", async () => {
      await anchorAuditHeads();
    });
  },
);
