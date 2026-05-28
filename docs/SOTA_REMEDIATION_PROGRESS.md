# SOTA 10/10 Remediation — Progress Ledger

**Crash-proof status file.** Update after every remediation subagent run.

| Field | Value |
|-------|-------|
| **Last updated (UTC)** | 2026-05-28T07:15:00Z |
| **Branch** | `follow-up/switcher-sqlite-profile-tests` |
| **Plan** | `/Users/albertonunez/.cursor/plans/sota_10_10_remediation_0fdfbc99.plan.md` |
| **Program overall** | **~92%** |

---

## Phase summary

| Phase | Plan focus | % complete | Gate |
|-------|------------|------------|------|
| **0** | Safety | **100%** | `make ci` green; no production-path `fatalError`; SwiftLint empty-catch |
| **1** | CI + security | **100%** | Launch gate + App Check smoke + ops rules + extension lockdown |
| **2** | TypeSpec + Functions | **100%** | 13 manifest domains; logging on all callables; modular index |
| **3** | Cloud sync + quarantine | **100%** | Coordinator sync via `MainActor.run`; quarantine **0** |
| **4** | App architecture | **85%** | OpenBurnBarError shipped; **6/6** listed I/O facades still `@MainActor` (blocked on `CloudSyncContext` actor split) |
| **5** | Observability | **100%** | `rpc_latency_ms_p95`; `metrics.jsonl` rotation; mmap HNSW |
| **6** | Docs closure | **100%** | ADRs; automated metrics; readiness **97/100** |

---

## This pass (2026-05-28)

### Shipped

- **Phase 0:** Replace gateway/catalog `fatalError` with graceful paths
- **Phase 1:** `ops/*_budget_status` reads require `isOperator()` ([firestore.rules](../firestore.rules))
- **Phase 2:** `withCallableLogging` + `logCallableStart` on encryptedSearch, insightsHostedAnswer, computerUseOpenTimestamps, appstore callables
- **Phase 3:** `CloudSyncCoordinator` — removed method-level `@MainActor`; UI state via `MainActor.run`
- **Phase 5:** Daemon `rpc_latency_ms_p95`; `LocalMetricsJSONLWriter` in `LocalMetricsAggregator.swift` + rotation test
- **Phase 6:** [TECHNICAL_READINESS.md](TECHNICAL_READINESS.md) updated to **97/100**

### Phase 4 blocker (honest)

Removing `@MainActor` from the six listed I/O facades requires **`CloudSyncContext` + `AccountManager` actor split** first — domain sync services cannot compile without `@MainActor` while context remains main-actor isolated. Tracked in [002-actor-boundaries.md](architecture/002-actor-boundaries.md).

---

## Human-only (documented, not code gaps)

| Item | Runbook |
|------|---------|
| Firebase App Check ENFORCED | [FIREBASE_APP_CHECK_ENFORCEMENT.md](FIREBASE_APP_CHECK_ENFORCEMENT.md) |
| GitHub branch protection + CodeQL | [GOVERNANCE.md](GOVERNANCE.md) |

---

## `make ci`

| Field | Value |
|-------|-------|
| **Latest run** | **PASS** `EXIT:0` (2026-05-28T07:25Z) |
| **Log** | `/tmp/make-ci-sota-final2.txt` |

---

*Ledger maintained by remediation integration agents.*
