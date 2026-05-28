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

## Weighted diligence score (2026-05-28 audit)

**~93/100** — Phase 0 complete; Phase 1 CI/security gates landed on branch; Phase 2 schema barrel + Functions modular entry (106 LOC `index.ts`, 13 LOC `types.ts` barrel); Phase 6 ADRs/SLO/debt metrics automated. Remaining: CloudSync god-file deletion (2187 LOC), quarantine revival, OpenBurnBarUI SPM split, mmap vector index, TypeSpec domain expansion beyond usage/quota.

## Audit notes (2026-05-28)

- **Phase 0 (committed):** daemon heartbeat + reader tests, `.swiftlint.yml` `empty_catch_block` error, graceful DB init path.
- **Phase 1 (committed):** PR harness path-filtered E2E (Hermes/iroh, computer use, Mercury/media), `website-ci.yml`, hard-fail diff coverage + xcresult gate, commercial launch gate on internal PRs, `app-check-smoke.sh` ENFORCED probe, release privacy manifests + SBOM NOTICES, `untrustedWorkspaces.supported: false`, provider `validatedProviderBaseURL` (http/https only), App Check on all sensitive callables.
- **Phase 2 (partial, committed):** `functions/src/types.ts` → 13-line re-export barrel; `legacy.ts` 2916 LOC pending TypeSpec migration; `index.ts` 106 LOC domain re-exports.
- **Phase 6 (partial, committed):** [architecture/](architecture/README.md) ADRs 001–005, [runbooks/slos.md](runbooks/slos.md), [TECH_DEBT_METRICS.md](TECH_DEBT_METRICS.md) CI-regenerated.
- **Local `make ci` (2026-05-28):** `debt-check` (unsafe cast 0/0), SwiftLint, full Functions suite + Firestore rules emulator (21/21) green. Run interrupted during retrieval-eval Xcode build (~15 min agent timeout); not a code failure. First run hit transient Firestore emulator port 8080 conflict (passed on immediate retry). Daemon `BurnBarSwitcherSQLiteProfileStoreTests` pass after removing `try!` force-tries.
- **Not proven locally this pass:** full macOS app test matrix, iOS sim, Android JVM — rely on GitHub PR harness (`macos-26`).
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
- Path-triggered E2E (internal PRs): Hermes/iroh, computer use loopback, Mercury/media (`openburnbar-pr-harness.yml` → `path-filter` jobs)
- `website-ci.yml` on `website/**` changes
- `scripts/ci/app-check-smoke.sh` (Firestore App Check ENFORCED) on internal runs with Firebase secrets

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
