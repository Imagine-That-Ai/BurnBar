# Media Quota Runbook

Operator runbook for the Mercury media quota system. Plan of record: `plans/2026-05-15-mercury-media-master-plan.md` § F.

## Daily envelope (normal mode)

| Feature | Per day | Per session/file | Concurrent |
|---|---|---|---|
| File transfer | 5 GB in + 5 GB out · 50 transfers | 1 GB / file · 4 concurrent | 4 |
| Screen share | 120 min/day | 60 min/session | 1 |
| Video call | 240 min/day · | 30 min/call | 1 (call + share simultaneously OK) |

Per-feature caps tighten automatically when hosted-relay budget enters soft cap — see `docs/runbooks/media-budget.md`.

## Storage

Per-user usage is recorded in `users/{uid}/media_quota_usage/{YYYY-MM-DD}` per the schema in `functions/src/types.ts` (`MediaQuotaUsageDoc`). Mac writes during active sessions every 30 s in batched updates; the scheduled Cloud Function `recomputeMediaQuotaUsage` corrects drift hourly by re-reading `users/{uid}/iroh_audit_events` for the day.

## Enforcement

Three layers (Decision 2 in the plan applies — Mac is source of truth):

1. **Mac host gate (primary)** — `MediaCapabilityGate.check(feature:duration:bytes:)` reads `MacCloudEntitlementStore.hostedMediaEntitlement`, the local quota counter cache, and `ops/media_budget_status/current`. Returns `.allowed` or `.denied(reason: enum)` synchronously.
2. **Control-plane reconcile** — Cloud Function recomputes from authoritative `iroh_audit_events`. Hourly schedule.
3. **iroh accept-loop gate (secondary)** — Mac's accept-loop re-checks freshness on each new `media.*` stream open (cached 60 s). Refuses streams when the entitlement, daily envelope, or kill-switch fail.

iOS-side check is informational only (Decision 2 in the plan). It surfaces the same toast text so the user understands why a call won't start, but the Mac is the actual gate.

## Disputes

If a user contacts support claiming "I should still have quota":

1. Verify entitlement state: query `users/{uid}/entitlements/hosted_media_sync` for `active`, `expireAt`, and `features.{fileTransfer,screenShare,videoCall}` flags.
2. Read today's usage: `users/{uid}/media_quota_usage/{YYYY-MM-DD}`. Reconcile against `users/{uid}/iroh_audit_events` filtered to today's `streamClass: media.*`.
3. Check budget level: `ops/media_budget_status/current.level`. If `soft_cap` or `hard_cap`, the envelope is intentionally narrowed (auto-recovers when month rolls over and projection drops back under $600).
4. Check kill-switch: Firebase Remote Config `media_kill_switch`. Override may have been triggered manually.
5. If genuine drift, manual reset: `gcloud firestore documents delete users/{uid}/media_quota_usage/{YYYY-MM-DD}`. The next session will recompute from `iroh_audit_events` on the Mac, and the hourly Cloud Function will reconcile globally.

## Telemetry

`media_quota_denied` Firebase Analytics event fires on every denial with `quotaReason` enum:

- `entitlement` — no `hosted_media_sync` entitlement
- `daily` — daily envelope exhausted
- `concurrent` — at concurrent-session ceiling
- `session-cap` — single session/call/file at per-session ceiling
- `soft-cap` — budget tightened envelope reached
- `hard-cap` — kill-switch active

Dashboard tile lives in the BigQuery → Looker Studio media monitoring board (see `docs/runbooks/media-budget.md`).
