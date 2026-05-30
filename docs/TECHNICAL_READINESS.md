# OpenBurnBar Technical Readiness

One-page diligence snapshot for investors, operators, and senior engineers.

**Evidence snapshot (UTC):** 2026-05-30 — budget split (ADR 006), error-debt CI gates, and readiness reconciliation on the remediation branch.

## Scorecard

Scores are **1–10 per category**, not aspirational targets.

| Category | Score | Evidence |
|----------|-------|----------|
| CI / Testing | **8/10** | PR harness runs empty-catch / try? ratchets + rules unit tests for CU + media budget split; full `make ci` remains the merge gate |
| Schema | **10/10** | **13** TypeSpec domains; `./tools/schema-sync/check-drift.sh` includes hand-maintained TS surface gate (PR2) |
| Security | **8/10** | App Check enforced on callables; budget public envelope exposes caps only (no USD); **97** empty catches baseline |
| Ops | **9/10** | SLO runbook + daemon `GET /metrics`; budget events path reconciled to Firestore `events/` |
| Architecture | **8/10** | ADR 006 budget split; daemon RPC domain extraction in progress; top service LOC splits scheduled PR4 |
| Documentation | **8/10** | ADRs + automated debt metrics; readiness math matches cited numbers |

## Weighted diligence score

**~85/100** — `round(mean(8, 10, 8, 9, 8, 8) × 10) = 85`. Held in the honest **~82–87** band until PR1 gates run green on main.

**Not 100/100 because:** **783** `try?` in Services; **97** empty catches; App Check ENFORCED and branch protection are human-only gates; hand-maintained TS surface still **~2864** LOC in `legacy.ts` alone.

**Not counted toward /100:** [`docs/TECH_DEBT_METRICS.md`](TECH_DEBT_METRICS.md) is trend input for monthly reviews, not an auto-scored category.

## Human-only operator steps

- Firestore App Check → **ENFORCED**: [FIREBASE_APP_CHECK_ENFORCEMENT.md](FIREBASE_APP_CHECK_ENFORCEMENT.md)
- GitHub branch protection + CodeQL: org admin per [GOVERNANCE.md](GOVERNANCE.md)

See [`docs/SOTA_REMEDIATION_PROGRESS.md`](SOTA_REMEDIATION_PROGRESS.md) for phase evidence.
