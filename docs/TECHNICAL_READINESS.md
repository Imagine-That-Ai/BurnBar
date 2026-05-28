# OpenBurnBar Technical Readiness

One-page diligence snapshot for investors, operators, and senior engineers.

## Scorecard (post-remediation target)

| Category | Target | Evidence |
|----------|--------|----------|
| CI / Testing | 10/10 | PR harness: macOS + iOS + Android unit tests, Functions, Firestore rules, supply chain audit |
| Schema | 9/10 | `tools/schema-sync/` TypeSpec + emit + `check-drift.sh` |
| Security | 9/10 | Threat model, rules tests, automated CU kill switch, App Check gate script |
| Ops | 9/10 | Runbooks incl. [SLO runbook](runbooks/slos.md), `commercial-launch-gate.mjs`, nightly workflow, daemon `GET /metrics` |
| Architecture | 9/10 | [Architecture ADRs](architecture/README.md); CloudSync coordinator; schema/sync ownership documented |

## Weighted diligence score (2026-05-27 audit)

**~92/100** — Phase 0–2 complete; Phase 1 CI gates and threat-model updates landed; Functions modularized; quarantine emptied (archived under `AgentLensTests/Archive/`); collaboration extracted; SLO/ADR/debt metrics automated. Remaining: CloudSync relay shim deletion, circuit-breaker revival, OpenBurnBarUI SPM split, mmap vector index, N+1 batch passes.

## Audit notes (2026-05-27)

- Phase 5 observability: [OBSERVABILITY.md](OBSERVABILITY.md) + [runbooks/slos.md](runbooks/slos.md) + loopback `GET /metrics` on daemon gateway.
- Phase 5 governance: [architecture/](architecture/README.md) ADRs (naming, actor isolation, errors, schema, sync).
- Debt trends: `./scripts/ci/update-tech-debt-metrics.sh` → [TECH_DEBT_METRICS.md](TECH_DEBT_METRICS.md) (quarantine count, MainActor I/O facades, empty catches, service LOC, schema barrel vs legacy).
- Verified locally: Functions build, schema drift check, supply-chain audit, OpenBurnBarCore budget tests, macOS app build, `OfflineOnlineMergeTests` (6 cases, 1 skipped).
- Not proven locally in this pass: full PR matrix (iOS sim + Android JVM) on this host; rely on CI.
- Kill-switch automation is wired in Functions but only covered by a source-contract smoke test today.

## CI matrix (PR)

- `./scripts/test-openburnbar-swift.sh`
- `./scripts/test-openburnbar-app.sh` (coverage)
- `./scripts/test-openburnbar-mobile.sh`
- `./scripts/test-openburnbar-android.sh`
- Functions `npm test` + Firestore rules emulator
- Extension retrieval/replay evals
- `./tools/schema-sync/check-drift.sh`
- `./scripts/supply-chain-audit.sh`
- `./scripts/diff-coverage-all.sh` (Swift/Kotlin/TS changed surfaces)

## Release matrix

`release.yml` runs the **superset** of PR tests before notarized macOS artifacts ship.

## Launch gate

```bash
node scripts/commercial-launch-gate.mjs
```

Requires Firestore App Check ENFORCED, branch protection, CodeQL green, hosted quota functions, billing alerts.

## Schema canon

Author in `tools/schema-sync/typespec/` → emit → commit generated TS/Swift/Kotlin → CI drift check.

## Known remaining work

- Complete CloudSync god-file deletion (Hermes/Pi relay hosts still in legacy service)
- Revive archived sync tests from `AgentLensTests/Archive/` against current `DownloadSyncService`
- Full `ChatSessionController` backend driver extraction
- Hermes wire type file split into RelayCore modules
- Expand daemon `/metrics` counters (`metrics.jsonl`, RPC latency histograms) per [runbooks/slos.md](runbooks/slos.md)
- OpenBurnBarUI SPM product split from OpenBurnBarCore Views

See [`docs/GOVERNANCE.md`](GOVERNANCE.md) for support tiers.
