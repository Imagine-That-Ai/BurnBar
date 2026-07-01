# Unit-Economics Cost Model (Firestore) — STARTING ESTIMATE

> **STATUS: STUB / STARTING ESTIMATE — the operator must fill in the `TODO` cells before it is load-bearing.**
>
> This is a *starting skeleton* for the per-active-user Firestore unit economics of
> the paid tiers. The **document-count fan-out and read/write shapes below are
> derived from the actual code paths** (they are real). The **dollar rates and the
> per-user activity assumptions are placeholders** and MUST be replaced with
> measured values before any pricing or margin decision. Do not quote a margin off
> this file until the `TODO`s are filled and a real week of PostHog / GCP billing
> data has been reconciled against it.

Related:

- Retention policy source of truth: [`ops/firestore-ttl-policies.json`](../../ops/firestore-ttl-policies.json)
- Fail-closed registration gate: `scripts/ci/check-firestore-ttl-declared.sh`
- Live TTL readback (needs gcloud): `scripts/ci/verify-firestore-ttl-state.mjs`, `scripts/security/verify-deployed-ttl.sh`
- Backend operating bar: [`docs/PAID_SCALE_FIREBASE_RUNBOOK.md`](../PAID_SCALE_FIREBASE_RUNBOOK.md)
- Billing alert thresholds: `functions/scripts/billing-alert-policy-definitions.mjs`

Firestore document **reads** are the first scaling cost signal, then **storage
bytes**, then hosted-relay Cloud Run spend. This model exists to turn "how much
does one paid user cost us per month?" into an auditable arithmetic instead of a
vibe.

---

## 1. Paid tiers (fill in real economics)

Product identifiers are from the entitlement catalog; prices are illustrative
placeholders only.

| Tier | Example product id | Entitlement | Assumed active user / day activity | Price / mo (USD) | TODO |
| --- | --- | --- | --- | --- | --- |
| Pro | `com.openburnbar.pro.monthly` | `burnbar_pro` | TODO usage events/day | `TODO` | fill |
| Pro Max | `com.openburnbar.proMax.monthly` | `burnbar_pro` | TODO usage events/day | `TODO` | fill |
| Ultra | `com.openburnbar.ultra.monthly` | `burnbar_pro` | TODO usage events/day | `TODO` | fill |
| Cloud (sync) | `com.openburnbar.data.cloud.Cloud` | `burnbar_cloud` | TODO synced docs/day | `TODO` | fill |

> Add hosted add-ons (`hostedQuotaSync`, `hostedMediaSync`,
> `hostedComputerUseSync`, `computerUse`) as separate rows if their Firestore /
> Cloud Run footprint is material.

---

## 2. GCP Firestore list rates (VERIFY — region-dependent)

Fill these from the **current** Firestore pricing page for the deployed region;
Firestore bills per-operation and per-GiB-month, and rates differ between
regional and multi-region databases. **Do not trust the placeholders.**

| Symbol | Meaning | Placeholder (VERIFY) |
| --- | --- | --- |
| `R` | USD per document **read** | `TODO` (~$0.03 / 100k reads, verify) |
| `W` | USD per document **write** | `TODO` (~$0.09 / 100k writes, verify) |
| `D` | USD per document **delete** | `TODO` (~$0.01 / 100k deletes, verify) |
| `S` | USD per **GiB-month** stored | `TODO` (~$0.15–0.18/GiB-mo, verify) |
| `TTL_del` | TTL deletes billed as normal deletes? | `TODO` (confirm on pricing page) |

---

## 3. Write model — usage accounting fan-out (derived from code)

Every raw usage document write is observed by `onUsageWritten`, which fans a
signed delta out through `functions/src/rollupCounters.ts`. `addContribution`
writes into **two** buckets — the per-day bucket
`users/{uid}/usage_counter_days/{yyyy-mm-dd}` and the all-time aggregate
`users/{uid}/usage_counter_totals/all_time` — and `addContributionToBucket`
writes the bucket doc plus up to four sub-counter docs (`providers`, `accounts`,
`models`, `devices`):

```
per usage event ≈
  1  raw usage doc (source write)
+ 2  bucket docs           (day + all_time)
+ 2  providers sub-counter (day + all_time)
+ 2  accounts  sub-counter (day + all_time)
+ 2  models    sub-counter (day + all_time, when model present)
+ 2  devices   sub-counter (day + all_time, when deviceId present)
+ N  usage_counter_keys winner-state writes (transaction, variable)
≈ 10–11 counter writes per usage event  (before usage_counter_keys)
```

So the **write amplification is ~10x**: one logged usage event becomes ~10
counter writes. Model per active user per day as:

```
writes/user/day ≈ usage_events/user/day × ~10   (+ rollup writes, below)
```

`rebuildRollups` additionally reads compact counter docs for the target windows
and writes `usage_rollups/{today,7d,30d,90d,all_time}` (≈5 writes per rebuild).
It is scheduled, so its cost scales with **active users × rebuild frequency**,
not with raw usage volume (that is the point of the counter design — see the
runbook's "Rollups" section).

Delivery collections (`voip_outbound`, `fcm_outbound`, `incoming_call_contexts`,
`agent_notification_events`) add one short-lived write per push; they already
self-expire (see the manifest), so they do not accumulate storage.

| Write source | Docs written per active user / day | Notes |
| --- | --- | --- |
| Raw usage events | `TODO events` | driver input |
| Counter fan-out | `≈ events × 10` | from code above |
| Rollup rebuilds | `≈ 5 × rebuilds/day` | scheduled |
| Push delivery | `TODO pushes` | self-expiring |
| **Total writes/user/day** | `TODO` | fill |

---

## 4. Read model (derived from code + runbook)

| Read source | Reads per active user / day | Notes |
| --- | --- | --- |
| Dashboard / cockpit polling | `TODO` | first cost signal per runbook |
| `searchStreams` (session log search) | `TODO` | `array-contains` on `chunks.terms` |
| `refreshAllProviderQuotas` | `TODO` | stale-first, batch-limited |
| Rollup reads (compact counters) | `TODO` | windows only, not raw scan |
| **Total reads/user/day** | `TODO` | fill |

---

## 5. Storage model — why the TTL manifest matters

Doc **count** for the usage subtree grows with account age until TTL is enabled:

```
usage_counter_days docs per user ≈ active_days
per-day sub-counter docs per user ≈ active_days × (distinct providers + accounts + models + devices)
```

With no TTL (today's state for `usage_counter_days` and its sub-counters — see
manifest `status: pending-operator-enablement`), this grows **without bound**.
With a TTL retention of `Rdays` days, steady-state doc count stabilises:

```
steady-state usage docs per user ≈ min(active_days, Rdays) × per_day_docs
```

`usage_counter_totals/all_time` is bounded to one doc per user, but its
`dailyTokens` **map** gains a key per active day forever — a field-TTL cannot
prune it, so it needs aggregate compaction (manifest
`mechanism: aggregate-compaction`).

| Collection (see manifest) | TTL today | Steady-state driver | Storage/user (fill) |
| --- | --- | --- | --- |
| `usage_counter_days` | pending | `min(age, retentionDays)` day docs | `TODO GiB` |
| `providers`/`accounts`/`models`/`devices` (per-day) | pending | day docs × distinct dims | `TODO GiB` |
| `usage_counter_totals` dailyTokens map | pending (compaction) | 1 doc, growing map | `TODO GiB` |
| Delivery collections | active | self-expiring, negligible | `~0` |

**Action:** enabling the pending TTL policies in the manifest converts an
unbounded storage liability into a bounded `retentionDays × daily-growth`
steady state. Do this before onboarding paid users at scale.

---

## 6. Monthly cost per active user (assemble)

```
cost/user/mo ≈ (writes/user/day × 30 × W)
             + (reads/user/day  × 30 × R)
             + (deletes/user/day × 30 × D)          # incl. TTL deletes, if billed
             + (storage_GiB/user × S)
             + hosted relay / Cloud Run share       # see runbook
```

Fill sections 2–5, evaluate, then reconcile against a real week of GCP billing
export + PostHog active-user counts. Flag any tier where
`cost/user/mo ≥ price/mo × TODO_margin_floor` as unprofitable and revisit the
retention windows in the manifest, the rollup cadence, or the tier price.

---

*Owner: operator / backend. Last structural update: see git history. This file
is intentionally a stub — completeness of the arithmetic is an operator task,
not an inferred number.*
