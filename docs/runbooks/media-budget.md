# Media Budget Runbook

Operator runbook for the n0 hosted-relay budget guardrail. Plan of record: `plans/2026-05-15-mercury-media-master-plan.md` § F.3 + Decision 4.

## Envelope

- **Soft cap**: $600/mo projected. Triggers automatic envelope tightening (file 2.5 GB/day, screen 30 min/session · 30 min/day, video 20 min/call · 120 min/day).
- **Hard cap**: $1000/mo projected. Triggers Remote Config `media_kill_switch` flip; in-flight sessions terminate within 60 s grace.
- **n0 dashboard alerts**: 75% / 100% / 150% of $600.
- **Baseline iroh tier**: $199/mo (`docs/runbooks/iroh-rollout-status.md`).

## Tunable parameters (Remote Config)

`evaluateMediaBudget` reads three Remote Config parameters every run so ops can recalibrate against an actual n0 invoice without a code deploy. All three fall back to the defaults below if Remote Config is unavailable or the value is non-positive / non-numeric — under-billing is preferable to skipping the gate.

| Remote Config parameter | Default | Purpose |
|---|---|---|
| `media_cost_per_gb_usd` | `0.04` | USD billed per GB of relayed media. Tune from n0 monthly invoice ÷ total relayed bytes (see `ops/media_session_daily_rollups`). |
| `media_budget_soft_cap_usd` | `600` | Projected month-end at which envelope tightens. Decision 4 of the master plan. |
| `media_budget_hard_cap_usd` | `1000` | Projected month-end at which the kill-switch flips. Must be strictly greater than the soft cap — if not, both fall back to defaults. |

### Tuning loop

1. After each n0 invoice lands, compute `actualUSD ÷ totalRelayedGB` from the invoice + `ops/media_session_daily_rollups` aggregation.
2. Update `media_cost_per_gb_usd` via `firebase remoteconfig:get` → edit → `firebase remoteconfig:set`.
3. Next `evaluateMediaBudget` run (hourly) picks up the new value automatically.
4. Verify the new `projectedMonthEndUSD` in `ops/media_budget_status/state/current` matches a hand calculation.

## Architecture

`evaluateMediaBudget` Cloud Function runs hourly (`functions/src/mediaBudget.ts`):

1. Reads n0 services API for month-to-date hosted-relay bytes.
2. Reads `ops/media_session_daily_rollups/days/*` for the current month.
3. Projects month-end at the current daily rate.
4. Writes `ops/media_budget_status/state/current`:
   ```jsonc
   {
     "level": "normal" | "soft_cap" | "hard_cap",
     "projectedMonthEndUSD": number,
     "monthToDateUSD": number,
     "lastEvaluatedAt": Timestamp,
     "activeEnvelope": {
       "screenShareDailyMinutes": number,
       "screenSharePerSessionMinutes": number,
       "videoCallDailyMinutes": number,
       "videoCallPerCallMinutes": number,
       "fileTransferDailyGBIn": number,
       "fileTransferDailyGBOut": number
     }
   }
   ```
5. On level transition, fires `media_budget_level_changed` Firebase Analytics event with `fromLevel`, `toLevel`, `projectedMonthEndUSDBucket`.

Both apps cache `ops/media_budget_status/state/current` for 60 s and re-read on session start. At `hard_cap`, `media_kill_switch` Remote Config also flips for belt-and-suspenders.

## Operator playbook

### Soft cap engaged

Expected behavior:

- New session attempts return `.denied(quotaSoftCap)` after the tightened envelope fills.
- Toast (once per day per user): "High demand — your media quota is reduced today. Daily allowance: 30 min screen share, 20 min/call. Quotas restore when demand drops."
- Existing in-flight sessions continue to their per-session cap then terminate normally.

Operator action: monitor n0 dashboard; verify projection re-converges to under $600 within 24-48 hours. If it does not, escalate by manually tightening the envelope further via direct edit of `ops/media_budget_status/state/current`'s `activeEnvelope` (write through the admin console; the Cloud Function re-overwrites on its next hourly tick, so this is a temporary nudge not a permanent override).

### Hard cap engaged

Expected behavior:

- `media_kill_switch` Remote Config flag flips to `true` (60 s propagation).
- Both apps refuse new sessions immediately ("Media paused — try again tomorrow").
- In-flight sessions receive `media.terminate(reason: budget_hard_cap)` with 60 s grace.
- Auto-recovers when month rolls over and projection drops back under $600.

Operator action: verify the kill-switch flipped via `firebase remoteconfig:get`. Notify Alberto. If projection looks anomalous (e.g., a single user is consuming most of the budget), check `ops/media_session_daily_rollups/days/*` for outliers and consider per-user manual quota override.

### Manual override

To force the envelope back to `normal` mode for a brief window (e.g., for an investor demo):

```bash
firebase remoteconfig:get > /tmp/rc.json
# edit /tmp/rc.json: set parameters.media_kill_switch.defaultValue.value to "false"
firebase remoteconfig:set --config /tmp/rc.json
```

The override is overwritten by the next hourly `evaluateMediaBudget` run if the budget projection still triggers hard cap. Schedule the demo accordingly.

## Telemetry

- **Per-event**: `media_budget_level_changed` Firebase Analytics, `ops/media_budget_status/state/current` Firestore doc.
- **Daily aggregate**: `ops/media_session_daily_rollups/days/{YYYY-MM-DD}` (per-feature p50/p95/p99 RTT, freeze rate, success rate, fallback rate, total minutes, total bytes).
- **Dashboard**: BigQuery export to Looker Studio with a `media-budget-status` board showing daily spend trend, projection, kill-switch state.

## Rollback

To roll back the entire media feature in an emergency: flip `media_kill_switch` to `true`. All seven media phase flags are independent of the kill-switch — flipping kill-switch overrides them all.

To roll back a single phase: flip its phase flag (e.g., `media_screen_share_enabled = false`) — the legacy iroh + WSS chat path is unaffected.
