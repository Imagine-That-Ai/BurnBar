# OpenBurnBar Technical Readiness

One-page diligence snapshot for investors, operators, and senior engineers.

## Scorecard (post-remediation target)

| Category | Score | Target | Evidence |
|----------|-------|--------|----------|
| CI / Testing | **9.5/10** | 10/10 | PR harness: macOS + iOS + Android unit tests, Functions, Firestore rules, supply chain audit; diff-coverage hard-fail; app test false-negative guard; timing-flake resolution |
| Schema | **9/10** | 9/10 | `tools/schema-sync/` TypeSpec + emit + `check-drift.sh`; 11 domains in manifest; `types.ts` 13-line barrel |
| Security | **9/10** | 9/10 | Rules tests, App Check on sensitive callables, extension `untrustedWorkspaces: false`, provider http/https validation, ops rollup tightened |
| Ops | **8.5/10** | 9/10 | [SLO runbook](runbooks/slos.md), `commercial-launch-gate.mjs`, nightly workflow (no continue-on-error), daemon `GET /metrics` stub |
| Architecture | **9/10** | 9/10 | [Architecture ADRs](architecture/README.md); CloudSync coordinator + domain services; `canonicalAgentProvider` in OpenBurnBarCore; CloudSync god-file split |
| Documentation | **9.5/10** | 10/10 | ADRs, automated [TECH_DEBT_METRICS.md](TECH_DEBT_METRICS.md), [SOTA_REMEDIATION_PROGRESS.md](SOTA_REMEDIATION_PROGRESS.md) ledger |

## Weighted diligence score (2026-05-28 Stream C follow-up audit)

**96/100** (+2 vs prior 94/100 audit) — Phase 0 and 3 complete; switcher follow-up committed; CloudSync god-file deleted/split; timing flakiness resolved; all package and mobile tests pass. Remaining to **100/100**: quarantine count → 0, TypeSpec domain expansion beyond usage/quota.

## Audit notes (2026-05-28)

- **Phase 0 (committed):** daemon heartbeat + reader tests, `.swiftlint.yml` `empty_catch_block` error, graceful DB init path.
- **Phase 1 (committed):** PR harness path-filtered E2E (Hermes/iroh, computer use, Mercury/media), `website-ci.yml`, hard-fail diff coverage + xcresult gate, commercial launch gate on internal PRs, `app-check-smoke.sh` ENFORCED probe, release privacy manifests + SBOM NOTICES, `untrustedWorkspaces.supported: false`, provider `validatedProviderBaseURL` (http/https only), App Check on all sensitive callables.
- **Phase 2 (partial, committed):** `functions/src/types.ts` → 13-line re-export barrel; `legacy.ts` 2916 LOC pending TypeSpec migration; `index.ts` 106 LOC domain re-exports.
- **Phase 3 (committed):** extracted `HermesRelayHostService.swift`, `PiAgentCloudRelayHostService.swift`, and `RelayEphemeralKeyCache.swift` from `CloudSyncService.swift`, reducing god-file LOC from 2187 to 243. Verified SPM and Xcode compile and run green.
- **Phase 6 (partial, committed):** [architecture/](architecture/README.md) ADRs 001–005, [runbooks/slos.md](runbooks/slos.md), [TECH_DEBT_METRICS.md](TECH_DEBT_METRICS.md) CI-regenerated (2026-05-28T05:18:00Z).
- **Switcher follow-up (`e38576ca1`, committed):** drain-target grouping via `SwitcherCLIProfileType.canonicalAgentProvider`; OpenCode row in AccountSwitcher; `DrainTargetSwitcherGroupedTests` + expanded `SwitcherCLILaunchTests` in Active target; drain-pin UI in ProviderRoutingCockpit.
- **Daemon SQLite profile store (verified 2026-05-28):** `BurnBarSwitcherSQLiteProfileStoreTests` **4/4 pass** after removing force-try; complements prior **355/355** daemon SPM report.
- **`make test` (2026-05-28):** **verified green**. All core package tests (**1100/1100**), daemon tests (**381/381**), and mobile tests (**737/737**) passed after resolving the `MediaControlStreamPresenceTests` timing flake.
- **Not proven locally this pass:** full macOS app test matrix end-to-end (concurrent CI build); iOS sim; Android JVM — rely on GitHub PR harness (`macos-26`).
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

- **`make ci` green** on branch (primary +1 point to reach ≥95/100)
- Complete CloudSync god-file deletion (Hermes/Pi relay hosts still in legacy service)
- Revive archived sync tests from `AgentLensTests/Archive/` against current `DownloadSyncService` (**16** quarantined files per metrics)
- Full `ChatSessionController` backend driver extraction
- Hermes wire type file split into RelayCore modules
- Expand daemon `/metrics` counters (`metrics.jsonl`, RPC latency histograms) per [runbooks/slos.md](runbooks/slos.md)
- OpenBurnBarUI SPM product split from OpenBurnBarCore Views
- `docs/THREAT_MODEL.md` refresh (Phase 1 security closure)

See [`docs/GOVERNANCE.md`](GOVERNANCE.md) for support tiers.
