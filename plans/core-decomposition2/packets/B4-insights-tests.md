# Packet B4: move Insights-owned tests → OpenBurnBarInsightsTests (29 files)
STATE: EXECUTED (branch core-decomp2/b4-insights-tests, base core-decomp2/b3-kernel-crypto-tests)
LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

## Execution outcome (this PR)
29 files `git mv`'d CoreTests → OpenBurnBarInsightsTests (git detected all 29 as renames,
97-99% similarity — the only content delta per file is its import block). PlaceholderTests.swift
deleted. Whole-package `swift test`: 2052 → 2051 enumerated tests; the sole delta is the removed
`OpenBurnBarInsightsTestsPlaceholder` scaffold stub (the identity diff `comm -23 base moved` shows
ZERO real tests dropped). OpenBurnBarInsightsTests now runs 223 tests (2 skipped, 0 failures).
Import rewrites applied:
- Default `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarInsights` on 25 files.
- BurnBarHostedAdapterWireTests / InsightCanvasStoreTests / RuleBasedVerdictEngineTests: dropped
  the redundant Core umbrella line, kept the pre-existing `@testable import OpenBurnBarInsights`.
- AgentInsightsViewModelTests: `@testable import OpenBurnBarInsights` + plain `import OpenBurnBarUI`
  (for the PUBLIC AgentInsightsViewModel / AgentInsightsBundleProducer /
  StaticAgentInsightsBundleProducer, which live in OpenBurnBarUI) + `import OpenBurnBarKernel`
  (for AgentProvider). Added "OpenBurnBarUI" to the OpenBurnBarInsightsTests target deps — UI→Insights
  is the only module edge, so a TEST target depending on both closes NO product cycle.
- AgentInsightsScopeTests + AgentInsightsBundleAssemblerTests: added plain `import OpenBurnBarKernel`
  (both reference AgentProvider, a KernelModels type reached via the Kernel umbrella; NOT re-exported
  by @testable Insights). The card's VectorKit/Quota "weak 1-hit" signals for
  AgentInsightsBundleAssemblerTests / InsightFoundationTests / AgentInsightsScopeTests were all
  confirmed FALSE POSITIVES (string-literal / lowercase-var / nested-type `Kind`/`Window` tokens) —
  no VectorKit or Quota dep added.
- InsightAnalysisTests: added plain `import OpenBurnBarUI` (it exercises the PUBLIC
  IntelligenceBriefFormatting enum, which lives in OpenBurnBarUI) — surfaced by the compiler, beyond
  the card's enumerated deviations. Covered by the same OpenBurnBarUI target dep.
No `Bundle.module` fixture reads (verified) — InsightTestFixtures is pure in-code and moved with its
consumers. coretests-file baseline intentionally NOT ratcheted here (integrator ratchets the stack at
the end); the shrink-only gate passes non-fatally. Daemon build green; whole-package build/test green;
all scripts/debt gates + no-suppressions + canon --check pass vs base b3. NB: the macOS
OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 build fails identically on the CLEAN base tree
(`unable to resolve module dependency: 'CSQLite'`) — a pre-existing host/toolchain issue, not this
packet (this change touches zero SQLite/daemon-graph code, and off-Apple `buildApplePrunedDecompositionTargets`
is compile-time false on Linux so the boundary graph never sees OpenBurnBarInsightsTests).

Destination: `OpenBurnBarCore/Tests/OpenBurnBarInsightsTests/` — an APPLE-PRUNED test target
(declared inside `applePrunedDecompositionTargets`, like the OpenBurnBarInsights module).
Delete `PlaceholderTests.swift` here. Preserve the Trace/Widget/Verdict/Cadence subdir layout
(`mkdir -p` destinations first — K1 OP-NOTE).

## git mv list
Top-level: InsightVerdictWidgetSnapshotDiffTests.swift
Insights/ (drop the now-redundant `Insights/` prefix in the destination, keep subdirs below it):
AgentInsightsBundleAssemblerTests.swift, AgentInsightsScopeTests.swift,
AgentInsightsViewModelTests.swift, BurnBarHostedAdapterWireTests.swift,
Cadence/CadenceRendererTests.swift, Cadence/CadenceSchedulerTests.swift,
HermesInsightAdapterTests.swift, HostedFallbackTests.swift, InsightAnalysisTests.swift,
InsightCacheAndAuditTests.swift, InsightCanvasStoreTests.swift, InsightDigestPrivacyTests.swift,
InsightExecutorTests.swift, InsightFoundationTests.swift, InsightGatewayTests.swift,
InsightLiveProviderSmokeTests.swift, InsightMissionApprovalPolicyTests.swift,
InsightTestFixtures.swift (shared helper — moves with its consumers),
Trace/InsightSessionTraceBuilderTests.swift, Verdict/InsightVerdictCodecTests.swift,
Verdict/InsightVerdictDemoFixtureTests.swift, Verdict/InsightVoicePostProcessorTests.swift,
Verdict/InsightVoiceSchemaV2Tests.swift, Verdict/RuleBasedVerdictEngineTests.swift,
Verdict/VerdictCacheTests.swift, Verdict/VerdictComposerTests.swift,
Verdict/VerdictWindowTests.swift, Widget/InsightVerdictWidgetSnapshotTests.swift

## Expected @testable rewrite per file
Default: `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarInsights`.
Deviations:
- BurnBarHostedAdapterWireTests, InsightCanvasStoreTests, RuleBasedVerdictEngineTests: already
  have `@testable import OpenBurnBarInsights` — just drop the Core umbrella import.
- AgentInsightsViewModelTests: real OpenBurnBarUI hits (3) — add `import OpenBurnBarUI` (or
  @testable) AND add "OpenBurnBarUI" to the OpenBurnBarInsightsTests dependency list (acyclic:
  UI→Insights is a target edge; a TEST target depending on both closes no cycle). If the UI
  symbols are internal-only and @testable-UI feels wrong here, valve the file to
  OpenBurnBarUIModuleTests instead.
- Weak 1-hit siblings (AgentInsightsBundleAssemblerTests: VectorKit/KernelModels/Quota;
  InsightFoundationTests: Quota; AgentInsightsScopeTests: KernelModels): plain `import` of the
  needed module + AE-dep, or false-positive — verify at move time.

## Package.swift seam edits
- `openBurnBarCoreTestExcludes` lists `Insights/BurnBarHostedAdapterWireTests.swift` and
  `Insights/InsightLiveProviderSmokeTests.swift` (off-Apple excludes): REMOVE both entries —
  the whole destination target is Apple-pruned, making the per-file exclusion structural.

## Fixtures
No `Fixtures/` reads (the "fixtures" here are the in-code InsightTestFixtures helpers, which
move in this packet). Verify with a `Bundle.module` grep at move time.

## Close-out
Delete PlaceholderTests.swift; `check-coretests-file-budget.sh --update`; full V-list
(including the off-Apple Linux-boundary build — it must never see this target).
