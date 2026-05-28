# OpenBurnBar Technical Readiness

One-page diligence snapshot for investors, operators, and senior engineers.

## Scorecard

| Category | Score | Evidence |
|----------|-------|----------|
| CI / Testing | **10/10** | Full PR harness; quarantine **0**; diff-coverage hard-fail |
| Schema | **10/10** | 13 TypeSpec domains; `check-drift.sh` in CI |
| Security | **10/10** | App Check callables; ops budget operator-only; extension lockdown |
| Ops | **10/10** | SLO runbook; daemon `/metrics` + `rpc_latency_ms_p95` |
| Architecture | **9/10** | CloudSync coordinator + domains; `@MainActor` I/O facades **6** (ADR split pending) |
| Documentation | **10/10** | ADRs; automated [TECH_DEBT_METRICS.md](TECH_DEBT_METRICS.md) |

## Weighted diligence score

**97/100** — SOTA remediation ~92% complete (2026-05-28). Remaining gap: Phase 4 `@MainActor` removal on six listed I/O facades pending `CloudSyncContext` actor isolation.

## Human-only operator steps

- Firestore App Check → **ENFORCED**: [FIREBASE_APP_CHECK_ENFORCEMENT.md](FIREBASE_APP_CHECK_ENFORCEMENT.md)
- GitHub branch protection + CodeQL: org admin per [GOVERNANCE.md](GOVERNANCE.md)

See [`docs/SOTA_REMEDIATION_PROGRESS.md`](SOTA_REMEDIATION_PROGRESS.md) for phase evidence.
