# SOTA remediation audit closure — 2026-05-28

**Scope:** Merged PR [#121](https://github.com/Imagine-That-Ai/BurnBar/pull/121) → `main` at `8c97169fc` (merge of `follow-up/switcher-sqlite-profile-tests`).  
**Auditor:** Principal review subagent (Cursor).  
**Repo state:** Audited at merge commit `8c97169fc`; doc fixes on branch `audit/sota-closure-2026-05-28`.

---

## Executive verdict

**Continue hardening** — ship the remediation to production with eyes open.

The merge delivers real, test-backed wins (CloudSync off main actor, daemon RPC metrics, schema drift gate, quarantine at zero compiled files, unsafe-cast budget at zero). It does **not** justify a literal **100/100** diligence score or “Phase 2 logging on all callables.” Treat [`TECHNICAL_READINESS.md`](TECHNICAL_READINESS.md) marketing scores as aspirational until the gaps below close.

**Not Hold:** CI-equivalent Mac unit tests passed in this audit; blocking issues are documentation inflation and observability coverage gaps, not a broken main tree.

---

## What was verified

| Check | Exit | Log / evidence |
|-------|------|----------------|
| `git fetch` + audit at `8c97169fc` | 0 | `main` blocked in sibling worktree; audited merge commit on `audit/sota-closure-2026-05-28` |
| `./scripts/ci/update-tech-debt-metrics.sh` | 0 | `/tmp/audit-tech-debt-metrics.log` |
| `make debt-check` | 0 | `/tmp/audit-debt-check.log` — unsafe cast live=0 |
| `./tools/schema-sync/check-drift.sh` | 0 | `/tmp/audit-schema-drift.log` |
| SwiftLint (`make lint` path) | skip | `swiftlint` not on PATH in audit shell |
| `swift test --filter BurnBarDaemonMetrics` (SPM) | 0 | `/tmp/audit-daemon-metrics-tests.log` — 3 tests |
| `swift test --filter BurnBarDaemonHeartbeat` (SPM) | 0 | `/tmp/audit-daemon-heartbeat-tests.log` — 2 tests |
| `./scripts/test-openburnbar-app.sh` (full Mac suite) | 0* | `/tmp/audit-drain-switcher-tests.log` — **2723** tests, 2 skipped |

\*Harness reported `xcodebuild` exit **65** with one failing test (`AntigravityQuotaAdapterTests.testFetch_whenDifferentModelSelected_thatModelIsActive`) but the script **accepted the run as passed**. Treat that test as a **P2 flake/regression** to fix; do not cite “zero failures” without this caveat.

**Not run in this audit:** full `make ci` (30+ min). Ledger cites `/tmp/make-ci-sota-phase4.txt` from 2026-05-28 — not re-validated here.

---

## Claim verification (docs vs tree)

| Claim | Verdict | Evidence |
|-------|---------|----------|
| `CloudSyncService.swift` ~242 LOC | **Close** | **230** lines at merge (`wc -l`) |
| Quarantine count = 0 actionable | **Pass** | `AgentLensTests/Quarantine/` has README + manifest only; **0** `.swift` under Quarantine; archived tests under `Archive/` |
| 4/6 I/O facades cleared; 2 retained per ADR 002 | **Pass** | CI script counts **2** class-scoped `@MainActor` on listed set: `UsageAggregator`, `OpenBurnBarDaemonManager`. `CloudSyncService` no longer class-isolated |
| ADR 002: `OpenBurnBarDaemonManager` “cleared” | **Was wrong** | Class still `@MainActor` at line 198; **fixed in this audit** (doc only) |
| Daemon `GET /metrics`: `rpc_*` counters + p95 | **Pass** | [`BurnBarGatewayMetrics.swift`](../OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarGatewayMetrics.swift) + unit tests |
| Hermes WSS retirement | **Partial** | Production Mac path uses `HermesIrohRelayHostClient` or `DisabledHermesRealtimeRelayHostClient`; **WSS implementation remains** (`HermesRealtimeRelayHostClient.swift`, fanout) for fallback/dev — infra deleted per CHANGELOG, not all client code |
| Phase 2: `logging.ts` on **all** callables | **Fail** | **49** `onCall` exports; **5** files use `withCallableLogging` / `logCallableStart` (`encryptedSearch`, `insightsHostedAnswer`, `appstore/callable`, `computerUseOpenTimestamps`, `logging.ts`) |
| `functions/src/types/legacy.ts` size | **Pass** | **2897** LOC per metrics script; barrel `types.ts` **16** LOC |
| `metrics.jsonl` rotation | **Pass** | `LocalMetricsJSONLWriter` in [`LocalMetricsAggregator.swift`](../AgentLens/Services/LocalMetricsAggregator.swift) |
| Readiness **100/100** | **Inflated** | See scores below |

---

## Architecture review (CloudSync / relay)

**Strengths**

- `CloudSyncService` is a thin `@Observable` coordinator; domain work uses `CloudSyncContext.syncGate()` snapshots — good boundary for account/settings immutability during sync.
- `CloudSyncCoordinator` routes domains without re-centralizing all logic in one god class.
- Hermes host defaults to iroh; WSS client disabled when iroh flag off (`DisabledHermesRealtimeRelayHostClient`).

**Risks / leaky boundaries**

- `HermesRelayHostService` remains **class `@MainActor`** with Firestore listeners and heartbeat tasks — not in the six-facade CI list but still a large main-actor relay surface.
- `CloudSyncService.memorySyncBoundarySnapshot()` uses `MainActor.run` for settings/account reads — acceptable but shows remaining UI-thread coupling at the boundary.
- `PiAgentCloudRelayHostService` mirrors Hermes pattern (`@MainActor`) — duplication between relay hosts; consider shared off-main heartbeat/listener helper in a follow-up.

---

## UI/UX (PR-adjacent)

- [`ProviderRoutingCockpit.swift`](../AgentLens/Views/Components/ProviderAccount/ProviderRoutingCockpit.swift): coherent routing lanes, drain-target pin, sanitized copy — **production-grade** for a power-user surface.
- [`DrainTargetSwitcher.swift`](../AgentLens/Views/Components/ProviderAccount/DrainTargetSwitcher.swift) + grouped tests: logic sound; tests emit **MainActor isolation warnings** — migrate `grouped` or tests to `@MainActor` for Swift 6 cleanliness (P2).

No visual regression testing performed in this audit.

---

## Edge-case grep (remediation-adjacent)

| Pattern | CloudSync tree | Notes |
|---------|----------------|-------|
| Empty `catch {}` | 0 in `AgentLens/Services/CloudSync/` | Good |
| `fatalError` | 0 in CloudSync | Good |
| Global empty catch | **68** | [`TECH_DEBT_METRICS.md`](TECH_DEBT_METRICS.md) — not remediated |
| `try?` in Services | **745** | High swallow risk; tracked, not SOTA-closed |

---

## Documentation accuracy

| Doc | Status |
|-----|--------|
| [`THREAT_MODEL.md`](THREAT_MODEL.md) | Accurate high-level boundaries |
| [`FIREBASE_APP_CHECK_ENFORCEMENT.md`](FIREBASE_APP_CHECK_ENFORCEMENT.md) | Accurate operator checklist; enforcement remains **human-only** |
| [`slos.md`](runbooks/slos.md) | Updated in audit: `rpc_latency_ms_p95`, `metrics.jsonl` status |
| [`002-actor-boundaries.md`](architecture/002-actor-boundaries.md) | Fixed DaemonManager line in audit |
| [`SOTA_REMEDIATION_PROGRESS.md`](SOTA_REMEDIATION_PROGRESS.md) | Phase 2 % corrected in audit |

---

## Issues found

### P0

None blocking release on evidence from this audit run.

### P1

1. **Callable structured logging incomplete** — 44/49 callables lack `withCallableLogging` / `logCallableStart`; SLO runbook assumes Functions JSON logs per callable.
2. **Readiness scorecard 10/10 across categories** — contradicts remaining debt (68 empty catches, 745 `try?`, 2897-line `legacy.ts`, partial Functions logging).
3. **ADR 002 claimed `OpenBurnBarDaemonManager` cleared** — was false; class still `@MainActor` (intentional supervisor, but doc wrong).

### P2

1. **Antigravity quota test** failed once in full suite while harness accepted pass — fix or tighten harness.
2. **Hermes WSS client code** still in tree (disabled path only) — document as legacy fallback or delete after retirement gate.
3. **DrainTargetSwitcher tests** — Swift 6 MainActor warnings.
4. **`slos.md` Functions section** — does not yet list required `callable_start` / `callable_error` events for log-based SLOs.

---

## Fixes applied during audit

| Fix | File(s) |
|-----|---------|
| ADR 002: DaemonManager **retained**, not cleared | `docs/architecture/002-actor-boundaries.md` |
| SLO table: `rpc_latency_ms_p95`; `metrics.jsonl` not “future” | `docs/runbooks/slos.md` |
| Phase 2 honest % (~85%, 5/49 callables) | `docs/SOTA_REMEDIATION_PROGRESS.md` |
| Export `onCallWithLogging` handler wrapper for incremental adoption | `functions/src/logging.ts` |
| This closure report | `docs/AUDIT_CLOSURE_SOTA_2026-05-28.md` |

**Not applied:** mass retrofit of 44 callables (follow-up PR recommended).

---

## Remaining risks (real only)

- **Firestore App Check ENFORCED** still operator-dependent — not provable from git.
- **GitHub branch protection / CodeQL** — human-only per governance docs.
- **SearchService** still **1297** LOC — top-four services **3175** LOC (under 5000 target but not “done”).
- **Archived tests** under `AgentLensTests/Archive/` — not quarantined in CI but stale; revival backlog remains.
- **Full `make ci`** not re-run in this audit session.

---

## SOTA scores (1–10, evidence-based)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Engineering | **8** | Strong sync/metrics/schema work; logging debt and test harness quirk hold back a 9 |
| UX | **7.5** | Routing cockpit polished; no full visual QA in audit |
| Reliability | **8** | Metrics + heartbeat tested; empty-catch/`try?` volume still high |
| Extensibility | **8** | TypeSpec domains + modular Functions index; legacy.ts still huge |
| Visual delight | **7** | Design system usage consistent; not a design-review pass |

**Adjusted diligence score: ~82/100** (not 100/100).

---

## Final recommendation

1. **Merge audit doc fixes** (`audit/sota-closure-2026-05-28` → `main`).
2. **Open a focused PR** to wrap remaining callables with `onCallWithLogging` (or shared `onCall` factory).
3. **Revise `TECHNICAL_READINESS.md`** scores to match [`TECH_DEBT_METRICS.md`](TECH_DEBT_METRICS.md) or link to this closure doc.
4. **Fix or quarantine** `AntigravityQuotaAdapterTests.testFetch_whenDifferentModelSelected_thatModelIsActive`.
5. Re-run **`make ci`** before next investor/launch diligence packet.

---

*Generated by principal audit subagent — 2026-05-28.*
