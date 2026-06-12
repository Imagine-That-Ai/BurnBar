# QA / Testing / CI/CD Review — OpenBurnBar

**Date:** 2026-04-27  
**Branch:** `release/openburnbar-0.1.2-beta.12`  
**Reviewer:** Factory Droid subagent

---

## 1. Executive Summary

OpenBurnBar is a **beta-grade project with production-grade release discipline** and **strong coverage in its highest-risk subsystems** (retrieval, parsing, data persistence). The glaring asymmetry is between the release pipeline (notarized, SBOM, checksums, smoke test) and the regression gates in CI (no performance gating, no visual regression, no macOS version matrix). The team can ship fast today, but reaching 1.0 trust requires replacing sleepless `Task.sleep` in unit tests, adding visual regression testing, and deepening the release smoke test.

---

## 2. Test Inventory (Evidence)

### Surface Count

| Target | Location | XCTest Classes | Notes |
|--------|----------|---------------|-------|
| App unit tests | `AgentLensTests/Active/` | ~64 | Includes 16 UI test classes under `Active/UI/` |
| Daemon unit tests | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/` | 15 | HTTP gateway, HNSW, lifecycle, run service, config, usage, agent stack, rate limiter, search, CLI, mission control, provider router, shell |
| Core unit tests | `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/` | 15 | HNSW vector index, search planner, run state machine, protocol versions, mission control contracts, catalog, terminal session supervisor, CLI launch/auth/discovery, Chrome profile discovery |
| Extension tests | `extensions/openburnbar/` | Unit + integ (jest) | Projections, controller, extension-host, cursor-smoke |
| Golden / replay | `AgentLensTests/Active/OpenBurnBarRetrievalReplayGoldenTests.swift`<br>`AgentLensTests/Active/OpenBurnBarAuthoringReplayGoldenTests.swift` | 2 classes, 6 golden assertions | Fixture-driven determinism |
| Integration harness | `AgentLensTests/Active/OpenBurnBarSearchIntegrationHarnessTests.swift` | 1 class, 9 tests | End-to-end projection → retrieval |

**Total: ~99 XCTest classes across app + daemon + core, plus TypeScript/jest extension suite.**

### Excluded from Compilation

`project.yml` excludes **5 files** from the `OpenBurnBarTests` target under `AgentLensTests/Active/`:

1. **`Parsers/ParserTests.swift`** — PERMANENTLY excluded. Legacy monolithic parser references removed private APIs (`parseJSONL`, `dateValue`, `TranscriptSummary`). Rationale: per-provider integration suites already cover the same ground.
2. **`SwitcherCLIAuthCoordinatorTests.swift`** — NOT excluded in `project.yml` (I verified `project.yml` lines 188–200; only `ParserTests.swift` is listed). **This test IS compiled** and contains 1,013 lines of auth coordinator coverage. The `QA_REVIEW_REPORT.md` incorrectly claims it is excluded.
3. **`UsageAggregatorTests.swift`** — NOT excluded in `project.yml`. **This test IS compiled** and contains 1,656 lines of usage aggregation coverage.
4. **`OpenBurnBarDaemonManagerTests.swift`** — NOT excluded in `project.yml`. **This test IS compiled** and contains 770 lines of daemon manager coverage.
5. **`PerformanceTests.swift`** — NOT excluded in `project.yml`. **This test IS compiled** and contains 609 lines of performance benchmarks.

> **Important finding:** The existing `QA_REVIEW_REPORT.md` (dated 2026-04-27, same day) claims 5 files are excluded, but the actual `project.yml` only excludes `Parsers/ParserTests.swift`. This is a **material inaccuracy** in the prior report. Only **1 file** (~1.5% of test surface) is actually excluded today.

---

## 3. Coverage by Domain (Evidence-Based)

### Impressively Tested

| Domain | Evidence | Depth |
|--------|----------|-------|
| **Retrieval / Search** | `SearchServiceTests` (~80K lines, stubbed semantic provider + reranker), `HybridRetrievalServiceTests`, `OpenBurnBarSearchIntegrationHarnessTests`, golden replay tests (lexical win, semantic rescue, degraded fallback, filter correctness, ANN vs exact baseline) | **Strong** — Deterministic fake embedder, fake clock, in-memory GRDB, temp file roots. Degradation and perf guardrails included. |
| **Data / Persistence** | `DataStoreTests`, `DatabaseEncryptionServiceTests`, `LocalSearchSchemaStoreTests`, `OpenBurnBarDatabaseMigrationTests`, `OpenBurnBarMigrationTests`, `CheckpointTests` | **Strong** — Migrations versioned, encryption verified, schema evolution covered. |
| **Parser Layer** | `ClaudeCodeParserIntegrationTests`, `FactoryDroidParserIntegrationTests`, `KimiParserTests`, `HermesParserIntegrationTests`, `CodexTokenAccountingRegressionTests`, per-provider unit tests | **Strong** — Integration + regression + token accounting. Dedicated testable parser subclasses in `Support/`. |
| **Cloud Sync** | `CloudSyncServiceTests` (~30K), `CloudSyncRetryPolicyTests`, `CloudSyncCircuitBreakerTests`, `RemoteSyncWatermarkTests`, `MultiSourceReconciliationTests` | **Moderate–Strong** — Retry, circuit breaker, watermark, reconciliation all exercised. |
| **Operating / Mission** | `OpenBurnBarOperatingComposerTests` (~125K lines), `OpenBurnBarOperatingLayerTests` (~24K) | **Strong** — Complex mission authoring and layer orchestration covered. |
| **Context Packs** | `ContextPackServiceTests`, `ContextPackCrossFlowTests`, `ContextPackDashboardSurfaceTests`, `ContextPackSessionDetailSurfaceTests`, `ContextPackExportTests` | **Strong** — Cross-flow, surface, and export coverage. |
| **Daemon Core** | `OpenBurnBarRunServiceTests`, `OpenBurnBarHTTPGatewayServerTests`, `BurnBarDaemonServerPRLifecycleTests`, `OpenBurnBarDaemonServerTests`, `OpenBurnBarProviderRouterTests`, `OpenBurnBarMissionControlServiceTests` | **Moderate–Strong** — HTTP gateway, lifecycle, PR lifecycle, provider routing, mission control. |

### Dangerously Undertested

| Domain | Evidence | Risk |
|--------|----------|------|
| **Visual / Pixel Regression** | All 16 `UI/*Tests.swift` use `ViewInspector` structural assertions only (`XCTAssertNoThrow(try view.inspect())`, text search). No `SnapshotTesting`, `XCUIScreenshot`, or Percy. | **High** — Dark/light mode changes, mercury gradients, shimmer effects, accessibility sizing are completely unguarded. |
| **Performance Regression** | `PerformanceTests.swift` IS compiled (609 lines) but uses `measure` blocks with static thresholds. However, there is **no CI gate** that fails if `measure` blocks exceed baselines. The `XCTPerformanceMetric` deprecation claim in the prior report is overstated — the file compiles and runs. The real issue is that **performance results are not tracked or gated**. | **Medium** — Parser slowdowns, DB query regressions, or semantic search latency could slip through. |
| **Daemon Process-Level Testing** | `OpenBurnBarDaemonSupervisorTests` (~10K) are pure state-machine tests. No test launches the actual daemon binary, verifies launchd plist generation, or exercises Unix socket handshake end-to-end (the local `test-openburnbar-release-smoke.sh` does this, but it does NOT run in CI). | **Medium** — A broken daemon binary that compiles but crashes on launch would pass CI. |
| **E2E / UI Automation** | No `XCUITest` or Playwright/macOS UI automation in CI. The 16 ViewInspector tests validate SwiftUI tree structure but not actual rendering, interaction, or accessibility. | **Medium** — Broken navigation, popover dismissal, or settings save flows are unguarded. |
| **Property-Based / Mutation Testing** | No `SwiftCheck`, Quick/Nimble property tests, or mutation testing tooling found. | **Low–Medium** — Edge cases in parsing, token accounting, or retrieval ranking are only covered by manually authored fixtures. |
| **Real `Task.sleep` in Unit Tests** | `ChatSessionControllerSearchStateTests.swift` uses `Task.sleep(nanoseconds: 20_000_000)`, `90_000_000`, `160_000_000`, plus a `ControlledChatSessionSearchProvider` that internally sleeps via `try? await Task.sleep(nanoseconds: UInt64(response.delaySeconds * 1_000_000_000))`. This is a **flakiness vector** under CI CPU pressure. | **Low–Medium** — Short sleeps, but unnecessary with a fake scheduler. |

---

## 4. Test Quality Evaluation

### Strengths (with evidence)

1. **Integration Harness Pattern** — `OpenBurnBarSearchIntegrationHarness` (1,100+ lines in `Support/`) is first-class. Provides deterministic fake clock (`OpenBurnBarFakeClock`), fake embedder (`OpenBurnBarFakeEmbedder` with seed + version tag), in-memory GRDB queue, temp file roots, and shared artifact context. This makes retrieval and authoring tests fully deterministic without real embedding models.

2. **Golden / Replay Tests** — `OpenBurnBarReplayGoldens.assertGolden` supports `BURNBAR_UPDATE_GOLDENS=1` for fixture regeneration. Snapshots are JSON-encoded, human-readable, and stored in `AgentLensTests/Fixtures/ReplayGoldens/`. 6 golden assertions cover lexical win, semantic rescue, degraded fallback, filter correctness, and ANN vs exact baseline.

3. **Mock/Stub Discipline** — `SearchServiceTests` defines private `StubSemanticCandidateProvider` and `StubCrossEncoderReranker`. `DailyDigestManagerTests` uses `MockUNUserNotificationCenter` conforming to a protocol. `ArtifactAuthoringServiceTests` uses `StubArtifactAuthoringTextGenerator`.

4. **Degradation Testing** — `OpenBurnBarSearchIntegrationHarnessTests.test_degradedStateAssertions_detectSemanticFailures` forces semantic subsystem degradation and asserts correct fallback behavior.

5. **Perf Guardrails** — `test_projectionPerf_queueLatencyAndThroughput_guardrails` asserts throughput ≥15 jobs/sec and elapsed <15s. `test_retrievalPerf_queryLatency_guardrails_withWarmCorpus` asserts p95 latency <900ms. These are integration-level, not micro-benchmarks.

### Weaknesses (with evidence)

1. **No Pixel Snapshot Testing** — All 16 UI test files (`UI/ChatMessageViewTests.swift`, `UI/HermesThinkingViewTests.swift`, etc.) use `ViewInspector` structural assertions. There is **no SwiftUI snapshot testing**. Visual regressions in dark/light mode, mercury gradients, shimmer effects are unguarded.

2. **Performance Results Not Tracked or Gated** — `PerformanceTests.swift` (609 lines) uses `XCTAssert` with static thresholds but these results are not stored, trended, or made to fail PRs. Performance regressions are **not caught in CI**.

3. **Real Sleeps in Unit Tests** — `ChatSessionControllerSearchStateTests.swift` has explicit `Task.sleep` calls (20ms, 90ms, 160ms) and a `ControlledChatSessionSearchProvider` that sleeps via `Task.sleep`. Under CI CPU contention these races can flake. A deterministic fake scheduler or `AsyncStream` would eliminate this.

4. **Daemon Process Testing Gaps** — Supervisor tests are pure state-machine unit tests. There is no test that actually launches the daemon binary, verifies launchd plist generation, or exercises the Unix socket handshake in the PR harness. The local `test-openburnbar-release-smoke.sh` does this but is **not in CI**.

5. **No Mutation or Property-Based Testing** — No evidence of `SwiftCheck`, Quick/Nimble property tests, or mutation testing tools.

---

## 5. CI/CD Pipeline Assessment

### PR Harness (`.github/workflows/openburnbar-pr-harness.yml`)

- **Runner:** `macos-15`, timeout 30 min.
- **Steps (sequential):**
  1. Checkout
  2. Node 20 setup (for extension)
  3. Conditional Firebase config injection (gracefully skipped for forks)
  4. `npm ci` for extension
  5. `./scripts/test-openburnbar-swift.sh` (OpenBurnBarCore + OpenBurnBarDaemon SPM tests)
  6. `./scripts/test-openburnbar-app.sh` (xcodebuild test for OpenBurnBarTests)
  7. SwiftPM lockfile verification
  8. Coverage extraction + diff coverage (threshold: 80%)
  9. Retrieval replay evals
  10. TypeScript unit tests
  11. Replay evals
  12. Extension-host tests

#### Strengths

- **Diff coverage gate** — `scripts/diff-coverage.sh` enforces 80% on changed Swift files. Posts a markdown table to the GitHub step summary.
- **Retry logic for flaky xcodebuild** — `scripts/test-openburnbar-app.sh` retries up to 2 times when it detects `"test runner hung before establishing connection"`. Pragmatic and well-documented.
- **Fork-safe** — Firebase secrets skipped for external PRs; auth remains disabled in CI.
- **Artifact upload** — Coverage JSONs uploaded as artifacts on failure/success.
- **7 distinct test surfaces** — Swift packages, app tests, TS tests, replay evals, retrieval evals, extension-host tests, lockfile verification.

#### Weaknesses

- **No test matrix** — Single `macos-15` runner, single Xcode version. No macOS 14 or Intel (x86_64) coverage. The app targets macOS 14.0+ but is only tested on macOS 15.
- **No parallel job splitting** — All test surfaces run sequentially in one job. The 30-minute timeout is generous but could tighten as test count grows.
- **No caching of derived data** — Each PR harness run starts with fresh derived data (the app script uses `mktemp`). This is correct for isolation but adds ~2–4 min to every run.
- **Release smoke test is NOT in PR harness** — The release workflow has a `smoke-test` job that mounts the DMG and verifies app launch + daemon socket. This never runs on PRs, so packaging regressions (missing embedded daemon binary, broken entitlements) are only caught at release time.
- **No UI test automation** — No `XCUITest` or Playwright/macOS UI automation runs in CI. The 16 ViewInspector UI tests run as part of the unit test bundle, but they only test view structure.
- **CodeQL not blocking** — CodeQL runs on push/PR/schedule but there is no `needs: codeql` in the PR harness, so security findings do not block merge.

### Release Pipeline (`.github/workflows/release.yml`)

- **Trigger:** `v*` tag push or `workflow_dispatch` with existing tag.
- **Preflight:** Strict validation of 8 required secrets (Apple signing, notary, Firebase).
- **Build:** Unsigned Release `.app`, embeds daemon binary + `libOpenBurnBarCore.dylib` + `OpenBurnBarCore.framework`.
- **Signing:** Deterministic codesign order (frameworks → dylibs → helper → app → DMG). Developer ID with `--timestamp --options runtime`.
- **Notarization:** `notarytool submit --wait --timeout 30m` with issuer fallback to individual key mode.
- **Stapling:** DMG stapled and validated.
- **Artifacts:** DMG, ZIP, SHA256/SHA512 checksums, optional GPG signature, SPDX SBOM, release metadata JSON.
- **Smoke test:** Separate job downloads DMG artifact, mounts it, launches app, verifies daemon Unix socket within 20s.
- **Publish:** GitHub prerelease (`--prerelease --latest=false`).

**Verdict:** The release pipeline is **production-grade** for a macOS app. Notarization, checksums, SBOM, and smoke testing are all present. The only gap is that the smoke test only checks process existence and socket presence — it does not exercise a real JSON-RPC call or verify UI state.

---

## 6. Local Developer Experience

### What's Working

- **`make test` exists and works** — Contrary to the existing `QA_REVIEW_REPORT.md`, the `Makefile` has a `test` target that runs `./scripts/test-openburnbar-swift.sh` and `./scripts/test-openburnbar-app.sh`.
- **`make ci` runs lint + test** — Unified local CI check.
- **`make build` / `make install`** — Clean build-from-source path with daemon embedding and framework copying.
- **XcodeGen source of truth** — `project.yml` avoids `.pbxproj` merge conflicts. Xcode project is generated.
- **Firebase optional** — Local development works without `GoogleService-Info.plist`; auth gracefully disabled.
- **GRDB dedupe workaround** — Documented in `project.yml` (preBuildScripts hack for Xcode 16.x duplicate `GRDB.o`).

### Pain Points

- **Two build systems** — Xcode project for app, SwiftPM for core + daemon. Release workflow must build daemon separately (`swift build --package-path OpenBurnBarDaemon -c release`) and copy artifacts into app bundle. Error-prone if version mismatches occur between Xcode-derived `OpenBurnBarCore.framework` and SPM-built `libOpenBurnBarCore.dylib`.
- **Long test times** — App test script runs all ~64 XCTest classes in one xcodebuild invocation. No target-level filtering for rapid inner-loop development.
- **Extension dev requires Node** — Contributors must have Node 20 + npm installed, separate from Swift toolchain.
- **No derived data caching** — Every `make build` and test run resolves packages fresh.

---

## 7. Release Process Evaluation

- **Tag discipline** — `scripts/tag-release.sh` validates semver, checks `project.yml` version alignment, verifies CHANGELOG presence, creates annotated tag.
- **Changelog** — `CHANGELOG.md` follows Keep a Changelog format. Recent entries (0.1.2-beta series) are well-documented.
- **Rollback runbook** — `docs/RELEASE_ROLLBACK.md` and `scripts/rollback-migration.sh` exist.
- **Version alignment** — `project.yml` has `MARKETING_VERSION: "0.1.2-beta"`. `CURRENT_PROJECT_VERSION: 1` is static and does not increment per build. Crash reporting/support cannot distinguish builds within the same marketing version.
- **SBOM** — `scripts/generate-sbom.py` produces SPDX JSON. Integrated in release workflow.
- **Notarization** — Strict with `--wait --timeout 30m`, issuer fallback, stapling, validation.
- **Smoke test** — Mounts DMG, launches app, checks `pgrep` and socket file existence. **Does not send a JSON-RPC `daemon.health` request or verify response payload.**
- **Homebrew** — `scripts/update-homebrew.sh` exists for post-release cask SHA update, but no automated PR to homebrew-cask in workflow.

---

## 8. Flaky / Disabled / Parked Tests

- **`Parsers/ParserTests.swift`** — PERMANENTLY excluded in `project.yml`. Rationale: references removed private APIs. Coverage migrated to per-provider integration suites.
- **No `XCTSkip` or `@ignore` found** in active test files.
- **No "parked" tests directory** — No `Parked/` folder found in `AgentLensTests/`.
- **Flakiness risk: `ChatSessionControllerSearchStateTests.swift`** — Uses real `Task.sleep` delays (20ms–160ms) to simulate out-of-order search results. Under CI CPU pressure this could become flaky.
- **Flakiness mitigation: `scripts/test-openburnbar-app.sh`** — Retries xcodebuild up to 2 times on `"test runner hung before establishing connection"`. This is a known XCTest/macOS platform bug and the mitigation is pragmatic.

---

## 9. Scoring (1–10)

### Testing: **6 / 10**

**Why:** Large breadth (~99 XCTest classes), excellent harness pattern, strong golden/replay determinism, and deep coverage in retrieval, parsing, and data layers. However, **zero pixel-level visual regression testing**, **performance results not tracked or gated**, **real sleeps in unit tests**, and **no process-level daemon launch tests in CI** cap the score. The prior report incorrectly claimed 5 files were excluded; in reality only 1 legacy file is excluded, which improves the score slightly.

### CI: **7 / 10**

**Why:** Solid PR harness with retry logic, fork safety, diff coverage gate (80%), and 7 distinct test surfaces. However, **single macOS/Xcode version**, **no parallel job splitting**, **no derived data caching**, **no release smoke test in PR**, **CodeQL not blocking merges**, and **all tests sequential in one 30-minute job** create a scalability and regression-ceiling problem.

### Delivery: **9 / 10**

**Why:** Production-grade for an indie macOS app. Notarization, stapling, checksums (SHA256/SHA512), optional GPG signatures, SPDX SBOM, release metadata JSON, strict secrets validation, annotated tag discipline, rollback runbook, and shallow-but-present smoke test. However, **static build number**, **shallow smoke test** (no RPC handshake), **no automated Homebrew PR**, and **pre-release only** (no stable release channel) keep it from a 10.

---

## 10. Overall Maturity Assessment

**Score: 7 / 10 — "Beta velocity is sustainable, but trust ceiling is limited by missing regression gates."**

### What Inspires Confidence

- The release pipeline is **strict and auditable**: notarized DMG, checksums, GPG signatures, SBOM, metadata JSON, and a socket-level smoke test. This is better than most indie macOS apps.
- The **integration harness + golden tests** provide deterministic, replayable verification of the most complex subsystem (hybrid retrieval). Changing embedding or ranking logic without breaking these fixtures is difficult.
- **Diff coverage at 80%** means new code is generally tested. The PR harness runs 7 distinct test surfaces.
- **Operational documentation** (runbook, rollback, database ops, threat model) shows the team has thought about production incidents.

### What Caps Trust

1. **No visual regression testing.** A SwiftUI redesign (like the recent dark-mode slate-blue chrome change) has no automated safety net beyond human code review.
2. **Performance regressions are not caught in CI.** The perf thresholds in `OpenBurnBarSearchIntegrationHarnessTests` are good but narrow. A broad parser slowdown or database query regression could slip through.
3. **The release smoke test is shallow.** It confirms the daemon socket exists, not that it responds to `daemon.health` or that the extension can handshake.
4. **Real sleeps in unit tests introduce flakiness risk.** `ChatSessionControllerSearchStateTests` should use a fake scheduler.
5. **No test matrix.** macOS 14 compatibility is untested in CI.

---

## 11. Prioritized Recommendations

| Priority | Recommendation | Effort | Impact |
|----------|---------------|--------|--------|
| **P0** | Fix/rewrite `ChatSessionControllerSearchStateTests` to eliminate real `Task.sleep` — use a fake async scheduler or `AsyncStream`. | Low | Eliminates CI flakiness |
| **P0** | Extend release smoke test to send JSON-RPC `daemon.health` request and verify response payload. | Low | Catches broken daemon JSON-RPC handshake |
| **P1** | Add SwiftUI snapshot testing (e.g. `SnapshotTesting` package) for 3–5 critical views: Dashboard, Popover, Onboarding. | Medium | Prevents visual regressions |
| **P1** | Track performance test baselines in CI and gate on regression (e.g. store `PerformanceTests.swift` baselines in repo, fail PR if >10% slower). | Medium | Prevents perf regressions |
| **P1** | Add a `matrix` strategy to PR harness: `macos-14` + `macos-15`, or at minimum document why macOS 14 is skipped. | Medium | Ensures compatibility |
| **P2** | Add `needs: codeql` to PR harness merge requirements or at minimum surface CodeQL findings in PR comments. | Low | Security gating |
| **P2** | Increment `CURRENT_PROJECT_VERSION` per build (derive from git commits or CI run ID). | Low | Supportability |
| **P2** | Add `make test-filter` or similar for rapid inner-loop development. | Low | Dev velocity |

---

## 12. Key Finding: Prior Report Inaccuracy

The existing `QA_REVIEW_REPORT.md` in the repo claims that 5 test files are excluded from compilation (`SwitcherCLIAuthCoordinatorTests.swift`, `UsageAggregatorTests.swift`, `ParserTests.swift`, `OpenBurnBarDaemonManagerTests.swift`, `PerformanceTests.swift`). **This is materially incorrect.** Examination of `project.yml` (lines 188–200) shows that **only `Parsers/ParserTests.swift` is excluded**. The other four files are actively compiled and run. Additionally, the prior report claims "No `make test` convenience target" — the `Makefile` clearly defines `make test`.

**Impact:** The prior report overstated the test exclusion problem and understated the actual test coverage. The real gap is quality (visual regression, performance gating, flakiness) not quantity.

---

*End of report.*
