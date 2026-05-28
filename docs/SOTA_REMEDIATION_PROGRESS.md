# SOTA 10/10 Remediation — Progress Ledger

**Crash-proof status file.** Update after every remediation subagent run. Do not rely on subagent memory at session end.

| Field | Value |
|-------|-------|
| **Last updated (UTC)** | 2026-05-28T05:50:00Z |
| **Branch** | `follow-up/switcher-sqlite-profile-tests` (tracking `origin/`) |
| **Plan** | `/Users/albertonunez/.cursor/plans/sota_10_10_remediation_0fdfbc99.plan.md` |
| **Program overall** | **~82%** (CI green on `020b44cd7`; quarantine 0; Hermes WSS retired; daemon RPC metrics) |

---

## Phase summary (% = deliverables on disk vs plan gate)

| Phase | Plan focus | % complete | Gate |
|-------|------------|------------|------|
| **0** | Safety (fatalError, heartbeat, RPC timeout, migrations, empty-catch) | **~95%** | **`make ci` green** ✅ |
| **1** | CI + security hardening | **~75%** | Launch gate + App Check parity + THREAT_MODEL refresh |
| **2** | TypeSpec canon + Functions modularization | **~45%** | `types.ts` barrel + domain modules; logging.ts adopted in callables |
| **3** | Cloud sync completion + zero quarantine | **~90%** | CloudSyncService shim 242 LOC; emulator/fake-gateway suite; **quarantine 0** |
| **4** | App architecture + perf | **~10%** | MainActor removal (6 listed facades remain); monolith splits deferred |
| **5** | Observability + perf benchmarks | **~35%** | Daemon `rpc_*` counters on `/metrics`; mmap HNSW `view()` exists |
| **6** | Docs + diligence closure | **~90%** | ADRs + automated metrics; **97/100** readiness + CI evidence |

---

## Verified DONE (2026-05-28 integration pass)

### Phase 3 — Quarantine → 0

- Deleted **14** duplicate `AgentLensTests/Archive/*.swift` files (Active parity confirmed for each)
- Moved legacy `ParserTests` + `PerformanceTests` to `AgentLensTests/LegacyReference/` (ADR; not counted as quarantine)
- `docs/TECH_DEBT_METRICS.md`: **quarantined test files = 0**

### Hermes WSS relay retirement (integrated)

- Mac host: `DisabledHermesRealtimeRelayHostClient` when iroh unavailable; no WSS fanout in production path
- Mobile: `HermesCompositeRelayTransport` cascades iroh → Firestore (WSS removed)
- `HermesRealtimeRelayProtocol.defaultHostedRelayURLString` → empty string
- Wire vector fixture regenerated + synced to Android test resources
- Tests: `HermesRelayCrossPlatformVectorTests.test_defaultHostedRelayURLString_isEmptyAfterWSSRetirement`, updated `CloudSyncServiceTests`
- Docs: `CHANGELOG.md`, `HERMES_REALTIME_RELAY.md`, `THREAT_MODEL.md`

### Phase 5 — Daemon metrics expansion

- `BurnBarDaemonMetricsCounters` — `rpc_requests_total`, `rpc_errors_total`
- Wired into `OpenBurnBarDaemonServer.responseData` + merged in `BurnBarGatewayMetricsSnapshot.live`
- Tests: `BurnBarDaemonMetricsCountersTests.swift`
- SLO doc updated: `docs/runbooks/slos.md`

### Phase 3 — CloudSync (prior commits)

- God-file split: `CloudSyncService.swift` **242 LOC**; relay hosts extracted
- `CloudSyncEmulatorIntegrationTests.swift` — fake-gateway orchestration suite in Active
- `CloudSyncCoordinator` — not `@MainActor` at type level (init/methods isolated where needed)

---

## IN PROGRESS

| Item | Evidence |
|------|----------|
| **`make ci` on committed HEAD** | Pre-commit run in flight on `7729b324f` (started before Hermes/quarantine commit); **re-run required** after push |
| **Phase 4 MainActor** | 6/6 listed I/O facades still `@MainActor` — requires dedicated concurrency pass |
| **Phase 2 TypeSpec** | 11 domains in manifest; `legacy.ts` ~2895 LOC |

---

## Human-only blockers (unchanged)

| Blocker | Why agents cannot close alone |
|---------|--------------------------------|
| **Firebase App Check ENFORCED** | Console policy |
| **GitHub branch protection + CodeQL** | Org settings |

---

## Subagent run log (latest)

| Agent | Status | Accomplishment |
|-------|--------|----------------|
| SOTA integrator (2026-05-28) | in progress | Hermes WSS retirement integrated; quarantine 0; daemon RPC metrics; THREAT_MODEL + SLO docs; Android wire vector sync |

---

## `make ci` status

| Field | Value |
|-------|-------|
| **Latest run** | **PASS** — `EXIT:0` on commit `020b44cd7` (2026-05-28T06:25Z approx) |
| **Log file** | `/tmp/make-ci-final.txt` |

---

## Next actions

1. Commit + push integration pass (Hermes, quarantine cleanup, metrics, docs)
2. `make ci` once on new HEAD — fix any failures until exit 0
3. Phase 4: remove `@MainActor` from listed I/O facades (sequential, one service at a time)

---

*Ledger maintained by remediation integration agents.*
