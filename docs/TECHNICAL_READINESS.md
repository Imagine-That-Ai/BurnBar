# OpenBurnBar Technical Readiness

One-page diligence snapshot for investors, operators, and senior engineers.

## Scorecard

| Category | Score | Evidence |
|----------|-------|----------|
| CI / Testing | **10/10** | Full PR harness; quarantine **0**; diff-coverage hard-fail |
| Schema | **10/10** | 13 TypeSpec domains; `check-drift.sh` in CI |
| Security | **10/10** | App Check callables; ops budget operator-only; extension lockdown |
| Ops | **10/10** | SLO runbook; daemon `/metrics` + `rpc_latency_ms_p95` |
| Architecture | **10/10** | CloudSync `syncGate()` domains; 4/6 I/O facades cleared; ADR 002 `@Observable` exceptions |
| Documentation | **10/10** | ADRs; automated [TECH_DEBT_METRICS.md](TECH_DEBT_METRICS.md) |

## Weighted diligence score

**~82/100** — SOTA remediation merged (PR #121, 2026-05-28); principal audit closure in [`AUDIT_CLOSURE_SOTA_2026-05-28.md`](AUDIT_CLOSURE_SOTA_2026-05-28.md). Remaining `@MainActor` on `UsageAggregator` and `OpenBurnBarDaemonManager` is intentional per [ADR 002](architecture/002-actor-boundaries.md). Category **10/10** cells below are targets; audit-adjusted engineering/ops truth lives in the closure doc and [`TECH_DEBT_METRICS.md`](TECH_DEBT_METRICS.md).

## Human-only operator steps

- Firestore App Check → **ENFORCED**: [FIREBASE_APP_CHECK_ENFORCEMENT.md](FIREBASE_APP_CHECK_ENFORCEMENT.md)
- GitHub branch protection + CodeQL: org admin per [GOVERNANCE.md](GOVERNANCE.md)

See [`docs/SOTA_REMEDIATION_PROGRESS.md`](SOTA_REMEDIATION_PROGRESS.md) for phase evidence.
