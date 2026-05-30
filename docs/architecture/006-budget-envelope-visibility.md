# ADR 006 — Budget envelope visibility split

**Status:** Accepted  
**Date:** 2026-05-30  
**Supersedes:** Operator-only read on `ops/*_budget_status/state/current` (2026-05-28 hardening)

## Context

On 2026-05-28, Firestore rules restricted reads on `ops/computer_use_budget_status/state/current` and `ops/media_budget_status/**` to users with the `burnbarOperator` custom claim. That hardening was intentional — the single budget document included operator-sensitive fields (`projectedMonthEndUSD`, `monthToDateUSD`) that would expose company-wide cloud burn to every authenticated user if opened broadly.

The same change inadvertently hid the **operability envelope** (level + per-session/day caps) that signed-in clients need to enforce soft caps locally. Mac and mobile coordinators fell back to `.initialNormal` / hardcoded stubs when listeners failed, creating a soft-cap bypass.

[`docs/THREAT_MODEL.md`](../THREAT_MODEL.md) states that any signed-in user may read the envelope caps; only USD projections and rollups are operator-only.

## Decision

Split each budget topic into two documents:

| Path | Fields | Read rule |
|------|--------|-----------|
| `ops/computer_use_budget_status/state/current` | `level`, action/session caps, `perUserDailySpendCeilingUSD`, `updatedAt` | `isSignedIn()` |
| `ops/computer_use_budget_status/metrics/current` | `projectedMonthEndUSD`, `monthToDateUSD`, `level`, `updatedAt` | `isOperator()` |
| `ops/media_budget_status/state/current` | `level`, `activeEnvelope`, `lastEvaluatedAt`, `schemaVersion` | `isSignedIn()` |
| `ops/media_budget_status/metrics/current` | `projectedMonthEndUSD`, `monthToDateUSD`, `level`, `lastEvaluatedAt` | `isOperator()` |

Daily rollups (`ops/computer_use_session_daily_rollups/**`, `ops/media_session_daily_rollups/**`) remain operator-only. Transition audit rows stay at `ops/*_budget_status/events/{eventId}` (operator read, server write).

Cloud Functions (`evaluateComputerUseBudget`, `evaluateMediaBudget`) write **both** documents atomically in sequence. Clients listen only to the public envelope path.

## Client error handling

Budget listeners classify Firestore errors:

- **`permissionDenied` while signed in** — fail closed: retain last-known envelope if fresh; otherwise deny soft-cap-eligible actions.
- **`unavailable` / network / not signed in** — use last-known envelope when present; otherwise fall back to conservative defaults and rely on Remote Config kill switches (`computer_use_kill_switch`, `media_kill_switch`) as the hard backstop.

## Consequences

- Signed-in users regain operability caps without seeing USD projections.
- Operators retain full metrics at `metrics/current` and rollups.
- CHANGELOG explicitly supersedes the 2026-05-28 operator-only line; this is not a silent revert.
- Rules unit tests enforce the public/operator matrix for both Computer Use and Media.

## References

- [`docs/runbooks/computer-use-budget.md`](../runbooks/computer-use-budget.md)
- [`docs/runbooks/media-budget.md`](../runbooks/media-budget.md)
- [`CHANGELOG.md`](../../CHANGELOG.md) — Unreleased supersede entry
