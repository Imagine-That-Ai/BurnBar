# Computer Use — budget runbook

**Plan:** [`plans/2026-05-16-computer-use-master-plan.md`](../../plans/2026-05-16-computer-use-master-plan.md) § E.3 · **Reference:** [`HERMES_COMPUTER_USE.md`](../HERMES_COMPUTER_USE.md) § 7

This runbook fires when the hourly `evaluateComputerUseBudget` Cloud Function flips the global envelope into `soft_cap` or `hard_cap`.

## Thresholds

| Level | Projected month-end | Active envelope |
|---|---|---|
| Normal | < $1500 | 50 actions/run · 200/day · 4 sessions/day · $5/user/day |
| Soft cap | ≥ $1500 | 25 actions/run · 100/day · 2 sessions/day · $2.50/user/day |
| Hard cap | ≥ $2500 | 0 (active sessions terminate within 60 s) |

## On soft cap fire

1. Confirm the firing in BigQuery: `SELECT level, projectedMonthEndUSD, monthToDateUSD FROM ops.computer_use_budget_status_history ORDER BY updatedAt DESC LIMIT 5`
2. Read `ops/computer_use_daily_rollups/days/<yesterday>` for the per-tool counts that drove the projection.
3. Identify any abusive user(s) via `users/*/computer_use_actions/*` aggregation.
4. If the projection is driven by genuine demand, expand the SKU price or add an `additional_computer_use_actions` IAP. If it is driven by a single user, downgrade their entitlement to inactive and contact them.
5. Soft cap is transparent to the user — they see a sidebar notice "Computer Use ran tight today; we lowered today's cap to keep the lights on" but their session does not interrupt.

## On hard cap fire

1. Hard cap is **kill switch**. Existing sessions tear down within 60 s.
2. Confirm `ops/computer_use_budget_status/state/current.level = "hard_cap"`.
3. Set Remote Config `computer_use_kill_switch=true` if not already auto-set.
4. Page the on-call. Drop the day's `users/*/computer_use_actions/*` and `users/*/computer_use_sessions/*` documents into a snapshot bucket for forensics.
5. Communicate via the in-app banner + status page: "Computer Use is paused while we investigate elevated vision-model spend. Existing audit chains are intact and your work is saved."
6. Resume only after `evaluateComputerUseBudget` projects month-end < $2000 with a 24 h trailing average.

## Per-user override

If a single user's `users/{uid}/computer_use_quota_usage/{day}.visionModelSpendUSD` exceeds the daily ceiling, the Mac coordinator will refuse new sessions with `denied(.dailySpendCeiling)`. The user's own work is unaffected; we never refund a session that has already been authorized — the audit chain entry is enough proof.

## Reset path

1. The auto-tightening function unwinds itself: when projection drops back below $1500, soft cap → normal; when projection drops back below $2500 AND `computer_use_kill_switch` is manually flipped to false, hard cap → soft cap → normal.
2. Per-user per-day counters reset at midnight UTC via the `recomputeComputerUseQuotaUsage` Cloud Function rollup.
