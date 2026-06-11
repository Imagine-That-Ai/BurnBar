# OpenBurnBar QA / Testing / Delivery Process Review

**Date:** 2026-04-27  
**Branch:** `release/openburnbar-0.1.2-beta.12`  
**Reviewer:** Factory Droid (subagent)  

---

## 1. Test Coverage Assessment (Breadth and Depth)

### Surface Inventory

| Target | Location | Classes | Notes |
|--------|----------|---------|-------|
| App unit tests | `AgentLensTests/Active/` | ~64 XCTest classes | 16 dedicated UI test classes in `Active/UI/` |
| Daemon unit tests | `OpenBurnBarDaemon/Tests/` | 15 XCTest classes | HTTP gateway, HNSW, lifecycle, run service, config, usage, agent stack, rate limiter, search, CLI, mission control, provider router, shell |
| Extension tests | `extensions/openburnbar/` | Unit + integration (npm/jest) | Projections, controller, extension-host, cursor-smoke |
| Golden / replay tests | `AgentLensTests/Active/OpenBurnBarRetrievalReplayGoldenTests.swift`<br>`AgentLensTests/Active/OpenBurnBarAuthoringReplayGoldenTests.swift` | 2 classes, 6 golden assertions | Fixture-driven determinism via `OpenBurnBarReplayGoldens.assertGolden` |
| Integration harness tests | `AgentLensTests/Active/OpenBurnBarSearchIntegrationHarnessTests.swift` | 1 class, 9 tests | End-to-end projection → retrieval perf & correctness |

**Total:** ~95+ XCTest classes across app + daemon, plus a TypeScript/jest suite for the VS Code extension.

### Coverage by Domain

- **Data layer:** Strong — `DataStoreTests`, `DatabaseEncryptionServiceTests`, `LocalSearchSchemaStoreTests`, `OpenBurnBarDatabaseMigrationTests`, `OpenBurnBarMigrationTests`, `OpenBurnBarMigrationBackfillRecoveryTests`.
- **Retrieval / search:** Strong — `SearchServiceTests` (~2,000 lines, stubbed semantic provider + reranker), `HybridRetrievalServiceTests`, `OpenBurnBarSearchIntegrationHarnessTests`, golden replay tests for lexical win, semantic rescue, degraded fallback, filter correctness, ANN vs exact baseline.
- **Parser layer:** Strong — per-provider integration suites in `AgentLensTests/Active/Parsers/` (ClaudeCode, FactoryDroid, Kimi, Hermes, CodexToken regression, etc.).
- **Cloud sync:** Moderate–Strong — `CloudSyncServiceTests`, `CloudSyncRetryPolicyTests`, `CloudSyncCircuitBreakerTests`, `RemoteSyncWatermarkTests`, `MultiSourceReconciliationTests`.
- **UI (SwiftUI):** Moderate — 16 `UI/` test files using `ViewInspector` (structural tree inspection), **no pixel-level snapshot testing**.
- **Operating / mission layer:** Strong — `OpenBurnBarOperatingComposerTests` (~2,700 lines), `OpenBurnBarOperatingLayerTests`.
- **Daemon RPC / gateway:** Moderate — `BurnBarHTTPGatewayServerTests`, `BurnBarDaemonServerPRLifecycleTests`, `BurnBarDaemonServerTests`, `OpenBurnBarDaemonSupervisorTests`.
- **Extension:** Moderate — TypeScript unit tests for projections, controller, extension-host; cursor-smoke test.

### Exclusions

`project.yml` explicitly excludes **5 files** from the active `OpenBurnBarTests` target (`AgentLensTests/Active/`):

1. `SwitcherCLIAuthCoordinatorTests.swift` — requires keychain-access-groups sandbox unavailable in CI.
2. `UsageAggregatorTests.swift` — targets a prior `ProviderUsageRecord` schema / billing API (pre-refactor).
3. `Parsers/ParserTests.swift` — legacy monolithic parser file referencing removed private APIs (`parseJSONL`, `dateValue`, `TranscriptSummary`).
4. `OpenBurnBarDaemonManagerTests.swift` — references renamed types (`BurnBarControllerSummary` vs `OpenBurnBarControllerSummary`) and pre-refactor daemon manager API.
5. `PerformanceTests.swift` — uses deprecated `XCTPerformanceMetric` APIs and references renamed types (`TokenUsageRecord`, `fetchAllUsage`).

> **Impact:** ~7% of potential test surface is excluded. Each exclusion is documented with a rationale in `project.yml`, but the gaps are real — especially performance regression gating and auth coordinator coverage.

---

## 2. Test Quality Evaluation

### Strengths

- **Harness pattern:** `OpenBurnBarSearchIntegrationHarness` (`AgentLensTests/Support/OpenBurnBarSearchIntegrationHarness.swift`) is a first-class integration fixture. It provides deterministic fake clock (`OpenBurnBarFakeClock`), fake embedder (`OpenBurnBarFakeEmbedder` with seed + version tag), in-memory GRDB queue, temp file roots, and shared artifact context. This makes retrieval and authoring tests fully deterministic without real embedding models.
- **Golden / replay tests:** `OpenBurnBarReplayGoldens.assertGolden` supports `BURNBAR_UPDATE_GOLDENS=1` for fixture regeneration. Snapshots are JSON-encoded, human-readable, and stored in `AgentLensTests/Fixtures/ReplayGoldens/`.
- **Stub / mock discipline:** `SearchServiceTests` defines private `StubSemanticCandidateProvider` and `StubCrossEncoderReranker`. `ArtifactAuthoringServiceTests` uses `StubArtifactAuthoringTextGenerator`. `DailyDigestManagerTests` uses `MockUNUserNotificationCenter` conforming to a protocol.
- **Degradation testing:** `OpenBurnBarSearchIntegrationHarnessTests.test_degradedStateAssertions_detectSemanticFailures` forces semantic subsystem degradation and asserts correct fallback behavior.
- **Perf guardrails in harness tests:** `test_projectionPerf_queueLatencyAndThroughput_guardrails` asserts throughput ≥15 jobs/sec and elapsed <15s. `test_retrievalPerf_queryLatency_guardrails_withWarmCorpus` asserts p95 latency <900ms. These are integration-level, not micro-benchmarks.

### Weaknesses

- **No pixel snapshot testing:** All 16 UI test files (`UI/ChatMessageViewTests.swift`, `UI/HermesThinkingViewTests.swift`, etc.) use `ViewInspector` structural assertions (`XCTAssertNoThrow(try view.inspect())`, text search). There is **no SwiftUI snapshot testing** (e.g. SnapshotTesting, Percy, or native `XCUIScreenshot`). Visual regressions in dark/light mode, mercury gradients, shimmer effects are unguarded.
- **Performance tests are excluded:** `PerformanceTests.swift` is excluded from compilation. The PR harness therefore **never catches performance regressions** in CI. The only perf assertions that run are inside the integration harness tests, which cover a narrow slice.
- **Real sleeps in unit tests:** `ChatSessionControllerSearchStateTests.swift` uses `Task.sleep(nanoseconds: 20_000_000)`, `90_000_000`, and `160_000_000` to race out-of-order search results. This introduces flakiness under CI load. A deterministic `ControlledChatSessionSearchProvider` with a fake clock or async channel would eliminate this.
- **Limited daemon process-level testing:** The supervisor tests (`OpenBurnBarDaemonSupervisorTests.swift`) are pure state-machine unit tests. There is no test that actually launches the daemon binary, verifies launchd plist generation, or exercises the Unix socket handshake (the release smoke test does this, but not in the PR harness).
- **No mutation or property-based testing:** No evidence of SwiftCheck, Quick/Nimble property tests, or mutation testing tools.

---

## 3. CI/CD Pipeline Assessment

### PR Harness (`.github/workflows/openburnbar-pr-harness.yml`)

- **Runner:** `macos-15`, timeout 30 min.
- **Steps:**
  1. Checkout
  2. Node 20 setup (for extension)
  3. Conditional Firebase config injection (gracefully skipped for forks / missing secrets)
  4. `npm ci` for extension
  5. `./scripts/test-openburnbar-swift.sh` (OpenBurnBarCore + OpenBurnBarDaemon SPM tests)
  6. `./scripts/test-openburnbar-app.sh` (xcodebuild test for OpenBurnBarTests)
  7. SwiftPM lockfile verification
  8. Coverage extraction + diff coverage (threshold: 80%)
  9. Retrieval replay evals
  10. TypeScript unit tests
  11. Replay evals
  12. Extension-host tests

### Strengths

- **Diff coverage gate:** `scripts/diff-coverage.sh` enforces 80% on changed Swift files. Posts a markdown table to the GitHub step summary.
- **Retry logic for flaky xcodebuild:** `scripts/test-openburnbar-app.sh` retries up to 2 times when it detects the string `"test runner hung before establishing connection"` in the xcodebuild log. This is a pragmatic acknowledgement of a known XCTest/macOS platform bug.
- **Fork-safe:** Firebase secrets are skipped for external PRs; auth remains disabled in CI.
- **Artifact upload:** Coverage JSONs are uploaded as artifacts on failure/success.

### Weaknesses

- **No test matrix:** Single `macos-15` runner, single Xcode version. No macOS 14 or Intel (x86_64) coverage. The app targets macOS 14.0+ but is only tested on macOS 15.
- **No parallel job splitting:** All test surfaces run sequentially in one job. The 30-minute timeout is generous but could be tight if the Swift test count grows significantly.
- **No caching of derived data:** Each PR harness run starts with fresh derived data (the app script uses `mktemp` for derived data). This is correct for isolation but adds ~2–4 min to every run.
- **Release smoke test is NOT in PR harness:** The release workflow has a `smoke-test` job that mounts the DMG and verifies app launch + daemon socket. This never runs on PRs, so packaging regressions (e.g. missing embedded daemon binary, broken entitlements) are only caught at release time.
- **No UI test automation:** No `XCUITest` or Playwright/macOS UI automation runs in CI. The 16 ViewInspector UI tests run as part of the unit test bundle, but they only test view structure, not actual rendering or interaction.
- **CodeQL separate but not blocking:** CodeQL runs on push/PR/schedule but there is no evidence it gates merges (no `needs: codeql` in the PR harness).

### Release Pipeline (`.github/workflows/release.yml`)

- **Trigger:** `v*` tag push or `workflow_dispatch` with existing tag.
- **Secrets validation:** Strict preflight — fails if any of 8 required secrets are missing (Apple signing, notary, Firebase).
- **Build:** Unsigned Release `.app`, embeds daemon binary + `libOpenBurnBarCore.dylib` + `OpenBurnBarCore.framework`.
- **Signing:** Deterministic codesign order (frameworks → dylibs → helper → app → DMG). Developer ID with `--timestamp --options runtime`.
- **Notarization:** `notarytool submit --wait --timeout 30m` with issuer fallback to individual key mode.
- **Stapling:** DMG stapled and validated.
- **Artifacts:** DMG, ZIP, SHA256/SHA512 checksums, optional GPG signature, SPDX SBOM, release metadata JSON.
- **Smoke test:** Separate job downloads DMG artifact, mounts it, launches app, verifies daemon Unix socket within 20s.
- **Publish:** GitHub prerelease (`--prerelease --latest=false`).

**Verdict:** The release pipeline is **production-grade** for a macOS app. Notarization, checksums, SBOM, and smoke testing are all present. The only gap is that the smoke test only checks process existence and socket presence — it does not exercise a real RPC call or verify UI state.

---

## 4. Release Process Evaluation

- **Tag discipline:** `scripts/tag-release.sh` validates semver, checks `project.yml` version alignment, verifies CHANGELOG presence, and creates an annotated tag. This prevents accidental mismatched releases.
- **Changelog:** `CHANGELOG.md` follows Keep a Changelog format. Recent releases are well-documented. Prior releases are summarized in a "Prior Releases" section rather than detailed per-version.
- **Rollback runbook:** `docs/RELEASE_ROLLBACK.md` and `scripts/rollback-migration.sh` exist.
- **Version alignment:** `project.yml` has `MARKETING_VERSION: "0.1.2-beta"`. `CURRENT_PROJECT_VERSION: 1` — this is static and may not increment per build. Consider deriving build number from git commits or CI run ID.
- **Pre-release flag:** Releases are published as GitHub prereleases. This is appropriate for a beta product but means users must explicitly opt into prerelease downloads.
- **Homebrew:** `scripts/update-homebrew.sh` exists for post-release cask SHA update, but no evidence of automated PR to homebrew-cask in the workflow.

---

## 5. Developer Experience Assessment

### Local Development

- **No Xcode project file conflicts:** `project.yml` is the source of truth; Xcode project is generated via XcodeGen. This avoids `.pbxproj` merge hell.
- **Test scripts are well-factored:**
  - `scripts/test-openburnbar-swift.sh` — SPM tests for core + daemon.
  - `scripts/test-openburnbar-app.sh` — xcodebuild with retry, coverage, and temp derived data.
  - `scripts/test-openburnbar-ts.sh` — extension unit tests.
  - `scripts/test-openburnbar-retrieval-evals.sh` — golden tests only.
  - `scripts/test-openburnbar-replay-evals.sh` — replay evals via npm.
  - `scripts/test-openburnbar-extension-host.sh` — extension integration + parity evidence.
  - `scripts/test-openburnbar-release-smoke.sh` — full local release smoke (builds Release app, launches daemon via launchd, probes Unix socket).
- **Firebase optional:** Local development works without `GoogleService-Info.plist`; auth is gracefully disabled.
- **GRDB dedupe workaround:** `project.yml` includes a `preBuildScripts` hack to remove duplicate `GRDB.o` entries from LinkFileList under Xcode 16.x. This is documented but brittle — it will break when Xcode 17 arrives and the script is gated on `XCODE_VERSION_MAJOR -lt 1700`.

### Pain Points

- **Two build systems:** Xcode project for the app, SwiftPM for core + daemon. The release workflow must build the daemon separately (`swift build --package-path OpenBurnBarDaemon -c release`) and then copy artifacts into the app bundle. This is error-prone if version mismatches occur between the Xcode-derived `OpenBurnBarCore.framework` and the SPM-built `libOpenBurnBarCore.dylib`.
- **No Makefile-driven test:** `Makefile` has `release-checksums` and `sbom`, but no `make test` target that runs the full local matrix. Developers must remember which script to run.
- **Long test times:** The app test script runs all ~64 XCTest classes in one xcodebuild invocation. No target-level filtering for rapid inner-loop development.
- **Extension dev requires Node:** Contributors must have Node 20 + npm installed, separate from the Swift toolchain.

---

## 6. Documentation Quality

### Developer Onboarding

- **`docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md`:** Clear setup steps for the Cursor extension, workspace modes, and recovery paths. Lists supported (Z.ai, MiniMax) and unsupported providers.
- **`AgentLensTests/README.md`:** Explains Active / Support / Fixtures folder contract, how to run the active bundle, and why certain suites are excluded.
- **`QUICKSTART.md`:** Present at repo root for new contributors.
- **`AGENTS.md` / `CLAUDE.md`:** AI-agent-specific coding standards and the "completion bar" philosophy.

### Operational Docs

- **`docs/RUNBOOK.md`:** 6 incident types (daemon not starting, database corruption, cloud sync failure, search degradation, extension disconnect, memory pressure). Includes diagnosis commands and remediation steps.
- **`docs/DATABASE_OPERATIONS.md`:** Migration catalog, rollback strategies, drill procedures.
- **`docs/RELEASE_ROLLBACK.md`:** Decision tree and hotfix procedures.
- **`docs/RELEASE_MACOS.md`:** Comprehensive release documentation including provenance, SBOM, checksums, GPG verification.
- **`docs/THREAT_MODEL.md`:** STRIDE-based model, Firebase App Check enforcement path, keychain storage rationale.

### Test Documentation

- Excluded suites in `project.yml` have inline YAML comments explaining the blocker and un-parking path. This is excellent — it prevents future developers from wondering "why is this excluded?"
- VAL-assertion tags in tests (e.g. `VAL-DASH-001`, `VAL-CTXCROSS-001`) trace tests back to a spec or requirement. This is visible in `SwitcherDashboardUITests.swift` and `ContextPackCrossFlowTests.swift`.

---

## 7. Specific Gaps and Weaknesses (with Evidence)

| # | Gap | Evidence | Risk |
|---|-----|----------|------|
| 1 | **5 test files excluded from compilation** | `project.yml` lines under `OpenBurnBarTests.sources.excludes` | Medium — keychain auth, billing reconciliation, performance, legacy parser, and daemon manager coverage missing |
| 2 | **No pixel-level snapshot / visual regression testing** | All 16 `UI/*Tests.swift` files use `ViewInspector` only (`UI/ChatMessageViewTests.swift`, `UI/HermesThinkingViewTests.swift`) | Medium — dark/light mode regressions, gradient/shimmer changes uncaught |
| 3 | **Performance tests excluded from CI** | `PerformanceTests.swift` excluded in `project.yml`; reason: deprecated `XCTPerformanceMetric` APIs | Medium — no automated regression gate for parse, DB, projection, or semantic search latency |
| 4 | **Real `Task.sleep` delays in unit tests** | `ChatSessionControllerSearchStateTests.swift` lines 29, 37, 42, 73, 78, 313 | Low–Medium — flakiness under CI CPU pressure; 20–160ms sleeps are short but unnecessary with a fake scheduler |
| 5 | **Release smoke test does not exercise RPC** | `.github/workflows/release.yml` smoke-test job checks `pgrep -x OpenBurnBar` and socket existence only | Low — a broken daemon that launches but fails JSON-RPC handshake would pass |
| 6 | **No test matrix (single macOS/Xcode version)** | `.github/workflows/openburnbar-pr-harness.yml` uses `macos-15` only | Low — macOS 14 compatibility is untested in CI |
| 7 | **Diff coverage only; no global coverage floor** | `scripts/diff-coverage.sh` threshold = 80%; `scripts/extract-coverage.sh` reports overall % but does not gate | Low — legacy untested code can remain untested indefinitely |
| 8 | **No automated Homebrew cask PR** | `scripts/update-homebrew.sh` exists but is not invoked in `release.yml` | Low — manual step post-release |
| 9 | **Extension tests are separate toolchain** | PR harness runs `npm ci` + `npm test` in addition to Swift tests | Low — adds ~2–3 min to PR time and another failure surface |
| 10 | **No `make test` convenience target** | `Makefile` lacks a unified local test target | Low — developer friction |
| 11 | **Static `CURRENT_PROJECT_VERSION: 1`** | `project.yml` | Low — build numbers do not increment; crash reporting / support cannot distinguish builds within the same marketing version |
| 12 | **GRDB LinkFileList dedupe script is version-gated** | `project.yml` `preBuildScripts` checks `XCODE_VERSION_MAJOR -lt 1700` | Low — will silently re-duplicate when Xcode 17 ships and the script no longer runs |

---

## 8. Verdict: Can the Team Ship Fast Without Breaking Trust?

### Overall Assessment: **Conditional Yes — Beta Velocity is Sustainable, but Trust Ceiling is Limited by Missing Regression Gates**

**What inspires confidence:**

- The release pipeline is **strict and auditable**: notarized DMG, checksums, GPG signatures, SBOM, metadata JSON, and a socket-level smoke test. This is better than most indie macOS apps.
- The **integration harness + golden tests** provide deterministic, replayable verification of the most complex subsystem (hybrid retrieval). Changing embedding or ranking logic without breaking these fixtures is difficult.
- **Diff coverage at 80%** means new code is generally tested. The PR harness runs 7 distinct test surfaces (Swift, app, TS, replay, retrieval, extension-host, lockfile).
- **Operational documentation** (runbook, rollback, database ops, threat model) shows the team has thought about production incidents.

**What caps trust:**

1. **Excluded tests represent real, known blind spots.** The team has chosen to park `PerformanceTests`, `UsageAggregatorTests`, and `SwitcherCLIAuthCoordinatorTests` rather than fix them. In a pre-release product this is acceptable; in a 1.0 it would not be.
2. **No visual regression testing.** A SwiftUI redesign (like the recent dark-mode slate-blue chrome change) has no automated safety net beyond human code review.
3. **Performance regressions are not caught in CI.** The perf thresholds in `OpenBurnBarSearchIntegrationHarnessTests` are good but narrow. A broad parser slowdown or database query regression could slip through.
4. **The release smoke test is shallow.** It confirms the daemon socket exists, not that it responds to `daemon.health` or that the extension can handshake.

### Recommendation

For the current **beta/pre-release** posture, the team can ship fast. The pipeline is robust enough that a bad build is unlikely to reach users. To move toward a trusted 1.0:

1. **Un-park the 5 excluded test files** (especially `PerformanceTests.swift` and `SwitcherCLIAuthCoordinatorTests.swift`) or delete them and replace with targeted coverage.
2. **Add a minimal visual regression test** (e.g. `SnapshotTesting` Swift package) for 2–3 critical views (Dashboard, Popover, Onboarding).
3. **Extend the release smoke test** to send a JSON-RPC `daemon.health` request and verify the response payload.
4. **Add a global coverage floor** (e.g. 60%) in addition to the 80% diff threshold.
5. **Introduce a `make test` target** that runs the full local matrix so developers catch issues before pushing.

---

*End of report.*
