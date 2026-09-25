# Unit economics cost model — Firestore

Wave 5 diligence input. Models the two known write-amplification paths called
out in the revision plan: the ~10× usage-counter fan-out and the 36-index
`session_logs` collection. All code references are to the current tree; prices
are the Standard-edition list prices on the dates cited and must be re-checked
before any contract or pricing decision.

Price deck (Standard edition, [Firestore pricing](https://cloud.google.com/firestore/pricing),
checked 2026-09-25): **reads $0.03 / 100K, writes $0.09 / 100K,
deletes $0.01 / 100K** documents, storage ~$0.15–0.18 / GB-month (region
dependent). Free tier: 50K reads / 20K writes / 20K deletes per day, 1 GB
storage. BurnBar uses the default database (no Enterprise database is
configured in `firebase.json`), so index entries cost storage + latency, not
per-index write units. On Enterprise edition index writes are metered, which
would turn §3 into a direct per-write multiplier.

## 1. Counter fan-out: ~10× per processed contribution

Path: a client writes `users/{uid}/usage/{usageDoc}` →
`onUsageWritten` (`functions/src/triggers.ts`) enqueues one pending-delta doc
and marks the rollup job dirty (2 writes, trigger latency bounded by design).
A scheduled worker coalesces deltas and applies each net contribution via
`addContribution` (`functions/src/rollupCounters.ts`):

- 2 buckets: `usage_counter_days/{day}` + `usage_counter_totals/all_time`.
- Per bucket, `addContributionToBucket` writes the bucket doc plus
  `providers`, `accounts`, and — when present — `models`, `devices`,
  `executionSources`, and `combos` subcollection docs: 3–7 writes.
- Plus 1 monthly all-time daily-tokens shard write.

Per processed contribution: **7–15 document writes** (minimum with no
model/device/source; typical with model + device is 11–13). Raw usage events
coalesce before this stage, so the multiplier applies to net contributions,
not to every client write. Deletes/updates re-fire the trigger and apply with
direction −1, doubling the cost of a corrected event.

Worked example at 1,000 net contributions/day: ~10K counter writes/day ≈
$0.009/day ($0.27/month) — immaterial on its own. It matters as the floor
under every active user, and because each of those docs also pays storage and
TTL/reaper deletes (`reapExpiredCounterDayBuckets`).

## 2. `session_logs`: 36 composite indexes

`users/{uid}/session_logs/{manifest}` + `chunks` subcollections are written by
clients (`AgentLens/Services/CloudSync/SessionLogSyncService.swift`, batched
≤450 ops). `firestore.indexes.json` carries **98 composite indexes, 36 on the
`session_logs` collection group** — permutations of
`provider × [projectName] × sort field` (`updatedAt`, `startTime`, `endTime`,
`totalTokens`, `costUSD`, …). No two are identical, so there is no
free duplicate to delete; each exists to serve a distinct
equality + `orderBy` query shape.

Cost shape on Standard edition:

- Every manifest/chunk write updates all matching composite indexes: no
  per-index op charge, but proportional storage growth and write latency.
- Index storage accrues per field combination per document; with 36 indexes,
  index bytes plausibly exceed document bytes for small manifests.
- TTL/reaper deletes and client re-syncs re-pay the full index set per doc.

## 3. Trim options (largest first)

1. **Audit which of the 36 indexes serve live queries.** Method: Firestore
   console index usage stats over 30 days + grep client/server `orderBy`
   sites (`SessionLogSyncService`, `MobileChatHistoryStore`,
   `FirestoreRepository`). Delete zero-traffic indexes from
   `firestore.indexes.json` and deploy. Expected outcome: unknown until
   measured — do not guess.
2. **Sort client-side.** The sort-field permutations (`updatedAt`,
   `startTime`, `totalTokens`, `costUSD`, …) exist to order small per-user
   result sets. Fetching by equality-only indexes and sorting in memory
   collapses each family to one index. Pays slightly more read bandwidth per
   query; saves nearly all index storage/latency.
3. **Single-field exemptions** for large never-queried payload fields on
   manifests/chunks (automatic-indexing exclusions), cutting per-write index
   bytes without touching query shapes.
4. **Counter dimensions.** The `combos`, `devices`, and `executionSources`
   subcollection writes exist to back heatmaps/breakdowns. If a breakdown is
   unread, deleting its branch of `addContributionToBucket` removes 2
   writes per contribution per branch (day + all-time buckets).

## 4. What this does not cover

Cloud Functions invocations/egress, FCM, App Check, Cloud Storage (media),
and BigQuery/exports are out of scope here. Revisit this model if the
database moves to Enterprise edition or if per-user event volume grows 10×.
