# Packet B4: move Insights-owned tests → OpenBurnBarInsightsTests (29 files)
STATE: READY  LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

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
