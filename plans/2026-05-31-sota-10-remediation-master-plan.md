# OpenBurnBar 10/10 SOTA Remediation Master Plan
## From "Strong Startup-Grade" to "Series A-Quality SOTA" — Engineering the next 90 days

**Date:** 2026-05-31
**Owner:** Alberto + engineering leads (per workstream)
**Branch baseline:** `main` @ `b80d31b6` (current head; `release/openburnbar-0.1.2-beta.12` line)
**Companion documents:**
- Diligence report: `plans/2026-05-31-sota-100-diligence-report.md` (six sub-agent reviews)
- Predecessor SOTA plan: `OpenBurnBar SOTA Remediation Plan.md` (Wave 0–4 framing, largely complete)
- Security follow-up: `plans/2026-05-30-sota-security-remediation.md` (P0 VirtualHID fix in progress)
- Computer Use: `plans/2026-05-16-computer-use-master-plan.md` (Phases 8–13)
**Bar:** SOTA on every dimension a Series A technical diligence partner would test. Not "ship-able" — *defensible*.
**Supersedes scope:** the predecessor SOTA plan is largely absorbed; this plan adds the new findings (launch-gate state, O(N²) parser, no-sandbox posture, mobile observability, RPC v2, schema canon as code) and tightens the acceptance criteria from "green" to "exercised, measured, defended."

---

## TL;DR

We are at **7.5/10 overall** and the launch gate is currently red (14 NO_GO, 0 GO in `launch-evidence/`). The repo is impressive — the engineering culture, the documentation, the supply-chain posture, the computer-use safety model, the resilience patterns, the debt ratchets. But there is a clear gap between *the artifact* and *the lived engineering state*, and a Series A diligence partner will see it.

This plan ships **13 workstreams across 4 waves** in **90 days** to close that gap. Every workstream has a concrete exit criterion, an empirical success metric, and a falsifiable "10/10" definition. No wave runs without the prior wave green.

The non-negotiable thesis: **10/10 is not "more documentation" or "more tests" — it is "every claim in the repo is executable, every gate is exercised, every risk is acknowledged with a fix date."**

---

## Goal: What 10/10 Actually Means

A category is at 10/10 when every claim in the corresponding docs is either **executed in CI** or **acknowledged as out-of-scope with a planned fix date**. No aspirational claims, no "documented but not enforced."

| Category | 10/10 Definition (falsifiable) |
|---|---|
| **Architecture** | Zero file > 500 lines that has a module doc; every ADR is enforced in CI; RPC v2 shipped with v1 deprecation shim; every package has a module doc; system has a documented 10x-scale path. |
| **Code Quality** | Zero `try?` in parser/write paths; zero `silentFailure` smell; zero code duplication > 10 lines; lint strict mode on every PR; ≥ 80% coverage per subsystem; no `force_cast`/`force_unwrap`/`as!` in production; no `// TODO` > 30 days. |
| **Reliability / Ops** | 100% SLO coverage with burn-rate alerts; Sentry on all 4 client surfaces + daemon; 3 Firebase projects; canary deploys; load tests scheduled; chaos drills quarterly; auto-rollback on SLO violation; MTTR < 15 min for P0. |
| **Security** | `app-sandbox = true` in default + Developer ID builds; App Check asserted in `firestore.rules`; cosign verify in every deploy; CodeQL gates every PR; per-file envelope encryption for iCloud; bug bounty live; annual third-party audit. |
| **Privacy** | Structured PII redaction (not regex); data export flow; right to rectification; cross-border data residency documented; PrivacyInfo audited; account deletion verified < 24h. |
| **Performance** | Linear parser (single-pass byte indexer); O(1) cache writes; daemon connection-slot semaphore; mobile request coalescer; adaptive embedding backpressure; sharded rollup recompute; documented perf budgets per surface. |
| **Scalability** | 100x user load test passing; shard-aware rollups; per-function concurrency caps; per-user daily ceiling enforced; passive WAL checkpoint; daemon accept loop backpressure. |
| **Testing / CI / Delivery** | 30 consecutive GO launch-gate verdicts; MissionControl 100% covered; Functions ≥ 1:0.5 test:LOC; golden tests for every parser; load tests in CI on every release; visual regression on UI; diff coverage 80% enforced; migration rollbacks tested in CI. |
| **Documentation / Maintainability** | ADRs enforced, not aspirational; runbooks tested quarterly (game day); schemas canonical (TypeSpec → everything); `docs/TECHNICAL_READINESS.md` 10/10; one launch-readiness dashboard per release. |
| **Launch Readiness** | Last 30 deploys: 30 GO; MTTR < 15 min; zero unresolved P0/P1 from launch-gate; `docs/OSS_LAUNCH_CHECKLIST.md` all green. |
| **Series A Diligence** | Diligence packet complete; empirical baselines (load, chaos, recall); customer references; cost projections; team velocity metrics; roadmap credibility. |

A category is **not** at 10/10 if it merely has a doc that says "we do X" without an executable proof.

---

## Current State (the honest scorecard)

From the 2026-05-31 diligence review (six specialized sub-agents, evidence in `plans/2026-05-31-sota-100-diligence-report.md`):

| Category | Now | Gap to 10 | Dominant gap |
|---|---|---|---|
| Architecture | 7.0 | 3.0 | 5 god classes (1,877 / 2,612 / 2,654 / 1,337 / 1,816 lines); 12 `nonisolated(unsafe)` escape hatches; 77-method RPC on two transports with no schema |
| Code Quality | 7.0 | 3.0 | Parsers declare `throws` then `try?` every error; duplicated `readAllUTF8Lines → TokenUsage` skeleton 6+ times; no lint strict mode on PR |
| Reliability / Ops | 6.5 | 3.5 | 14 consecutive NO_GO launch-gate verdicts; no Sentry on iOS/Android; only 3 log metrics; single Firebase project; no SLO burn-rate alerts |
| Security | 8.0 | 2.0 | `app-sandbox = false` in default + Developer ID; App Check console-toggle; CodeQL nightly (not PR); cosign attest produced not verified; iCloud mirror unencrypted |
| Privacy | 7.0 | 3.0 | Regex PII scrub; iCloud session mirror unencrypted; no data-export flow; cross-border undocumented |
| Performance | 6.0 | 4.0 | `BufferedLineSequence.firstIndex(where:)` → O(N²) at `AgentLens/Utilities/BufferedLineSequence.swift:46`; single-actor projection sweeper; daemon accept loop no semaphore; no request coalescer on mobile |
| Scalability | 5.7 | 4.3 | `usage_rollups` 5-doc fan-out on Android; single-actor daemon; no shard-aware rollups; 100x will collide |
| Testing / CI / Delivery | 7.5 | 2.5 | MissionControl zero tests; Functions 1:0.024 test:LOC; manual QA 25 days stale; SwiftLint not PR-gated |
| Documentation | 9.0 | 1.0 | The standout strength. Need ADR enforcement + runbook testing to reach 10. |
| Launch Readiness | 6.0 | 4.0 | Gate red. |
| Series A Diligence | 7.0 | 3.0 | Need empirical baselines, customer references, cost projections. |
| **Overall weighted** | **69/100** | **31** | |

---

## Guiding Principles (the team's existing bar, sharpened)

1. **Boil the ocean.** The marginal cost of completeness is near zero with AI. The standard is not "good enough" — it is "holy shit, that's done."
2. **Search before building.** Extend what exists; greenfield only when the task requires.
3. **Tests before shipping.** Every behavior change ships with tests; every new surface ships with golden tests.
4. **Schemas are code.** TypeSpec → TS → Swift → Kotlin, generated, never hand-edited in two places.
5. **ADRs are executable.** Every cross-cutting decision has an ADR; the CI harness enforces it.
6. **Errors are loud.** No `try?` in parser/write paths. No `silentFailure` smell. No "I returned empty because I don't know why."
7. **Sandbox-first.** The default build is sandboxed; the un-sandboxed build is the exception, not the rule.
8. **Observability is fail-loud.** Sentry DSN missing in prod = CI fails. Sentry on iOS/Android is non-optional.
9. **SLOs are measured, not documented.** A SLO without a burn-rate alert is a wish, not a target.
10. **Every review-grade claim is testable.** A diligence question like "what happens if the daemon is unreachable for 10 minutes?" has an executable answer, not a doc.

---

## Architecture of the Plan

13 workstreams across 4 waves, 90 calendar days, ~3 senior engineers + 1 SRE + 1 security engineer + part-time PM. Some workstreams are parallelizable; the critical path is WS1 → WS2 → WS3 → WS4 → WS6.

| Wave | Duration | Theme | Workstreams |
|---|---|---|---|
| **Wave 1: Truth and Safety** | Days 0–14 | Stop the bleeding. Make every claim executable. | WS1 (Launch Gate), WS6 (Sentry iOS/Android + App Check), WS9 (VirtualHID P0 carryover from `2026-05-30-sota-security-remediation.md`) |
| **Wave 2: Foundation** | Days 14–45 | Architecture and parsers. The highest-leverage refactors. | WS2 (Parser Modernization), WS3 (God File Decomposition), WS4 (Schema Canon), WS5 (RPC v2) |
| **Wave 3: Quality and Observability** | Days 45–75 | Tests, telemetry, performance, and operational maturity. | WS7 (Performance & Scalability), WS8 (Test Coverage Equity), WS10 (SLO Discipline), WS12 (Architecture Governance) |
| **Wave 4: Polish and Proof** | Days 75–90 | Computer Use phase completion, full security posture, operational excellence, diligence packet. | WS11 (Computer Use Phase Completion), WS13 (Operational Excellence), launch-readiness dashboard, diligence packet |

Each workstream has a single owner, a public dashboard URL, and a definition-of-done that is binary (passes / does not pass).

---

## WS1: Launch Gate & Release Hygiene

**Goal:** The commercial launch gate is green for 30 consecutive runs. Every release artifact is reproducible, signed, and version-consistent.

**Why it matters:** The 14 NO_GO streak in `launch-evidence/` is the single most damaging signal in the diligence review. A partner's first question is "show me your last successful production deploy date." Today that answer is uncomfortable.

**Current state evidence:**
- `launch-evidence/` — 14 NO_GO JSONs, 0 GO JSONs, between 2026-05-30 and 2026-05-31
- Latest: `launch-evidence/2026-05-31T18-59-40-621Z-commercial-launch-gate-no_go-main-ci.json` — fails on `mainRequiredGate` (PR harness) and `mainCodeQL` (Swift CodeQL `in_progress`)
- `docs/OSS_LAUNCH_CHECKLIST.md` exists but is not the gate itself
- `scripts/commercial-launch-gate.mjs` — operator Node script
- `.github/workflows/codeql.yml:25-30` — 60–90 min Swift CodeQL on push:main + nightly cron (PR-gating absent)

**Phases and tasks:**

| Task | File:line | Effort | Exit criterion |
|---|---|---|---|
| **1.1** Decouple launch gate from in-flight main. Resolve `mainRequiredGate` to a frozen ref (e.g., `git rev-parse HEAD~N` where N is the pr-harness push cadence) OR a "last N merged PRs" iteration. | `scripts/commercial-launch-gate.mjs:mainRequiredGate` | 1d | Gate reads from a 24h-old main SHA; new commits do not flip the verdict. |
| **1.2** Move Swift CodeQL to PR-gated, not nightly-only. Either split the Swift query pack (high-signal subset on PR, full on main) or add a fast Swift static-analysis stage (e.g., `swiftlint --strict` already wired in `openburnbar-pr-harness.yml:78-85` but `continue-on-error: true`). | `.github/workflows/codeql.yml:8-9, 25-30` | 2d | CodeQL on PR < 10 min; nightly full scan unchanged. PR can no longer merge with a high-severity Swift finding. |
| **1.3** Make SwiftLint a hard PR gate on `AgentLens/`, `OpenBurnBarCore/`, `OpenBurnBarDaemon/`, `OpenBurnBarMobile/`. Remove `continue-on-error: true` from `openburnbar-pr-harness.yml:78-85`. | `.github/workflows/openburnbar-pr-harness.yml:78-85` | 0.5d | PR fails on SwiftLint violation. `.swiftlint.yml` already has `force_unwrapping`, `force_cast`, `discouraged_optional_boolean`. |
| **1.4** Add Sentry DSN non-empty assertion to `deploy-production.yml`. Fail the deploy if `SENTRY_DSN` is empty or malformed. Extend to iOS via `scripts/ci/inject-firebase-config.sh` and to Android via `inject-firebase-config-android.sh`. | `.github/workflows/deploy-production.yml:1-130`, `scripts/ci/inject-firebase-config.sh`, `inject-firebase-config-android.sh` | 1d | Deploy fails on missing DSN; release build cannot ship with crashes un-captured. |
| **1.5** Wire `ops-confidence.yml` into the commercial launch gate. The gate must read the latest `ops-confidence` verdict, not just rely on `verify-production-ops-plane.sh`. | `scripts/commercial-launch-gate.mjs`, `.github/workflows/ops-confidence.yml` | 0.5d | Gate refuses GO if `ops-confidence` is yellow/red. |
| **1.6** Add a "release freshness" view to the launch-readiness dashboard. Each metric is a row; each row is green/yellow/red with the SHA that flipped it. | New: `scripts/release-readiness-dashboard.mjs` | 1d | Dashboard renders in < 5s; includes latest commit, required workflow status, coverage trend, skipped/quarantined test count, vuln count, CodeQL status, Sentry DSN populated, App Check enforcement, version consistency, notarization smoke, runbook drill recency. |
| **1.7** Run the gate 30 times consecutively under synthetic load. | Manual / CI | 2d | 30 GO verdicts. |

**Total effort:** 1 senior engineer × 8 days = **8 engineer-days.**

**Exit criteria:**
- 30 consecutive GO launch-gate verdicts in `launch-evidence/`
- Release-readiness dashboard live and accurate
- Sentry DSN populated in all release artifacts (verified by CI)
- SwiftLint, CodeQL (fast), and ops-confidence are all PR-blocking

**Risk:** The Swift CodeQL PR-gate is the highest-risk change. Mitigation: split the query pack, run high-signal subset (security, injection, hard-coded credentials) on PR, full nightly on main.

**Dependencies:** None. This is the unblock.

---

## WS2: Parser Modernization

**Goal:** A single `ProviderLogLayout<Entry>` generic powers every parser. Parser errors are observable, not silent. Parser hot loop is linear, not quadratic.

**Why it matters:** 6+ parsers reimplement the same skeleton (`readAllUTF8Lines → [String: Any] → TokenUsage`) with per-vendor field lookups. The current loop is O(N²) over file size. Errors are swallowed via `try?` and the user sees an empty dashboard with no recourse.

**Current state evidence:**
- `AgentLens/Utilities/BufferedLineSequence.swift:46` — `buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D })` per call → O(N²) over a 200MB / 1M-line file
- `AgentLens/Utilities/ParserDiskCache.swift:108` — `JSONEncoder.OutputFormatting.prettyPrinted.union(.sortedKeys)` → 2–3× write amplification
- `AgentLens/Services/LogParser/LogParserProtocol.swift:14` — protocol: `func parse() async throws -> ParseResult`; every implementation does `try?` and returns empty
- `AgentLens/Services/LogParser/ClaudeCodeParser.swift:43-48, 55-57, 71-75` — `try?` in 3+ places
- Same pattern in `GrokParser.swift:29, 36, 45, 69, 211, 217-234`, `KimiParser.swift:28, 34, 44, 76, 228`, `AntigravityParser.swift:33, 45, 82, 113`, `FactoryDroidParser.swift:48, 54, 73, 160, 188, 210, 340`
- 8+ parsers: `ClaudeCodeParser.swift:13-27`, `FactoryDroidParser.swift:15-31`, `KimiParser.swift:12-23`, `GrokParser.swift:15-23` — duplicated constructor pattern

**Phases and tasks:**

| Task | File:line | Effort | Exit criterion |
|---|---|---|---|
| **2.1** Single-pass byte indexer for `BufferedLineSequence`. Use `withUnsafeBytes` + a manual rolling pointer to scan for `\n`/`\r` and slice the buffer in place. | `AgentLens/Utilities/BufferedLineSequence.swift:46` | 1d | Parser throughput: 200MB / 1M-line JSONL parses in < 5s (currently minutes). Benchmark recorded in `scripts/perf/parser-bench.swift`. |
| **2.2** Define `ProviderLogEntry` protocol + `ProviderLogLayout<E: ProviderLogEntry>` generic. Encapsulates `contentsOfDirectory → filter isDirectory → iterate files → cacheKey → signature → parse → cache → stale GC`. | New: `AgentLens/Services/LogParser/ProviderLogLayout.swift` | 3d | New parsers are ≤ 100 lines (just the per-vendor field mapping). |
| **2.3** Migrate ClaudeCodeParser, FactoryDroidParser, KimiParser, GrokParser, AntigravityParser, HermesParser, ForgeDevParser, WarpParser, CursorAgentParser to use `ProviderLogLayout`. | `AgentLens/Services/LogParser/*.swift` | 4d | Each parser ≤ 250 lines. The 6+ duplicated skeletons collapse to one. |
| **2.4** Switch parser cache to per-file shards, no `prettyPrinted + sortedKeys`. Either binary plist or compact JSON, with the cache split into one file per source. | `AgentLens/Utilities/ParserDiskCache.swift:108` | 1d | Cache write amplification ≤ 1.1×. Per-file eviction possible. |
| **2.5** Change `LogParserProtocol.parse()` to return `(ParseResult, [ParserDiagnostic])`. Add `enum ParserDiagnostic { case missingDirectory(URL), unreadableFile(URL, Error), zeroUsage(URL), schemaMismatch(field: String) }`. | `AgentLens/Services/LogParser/LogParserProtocol.swift:14` | 2d | Every parser surfaces diagnostics; no `try?` in parser code. |
| **2.6** Wire `ParserDiagnostic` to `AppLogger.parser` and surface in the Settings → Diagnostics tab. Show per-vendor health: `last_parsed_at`, `last_error`, `files_seen`, `files_failed`, `tokens_aggregated`. | `AgentLens/Views/Settings/DiagnosticsView.swift` (new or extend) | 2d | Diagnostics tab shows real-time per-vendor health; user can see "Claude Code: 12 files, 0 errors, last 2 min ago." |
| **2.7** Add a per-vendor health snapshot to the `OpenBurnBarDaemon` heartbeat so a broken parser is visible to remote support. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarDaemonHeartbeat.swift` | 1d | Heartbeat JSON includes `parser_health: { claude_code: { ok, last_error, last_parsed_at } }`. |
| **2.8** Golden tests for every parser. Snapshot the `ParseResult` for a fixed input, fail on drift. Existing goldens in `AgentLensTests/Fixtures/ReplayGoldens/` (6 JSON files) — extend to all 9 parsers. | `AgentLensTests/Fixtures/ParserGoldens/` (new) | 2d | 1 golden per parser per vendor version. CI fails on drift. |

**Total effort:** 2 senior engineers × 8 days = **16 engineer-days.**

**Exit criteria:**
- All 9 parsers ≤ 250 lines
- No `try?` in any parser file (`grep -rn "try?" AgentLens/Services/LogParser/` returns 0)
- `ParserDiagnostic` flows to AppLogger + Diagnostics tab
- Linear parse time on 200MB / 1M-line input
- Golden tests cover every parser; CI fails on regression

**Risk:** The byte-indexer change is low-risk but high-impact. Mitigation: benchmark before/after; keep the old path behind a flag for one release.

**Dependencies:** None.

---

## WS3: God File Decomposition

**Goal:** Every file in the repo is ≤ 500 lines OR has a module doc that justifies the size AND a decomposition PR filed against it. No more 1,800+ line god classes.

**Why it matters:** Five files absorb every new requirement and have no module doc. Discoverability and reviewability are a real tax. A senior engineer reviewing any of them cannot "read the function in their head."

**Current state evidence:**
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderRouter.swift` — 1,877 lines
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderExecutor.swift` — 2,612 lines
- `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift` — 2,654 lines (a "listener")
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarIndexedSearchService.swift` — 1,337 lines
- `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift` — 1,816 lines (45 migrations in one file)
- `AgentLens/Services/CloudSync/CloudSyncCoordinator.swift` — 5 byte-identical `propagateXErrors` methods at `:275-361`
- `AgentLens/Services/SettingsManager.swift` — 1,184 lines
- `AgentLens/Services/UsageAggregatorParsers.swift` — 2,211 lines (largest Swift file in repo)
- `functions/src/callables/shared.ts` — 1,413 lines
- `functions/src/routerRundown.ts` — 1,085 lines
- `extensions/openburnbar/src/extension.ts` — 809 lines (activation + smoke + commands + helpers mixed)
- `extensions/openburnbar/src/state/controller.ts` — 979 lines + `projections.ts` — 1,676 lines

**Phases and tasks:**

| Task | File | Effort | Exit criterion |
|---|---|---|---|
| **3.1** Split `OpenBurnBarProviderRouter.swift` into 4 files: `ProviderRouteResolver.swift`, `RouteRanker.swift`, `DecisionEventBuilder.swift`, `FailoverInvariants.swift`. The main `ProviderRouter.swift` becomes a 200-line coordinator. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderRouter.swift:1-1877` | 5d | Each new file ≤ 500 lines. Each has a module doc. Routing invariants (provider-family vs. exact-model) become independently testable. |
| **3.2** Split `OpenBurnBarProviderExecutor.swift` into 4 files: `ProviderExecutor.swift` (coordinator), `ProviderCall.swift` (request building), `ProviderResponse.swift` (response shaping), `ProviderErrorMapper.swift`. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderExecutor.swift:1-2612` | 5d | Each file ≤ 500 lines. |
| **3.3** Split `CLIAgentMissionRequestListener.swift` into a per-concern set: `MissionRequestListener.swift` (entry), `MissionRequestValidator.swift`, `MissionRequestPersister.swift`, `MissionRequestStreamer.swift`, `MissionRequestDiagnostics.swift`. | `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift:1-2654` | 5d | Each file ≤ 500 lines. |
| **3.4** Generalize the 5 `propagateXErrors` methods in `CloudSyncCoordinator.swift:275-361` into a single `withSyncGate<T>(service: CloudSyncDomain, propagate: (T) -> Error?) async throws -> T` helper. New sync domains become a 5-line addition, not a 20-line copy-paste. | `AgentLens/Services/CloudSync/CloudSyncCoordinator.swift:275-361` | 2d | All 5 methods replaced by generic. New sync domain is a 1-PR change. The `isSyncing` race is fixed (single transaction). |
| **3.5** Split `OpenBurnBarDatabase.swift` migrations v1–v45 into per-migration files: `Migrations/v01-v10.swift`, `Migrations/v11-v20.swift`, `Migrations/v21-v30.swift`, `Migrations/v31-v45.swift`. Main `OpenBurnBarDatabase.swift` becomes 300 lines of struct + protocol. | `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift:1-1816` | 3d | Main file ≤ 500 lines. Per-migration files are independent. |
| **3.6** Split `OpenBurnBarIndexedSearchService.swift` into 3 files: `IndexedSearchService.swift` (coordinator), `SearchHydrator.swift` (FTS5 hydration), `SearchReRanker.swift` (semantic re-rank). | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarIndexedSearchService.swift:1-1337` | 3d | Each file ≤ 500 lines. |
| **3.7** Split `UsageAggregatorParsers.swift` (2,211 lines) — this is the largest Swift file. Either (a) move to per-provider files under `LogParser/` or (b) extract shared aggregation logic into a `UsageAggregator.swift` and let each parser contribute. | `AgentLens/Services/UsageAggregatorParsers.swift:1-2211` | 4d | Each file ≤ 500 lines. Aggregation logic is independently testable. |
| **3.8** Split `callables/shared.ts` (1,413 lines) and `routerRundown.ts` (1,085 lines) into per-domain files. | `functions/src/callables/shared.ts:1-1413`, `functions/src/routerRundown.ts:1-1085` | 3d | Each file ≤ 500 lines. |
| **3.9** Split `extension.ts` (809 lines) into 4 files: `extension-activation.ts`, `extension-smoke.ts`, `extension-commands.ts`, `extension-helpers.ts`. | `extensions/openburnbar/src/extension.ts:1-809` | 2d | Each file ≤ 500 lines. |
| **3.10** Extract `HostTransport` interface for the Hermes host. `HermesRealtimeRelayHostClient.swift` (693 lines) + `HermesIrohRelayHostClient.swift` (575 lines) share a base; WSS retirement (per `AGENTS.md`) becomes 2x cheaper. | `AgentLens/Services/CloudSync/HermesRealtimeRelayHostClient.swift`, `HermesIrohRelayHostClient.swift` | 4d | Shared base class. WSS retirement closes cleanly. |
| **3.11** Replace `OpenBurnBarError.inferSync(from:)` (string-matching classifier at `OpenBurnBarError.swift:145-160`) with typed throws end-to-end. The 8 RPC error codes at `OpenBurnBarDaemonServerTypes.swift:35-43` are the targets. | `OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarError.swift:145-160` | 3d | String classifier deleted. `CloudSyncDomain.sync()` throws `OpenBurnBarError`. ADR 003 is now reality. |

**Total effort:** 3 senior engineers × 12 days = **36 engineer-days** (parallelizable to 2 engineers × 18 days = 36 engineer-days, or 1 engineer × 36 days).

**Exit criteria:**
- `git ls-files | xargs wc -l | sort -rn | head -20` shows no file > 700 lines (allowing modest headroom for module docs)
- Every file > 500 lines has a module doc explaining why + a decomposition issue filed
- All 5 god classes split; each child file has tests
- ADR 003 ("error handling") is now enforced (no string classifiers)

**Risk:** Decomposition without tests is regression risk. Mitigation: every split ships with at least 1 golden test + 1 unit test per new file.

**Dependencies:** WS8 (Test Coverage Equity) for safety net; WS1 for green baseline.

---

## WS4: Schema Canon Live (TypeSpec → Everything)

**Goal:** The schema canon (`tools/schema-sync/`) is the *only* source of truth. `functions/src/types.ts`, OpenBurnBarCore models, Android `data/models/*.kt`, iOS Firestore models, and extension `state/types.ts` are all generated. No hand-maintained mirrors.

**Why it matters:** The repo documents the canon (ADR 004) but doesn't enforce it. `functions/src/types.ts:1-16` is a 16-line re-export barrel over "legacy" types. `android/.../TokenUsage.kt:136-147` has a comment that says "Live-data extra fields (not in TS types, observed in Firestore)" — a schema-drift confession. The `android-firestore-worker` factory skill exists to manually re-align, which is an admission.

**Current state evidence:**
- `tools/schema-sync/check-drift.sh` — drift detection exists but is informational
- `functions/src/types.ts:1-16` — 16-line re-export barrel
- `android/app/src/main/java/com/openburnbar/data/models/TokenUsage.kt:136-147` — `// Live-data extra fields (not in TS types, observed in Firestore)` comment
- `legacy.ts` (~2,864 LOC) hand-maintained, exists outside the canon
- `hand-maintained-ts-baseline.json` ratchet exists but is by definition not auto-migrated
- `OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarFirestoreModels/` — exists but is hand-maintained

**Phases and tasks:**

| Task | File | Effort | Exit criterion |
|---|---|---|---|
| **4.1** Author the TypeSpec schemas for every domain: `usage.tsp`, `quota.tsp`, `provider_account.tsp`, `chat_thread.tsp`, `conversation.tsp`, `text_snippet.tsp`, `session_log.tsp`, `shared_artifact.tsp`, `computer_use_audit.tsp`, `remote_mcp_grant.tsp`. | New: `tools/schema-sync/typespec/*.tsp` | 5d | One `.tsp` per domain. All 10 domains covered. |
| **4.2** Implement the TypeSpec → TypeScript emitter. Outputs `functions/src/types/generated/*.ts`. The hand-maintained `legacy.ts` is deleted; the `types.ts` barrel becomes pure re-exports. | `tools/schema-sync/emitters/typescript.ts` | 4d | `npm run generate:types` produces identical output for unchanged input (snapshot). |
| **4.3** Implement the TypeSpec → Swift emitter. Outputs `OpenBurnBarCore/Sources/OpenBurnBarCore/Models/Generated/*.swift`. | `tools/schema-sync/emitters/swift.ts` | 4d | Generated Swift matches the existing `OpenBurnBarFirestoreModels` interface; existing tests pass without modification. |
| **4.4** Implement the TypeSpec → Kotlin emitter. Outputs `android/app/src/main/java/com/openburnbar/data/models/generated/*.kt`. | `tools/schema-sync/emitters/kotlin.ts` | 4d | Generated Kotlin matches `TokenUsage` + siblings; existing tests pass. |
| **4.5** Implement the TypeSpec → JSON Schema emitter for the extension's `state/types.ts` validation. | `tools/schema-sync/emitters/json-schema.ts` | 2d | Extension uses generated JSON Schema for runtime validation. |
| **4.6** Wire `tools/schema-sync/check-drift.sh` as a hard PR gate. PRs that introduce a new field in Firestore but not in the canon fail the harness. | `.github/workflows/openburnbar-pr-harness.yml` + `tools/schema-sync/check-drift.sh` | 1d | PR cannot merge if a Firestore field is not in the canon. |
| **4.7** Delete `functions/src/legacy.ts`, the hand-maintained `OpenBurnBarFirestoreModels`, and the hand-maintained `TokenUsage.kt`. Move any escape hatches to a `// CANON-EXCEPTION:` annotation that the drift checker tolerates. | Multiple | 2d | No hand-maintained mirror exists. Any future addition is added to TypeSpec and generated. |
| **4.8** Add a "what changed" report to the launch-readiness dashboard. Each release shows which schemas were added/modified and the cross-platform consumer impact. | New: `scripts/release-readiness-dashboard.mjs` | 1d | Dashboard shows schema change log. |

**Total effort:** 1 senior TS engineer + 1 senior Swift engineer + 1 senior Kotlin engineer × 8 days = **24 engineer-days** (parallelizable).

**Exit criteria:**
- All 4 emitters produce output for all 10 domains
- Generated code is the *only* code in the canonical surfaces
- `check-drift.sh` is a hard PR gate
- Hand-maintained mirrors deleted
- A new domain (e.g., `usage_event_v2.tsp`) is a single-PR change that generates across all 4 platforms

**Risk:** Generators are notoriously buggy. Mitigation: golden tests for each emitter; commit generated code to the repo so the PR review is on the *diff*, not the generator output.

**Dependencies:** WS8 (golden tests for emitters).

---

## WS5: RPC v2 + State Sync Hardening

**Goal:** A versioned RPC transport with a deprecation shim. The 77-method Unix-socket + HTTP-gateway surface is a formal contract. State ownership is documented, enforced, and provably safe.

**Why it matters:** `BurnBarRPCContracts.swift:12-84` enumerates 77 cases, all transported over `~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock` with a 64KB cap. Same 77 methods on HTTP gateway port 8317. JSONDecoder failures collapse to `invalidParams` with no per-field diagnostics. The moment a v2 is needed, this is a 6-month migration.

**Current state evidence:**
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift:1-84` — 77 method cases
- `BurnBarRPCRequestEnvelope` — 4-line struct, no schema validation
- `OpenBurnBarDaemonServer.swift:469` — JSONDecoder failures → `invalidParams` with no per-field error
- `OpenBurnBarDaemonServer.swift:389-460` — 70-line switch
- `OpenBurnBarDaemonMain.swift:66-70` — same 77 methods on HTTP gateway
- `OpenBurnBarError.inferSync(from:)` at `OpenBurnBarError.swift:145-160` — string classifier
- `OpenBurnBarDaemonManager.swift:91-103` — `daemonRPC` vs `localFallback` split-brain risk
- 5 `propagateXErrors` methods at `CloudSyncCoordinator.swift:275-361` (see WS3.4)

**Phases and tasks:**

| Task | File:line | Effort | Exit criterion |
|---|---|---|---|
| **5.1** Define `BurnBarRPCMethod` registry: a `[BurnBarRPCMethod: (Request, Decoder) async throws -> Response]` lookup. Replace the 70-line `switch` and the 8 `+RPC*.swift` `preconditionFailure` dispatchers. | `OpenBurnBarDaemonServer.swift:389-460`, `+RPC*.swift` | 4d | Single typed router. Unknown methods return `encodeErrorResponse(... .methodNotFound ...)` (pattern at `OpenBurnBarDaemonServer.swift:348-362`). Daemon survives a version mismatch. |
| **5.2** Add JSON Schema validation for `BurnBarRPCRequestEnvelope`. Validate per-method params against a generated schema; return `invalidParams` with per-field error path. | `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift` | 3d | Per-field `invalidParams` error responses. CI tests cover malformed payload rejection. |
| **5.3** Bump `BurnBarProtocolVersion` from 1 to 2. Add a `versioned_method` shim: a v1 client can talk to a v2 daemon, the v2 daemon translates v1 calls to v2 internally. | `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift:1-10` | 5d | v1 client works against v2 daemon. v2 features (per-field errors, typed throws) are additive. |
| **5.4** Replace `OpenBurnBarError.inferSync(from:)` with typed throws. Make `CloudSyncDomain.sync()` throw `OpenBurnBarError`; remove `lastSyncError: String?` from the protocol. Handlers in `OpenBurnBarDaemonServer` throw typed codes that map to the 8 RPC error codes. | `OpenBurnBarError.swift:145-160`, `OpenBurnBarDaemonServerTypes.swift:35-43` | 3d | String classifier deleted. ADR 003 is enforced. |
| **5.5** Resolve the `daemonRPC` vs `localFallback` split-brain risk in `OpenBurnBarDaemonManager.swift:91-103`. Define a single source of truth: daemon is authoritative; the app's `localFallback` cache is read-only and read-after-write is forbidden. On daemon reconnect, the local cache is invalidated, not merged. | `OpenBurnBarDaemonManager.swift:91-103` | 3d | `localFallback` is documented as a read-only degraded view; reconnect invalidates the cache; ADR 005 is enforced. |
| **5.6** Add per-RPC latency p50/p95/p99 metrics to the daemon. Expose via the existing `/metrics` Prometheus endpoint (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarGatewayMetrics.swift:1-180+`). Wire the existing `BurnBarDaemonMetricsCounters.recordRPCLatency` to the histogram. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarGatewayMetrics.swift`, `OpenBurnBarDaemonServer.swift:312-400` | 2d | Per-RPC latency histogram exported in Prometheus format. |
| **5.7** Add a daemon `/healthz` endpoint. Returns 200 with `{version, uptime, parser_health, db_ok, fts_ok, semantic_ok, last_heartbeat_age}`. Existing heartbeat is file-based; the endpoint consolidates. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/` (new `BurnBarDaemonHealthEndpoint.swift`) | 1d | `curl /healthz` returns 200/503 with structured JSON. |
| **5.8** Document the RPC v2 contract in `docs/ARCHITECTURE/rpc-v2.md`. Include deprecation timeline (v1 support for 6 months after v2 GA), error model, transport (Unix socket + HTTP gateway), and version-negotiation semantics. | New: `docs/ARCHITECTURE/rpc-v2.md` | 1d | Doc live; cross-referenced from `BurnBarProtocolVersion`. |

**Total effort:** 2 senior engineers × 10 days = **20 engineer-days.**

**Exit criteria:**
- BurnBarProtocolVersion v2 GA with v1 deprecation shim
- All 77 methods in the v2 registry; unknown methods return `methodNotFound`, not crash
- Per-field error responses
- Per-RPC latency histogram exported
- `localFallback` is read-only and documented
- ADR 003 + ADR 005 enforced in CI

**Risk:** v1 deprecation shim is non-trivial. Mitigation: ship v2 with a 6-month v1 sunset, gated by a 30-day warning at 80% v1 traffic, kill at 0% v1 traffic after 6 months.

**Dependencies:** WS8 (golden tests for the registry).

---

## WS6: Cross-Platform Observability (Sentry iOS/Android + App Check in Rules)

**Goal:** Sentry captures crashes on iOS, Android, and the extension — not just the macOS app and the daemon. App Check enforcement is in `firestore.rules`, not a console toggle. The macOS app, iOS app, Android app, and extension all have fail-loud observability.

**Why it matters:** Three of four client surfaces can ship with observability off. A bad iOS release will be discovered via App Store reviews, not via telemetry. App Check enforcement is a single operator-action failure away from a regression.

**Current state evidence:**
- `AgentLens/App/AgentLensApp.swift:1043` — Sentry read from Info.plist, lazily initialized
- `OpenBurnBarDaemonMain.swift:187-201` — Sentry initialized with `OPENBURNBAR_SENTRY_DSN` env, silently disabled if unset
- `extensions/openburnbar/src/telemetry/sentry.ts:1-150+` — `@sentry/node` lazy-loaded
- `OpenBurnBarMobile/Sources/OpenBurnBarMobile/` — zero Sentry references
- `android/app/src/main/java/com/openburnbar/` — Firebase Crashlytics gated by SharedPreferences flag (`BurnBarApplication.kt:131`)
- `AgentLens/App/AgentLensApp.swift:944-1031` — App Check wired only on macOS
- `firestore.rules:20-22` — explicit comment "Enforce App Check for Cloud Firestore in the Firebase console"
- `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md` — describes a checklist, not code

**Phases and tasks:**

| Task | File:line | Effort | Exit criterion |
|---|---|---|---|
| **6.1** Add Sentry SDK to iOS via SPM. Initialize in `OpenBurnBarMobileApp.swift` (the iOS app entry, parallel to `AgentLensApp.swift:1043`). Read DSN from `Info.plist` (mirroring the macOS pattern). | `OpenBurnBarMobile/Sources/OpenBurnBarMobile/OpenBurnBarMobileApp.swift` | 1d | iOS Sentry captures crashes. |
| **6.2** Add Sentry Android SDK to `android/app/build.gradle.kts`. Initialize in `BurnBarApplication.kt:131` after Crashlytics. Read DSN from `local.properties` or BuildConfig. | `android/app/build.gradle.kts`, `BurnBarApplication.kt:131` | 1d | Android Sentry captures crashes. |
| **6.3** Add Sentry SDK to the extension as a required dep, not optional. Remove the lazy `@sentry/node` load; fail-loud at extension activation if DSN is unset. | `extensions/openburnbar/src/extension.ts` (activation block at `:43-49`), `extensions/openburnbar/src/telemetry/sentry.ts` | 0.5d | Extension activation fails on missing Sentry DSN in production. |
| **6.4** Add CI assertion: Sentry DSN must be non-empty in release builds. Inject via `scripts/ci/inject-firebase-config.sh` (iOS) and `inject-firebase-config-android.sh` (Android). Add the same assertion to `.github/workflows/deploy-production.yml`. | `.github/workflows/deploy-production.yml:1-130` | 1d | CI refuses to deploy with empty Sentry DSN. |
| **6.5** Add App Check provider to iOS: `OpenBurnBarAppCheckProviderFactory` (mirroring `AgentLensApp.swift:944-1031`). Wire in `OpenBurnBarMobileApp.swift`. | `OpenBurnBarMobile/Sources/OpenBurnBarMobile/` | 1d | iOS App Check attestation on every Firestore call. |
| **6.6** Add App Check provider to Android: `OpenBurnBarAppCheckProviderFactory.kt` (Play Integrity). Wire in `BurnBarApplication.kt:131`. | `android/app/src/main/java/com/openburnbar/` | 1d | Android App Check attestation on every Firestore call. |
| **6.7** Move App Check enforcement into `firestore.rules`. Add `hasValidAppCheck` helper that inspects `request.auth.token.firebase.app_check == true` and require it on `usage_rollups/{today,...}` reads and all write paths. | `firestore.rules:20-22` (and all 2,562 lines) | 3d | App Check is asserted in code, not console. |
| **6.8** Add `scripts/ci/verify-firestore-appcheck.sh` that calls the Firebase Management API and fails CI if App Check is unenforced. | New: `scripts/ci/verify-firestore-appcheck.sh` | 1d | CI gate. Console toggle can't silently regress. |
| **6.9** Add a Sentry "smoke test" to the launch-gate: trigger a synthetic event in each of the 4 surfaces during the gate, assert Sentry received it. | `scripts/commercial-launch-gate.mjs` | 1d | Launch-gate verifies observability before GO. |

**Total effort:** 1 mobile engineer + 1 backend engineer × 6 days = **12 engineer-days** (parallelizable).

**Exit criteria:**
- Sentry captures crashes on iOS, Android, macOS, extension, daemon
- App Check asserted in `firestore.rules` + CI-verified
- Launch-gate refuses GO if any surface is observability-dark

**Risk:** App Check enforcement is a one-way door — turning it on can break a misconfigured client. Mitigation: ship in dry-run mode first (log only, don't reject), then enforce.

**Dependencies:** None.

---

## WS7: Performance & Scalability

**Goal:** Linear parser time on 200MB / 1M-line inputs. Connection-slot semaphore on the daemon accept loop. Adaptive embedding backpressure. Shard-aware rollup recompute. Documented performance budgets per surface. 100x user load test passing.

**Why it matters:** The O(N²) parser dominates the refresh budget. The single-actor daemon accept loop is a DoS surface. The single-actor projection sweeper is bounded at 24 jobs/sweep. The Cloud Functions rollup recompute puts unbounded work in a single transaction.

**Current state evidence:**
- `AgentLens/Utilities/BufferedLineSequence.swift:46` — O(N²) over file
- `OpenBurnBarDaemonServer.swift:475-509` — `Task.detached(priority: .utility)` per connection, no semaphore
- `OpenBurnBarHTTPGatewayServer.swift:95-97` — same pattern
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarIndexedSearchService.swift` — single-actor, no backpressure
- `ProjectionPipelineCore.swift:19-32` — `defaultSweepMaxJobs = 24`, `interEmbeddingBatchPauseNanoseconds = 20_000_000` (20ms)
- `functions/src/rollups.ts:608+` — counter-winner path in one transaction
- `OpenBurnBarCore/Sources/OpenBurnBarCore/BurnBarHNSWVectorIndex.swift:432` — HNSW load uses `Data(contentsOf:)`, not `mappedIfSafe`
- `android/.../FirestoreRepository.kt:111` — one `addSnapshotListener` per `rollupWindowKeys` entry
- `OpenBurnBarDatabase.swift:564-568` — composite indexes well-targeted, but no usage_rollups index
- `AgentLens/Services/DataStore/OpenBurnBarQueryTracer.swift` — exists but never asserted in tests

**Phases and tasks:**

| Task | File:line | Effort | Exit criterion |
|---|---|---|---|
| **7.1** Replace `BufferedLineSequence.firstIndex(where:)` with a single-pass byte indexer. Use `withUnsafeBytes` + a manual rolling pointer. (Same as WS2.1; reused here for the perf outcome.) | `AgentLens/Utilities/BufferedLineSequence.swift:46` | 1d | 200MB / 1M-line JSONL parses in < 5s. |
| **7.2** Add connection-slot semaphore to daemon accept loop and HTTP gateway. Bound concurrent in-flight handlers (e.g., 32 with priority queue) and reject bursts with `503 + Retry-After`. | `OpenBurnBarDaemonServer.swift:475-509`, `OpenBurnBarHTTPGatewayServer.swift:95-97` | 2d | Daemon survives 10k concurrent connection attempts without pinning all cores. |
| **7.3** Adaptive embedding backpressure. Observe 429 responses, widen `interEmbeddingBatchPauseNanoseconds` exponentially up to a 2s ceiling, narrow on success. Consult `projection_jobs_source_lookup_idx` at sweep time and dedupe before enqueue. | `ProjectionPipelineCore.swift:19-32`, `ProjectionPipelineService+Jobs.swift:226/247` | 2d | 429 storms widen the pause; no cascading failures. |
| **7.4** Slice Cloud Functions rollup recompute into per-window transactions. Replace the 970-line single transaction with a coordinator that dispatches per `(uid, windowKey)` and dedupes by `updatedAt`. Add a Firestore composite index on `usage_rollups(uid, window, updatedAt)`. | `functions/src/rollups.ts:608+`, `firestore.indexes.json` | 4d | 100x user load test passes; per-user recompute ≤ 500-doc transaction. |
| **7.5** Switch `BurnBarHNSWVectorIndex.load()` to `mappedIfSafe` by default. | `OpenBurnBarCore/Sources/OpenBurnBarCore/BurnBarHNSWVectorIndex.swift:432, 437` | 1d | HNSW load no longer doubles RSS. |
| **7.6** Add passive WAL checkpoint scheduler. `PRAGMA wal_checkpoint(PASSIVE)` every 5 minutes from a background actor. | `OpenBurnBarDatabase.swift` | 1d | WAL stays bounded; no APFS hiccup stalls the daemon. |
| **7.7** Add `RequestCoalescer` in iOS Firestore repository and Android `FirestoreRepository`. Key by `(uid, query, params)` with TTL. Multiple screens share one read. | `OpenBurnBarMobile/Services/FirestoreRepository.swift:600+`, `android/.../FirestoreRepository.kt:111` | 3d | 5 screens with same query = 1 Firestore read. |
| **7.8** Wire `OpenBurnBarQueryTracer` into the test target. Add 1 assertion per `SearchService` query path: `assertMaxQueries(count: 3)`. | `OpenBurnBarQueryTracer.swift`, `AgentLensTests/...` | 1d | N+1 detection is in CI, not just defined. |
| **7.9** Pause the extension's `setInterval` poll when the webview is hidden. Use `VisibilityObserver` pattern. | `extensions/openburnbar/src/webview/workspace.ts` | 0.5d | Webview doesn't burn CPU when hidden. |
| **7.10** Document performance budgets per surface in `docs/PERFORMANCE_BUDGETS.md`. Include: parser throughput, projection sweep rate, daemon RPC p95, mobile app cold start, Firestore read cost per session. | New: `docs/PERFORMANCE_BUDGETS.md` | 1d | Doc live; budgets enforced in CI (existing `scripts/perf/` tests). |
| **7.11** Schedule a weekly load test in `nightly-e2e.yml` (cron). k6 hits 5 representative callables at 100 RPS for 10 minutes; asserts p95 < 800ms. | `.github/workflows/nightly-e2e.yml`, `scripts/load/k6-callables.js` (new) | 3d | Empirical baseline exists; weekly trend tracked. |

**Total effort:** 2 senior engineers × 10 days = **20 engineer-days.**

**Exit criteria:**
- Linear parser time
- Daemon accept loop with backpressure
- 100x user load test passes (SLO: p95 < 800ms for top 5 callables)
- WAL stays bounded
- Mobile request coalescing reduces read cost
- Performance budgets documented and enforced

**Risk:** Load test failures may reveal real bugs. Mitigation: the load test is weekly; a failure is an issue, not a release-blocker, until 30 days of green.

**Dependencies:** None.

---

## WS8: Test Coverage Equity

**Goal:** Every subsystem has tests. MissionControl has 100% unit coverage. Functions surface reaches ≥ 1:0.5 test:LOC ratio. Golden tests for every parser (also WS2.8). Load tests in CI. Visual regression on UI.

**Why it matters:** `ARCHITECTURE_REVIEW_V2.md:260-275` flags `MissionControl/` zero-test files. Functions surface is 1:0.024 test:LOC (vs Extension 1:1.02). The 25-day-stale manual QA report is not acceptable.

**Current state evidence:**
- `ARCHITECTURE_REVIEW_V2.md:260-275` — MissionControl zero tests
- `OpenBurnBarDaemon/Tests/OpenBurnBarMissionControlServiceTests.swift` exists (5,605 lines) but `MissionControlStore.swift` (53,411 bytes) and `BurnBarParallelDAGScheduler.swift` (933 lines) have none
- `functions/src/__tests__/` — 8 .test.ts files, 50 funcs, ~1:0.024 test:LOC
- `extensions/openburnbar/test/` — 344 TS test funcs, 1:1.02
- `qa-results/latest-run-id.txt` → `qa-20260506-005629` — 25 days stale
- `qa-results/report.md` — 4 of 11 test cases BLOCKED
- `.swiftlint.yml` has `force_unwrapping`, `force_cast` opt-in (lint strict mode not PR-gated)

**Test-density baselines (from diligence report):**
- AgentLens: 217,333 src vs 82,350 test (1 : 0.38)
- Daemon: 278,561 src vs 23,996 test (1 : 0.09)
- Core: 89,608 src vs 25,773 test (1 : 0.29)
- Mobile: 117,996 src vs 17,957 test (1 : 0.15)
- Android: 129,427 src vs 14,362 test (1 : 0.11)
- Functions: 26,385 src vs 8 TS test files / 50 funcs (1 : 0.024)
- Extension: 7,943 src vs 344 funcs (1 : 1.02)

**Phases and tasks:**

| Task | Subsystem | Effort | Exit criterion |
|---|---|---|---|
| **8.1** Add MissionControl unit tests. Start with `BurnBarParallelDAGScheduler.swift` (933 lines, most algorithmic complexity) and `MissionControlStore.swift` (53K state file). Use the actor-isolated fakes pattern from `OpenBurnBarHTTPGatewayServerTests.swift` (85 funcs) and `OpenBurnBarMissionControlServiceTests.swift` (67 funcs). | MissionControl | 10d | 100% line coverage on both files. |
| **8.2** Add Functions unit tests. Model on `scripts/diff-coverage-functions.sh` (mirror of `scripts/diff-coverage-ts.sh`). Wire to a new job in `openburnbar-pr-harness.yml` that runs only when `functions/src/**` changes. | Functions | 5d | Functions test:LOC ≥ 1:0.5. |
| **8.3** Golden tests for every parser. Snapshot the `ParseResult` for fixed inputs. Extend the existing 6 goldens in `AgentLensTests/Fixtures/ReplayGoldens/` to all 9 parsers. (Also WS2.8; same effort, reused here for the coverage outcome.) | Parsers | 2d | 1 golden per parser per vendor version. CI fails on drift. |
| **8.4** Add Hermes relay tests. `crates/openburnbar-iroh/` has unit tests but coverage is limited. Add codec, pairing, and loopback transport tests. | Rust iroh | 3d | ≥ 80% line coverage on `crates/openburnbar-iroh/src/lib.rs`. |
| **8.5** Add Android iroh-relay unit tests. `android/openburnbar-iroh-relay/src/test/` exists but is small. Add codec, pairing, and loopback transport tests. | Android iroh-relay | 3d | ≥ 80% line coverage. |
| **8.6** Add iOS unit tests. OpenBurnBarMobile is at 1:0.15. Add tests for `FirestoreRepository`, `EncryptedCredentialTransfer`, `QuotaWatch` view model. | iOS mobile | 5d | iOS test:LOC ≥ 1:0.30. |
| **8.7** Add Android unit tests. Currently 1:0.11. Add tests for `FirestoreRepository`, `TokenUsage` deserialization, `InsightsViewModel`, `MissionActivityViewModel`. | Android | 5d | Android test:LOC ≥ 1:0.25. |
| **8.8** Add visual regression tests. SnapshotTesting is a dependency in `project.yml:45-47`. Add snapshot tests for dashboard, onboarding, provider routing cockpit, chat panel, settings. | SwiftUI / iOS / Android | 5d | 6+ surfaces with snapshot tests. |
| **8.9** Promote diff coverage to 80% enforced on every PR harness. Current: `scripts/diff-coverage-all.sh:8-18` default 80%, but enforcement is informational. | CI | 1d | PR fails on diff coverage < 80%. |
| **8.10** Add a ratchet for total coverage by subsystem. Module-level thresholds, not one global number. | CI | 2d | Coverage ratchet on each subsystem. |
| **8.11** Re-run the manual QA pipeline and gate on a fresh evidence directory. The `.factory/skills/qa/` config is already wired. Add a step to `openburnbar-pr-harness.yml` that runs `node .factory/skills/qa/run.mjs` after the main job. | QA pipeline | 1d | `qa-results/latest-run-id.txt` is < 7 days old at every release. |
| **8.12** Add `xcodebuild_test_iterations=3` to all XCTest invocations in CI (already in `openburnbar-pr-harness.yml:182-194` for Core/Swift and App — extend to Mobile). | CI | 0.5d | Mobile test runs are retried 3× before failing. |
| **8.13** Quarantine manifest with reason, owner, revival criteria. Add a manifest table for any test that is `XCTSkip` or that lives in `Quarantine/`. Each row must have an issue link and an expiry. | Test governance | 1d | All `XCTSkip` and `Quarantine/` tests have an issue + owner + expiry. |

**Total effort:** 2 senior engineers × 22 days = **44 engineer-days** (parallelizable).

**Exit criteria:**
- MissionControl 100% covered
- Functions ≥ 1:0.5 test:LOC
- iOS ≥ 1:0.30, Android ≥ 1:0.25
- 9 parsers with golden tests
- Diff coverage 80% enforced
- Manual QA fresh at every release
- No `XCTSkip` without an issue link

**Risk:** Adding 44 engineer-days of tests is hard to scope-creep into a release. Mitigation: split per-subsystem PRs; each PR is a small diff with a clear test outcome.

**Dependencies:** None (but feeds WS2, WS3, WS5).

---

## WS9: Security Posture & Privacy

**Goal:** `app-sandbox = true` in default + Developer ID builds. App Check asserted in `firestore.rules`. Cosign verify in every deploy. CodeQL gates every PR. Per-file envelope encryption for iCloud mirror. Bug bounty program live. Annual third-party audit. Privacy posture is structured, not regex.

**Why it matters:** This is the dimension that protects the product and the user. The `app-sandbox = false` decision is defensible but uncomfortable. The iCloud session mirror is unencrypted. Cosign attestations are produced but not verified. CodeQL is nightly, not PR-gated. Bug bounty doesn't exist.

**Current state evidence:**
- `AgentLens/Resources/OpenBurnBar.entitlements:23-24` — `app-sandbox = false` in default
- `OpenBurnBarRelease.entitlements:13-14` — same in Developer ID
- `OpenBurnBarMAS.entitlements:9-10` — `app-sandbox = true` in MAS variant
- `firestore.rules:20-22` — App Check enforcement is a comment, not a rule
- `ICloudSessionMirrorService.swift:62-120` — raw session logs to iCloud Drive, no envelope encryption
- `functions/src/logging.ts:16-29` — regex PII scrub
- `.github/workflows/codeql.yml:8-9` — nightly, not PR
- `supply-chain-provenance.yml` — produces attestations, no verify
- `docs/REMOTE_MCP_THREAT_MODEL.md` — exists, well-written
- `docs/HERMES_COMPUTER_USE.md` — kill switch, audit chain

**Phases and tasks:**

| Task | File:line | Effort | Exit criterion |
|---|---|---|---|
| **9.1** Carry over the P0 VirtualHID fix from `plans/2026-05-30-sota-security-remediation.md` (Phases P0.a + P0.b + WS1). This is the highest-priority security work and should land in Wave 1. | `OpenBurnBarVirtualHIDBridgeMain.swift:194-206`, `OpenBurnBarRemoteAccessAgentMain.swift:231-240` | 2d | Peer code-signature authentication on both privileged sockets; bridge `"input"` op constrained. |
| **9.2** Enable App Sandbox in the Developer ID release build. Add `com.apple.security.files.user-selected.read-write` + `com.apple.security.network.client`. Re-architect the helper to use a sandboxed per-launch XPC for cross-user log access. OR document the helper boundary as the trust root and rebrand as "advanced user tool" with on-install disclosure. | `OpenBurnBarRelease.entitlements:13-14` | 10d | `app-sandbox = true` in Developer ID release. OR a one-page disclosure + opt-in flow with explicit consent. |
| **9.3** Envelope-encrypt the iCloud session mirror. Wrap each mirrored file with AES-GCM using a per-user key in Keychain. Or use NSFileProtectionComplete and ship a README warning. | `ICloudSessionMirrorService.swift:62-120` | 3d | iCloud mirror is encrypted at rest. |
| **9.4** Add `cosign verify` to the deploy workflow. Verify SLSA provenance before `firebase deploy`. Verify each release artifact before publishing. | `.github/workflows/deploy-production.yml`, `release.yml` | 2d | Deploy fails on unsigned/unverified artifact. |
| **9.5** Move CodeQL to PR-gated. Add a fast Swift query pack (security, injection, hard-coded credentials) on PR; full nightly on main. | `.github/workflows/codeql.yml:8-9, 25-30` | 2d | PR fails on high-severity Swift finding. |
| **9.6** Add a structured PII redaction pass. Replace the regex scrub in `functions/src/logging.ts:16-29` with a structured pass that redacts paths, tokens, auth headers, project names, model prompts, user content. Add tests that assert sensitive keys/values are not emitted. | `functions/src/logging.ts:16-29`, `AgentLens/Services/AppLogger.swift:60-88` | 3d | PII redaction is structured, not regex. Tests cover known leak vectors. |
| **9.7** Add a data export flow. A "Download my data" button in Settings that produces a JSON bundle of `usage`, `conversations`, `chat_threads`, `text_snippets`, `session_logs` (per the user's settings). | `AgentLens/Views/Settings/AccountView.swift`, `functions/src/accountDeletion.ts` (sibling) | 4d | User can download their data; bundle matches the user-visible account. |
| **9.8** Right to rectification. Allow users to self-edit any `text_snippet` and any `chat_thread` title (already possible). For provider accounts, allow "rename" with a per-account alias. | `AgentLens/Services/AccountManager.swift` | 1d | UI exists; round-trip test passes. |
| **9.9** Cross-border data residency. Document in `docs/PRIVACY.md`: iCloud session mirror is in the user's iCloud region; Firestore is in `us-central1` today; add an EU project for EU users. | `docs/PRIVACY.md` | 1d | Doc updated; EU project provisioned. |
| **9.10** Audit `PrivacyInfo.xcprivacy` for completeness. Add `NSPrivacyAccessedAPICategoryUserDefaults` reasons for any new UserDefaults use since the last review. | `AgentLens/Resources/PrivacyInfo.xcprivacy` | 1d | PrivacyInfo audited; every required-reason API is declared. |
| **9.11** Account deletion verification. After `accountDeletion.ts:41-78` runs, verify all subcollections are gone in < 24h. Add a script that asserts this in CI nightly. | `functions/src/accountDeletion.ts:41-78` | 2d | Nightly CI verifies account deletion within 24h. |
| **9.12** Bug bounty program. Set up a coordinated disclosure page on `https://openburnbar.com/security` (or equivalent). Define response SLA: P0 in 24h, P1 in 72h, P2 in 7d. | New: `docs/SECURITY.md` update + website page | 2d | Page live; SLAs documented; first researcher disclosure handled. |
| **9.13** Annual third-party security audit. Engage a reputable firm (Trail of Bits, Cure53, NCC). Scope: macOS app, iOS app, Android app, daemon, Cloud Functions, Firestore rules, Computer Use surface. | External | 30d + cost | Audit report; P0/P1 findings tracked in repo. |

**Total effort:** 1 security engineer × 33 days + external audit = **~33 engineer-days + audit cost.**

**Exit criteria:**
- `app-sandbox = true` in default + Developer ID (or documented opt-in with explicit consent)
- App Check asserted in `firestore.rules` (also WS6.7)
- iCloud session mirror envelope-encrypted
- Cosign verify in every deploy
- CodeQL PR-gated
- Bug bounty live
- Annual audit completed; P0/P1 findings tracked

**Risk:** Sandbox enablement is a 10-day risk because it may require a helper XPC re-architecture. Mitigation: do the cost/benefit analysis first; if the XPC re-architecture is too expensive, fall back to the opt-in disclosure path.

**Dependencies:** WS6 (App Check in rules is shared work).

---

## WS10: SLO Discipline

**Goal:** SLOs are measured, alerted on, and regression-tested. Custom metrics cover callable latency, quota exhaustion, daemon heartbeat staleness, and sync failure rate.

**Why it matters:** `docs/runbooks/slos.md:1-230+` defines SLOs but only 3 log-based metrics are exported. Sentry's 10% tracing sample doesn't back any SLO. The SLOs are aspirational.

**Current state evidence:**
- `functions/scripts/create-ops-log-metrics.mjs:1-60+` — only 3 log metrics: `openburnbar_callable_error`, `openburnbar_circuit_breaker_tripped`, `openburnbar_hosted_mcp_5xx`
- `docs/runbooks/slos.md:1-230+` — SLOs defined but not measured
- `functions/src/sentry.ts:1-100+` — 10% tracing sample, not SLO-linked
- `functions/scripts/ops-alert-policy-definitions.mjs:1-150+` — 8 SLO policies + 4 billing alerts
- `scripts/ci/verify-ops-readiness.sh:1-29` — gate exists
- `.github/workflows/ops-plane-verify.yml:1-60` — runs Mon 14:00 UTC
- Daemon `/metrics` endpoint: `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarGatewayMetrics.swift:1-180+` — exposed but not scraped

**Phases and tasks:**

| Task | File:line | Effort | Exit criterion |
|---|---|---|---|
| **10.1** Add 4 new log-based metrics: `openburnbar_callable_latency_ms`, `openburnbar_callable_cold_start`, `openburnbar_quota_exhausted`, `openburnbar_daemon_heartbeat_stale`. | `functions/scripts/create-ops-log-metrics.mjs:1-60+` | 2d | 7 log metrics exported. |
| **10.2** Wire corresponding SLO burn-rate alerts. Add 4 new alert policies in `ops-alert-policy-definitions.mjs`. Burn rate > 2x for 1h = warn, > 14.4x for 5min = page. | `functions/scripts/ops-alert-policy-definitions.mjs:1-150+` | 2d | 12 SLO policies total. |
| **10.3** Daemon `/metrics` Prometheus endpoint is scraped. Set up GCP Managed Prometheus scraping of `localhost:8317/metrics` (or the unix-socket equivalent). | `BurnBarGatewayMetrics.swift:1-180+`, `firebase.json` | 2d | Daemon metrics in Cloud Monitoring. |
| **10.4** Add per-RPC latency histogram (also WS5.6). | `OpenBurnBarDaemonServer.swift:312-400`, `BurnBarGatewayMetrics.swift` | 1d | Per-RPC p50/p95/p99 in Cloud Monitoring. |
| **10.5** Mobile cold-start metric. iOS: `OpenBurnBarMobile/Sources/OpenBurnBarMobile/OpenBurnBarMobileApp.swift` reports time-to-first-frame. Android: `BurnBarApplication.kt:131` reports time-to-first-activity. | iOS, Android | 2d | Cold-start tracked per release. |
| **10.6** Sync failure rate metric. Client-side: macOS app reports `sync_failures_total{domain}` to Sentry. Server-side: Cloud Functions reports the same in a log metric. | Multiple | 2d | Sync failure rate per domain. |
| **10.7** SLO regression test in `nightly-e2e.yml`. Generate a synthetic load that exceeds the SLO; assert the alert fires within 5 min. | `.github/workflows/nightly-e2e.yml` | 2d | SLO alert path is tested nightly. |
| **10.8** Document SLOs in `docs/runbooks/slos.md` as a runbook with the alert → diagnosis → remediation path for each. | `docs/runbooks/slos.md` | 1d | Every SLO has a runbook. |
| **10.9** Oncall drill quarterly. Pick a random SLO, simulate the failure, measure MTTR. Track in `docs/runbooks/oncall-drills/`. | New: `docs/runbooks/oncall-drills/` | 0.5d per quarter | MTTR < 15 min for P0. |

**Total effort:** 1 SRE × 14 days = **14 engineer-days** (parallelizable with WS6, WS7).

**Exit criteria:**
- 12 SLO policies (was 8) with burn-rate alerts
- 7 log metrics (was 3)
- Daemon metrics scraped
- Mobile cold-start tracked
- SLO regression test in nightly CI
- Quarterly oncall drill with MTTR < 15 min for P0

**Risk:** SLO alert storms. Mitigation: burn rate windows tuned conservatively; alert suppression for known deploys.

**Dependencies:** WS1 (ops-confidence gate), WS5 (per-RPC latency), WS7 (load test).

---

## WS11: Computer Use Phase Completion (Phases 9–13)

**Goal:** Phases 8–13 of the Computer Use master plan ship behind feature flags. Phase 13 polish closes the audit/UX gaps. The trust model is end-to-end testable.

**Why it matters:** Phases 8 (Agent Watch) shipped; 9–13 (Browser Use, Trust modes, Mac System, Phone-as-controller, Polish) are gated behind flags. The `yolo` and `desktop` presets enable the maximum blast radius; the kill switch doesn't reach the input leaf.

**Current state evidence:**
- `docs/HERMES_COMPUTER_USE.md` — kill switch, audit chain, approval model
- `plans/2026-05-16-computer-use-master-plan.md` — Phases 8–13
- `docs/runbooks/computer-use-rollout-status.md` — Phase 8 shipped, others gated
- `docs/runbooks/computer-use-audit-disputes.md` — content-addressed audit chain
- `firestore.rules:1838, 1874, 1886` — `yolo` and `desktop` presets exist
- `ComputerUsePanicHaltCoordinator.swift` — kill/panic paths in app process, not bridge
- `OpenBurnBarVirtualHIDBridgeMain.swift:306-333` — bridge `"input"` op general; kill doesn't reach leaf (per `plans/2026-05-30-sota-security-remediation.md` V1-2)

**Phases and tasks (per `plans/2026-05-16-computer-use-master-plan.md`):**

| Task | Effort | Exit criterion |
|---|---|---|
| **11.1** Phase 9: Browser Computer Use (Playwright-driven). Ship `BurnBarToolKind.computerUseToolKinds` (13 kinds), `ComputerUseRunCoordinator`, bridge script `openburnbar-playwright-bridge.js` (pinned `playwright@1.49.1`). | 10d | Phase 9 GA; field data on real users. |
| **11.2** Phase 10: Trust modes + scope rules + audit chain. `AgentCapabilityGrant.shellUnrestricted` per-session grant. `firestore.rules` validation. | 8d | Trust modes work end-to-end. |
| **11.3** Phase 11: Mac System Computer Use (CGEvent + AX). Per the master plan, ships only via direct download with notarization; MAS build compiles out via `#if DISTRIBUTION_MAS`. | 10d | Phase 11 GA (direct download only). |
| **11.4** Phase 12: Phone-as-controller (Ed25519-signed intents). Validate monotonic counter, intent hash, ±5s freshness. Per `ComputerUsePhoneControlSigner.swift:14-17`. | 8d | Phase 12 GA. |
| **11.5** Phase 13 polish: Trusted scopes, audit export, OpenTimestamps, "no `yolo` in default presets". | 5d | Phase 13 GA; default presets are `standard`/`readonly` only. |
| **11.6** Kill paths reach the input leaf. Per `plans/2026-05-30-sota-security-remediation.md` V1-2. The bridge must check a local panic flag on every dispatch. | 3d | Bridge honors panic flag in < 100ms. |
| **11.7** End-to-end trust model test. A test script that exercises Manual → Step → Trusted; a test that exercises panic; a test that exercises scope rule mismatch. | 3d | Trust model is tested, not documented. |

**Total effort:** 2 senior engineers × 23 days = **47 engineer-days** (Phase 11 is gated on direct-download notarization infra; can run in parallel with WS1-WS10).

**Exit criteria:**
- Phases 8–13 all GA (or explicitly out of scope for the launch)
- Kill paths reach the input leaf
- `yolo` and `desktop` presets are not in default lists
- Trust model is end-to-end testable

**Risk:** Phase 11 (Mac System) is the highest-risk. Mitigation: 14-day soak after Phase 9 (per master plan Decision 3).

**Dependencies:** P0 VirtualHID fix from `plans/2026-05-30-sota-security-remediation.md`.

---

## WS12: Architecture Governance

**Goal:** ADRs are enforced, not aspirational. Every cross-cutting decision has an ADR. CI fails on ADR violations. Runbooks are tested quarterly. Schemas are canonical.

**Why it matters:** The 6 ADRs in `docs/ARCHITECTURE/` are dated and opinionated, but enforcement is inconsistent. ADR 002 (actor isolation) is violated by 12+ `nonisolated(unsafe)` declarations; ADR 003 (error handling) is half honored (string classifier at `OpenBurnBarError.swift:145-160`); ADR 004 (schema canon) is aspirational (see WS4). Runbooks are documents, not tested procedures.

**Current state evidence:**
- `docs/ARCHITECTURE/` — 6 ADRs (naming, actor isolation, errors, schema, sync, ops)
- ADR 002 violations: 12+ `nonisolated(unsafe)` including `OpenBurnBarDaemonSocketClient.swift:12`, `MercuryRouter.swift:145`, `BackgroundCadenceCoordinator.swift:148`, `ComputerUseSessionCoordinator.swift:123`, `AgentLensApp.swift:1372`, `AppDelegate.swift:1308-1321`, `CloudStoreSettingsView.swift:1560-1561`, `MacAgentReplyNotificationListener.swift:127`, `MacCloudEntitlementStore.swift:41`, `RoutedClientWiringSentry.swift:68-71`
- `docs/TECHNICAL_READINESS.md` — self-scores 8/10 on CI/Testing
- `docs/runbooks/` — 14 runbooks exist; not tested

**Phases and tasks:**

| Task | File | Effort | Exit criterion |
|---|---|---|---|
| **12.1** Add a CI rule that fails the build on new `nonisolated(unsafe)` declarations in `AgentLens/`, `OpenBurnBarCore/`, `OpenBurnBarDaemon/`, `OpenBurnBarMobile/`. The existing 12 violations become a "grandfathered" list with an expiry date. | `scripts/ci/verify-actor-isolation.sh` (new) | 2d | CI blocks new violations. |
| **12.2** Add a CI rule that fails the build on new `try?` in parser/write paths. Existing violations are ratcheted down via `scripts/debt/check-try-optional-budget.sh` (already in `.github/workflows/openburnbar-pr-harness.yml:71-77`). | `scripts/debt/check-try-optional-budget.sh` | 0.5d | Parser/write paths are `try?`-free. |
| **12.3** Add a CI rule that fails the build on new `silentFailure` calls. | `scripts/ci/verify-no-silent-failure.sh` (new) | 0.5d | No new silent failures. |
| **12.4** Add a CI rule that fails the build on new `// TODO` without an issue link. | `scripts/ci/verify-todo-issues.sh` (new) | 0.5d | Every TODO has an issue. |
| **12.5** Quarterly runbook drill. Pick a runbook, simulate the failure, measure MTTR. Track in `docs/runbooks/drills/`. | New: `docs/runbooks/drills/YYYY-QN.md` | 1d per quarter | MTTR < 30 min for P1. |
| **12.6** "What changed" page in `docs/CHANGELOG.md` (already 2,552 lines). Add a per-release "ADRs touched" section that lists the ADRs added/modified. | `CHANGELOG.md` | 0.5d | Changelog references ADRs. |
| **12.7** Update `docs/TECHNICAL_READINESS.md` to 10/10. Reflect the 90-day plan completion. | `docs/TECHNICAL_READINESS.md` | 0.5d | Self-score is 10/10 with evidence. |
| **12.8** Schema canon doc. `docs/SCHEMA_CANON.md` explains the TypeSpec → TS → Swift → Kotlin pipeline (linked to WS4). | New: `docs/SCHEMA_CANON.md` | 0.5d | Doc live. |
| **12.9** Architectural Decision Records hygiene. Review every ADR in `docs/ARCHITECTURE/`; mark superseded ones; link to the successor. | `docs/ARCHITECTURE/` | 1d | No zombie ADRs. |
| **12.10** Module docs. Add a module-level doc to every package: `AgentLens/`, `OpenBurnBarCore/`, `OpenBurnBarDaemon/`, `OpenBurnBarMobile/`, `extensions/openburnbar/`, `android/app/`, `functions/`. Each explains boundaries, ownership, and key invariants. | Multiple | 2d | Every package has a module doc. |

**Total effort:** 1 senior engineer × 9 days = **9 engineer-days.**

**Exit criteria:**
- New `nonisolated(unsafe)`, `try?` in parser/write paths, `silentFailure`, and unlinked `// TODO` all fail CI
- Quarterly runbook drills tracked
- `docs/TECHNICAL_READINESS.md` is 10/10 with evidence
- Every package has a module doc

**Risk:** ADR enforcement is invasive. Mitigation: ship in warn-only mode for one release, then enforce.

**Dependencies:** None (feeds WS3 — the god-file decomposition enables ADR enforcement).

---

## WS13: Operational Excellence

**Goal:** Three Firebase projects. Canary deploys. Load tests scheduled. Chaos drills quarterly. Oncall drills quarterly. Auto-rollback on SLO violation.

**Why it matters:** Single Firebase project, no canary, no load tests, no chaos drills, no oncall drills. A misconfigured deploy can land in production. The SLO burn rates have no empirical baseline.

**Current state evidence:**
- `.firebaserc:1-12` — single `"default": "burnbar"`
- `scripts/rollout.mjs:1-200+` — ring rollout (1% → 5% → 25% → 100%) for Remote Config flags, not for Cloud Functions
- `release.yml` (35,229 bytes) — no canary
- `nightly-e2e.yml:1-100` — `prod-health-synthetic` cron 09:00
- `oncall.md:1-50+` — P0/P1/P2 matrix, 15-min MTTR
- `verify-production-ops-plane.sh:1-80+` — no dry-run

**Phases and tasks:**

| Task | File | Effort | Exit criterion |
|---|---|---|---|
| **13.1** Split Firebase into `burnbar-dev`, `burnbar-staging`, `burnbar-prod`. Update `.firebaserc:1-12` with project aliases, `firebase.json:1-100+` to read from alias, all deploy scripts to target the alias. | `.firebaserc:1-12`, `firebase.json:1-100+`, `scripts/deploy-production.sh` | 3d | Three projects. A misconfigured deploy cannot land in prod. |
| **13.2** Add canary to Cloud Functions deploy. Deploy new version to `burnbar-canary`; 5% of traffic for 1 hour; auto-promote if SLO holds; auto-rollback if SLO violates. Use `gcloud functions deploy --gen2` traffic splitting. | `.github/workflows/deploy-production.yml:1-120`, `gcloud` config | 4d | Canary deploys land in prod only after SLO holds. |
| **13.3** Auto-rollback on SLO violation. The post-deploy health gate (`scripts/ci/post-deploy-health-gate.sh:1-100+`) currently blocks promotion; add auto-revert to the prior `v*` tag. | `scripts/ci/post-deploy-health-gate.sh`, `scripts/rollback.sh:1-50` | 2d | SLO violation triggers auto-rollback in < 5 min. |
| **13.4** Add Dependabot coverage for `cargo`, `swift`, `gradle`, `github-actions`. Currently `.github/dependabot.yml:1-50+` covers only `npm`. | `.github/dependabot.yml` | 1d | All ecosystems covered. |
| **13.5** Add weekly load test (also WS7.11). | `.github/workflows/nightly-e2e.yml` | 1d | Load test runs weekly; trend tracked. |
| **13.6** Quarterly chaos drill. Pick a service, induce failure (latency, 5xx, dependency down), measure MTTR. | New: `docs/runbooks/chaos-drills/YYYY-QN.md` | 1d per quarter | MTTR < 15 min for P0 chaos events. |
| **13.7** Quarterly oncall drill. Pick an SLO, simulate the failure, measure MTTR. (Same as WS10.9; tracked here for completeness.) | `docs/runbooks/oncall-drills/` | 1d per quarter | MTTR < 15 min. |
| **13.8** Document the oncall rotation. Current docs have the SLA matrix; missing the rotation schedule, escalation policy, and PagerDuty equivalent. | `docs/runbooks/oncall.md` | 0.5d | Doc complete; rotation live. |
| **13.9** Add a launch-readiness dashboard (also WS1.6). | `scripts/release-readiness-dashboard.mjs` | 1d | Dashboard live; updated per release. |
| **13.10** Annual business review. Update `docs/TECH_DEBT_METRICS.md` via `./scripts/ci/update-tech-debt-metrics.sh`. Commit the snapshot. | `docs/TECH_DEBT_METRICS.md` | 0.5d per month | Trend visible. |

**Total effort:** 1 SRE × 15 days = **15 engineer-days** (parallelizable).

**Exit criteria:**
- Three Firebase projects
- Canary deploys
- Auto-rollback on SLO violation
- Dependabot for all ecosystems
- Quarterly chaos + oncall drills
- Launch-readiness dashboard live

**Risk:** Project split can break existing deploys. Mitigation: dry-run first, document the migration, run the new pipeline in shadow mode for 1 week.

**Dependencies:** WS1 (ops-confidence gate), WS10 (SLO burn alerts).

---

## Critical Path and Sequencing

```
Day 0 ───────────────────────────────────────────────────────────────────────── Day 90

Wave 1 (Days 0–14)               Wave 2 (Days 14–45)               Wave 3 (Days 45–75)              Wave 4 (Days 75–90)
├── WS1  Launch Gate (8d)         ├── WS2  Parser (16d)            ├── WS7  Perf (20d)              ├── WS11 Phase 13 (5d)
├── WS6  Observability (12d)      ├── WS3  God Files (36d)         ├── WS8  Test Equity (44d)       ├── WS13  Operational (15d)
└── WS9  Security P0 carry (2d)   ├── WS4  Schema Canon (24d)      ├── WS10 SLO Discipline (14d)    └── Diligence packet
                                  └── WS5  RPC v2 (20d)            └── WS12 Architecture Gov (9d)
                                                                    
Critical path: WS1 → WS2 → WS3 → WS4 → WS6 → Diligence
Wall-clock with 3 parallel senior engineers: ~75–80 working days
Wall-clock with 5 senior engineers + 1 SRE + 1 security: ~50–55 working days
```

The critical path is **WS1 → WS2 → WS3 → WS4 → WS6 → Diligence**. WS2 and WS6 run in parallel after WS1 closes. WS3 feeds WS5 (RPC v2 needs the file splits for clean dispatch). WS4 is a hard dependency for any future schema work. WS7/WS8/WS10/WS12/WS13 are parallelizable; WS11 is gated on the P0 security fix and runs in parallel with everything.

---

## Acceptance Criteria (the launch gate for "10/10")

The repo is at 10/10 when **all** of the following are true:

1. **30 consecutive GO commercial-launch-gate verdicts** in `launch-evidence/`.
2. **All 12 categories at 10/10** with the falsifiable definitions in the table above.
3. **`docs/TECHNICAL_READINESS.md` is 10/10** with evidence per category.
4. **`docs/OSS_LAUNCH_CHECKLIST.md` is all green.**
5. **All 4 client surfaces** (macOS, iOS, Android, extension) ship with Sentry DSN populated (verified by CI).
6. **`app-sandbox = true` in default + Developer ID**, OR an opt-in disclosure flow with explicit consent and on-install warning.
7. **App Check asserted in `firestore.rules` and CI-verified.**
8. **Cosign verify in every deploy workflow.**
9. **All 9 parsers ≤ 250 lines; no `try?` in any parser file.**
10. **No file > 500 lines without a module doc + a decomposition issue.**
11. **All 5 god classes split.**
12. **Schema canon: TypeSpec is the only source of truth; generated code is the only code in canonical surfaces.**
13. **RPC v2 GA with v1 deprecation shim.**
14. **MissionControl 100% covered; Functions ≥ 1:0.5 test:LOC; iOS ≥ 1:0.30; Android ≥ 1:0.25.**
15. **100x user load test passing; SLO p95 < 800ms for top 5 callables.**
16. **12 SLO policies with burn-rate alerts; 7 log metrics; daemon metrics scraped.**
17. **Three Firebase projects; canary deploys; auto-rollback on SLO violation.**
18. **Bug bounty live; annual third-party audit complete; P0/P1 findings tracked.**
19. **Computer Use Phases 8–13 GA (or explicitly out of scope for the launch).**
20. **Diligence packet complete** with empirical baselines (load, chaos, recall), customer references, cost projections, team velocity metrics, roadmap credibility.

If any one of these is not green, the repo is not at 10/10.

---

## Risk Register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| **Sandbox enablement requires XPC re-architecture that exceeds 10 days** | Medium | High | Fall back to opt-in disclosure path with explicit consent. |
| **TypeSpec generator bugs cause cross-platform schema drift** | High | High | Golden tests for each emitter; commit generated code; PR review is on the diff. |
| **MissionControl tests reveal real bugs that block the 90-day timeline** | Medium | Medium | Triage: bugs that block land in WS3.4 god file work; cosmetic bugs ship in next release. |
| **Load test reveals Cloud Functions cold-start is a real SLO violation** | High | Medium | Increase `minInstances` for hot functions; document the trade-off. |
| **App Check enforcement breaks a misconfigured client** | Medium | High | Ship in dry-run (log only) for 1 release before enforcing. |
| **Bug bounty disclosure before the team is ready to triage** | Low | High | Soft-launch with a private disclosure email; full program at GA. |
| **SLO alert storms on the first 30 days** | High | Low | Burn rate windows tuned conservatively; suppress for known deploys. |
| **Computer Use Phase 11 (Mac System) is harder than the plan assumes** | Medium | High | Per master plan Decision 3, Phase 11 ships only via direct download with notarization; MAS build compiles out via `#if DISTRIBUTION_MAS`. |
| **Three-Firebase project split breaks existing deploys** | Low | High | Dry-run first; shadow mode for 1 week. |
| **Sentry DSN injection in CI breaks for fork PRs** | Medium | Low | Use a public DSN for fork PRs; private DSN only on `INTERNAL_RUN` workflows (per `docs/runbooks/fork-pr-ci.md`). |

---

## Success Metrics

The plan is successful when:

1. **30 consecutive GO launch-gate verdicts** (target: Day 30).
2. **`docs/TECHNICAL_READINESS.md` is 10/10** (target: Day 90).
3. **Diligence packet signed off by Alberto** (target: Day 90).
4. **A Series A technical diligence partner reads the packet, asks 5 questions, gets 5 evidence-based answers** (target: Day 90).
5. **The team can ship a new provider in 3 days, not 2 weeks** (target: Day 60).
6. **A new engineer can run `make ci` and have green tests in < 10 minutes** (target: Day 30).
7. **MTTR < 15 min for P0 in production** (target: Day 75, measured by quarterly chaos drill).
8. **0 silent parser errors in production** (target: Day 14, after WS2 ships).
9. **0 `nonisolated(unsafe)` violations added in any PR** (target: Day 14, after WS12.1 ships).
10. **The launch-gate is the team's most trusted signal, not its most feared one** (target: Day 60).

---

## Governance

- **Workstream owners** are named in each WS header; the team meets weekly to review progress, blockers, and cross-WS dependencies.
- **Definition of done** is binary for every WS: it passes, or it doesn't. No "in progress" verbiage in the launch-readiness dashboard.
- **Risks** are tracked in `docs/RISKS.md` (new); reviewed at every weekly meeting.
- **The commercial launch gate** is the only source of truth for "are we launchable." No "but the team says we're ready" — the gate says it.
- **Diligence packet** is maintained in `plans/2026-05-31-sota-100-diligence-packet.md` (new) and updated weekly. The packet includes: load test trends, SLO status, security review status, customer references, cost projections, team velocity metrics, roadmap credibility, and the resolution of every item in this plan.
- **After 90 days**, the plan is reviewed. Anything not at 10/10 gets a "what's blocking it" root cause and either ships in the next 30 days or is explicitly de-scoped with Alberto's sign-off.

---

## What This Plan Does NOT Do

To be honest about scope:

- It does **not** rewrite the parsers from scratch. WS2 reduces duplication and removes silent errors; it does not redesign the parser architecture.
- It does **not** rewrite the daemon. WS3 splits god files; WS5 hardens RPC. The daemon is fundamentally sound; this is surgical.
- It does **not** migrate to a new database engine. SQLite is the right choice; the plan makes it scale, not replaces it.
- It does **not** add a Windows daemon. That's a 12-month project in its own right.
- It does **not** add multi-tenant or team features. Those require architectural changes not in scope.
- It does **not** ship Computer Use Phases 9–13 to all users at once. Per the master plan, each phase ships behind a feature flag with a ring rollout.

These are explicitly future work. If the diligence partner asks about any of them, the answer is "we know, it's the next 12-month plan."

---

## Closing

OpenBurnBar at 7.5/10 is already a serious engineering foundation. The work to reach 10/10 is not a rewrite — it is the execution of the discipline the team has already proven they have, applied to the load-bearing seams that the diligence review surfaced.

The bar is set. The workstreams are scoped. The exit criteria are falsifiable. The critical path is 50–55 working days with 5 senior engineers + 1 SRE + 1 security engineer.

**Boil the ocean. Ship the complete thing. The standard isn't "good enough" — it's "holy shit, that's done."**
