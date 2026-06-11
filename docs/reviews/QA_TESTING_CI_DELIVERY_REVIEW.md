# QA / Testing / CI / Delivery Review — OpenBurnBar

**Date:** 2026-05-08  
**Branch:** `main`  
**Reviewer:** Factory Droid Sub-Agent 6 (QA / Testing / Delivery Process Reviewer)

---

## 1. Executive Summary

OpenBurnBar's testing, CI/CD, and delivery infrastructure is **unusually sophisticated for a beta macOS app**. The project has production-grade release discipline (notarized DMG, SBOM, checksums, GPG signatures, smoke test) and deep, deterministic test coverage in its highest-risk subsystems (retrieval, parsing, data persistence, mission orchestration). Two prior reviews exist in the repo (`QA_REVIEW_REPORT.md` and `QA_TESTING_CI_REVIEW_REPORT.md`, both from 2026-04-27) and this report cross-references and updates their findings.

**Key changes since those reviews:**
- **Snapshot testing has been added.** There are now 7 SnapshotTests files under `AgentLensTests/Active/UI/SnapshotTests/` using the `SnapshotTesting` Swift package, covering adaptive colors, card layouts, Mercury gradients, chat visuals, dashboard, and onboarding. `SnapshotTestSupport.swift` provides `assertAdaptiveSnapshot()` for light/dark mode coverage. This directly addresses the #1 weakness in both prior reports.
- **Runner upgraded to `macos-26`** (was `macos-15`). Timeout increased to 45 min (was 30 min).
- **Shell syntax validation and version consistency checks** added as PR harness steps.
- **Functions (`functions/`) lint, build, and test steps** now run in the PR harness.
- **Firestore rules emulator tests** now run in the PR harness.
- **`make test` and `make ci` targets** confirmed to exist and work (contrary to the 2026-04-27 `QA_REVIEW_REPORT.md` which claimed no `make test`).
- **5 files are NOT excluded from compilation** — the 2026-04-27 `QA_REVIEW_REPORT.md` was materially incorrect on this point. Only `ParserTests.swift` is permanently excluded (legacy monolithic file). The `QA_TESTING_CI_REVIEW_REPORT.md` already corrected this. I verified `project.yml` — only 1 file is excluded.

---

## 2. Test Inventory

### 2.1 Surface Count

| Target | Location | Test Files | Total Lines (approx) | Notes |
|--------|----------|-----------|----------------------|-------|
| App unit tests | `AgentLensTests/Active/` | ~85 files | ~700K+ | Includes 26 SnapshotTests + 20 other UI tests, plus comprehensive service, parser, and integration tests |
| Daemon unit tests | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/` | 15 files | ~560K | HTTP gateway, HNSW, lifecycle, run service, config, usage, agent stack, rate limiter, search, CLI, mission control, provider router, shell |
| Core unit tests | `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/` | 23 files | ~200K | HNSW vector index, search planner, run state machine, protocol versions, mission control contracts, catalog, terminal session, CLI launch/auth/discovery, Hermes atoms, attachments, relay, provider accounts |
| Mobile tests | `OpenBurnBarMobileTests/` | 24 files | Moderate | Onboarding wizard, chart studio, theme, quota, cloud codables, trend, hermes service, UI modes, provider avatars, escrow crypto, gallery |
| Extension tests | `extensions/openburnbar/` | Unit + integ (jest) | Moderate | Projections, controller, extension-host, cursor-smoke |
| Golden / replay | `AgentLensTests/Active/OpenBurnBarRetrievalReplayGoldenTests.swift` + `OpenBurnBarAuthoringReplayGoldenTests.swift` | 2 files | ~30K | 6+ golden assertions, fixture-driven determinism |
| Integration harness | `AgentLensTests/Active/OpenBurnBarSearchIntegrationHarnessTests.swift` | 1 file, 9+ tests | ~25K | End-to-end projection → retrieval perf & correctness |
| Functions tests | `functions/` | Jest | Moderate | Lint + build + test + Firestore rules emulator |

**Total: ~150+ test files across all targets. Well over 1M lines of test code.**

### 2.2 Support Infrastructure

`AgentLensTests/Support/` provides a robust testing foundation:

| File | Lines | Purpose |
|------|-------|---------|
| `OpenBurnBarSearchIntegrationHarness.swift` | ~26K | Deterministic fake clock, fake embedder (seed + version tag), in-memory GRDB, temp file roots, shared artifact context |
| `ParserIntegrationTestSupport.swift` | ~21K | Shared parser test fixtures and helpers |
| `MockBurnBarDaemonSocketClient.swift` | ~10K | Mock daemon socket client for testing |
| `TestableClaudeCodeParser.swift` | ~9K | Testable parser subclass |
| `TestableFactoryDroidParser.swift` | ~7K | Testable parser subclass |
| `SnapshotTestSupport.swift` | ~6K | `renderViewSnapshot()` + `assertAdaptiveSnapshot()` for light/dark mode visual regression testing |
| `ReplayGoldenSupport.swift` | ~6K | Golden assertion infrastructure with `BURNBAR_UPDATE_GOLDENS=1` for regeneration |
| `SettingsTestSupport.swift` | ~6K | Settings test helpers |
| `ViewFixtures.swift` | ~5K | Shared SwiftUI view fixtures |
| Others | ~5K | CloudSync, FakeMacDeviceTrustGateway, type aliases |

### 2.3 Quarantine

`AgentLensTests/Quarantine/` contains 18 test files (~80K lines) that are **not compiled** and are excluded from CI. The `QUARANTINE_MANIFEST.md` tracks 24 Wave 2 quarantined tests + 2 legacy suites (`ParserTests`, `PerformanceTests`), all with revival criteria and target dates.

**Summary of excluded code:**
- Only 1 file permanently excluded in `project.yml`: `Parsers/ParserTests.swift` (legacy monolithic, references removed private APIs)
- 18 files in `Quarantine/` excluded by directory convention (stale contracts, environmental dependencies)
- Impact: ~1.5% of potential test surface is currently excluded

---

## 3. Coverage by Domain

### 3.1 Impressively Tested

| Domain | Evidence | Depth |
|--------|----------|-------|
| **Retrieval / Search** | `SearchServiceTests` (~80K), `HybridRetrievalServiceTests` (~38K), `OpenBurnBarSearchIntegrationHarnessTests` (~26K), golden replay tests | **Strong** — Deterministic fake embedder, fake clock, in-memory GRDB. Degradation and perf guardrails included |
| **Data / Persistence** | `DataStoreTests`, `DatabaseEncryptionServiceTests`, `LocalSearchSchemaStoreTests`, `OpenBurnBarDatabaseMigrationTests`, `OpenBurnBarMigrationTests`, `CheckpointTests` | **Strong** — Migrations versioned, encryption verified, schema evolution covered |
| **Parser Layer** | `ClaudeCodeParserIntegrationTests`, `FactoryDroidParserIntegrationTests`, `KimiParserTests`, `HermesParserIntegrationTests`, `CodexTokenAccountingRegressionTests` | **Strong** — Integration + regression + token accounting. Testable parser subclasses in Support/ |
| **Cloud Sync** | `CloudSyncServiceTests` (~33K), `CloudSyncRetryPolicyTests`, `CloudSyncCircuitBreakerTests`, `RemoteSyncWatermarkTests`, `MultiSourceReconciliationTests` (~43K) | **Strong** — Retry, circuit breaker, watermark, reconciliation all exercised |
| **Projection Pipeline** | `ProjectionPipelineServiceTests` (~185K) | **Strong** — Massive coverage: crash recovery, dedup, enqueue suppression, selective reproject, health sweep |
| **Operating / Mission** | `OpenBurnBarOperatingComposerTests` (~126K), `OpenBurnBarOperatingLayerTests` (~23K) | **Strong** — Complex mission authoring and layer orchestration |
| **Context Packs** | `ContextPackServiceTests`, `ContextPackCrossFlowTests`, `ContextPackDashboardSurfaceTests`, `ContextPackSessionDetailSurfaceTests`, `ContextPackExportTests` | **Strong** — Cross-flow, surface, and export coverage |
| **Daemon** | `OpenBurnBarRunServiceTests` (~103K), `OpenBurnBarDaemonServerTests` (~51K), `OpenBurnBarMissionControlServiceTests` (~250K), `OpenBurnBarHTTPGatewayServerTests`, `BurnBarDaemonServerPRLifecycleTests` | **Strong** — HTTP gateway, lifecycle, PR lifecycle, provider routing, mission control |
| **Switcher / Account** | `SwitcherCrossFlowTests`, `SwitcherDashboardUITests`, `SwitcherPopoverUITests`, `SwitcherCLIAuthCoordinatorTests`, `SwitcherSettingsUITests` | **Strong** — Cross-surface, auth, launch, settings |
| **Token Accounting** | `TokenAccountingPrecedenceTests`, `TokenUsageProvenanceTests` | **Strong** — Provenance tracking and precedence rules |
| **Settings** | `SettingsManagerTests` (~53K), `SettingsManagerSecretStorageTests` | **Strong** |

### 3.2 Adequately Tested

| Domain | Evidence | Notes |
|--------|----------|-------|
| **Visual Regression** | 7 SnapshotTest files (`AdaptiveColorSnapshotTests`, `CardLayoutSnapshotTests`, `ChatVisualSnapshotTests`, `DashboardVisualSnapshotTests`, `MercuryGradientSnapshotTests`, `OnboardingVisualSnapshotTests`, etc.) | **New since prior reviews — was "dangerously undertested" before.** Uses `SnapshotTesting` package with light/dark mode coverage. |
| **UI Components** | 20 structural UI tests (`ChatMessageViewTests`, `DashboardLaneViewTests`, `HermesToolCardTests`, etc.) | ViewInspector structural assertions plus SnapshotTesting visual assertions |
| **Mobile** | 24 test files (`CloudModelCodableTests`, `OnboardingWizardFlowTests`, `ChartSpecRendererTests`, `HermesServiceTests`, etc.) | Good breadth. Some are codable roundtrip tests rather than UI integration |
| **Functions** | Jest tests for Firebase Functions + Firestore rules emulator | Lint + build + test all run in CI |
| **Extension** | TypeScript jest tests for projections, controller, extension-host, cursor-smoke | Unit + integration |

### 3.3 Undercovered

| Domain | Evidence | Risk |
|--------|----------|------|
| **Performance Regression Gating** | `PerformanceTests.swift` is quarantined (24K lines of benchmarks). The integration harness has perf guardrails (p95 latency <900ms, throughput ≥15 jobs/sec) but these are narrow. | **Medium** — A broad parser or DB query slowdown could slip through |
| **Daemon Process-Level Testing** | Supervisor tests are pure state-machine unit tests. No test launches the actual daemon binary in the PR harness | **Medium** — A broken daemon binary that compiles but crashes on launch would pass CI |
| **E2E / UI Automation** | No `XCUITest` or Playwright UI automation in CI. `qa.yml` runs a Droid-driven functional QA but it's informational only | **Low-Medium** |

---

## 4. Test Quality Evaluation

### 4.1 Strengths

1. **Integration Harness Pattern** — `OpenBurnBarSearchIntegrationHarness` is first-class (26K lines). Provides deterministic fake clock, fake embedder (seeded + version-tagged), in-memory GRDB, temp file roots, shared artifact context. Retrieval and authoring tests are fully deterministic—no real embedding models needed.

2. **Golden / Replay Tests** — `OpenBurnBarReplayGoldens.assertGolden` with `BURNBAR_UPDATE_GOLDENS=1` for regeneration. Snapshots are JSON, human-readable, stored in `AgentLensTests/Fixtures/ReplayGoldens/`.

3. **Visual Regression Testing** — 7 SnapshotTest files using `SnapshotTesting` package with `assertAdaptiveSnapshot()` for light/dark mode coverage. Covers colors, cards, Mercury gradients, chat, dashboard, and onboarding. **This is a new addition that directly addresses the top weakness in both prior reviews.**

4. **Mock/Stub Discipline** — Private stub classes defined inline: `StubSemanticCandidateProvider`, `StubCrossEncoderReranker`, `StubArtifactAuthoringTextGenerator`, `MockUNUserNotificationCenter`, `ControlledChatSessionSearchProvider`.

5. **Degradation Testing** — `test_degradedStateAssertions_detectSemanticFailures` forces semantic subsystem degradation and asserts correct fallback.

6. **Perf Guardrails** — Integration-level: throughput ≥15 jobs/sec, elapsed <15s, p95 latency <900ms.

7. **Testable Parser Subclasses** — `TestableClaudeCodeParser`, `TestableCodexParser`, `TestableFactoryDroidParser` in Support/ allow injecting controlled file contents without touching real filesystems.

8. **VAL Assertion Tags** — Tags like `VAL-DASH-001`, `VAL-CTXCROSS-001` trace tests to specs/requirements.

### 4.2 Weaknesses

1. **Real `Task.sleep` in Unit Tests** — `ChatSessionControllerSearchStateTests.swift` uses `Task.sleep(20ms/90ms/160ms)` and `ControlledChatSessionSearchProvider` sleeps via configurable delays. Under CI CPU pressure, these races can flake. A deterministic fake scheduler or `AsyncStream`/`AsyncChannel` would eliminate this. **Both prior reviews flagged this — it's still present.**

2. **Performance Tests Are Quarantined** — 24K lines of `PerformanceTests.swift` are in Quarantine, not compiled. The integration harness perf guardrails are good but narrow. No automated regression gate for parser speed, DB query latency, or semantic search performance.

3. **No Performance Baseline Tracking** — Perf results from `measure` blocks or integration guardrails are not stored, trended, or made to block PRs.

4. **Quarantine Backlog** — 24 quarantined tests with specific revival criteria. Many had target dates of 2026-05-17 (9 days from now). Progress tracking is unclear.

5. **No Property-Based or Mutation Testing** — No `SwiftCheck`, Quick/Nimble property tests, or mutation testing.

---

## 5. CI/CD Pipeline Assessment

### 5.1 PR Harness (`.github/workflows/openburnbar-pr-harness.yml`)

**Runner:** `macos-26`, timeout 45 min (upgraded from macos-15/30 min in prior reviews)

**Steps (sequential):**
1. Checkout
2. Shell script syntax validation **(NEW)**
3. Version consistency check **(NEW)**
4. Node 22 setup
5. Conditional Firebase config injection (fork-safe)
6. `npm ci` for extension
7. `npm ci` for functions **(NEW)**
8. Functions lint **(NEW)**
9. Functions build **(NEW)**
10. Functions test **(NEW)**
11. Swift package tests (core + daemon)
12. App tests (xcodebuild with retry)
13. SwiftPM lockfile verification
14. Coverage extraction + diff coverage (80% threshold)
15. Coverage summary post
16. Retrieval replay evals
17. TypeScript unit tests
18. Replay evals
19. Extension-host tests
20. Firestore rules emulator tests **(NEW)**
21. CodeQL workflow verification

**Total: 21 steps, 13 distinct test/eval surfaces**

#### Strengths
- **Diff coverage gate at 80%** on changed Swift files
- **Retry logic** for flaky xcodebuild (up to 4 attempts with exponential backoff, detects known hang families)
- **Fork-safe** — Firebase secrets gracefully skipped
- **Structured telemetry** — JSONL attempt logs, markdown step summary
- **Shell syntax validation** — Proactive prevention of script breakage
- **Functions + Firestore rules in CI** — Cloud backend tests run on every PR
- **Version consistency** — Prevents mismatched `project.yml` vs README versions

#### Weaknesses
- **No test matrix** — Single `macos-26` runner. No macOS 14 or 15, no Intel. App targets macOS 14.0+ but is only tested on macOS 26
- **Sequential execution** — All 21 steps in one job. No parallel splitting
- **No derived data caching** — Fresh derived data each run (correct for isolation, adds 2-4 min)
- **Release smoke test not in PR harness** — DMG mount + daemon socket check only at release time
- **No `XCUITest` automation** — Functional QA (`qa.yml`) is informational only
- **CodeQL not blocking** — Runs separately, no merge gate

### 5.2 Release Pipeline (`.github/workflows/release.yml`)

**Trigger:** `v*` tag push or `workflow_dispatch`  
**Runner:** `macos-26`, timeout 60 min

**Pipeline:**
1. Strict secrets validation (8 required)
2. Run full test suite (Swift + app + TypeScript)
3. Build unsigned Release `.app`
4. Embed daemon binary + `libOpenBurnBarCore.dylib` + `OpenBurnBarCore.framework`
5. Developer ID codesign (deterministic order: frameworks → dylibs → helper → app → DMG)
6. Notarization (`notarytool submit --wait --timeout 30m`, issuer fallback)
7. Stapling + validation
8. DMG + ZIP artifacts
9. SHA256/SHA512 checksums
10. Optional GPG signature
11. SPDX SBOM (JSON)
12. Release metadata JSON
13. Smoke test (mounts DMG, launches app, checks socket)
14. GitHub prerelease publish

**Verdict:** **Production-grade** for an indie macOS app. Notarization, checksums, SBOM, GPG, smoke test, and strict secrets validation are all present.

**Gap:** Smoke test only checks `pgrep` + socket file existence. Does not send a JSON-RPC `daemon.health` request.

### 5.3 Functional QA Workflow (`.github/workflows/qa.yml`)

- **Informational only** — posts PR comment, does not block merge
- Uses `droid exec` to run the `qa` skill
- Installs `tuistory`, `imagemagick`, extension deps
- Requires 14 secrets (Factory, Firebase, Anthropic, OpenAI, OpenRouter, Z.ai, MiniMax, Sentry)
- Posts report as PR comment with workflow run link
- **Verdict:** Aspirational but fragile — depends on Droid availability, many API keys, and `macos-15` runner

---

## 6. Dependency Management

### Dependabot (`.github/dependabot.yml`)

**Well-configured across 4 ecosystems:**

| Ecosystem | Directory | Schedule | Limit |
|-----------|-----------|----------|-------|
| npm | `/extensions/openburnbar` | Weekly Mon 9am PT | 10 PRs |
| Swift | `/OpenBurnBarCore` | Weekly Mon 9am PT | 5 PRs |
| Swift | `/OpenBurnBarDaemon` | Weekly Mon 9am PT | 5 PRs |
| GitHub Actions | `/` | Weekly Mon 9am PT | 3 PRs |

**Strengths:**
- npm dependencies grouped by dev/production with minor+patch auto-merge
- GitHub Actions pinned to SHA for supply-chain security
- Weekly cadence is appropriate

**Gap:** No dependabot for `functions/` npm dependencies (separate `package.json`)

### Pre-commit Hooks
**No pre-commit hooks found** — no `.pre-commit-config.yaml`, no `.githooks/`, no Husky configuration. All validation runs in CI rather than pre-commit. This is acceptable for a small team but could shift-left some failures.

---

## 7. Local Developer Experience

### What's Working

| Feature | Evidence |
|---------|----------|
| `make build` | Builds Release .app + daemon + embeds helpers |
| `make install` | Builds signed .app → `/Applications` |
| `make test` | Runs Swift package tests + app tests |
| `make lint` | Runs SwiftLint if installed |
| `make ci` | `lint` + `test` (full local CI) |
| `make clean` | Removes derived data + cache |
| `make release-checksums` | SHA256/SHA512 checksums |
| `make sbom` | SPDX SBOM generation |
| Firebase optional | Local dev works without `GoogleService-Info.plist` |
| XcodeGen source of truth | `project.yml` avoids `.pbxproj` merge conflicts |
| Cache clearing script | `scripts/clear-xcode-caches.sh` for stale artifacts |
| QUICKSTART.md | Clear 2-minute onboarding |
| CONTRIBUTING.md | Detailed architecture + how to add a parser |
| `AGENTS.md` / `CLAUDE.md` | AI agent coding standards |

### Pain Points

1. **Two build systems** — Xcode project for app, SwiftPM for core + daemon. Release must build daemon separately and copy artifacts
2. **Long test times** — All ~85 XCTest classes in one `xcodebuild` invocation
3. **Extension dev requires Node 22** — Separate toolchain from Swift
4. **No derived data caching** — Every build/test resolves packages fresh
5. **No `make test-filter`** for rapid inner-loop development
6. **GRDB dedupe script gated on Xcode version** — Will break silently when Xcode 17 ships

---

## 8. Version Management

- **`MARKETING_VERSION`:** `"0.1.2-beta"` in `project.yml`
- **`CURRENT_PROJECT_VERSION`:** `1` — static, does not increment per build
- **Tagging:** `scripts/tag-release.sh` validates semver, checks alignment, verifies CHANGELOG, creates annotated tag
- **Changelog:** Follows Keep a Changelog. Current entries are comprehensive and well-written (Conversation Atoms, Hermes attachments, iOS Pulse, commercial launch gates)
- **Rollback:** `docs/RELEASE_ROLLBACK.md` + `scripts/rollback-migration.sh`
- **Version consistency check:** CI step `verify-version-consistency.sh` prevents mismatches

---

## 9. Scoring

### Testing: **7.5 / 10** *(up from 6/10 in the 2026-04-27 reviews)*

**Why higher:**
- Snapshot testing has been added (7 test files, `SnapshotTesting` package, adaptive light/dark mode coverage). This was the #1 gap in prior reviews.
- Functions + Firestore rules tests now run in CI.
- Shell syntax + version consistency checks added.
- Only 1 file truly excluded (not 5 as prior report claimed).

**Why not higher:**
- Real `Task.sleep` in `ChatSessionControllerSearchStateTests` still creates flakiness risk.
- Performance tests are still quarantined (24K lines).
- No performance baseline tracking or regression gating.
- 24 tests in quarantine with approaching target dates.
- No property-based or mutation testing.

### CI: **7.5 / 10** *(up from 7/10)*

**Why higher:**
- Runner upgraded to macos-26, timeout increased to 45 min.
- 4 new steps added (shell validation, version consistency, functions tests, Firestore rules emulator).
- 13 distinct test surfaces now run.

**Why not higher:**
- Still single runner, single macOS version.
- Still sequential execution.
- Still no derived data caching.
- Release smoke test not in PR harness.
- CodeQL not blocking.

### Delivery: **9 / 10** *(unchanged)*

**Why:**
- Production-grade release pipeline with notarization, stapling, checksums (SHA256/SHA512), GPG signatures, SPDX SBOM, release metadata JSON, strict secrets validation.
- Annotated tag discipline with scripted validation.
- Dependabot across 4 ecosystems.
- Rollback runbook and migration rollback scripts.

**Why not 10:**
- Static `CURRENT_PROJECT_VERSION: 1` (no build-number increment).
- Shallow smoke test (no JSON-RPC handshake verification).
- No automated Homebrew cask PR.
- Pre-release only (no stable release channel).

---

## 10. Overall Maturity Assessment

**Score: 8 / 10 — "Beta velocity is sustainable with improving trust ceiling."**

### What Inspires Confidence

1. **The release pipeline is strict and auditable.** Notarized DMG, checksums, GPG signatures, SBOM, metadata JSON, socket-level smoke test. This is better than most indie macOS apps.

2. **The integration harness + golden tests provide deterministic, replayable verification** of the most complex subsystems. Changing embedding or ranking logic without breaking fixtures is difficult.

3. **Visual regression testing is now present.** The addition of `SnapshotTesting` with adaptive light/dark mode coverage directly addresses the #1 gap from prior reviews.

4. **13 distinct test/eval surfaces run on every PR.** Diff coverage at 80% means new code is tested.

5. **Operational documentation is comprehensive.** Runbook, rollback, database ops, threat model, release architecture docs are all present.

6. **Dependabot automates dependency updates** across npm, Swift (2 packages), and GitHub Actions.

7. **Test infrastructure is reusable.** Support/ provides harnesses, mock clients, testable parser subclasses, snapshot helpers, and golden assertion infrastructure.

### What Caps Trust

1. **Real `Task.sleep` in unit tests remains a flakiness risk.** `ChatSessionControllerSearchStateTests` uses 20-160ms sleeps + configurable-delay providers. This was flagged in both prior reviews and persists.

2. **Performance regression is not systematically guarded.** `PerformanceTests.swift` is quarantined. The integration harness has perf guardrails but they're narrow.

3. **The release smoke test is shallow.** Confirms daemon socket exists, not that it responds to JSON-RPC `daemon.health`.

4. **No test matrix.** macOS 14 compatibility is untested in CI. The app targets macOS 14+ but runs only on macOS 26.

5. **Quarantine backlog.** 24 tests with revival criteria, many approaching their target dates.

---

## 11. Top 5 Testing/Delivery Improvements Needed

| # | Improvement | Priority | Effort | Impact |
|---|------------|----------|--------|--------|
| 1 | **Eliminate `Task.sleep` from `ChatSessionControllerSearchStateTests`** — Replace with a fake scheduler, `AsyncStream`, or `AsyncChannel`. Tests should be fully deterministic. | **P0** | Low | Eliminates CI flakiness risk |
| 2 | **Deepen release smoke test** — Send `{"jsonrpc":"2.0","method":"daemon.health","id":1}` to the Unix socket and verify `{"result":{"status":"ok"}}`. | **P0** | Low | Catches broken daemon RPC handshake before users download |
| 3 | **Un-quarantine or replace `PerformanceTests.swift`** — Either fix the 24K lines of benchmarks for current contracts, or write 5-8 targeted perf tests (parser throughput, DB query latency, semantic search p95) with tracked baselines and CI regression gating. | **P1** | Medium | Prevents perf regressions |
| 4 | **Add macOS version matrix** — Add `macos-15` to PR harness strategy or document why it's skipped. The app targets macOS 14.0+. | **P1** | Medium | Ensures backward compatibility |
| 5 | **Add `make test-filter`** — Quick local test filtering for inner-loop development (e.g., `make test-filter SearchService`). | **P2** | Low | Developer velocity |

---

## 12. Ship Confidence Assessment

### **CONDITIONAL YES — Can ship beta with confidence, needs P0 fixes before 1.0.**

**For beta/pre-release:** The infrastructure is robust. The release pipeline produces notarized, checksummed, SBOM-verified builds. The PR harness runs 13 test/eval surfaces with diff coverage gating. A bad build is unlikely to reach users.

**For 1.0/stables:** The two P0 items should be addressed first:
1. Fix `ChatSessionControllerSearchStateTests` flakiness (eliminate `Task.sleep`)
2. Extend release smoke test to verify JSON-RPC `daemon.health` handshake

After that, the P1 items (performance regression gating, test matrix) would move the project from "beta confidence" to "1.0 confidence."

**Bottom line:** The team has built testing and delivery infrastructure that is **unusually mature for a beta product**. The trajectory from the April 2026 reviews is positive — snapshot testing was added, the runner was upgraded, and 4 new CI steps were added. Closing the remaining P0 gaps would put this in the top tier of indie macOS app quality.

---

*End of report.*
