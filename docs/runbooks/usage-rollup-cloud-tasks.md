# Usage Rollup Cloud Tasks

The `rebuildRollups` scheduler now only discovers dirty `users/{uid}/rollup_jobs/current` markers and enqueues one Cloud Task per uid. `rollupUserRebuild` owns the per-user rebuild body, including the dirty-epoch race guard, delta drain, full-rebuild breaker, capped-drain resume nonce, and dirty clear.

## Queue

Queue id: `rollup-user-rebuilds`

Location: `ROLLUP_REBUILD_TASK_LOCATION`, defaulting to the functions region.

Task target: `rollupUserRebuild` Cloud Functions v2 URL. Set `ROLLUP_REBUILD_TASK_TARGET_URI` only when the Cloud Functions API lookup is unavailable in the runtime.

Recommended queue shape:

```bash
gcloud tasks queues create rollup-user-rebuilds \
  --location=us-central1 \
  --max-dispatches-per-second=5 \
  --max-concurrent-dispatches=10 \
  --max-attempts=5 \
  --max-retry-duration=3600s \
  --min-backoff=60s \
  --max-backoff=600s \
  --max-doublings=5 \
  --log-sampling-ratio=1
```

Use the same flags with `gcloud tasks queues update` to reconcile drift.

## IAM

The service account that runs `rebuildRollups` needs `cloudtasks.tasks.create` on the queue and permission to mint the OIDC token for `ROLLUP_REBUILD_TASK_SERVICE_ACCOUNT_EMAIL`:

```bash
gcloud projects add-iam-policy-binding burnbar \
  --member="serviceAccount:burnbar@appspot.gserviceaccount.com" \
  --role="roles/cloudtasks.enqueuer"

gcloud iam service-accounts add-iam-policy-binding burnbar@appspot.gserviceaccount.com \
  --member="serviceAccount:burnbar@appspot.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
```

`rollupUserRebuild` is deployed with `invoker: "private"` and validates only `{ uid, dirtiedAt?, requeueNonce? }`; it re-reads `users/{uid}/rollup_jobs/current` before work. A task whose `dirtiedAt` no longer matches is a no-op. The `requeueNonce` participates only in Cloud Task naming: a capped delta drain rotates it while keeping the same dirty epoch alive, so the next scheduler tick can enqueue the resume task instead of colliding with the completed task name.

## Poison Tasks

Cloud Tasks gives retry limits and per-queue rate control. It does not provide a Pub/Sub-style dead-letter queue. Poison rollup work is bounded by:

- queue retry config: 5 attempts over at most 1 hour
- `rollup.full_rebuild_circuit_open` breaker after repeated repair failures
- `OpenBurnBar Rollup task queue backlog` alert when queue depth stays above 500 for 15 minutes

If the alert fires, check:

```bash
gcloud tasks queues describe rollup-user-rebuilds --location=us-central1
gcloud tasks tasks list --queue=rollup-user-rebuilds --location=us-central1 --limit=20
```

Then inspect Cloud Logging for `rollup.rebuild_failed`, `rollup.full_rebuild_circuit_open`, and `rollup.task_enqueue_failed`.

## Day-Bucket Retention (Wave 2.6)

`usage_counter_days/{day}` docs older than 180 days (`COUNTER_DAY_RETENTION_DAYS`,
mirroring Swift `UsageRetentionPolicy`) are dead weight — rollup compute only
reads the trailing 90-day union. The daily `reapExpiredCounterDayBuckets`
schedule `recursiveDelete`s them (subcollections included). Every day doc also
carries `expireAt` (day + 190d), and the Firestore TTL policy on
`usage_counter_days.expireAt` is the backstop for anything the sweeper misses
(enabled 2026-09-24 on `burnbar` and `burnbar-staging`; verify with
`gcloud firestore fields ttls list`). The all_time daily series lives in
monthly `all_time_daily_YYYY-MM` shards, so reaping day buckets never truncates
chart history — see `npm run test:counter-growth` for the 3-year proof.
