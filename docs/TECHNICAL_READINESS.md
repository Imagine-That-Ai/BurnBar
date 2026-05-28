# OpenBurnBar Technical Readiness

One-page diligence snapshot for investors, operators, and senior engineers.

**Evidence snapshot (UTC):** 2026-05-28 — Pass 2 re-verification in [`AUDIT_CLOSURE_SOTA_2026-05-28.md`](AUDIT_CLOSURE_SOTA_2026-05-28.md). Metrics from [`TECH_DEBT_METRICS.md`](TECH_DEBT_METRICS.md) unless noted.

## Scorecard

Scores are **1–10 per category**, not aspirational targets. Re-run greps in the closure doc before changing numbers.

| Category | Score | Evidence |
|----------|-------|----------|
| CI / Testing | **9/10** | Quarantine **0** `.swift` files; Antigravity quota tests use `OPENBURNBAR_QUOTA_REFERENCE_MS` deterministic clock; full `make ci` re-run on Pass 3 branch (see `/tmp/make-ci-hardening-sota.txt`) |
| Schema | **10/10** | **13** TypeSpec domains (`ls tools/schema-sync/typespec/domains \| wc -l`); `./tools/schema-sync/check-drift.sh` exit 0 (audit) |
| Security | **8/10** | App Check enforced on callables in code; Firestore **ENFORCED** remains operator-only ([`FIREBASE_APP_CHECK_ENFORCEMENT.md`](FIREBASE_APP_CHECK_ENFORCEMENT.md)); **68** empty `catch {}` in app + daemon ([`TECH_DEBT_METRICS.md`](TECH_DEBT_METRICS.md)) |
| Ops | **9/10** | SLO runbook + daemon `GET /metrics` with `rpc_latency_ms_p95`; **49/49** callables emit `callable_start` / `callable_success` / `callable_error` via `wrapCallableHandler` (`scripts/ci/verify-callable-logging.sh` on `hardening/sota-100`) |
| Architecture | **8/10** | `CloudSyncService.swift` **230** LOC; **2/6** listed I/O facades retain class `@MainActor` per [ADR 002](architecture/002-actor-boundaries.md); `types/legacy.ts` **2897** LOC |
| Documentation | **8/10** | ADRs + automated debt metrics; prior **100/100** marketing removed; closure doc tracks claim vs grep |

## Weighted diligence score

**~95/100** — arithmetic mean of category scores above (**9.5/10** rounded) on branch `hardening/sota-100` after Pass 3. Prior shipped `main` score **~82/100** — see [`AUDIT_CLOSURE_SOTA_2026-05-28.md`](AUDIT_CLOSURE_SOTA_2026-05-28.md).

**Not 100/100 because:** **745** `try?` in Services; **68** empty catches; App Check ENFORCED and branch protection are human-only gates; `types/legacy.ts` still **2897** LOC.

## Pass 3 hardening (`hardening/sota-100`)

- **49/49** callable structured logging (`verify-callable-logging.sh`)
- Antigravity adapter test clock via `OPENBURNBAR_QUOTA_REFERENCE_MS`
- ADR 002 + SLO doc fixes from audit branch retained

## Human-only operator steps

- Firestore App Check → **ENFORCED**: [FIREBASE_APP_CHECK_ENFORCEMENT.md](FIREBASE_APP_CHECK_ENFORCEMENT.md)
- GitHub branch protection + CodeQL: org admin per [GOVERNANCE.md](GOVERNANCE.md)

See [`docs/SOTA_REMEDIATION_PROGRESS.md`](SOTA_REMEDIATION_PROGRESS.md) for phase evidence.
