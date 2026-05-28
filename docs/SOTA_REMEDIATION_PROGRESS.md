# SOTA 10/10 Remediation — Progress Ledger

**Crash-proof status file.** Update after every remediation subagent run.

| Field | Value |
|-------|-------|
| **Last updated (UTC)** | 2026-05-28T09:15:00Z |
| **Branch** | `hardening/sota-100` (Pass 3 hardening) |
| **Base** | `main` @ `8c97169fc` + audit closure `b4e71f84f` |
| **Plan** | `/Users/albertonunez/.cursor/plans/sota_10_10_remediation_0fdfbc99.plan.md` |
| **Program overall** | **~95%** after Pass 3 — pending `make ci` on hardening branch |

---

## Phase summary

| Phase | Plan focus | % complete (shipped `main`) | Gate / evidence |
|-------|------------|----------------------------|-----------------|
| **0** | Safety | **100%** | No production-path `fatalError`; gateway graceful degradation; SwiftLint empty-catch |
| **1** | CI + security | **100%** | Launch gate + App Check smoke + ops rules operator-only + extension lockdown |
| **2** | TypeSpec + Functions | **100%** | **13** TypeSpec domains; modular `index.ts`; **49/49** callables use `wrapCallableHandler` — `./scripts/ci/verify-callable-logging.sh` |
| **3** | Cloud sync + quarantine | **100%** | `CloudSyncCoordinator` off class `@MainActor`; `syncGate()` domain services; quarantine **0** `.swift` |
| **4** | App architecture | **100%** | 4/6 listed I/O facades class-scoped `@MainActor` **cleared**; 2 `@Observable` supervisors retained per [ADR 002](architecture/002-actor-boundaries.md); `OpenBurnBarError` shipped |
| **5** | Observability | **100%** | `rpc_latency_ms_p95`; `metrics.jsonl` rotation; mmap HNSW |
| **6** | Docs closure | **~90%** | ADRs; automated metrics; readiness scorecard corrected to **~82/100** (not 100/100) |

### Phase 2 — callable logging detail (Pass 2)

| State | Full lifecycle (`wrapCallableHandler` \| `withCallableLogging`) | Any helper (+ `logCallableStart`) | Missing |
|-------|----------------------------------------------------------------|-----------------------------------|---------|
| **Shipped `main` (HEAD)** | **1/49** | **6/49** | **43/49** |
| **`hardening/sota-100` (Pass 3)** | **49/49** | **49/49** | **0/49** |

**Verify on `main`:**

```bash
git grep -E 'export const .* = onCall\(' functions/src | wc -l   # expect 49
# Pass-2 audit script (Python) on HEAD — see AUDIT_CLOSURE Pass 2
```

**Phase 2 % rationale:** TypeSpec + modular Functions index are **100%**; logging sub-gate on shipped code is **~12%** (6/49). Equal weight → **(100 + 100 + 12) / 3 ≈ 72%**. Do **not** report **85%** or **100%** until Stream A/B merges and CI passes.

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
| **Latest run** | In progress — Pass 3 hardening (`/tmp/make-ci-hardening-sota.txt`) |
| **Prior** | **PASS** `EXIT:0` (2026-05-28T12:05Z) — `/tmp/make-ci-sota-phase4.txt` |

---

*Ledger maintained by remediation integration agents. Pass 2 alignment: Stream C, 2026-05-28.*
