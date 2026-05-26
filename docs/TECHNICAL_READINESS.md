# OpenBurnBar Technical Readiness

One-page diligence snapshot for investors, operators, and senior engineers.

## Scorecard (post-remediation target)

| Category | Target | Evidence |
|----------|--------|----------|
| CI / Testing | 10/10 | PR harness: macOS + iOS + Android unit tests, Functions, Firestore rules, supply chain audit |
| Schema | 9/10 | `tools/schema-sync/` TypeSpec + emit + `check-drift.sh` |
| Security | 9/10 | Threat model, rules tests, automated CU kill switch, App Check gate script |
| Ops | 9/10 | Runbooks, `commercial-launch-gate.mjs`, nightly workflow |
| Architecture | 8/10 | CloudSync coordinator owns download + session-log reads; `ProjectsModels` extracted; chat registry scaffold |

## Weighted diligence score (2026-05-25 audit)

**~78/100** — up from 68/100 pre-remediation (not 82; see audit closure). CI/schema/security foundations are materially stronger; collaboration god-file, Hermes wire split, and 22 quarantined tests remain.

## Audit notes (2026-05-25)

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

- Complete CloudSync god-file deletion (relay hosts still in legacy service)
- Revive quarantined sync tests against `DownloadSyncService`
- Full `ChatSessionController` backend driver extraction
- Hermes wire type file split into RelayCore modules

See [`docs/GOVERNANCE.md`](GOVERNANCE.md) for support tiers.
