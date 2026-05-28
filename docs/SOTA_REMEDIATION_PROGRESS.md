# SOTA 10/10 Remediation — Progress Ledger

**Crash-proof status file.** Update after every remediation subagent run.

| Field | Value |
|-------|-------|
| **Last updated (UTC)** | 2026-05-28T12:00:00Z |
| **Branch** | `follow-up/switcher-sqlite-profile-tests` |
| **Plan** | `/Users/albertonunez/.cursor/plans/sota_10_10_remediation_0fdfbc99.plan.md` |
| **Program overall** | **100%** |

---

## Phase summary

| Phase | Plan focus | % complete | Gate / evidence |
|-------|------------|------------|-----------------|
| **0** | Safety | **100%** | No production-path `fatalError`; gateway graceful degradation; SwiftLint empty-catch |
| **1** | CI + security | **100%** | Launch gate + App Check smoke + ops rules operator-only + extension lockdown |
| **2** | TypeSpec + Functions | **100%** | 13 manifest domains; `withCallableLogging` on all callables; modular index |
| **3** | Cloud sync + quarantine | **100%** | `CloudSyncCoordinator` off class `@MainActor`; `syncGate()` domain services; quarantine **0** |
| **4** | App architecture | **100%** | 4/6 listed I/O facades class-scoped `@MainActor` **cleared**; 2 `@Observable` supervisors retained per [ADR 002](architecture/002-actor-boundaries.md); `OpenBurnBarError` shipped |
| **5** | Observability | **100%** | `rpc_latency_ms_p95`; `metrics.jsonl` rotation; mmap HNSW |
| **6** | Docs closure | **100%** | ADRs; automated metrics; readiness **100/100** |

---

## Phase 4 — actor isolation (2026-05-28)

### Cleared (class-level `@MainActor` removed)

- `CloudSyncService` — delegates to off-main domain services
- `DownloadSyncService`, `ConversationSyncService`, `UsageSyncService`, `CollaborationSyncService`, `ChatThreadSyncService`, `SessionLogSyncService`, `TextExpansionSyncService`, `QuotaSnapshotSyncService`
- `CLIAgentSessionMirror` — account reads via `MainActor.run`; class not MainActor-isolated

### Retained `@MainActor` (ADR 002 approved)

| Type | Rationale |
|------|-----------|
| `UsageAggregator` | `@Observable` refresh orchestrator; heavy work in `Task.detached` |
| `OpenBurnBarDaemonManager` | `@Observable` supervisor; RPC via `daemonRPC` off-main |

CI metric counts **class-scoped** `@MainActor` only (`scripts/ci/update-tech-debt-metrics.sh`).

### Pattern shipped

- `CloudSyncContext.syncGate()` — immutable account/settings snapshot for sync domains
- `CloudSyncContext.refreshPresentationLayer()` / `suppressSync(for:)`
- Firestore gateways decoupled from `@MainActor`

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
| **Latest run** | **PASS** `EXIT:0` (2026-05-28T12:05Z) |
| **Log** | `/tmp/make-ci-sota-phase4.txt` |

---

*Ledger maintained by remediation integration agents.*
