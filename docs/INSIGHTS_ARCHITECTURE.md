# Insights — Architecture

This document is the internal map of the Insights system. For the
user-facing overview, see [`INSIGHTS.md`](INSIGHTS.md).

## Layers

```
┌──────────────────────────────────────────────────────────────────────────┐
│              OpenBurnBarCore.Insights — shared, platform-agnostic         │
│   Canonical Codable types + executor + gateway + JSON-Schema contract    │
│                                                                          │
│   SharedModels/Insights/      — types (analysis, canvas, widget, digest) │
│   Services/Insights/          — digest builder, executor, store, cache,  │
│                                  aggregator, analysis engine, audit log, │
│                                  model gateway, prompt, tool broker      │
│   Services/Insights/Adapters/ — adapters (Anthropic / OpenAI / OpenAI-   │
│                                  compatible / Ollama / Hermes / Pi /     │
│                                  LocalRules)                             │
│   Views/Insights/             — SwiftUI renderers (one per widget kind)  │
└──────────────────────────────────────────────────────────────────────────┘
                ▲                                       ▲
                │                                       │
   ┌────────────┴────────────┐         ┌────────────────┴────────────────┐
   │  AgentLens (macOS)      │         │  OpenBurnBarMobile (iOS/iPad)   │
   │  Views/Insights/        │         │  Views/Insights/                │
   │  DashboardMainRoute     │         │  AuroraNavDestination.insights  │
   │  3-pane workspace       │         │  Tab (iPhone) / Split (iPad)    │
   │  Custom 12-col Layout   │         │  Reflow projection (6/2 col)    │
   └─────────────────────────┘         └─────────────────────────────────┘
```

## Data flow

```
DataStore / DashboardStore / Firestore rollups / quota snapshots
        │
        ▼
InsightDataSource.snapshot(window:) → InsightDataSnapshot
        │
        ├────────────────┬────────────────┐
        ▼                ▼                ▼
InsightAggregator  InsightDigestBuilder  InsightExecutor
        │                │                │
        ▼                ▼                ▼
InsightAnalysisContext  InsightDigest  InsightWidgetData (per widget)
        │
        ▼
InsightAnalysisEngine
        │
        ▼
InsightAnalysisResult
        │
        ▼
Generated widgets + findings + citations + audit entry
        │
        ▼
InsightCanvasStore (file-backed, append-safe merge by canvas ID, optional Firestore sync)
        │
        ▼
SwiftUI renderers
```

## Types of interest

- `InsightCanvas` — a persistent dashboard.
- `InsightWidget` — a card on the canvas: `(kind, spec, dataBinding, data)`.
- `InsightWidgetKind` — the registry. 26 cases; exhaustive switch fans
  out to renderers and executor.
- `InsightWidgetSpec` — authoring intent (titles, formatting, sort
  order). Produced by the LLM, persisted with the widget.
- `InsightDataBinding` — declarative description of "what data does this
  widget want?". The executor turns it into `InsightWidgetData`.
- `InsightDigest` — the privacy-bounded snapshot sent to LLMs. 24 KB ceiling,
  enforced by `InsightDigestBuilder.trim(_:toMaxBytes:)`.
- `InsightAnalysisRequest` — the user's question plus the selected
  provider/model, current canvas, instruction, transcript opt-in, and widget
  budget.
- `InsightAnalysisContext` — the LLM-safe digest, local evidence index,
  context budget report, and recent prior run summaries.
- `InsightAnalysisResult` — structured JSON containing the executive summary,
  findings, anomalies, recommendations, generated widgets, follow-up
  questions, citations, token/cost accounting, audit id, and result hash.
- `InsightFinding` / `InsightRecommendation` — every major claim carries
  evidence citations, confidence, severity, and a concrete recommended action.

## Aggregator responsibilities

Each platform owns an `InsightAggregator` with the same conceptual contract:

- macOS includes local disk session logs, DataStore usage/session/project
  rows, Firestore rollups/quota state, provider account state, Chart Studio
  refs, and prior analysis/audit history when available.
- iOS/iPadOS builds a mobile-safe digest from `DashboardStore`/Firestore
  rollups, quota snapshots, provider/model summaries, and prior mobile
  analysis history.
- Android builds the same digest/evidence/budget shape from Firestore rollups,
  quota snapshots, provider/model summaries, and Android audit history. The
  production path no longer defaults to fixture/demo content.

All aggregators emit a compact prompt context plus a richer local evidence
index for drilldowns. The budget report records encoded bytes, estimated
prompt tokens, included data sources, and truncation notes.

## LLM plane

- `InsightModelGateway` — protocol every adapter conforms to. Streams
  `InsightInvestigateEvent` values and, for the intelligence layer, returns
  a structured `InsightAnalysisResult`.
- `InsightModelCatalog` — actor that aggregates registered gateways and
  exposes their models for the picker.
- `InsightInvestigation` — orchestrator that: privacy-gates, cache-checks,
  dispatches to the gateway, persists the result, and writes audit.
- `InsightPromptEngine` — builds the system prompt + user payload.
- `InsightJSONSchema.canvasSchemaV1` — JSON Schema for strict-mode generation.
- `InsightJSONSchema.analysisResultSchemaV1` — JSON Schema for the structured
  intelligence result above the canvas/widget layer.
- `InsightToolBroker` — read-only tool plane for follow-up queries.
- `InsightCapabilityTier` — `.strictJSONSchema` | `.jsonObject` | `.narrativeOnly`.
  Gateways advertise capabilities; the orchestrator picks the best
  supported tier and falls back gracefully.

## Adapters

```
Anthropic (Claude)    — structured analysis via user's API key
OpenAI / Codex        — structured analysis via user's API key
OpenAI-compatible     — MiniMax, Z.ai, Kimi, OpenRouter/Hermes-like gateways
                        through user-provided credentials
Hermes                — uses existing relay transport
Pi                    — uses existing Pi runtime transport
Ollama                — local-only json_object
LocalRules            — no model call; rule-based canvas authoring
```

`HermesInsightTransport` is the plug-in seam for Hermes and Pi — shells
provide a concrete transport so we don't pull the entire Hermes
codebase into Core.

The selected model is always user-owned: a local runtime, a user API key, a
user relay, or a Hermes-advertised route. The analysis layer must not silently
fail over to an OpenBurnBar-owned model account.

## Analysis plane

The analysis layer is the intelligence contract *above* the canvas. Engines
produce one structured `InsightAnalysisResult` per run, validated against
`InsightJSONSchema.analysisResultSchemaV1`. The shape is identical across
Swift, Kotlin, and the Functions TypeScript types so a result built on macOS
round-trips through iOS, iPadOS, Android, and Firestore without translation.

- **Engines.** `InsightAnalysisEngine` (Swift protocol, Kotlin interface)
  exposes `analyze(_ request:) -> InsightAnalysisResult`. The shared
  `RuleBasedInsightAnalysisEngine` is the always-on local fallback — pure
  heuristics, zero egress. `OrchestratedInsightAnalysisEngine` (Swift) and
  the upgraded `AndroidInsightAnalysisEngine` (Kotlin) enforce privacy mode,
  dispatch to the selected registered gateway when the user picked a
  non-local model, and wrap the run in the audit + cache pipeline.
  Platform-specific wrappers (`MacInsightAnalysisEngine`,
  `MobileInsightAnalysisEngine`) are thin constructors that pick up the
  right audit-log / cache locations and model catalog.
- **Cache.** `InsightAnalysisCache` (Swift actor) and
  `InsightAnalysisCacheRepository` (Kotlin) are content-addressed by
  `(prompt, digest content hash, model id, instruction)`. LRU at 64 entries.
  Lookup short-circuits the gateway call and skips writing a new audit row.
- **Audit.** `InsightAnalysisAuditLog` (Swift) and
  `InsightAnalysisAuditLogRepository` (Kotlin) are append-only JSONL trails
  sibling to the canvas-investigation audit. Each row captures: request id,
  platform, model + egress tier, time window, included data sources, prompt
  hash, result hash, status (`started`/`succeeded`/`partial`/
  `modelUnavailable`/`schemaViolation`/`cancelled`/`failed`), token usage,
  and cost estimate. `upsertLatest` is used by the orchestrator to mark a
  started entry succeeded/failed without writing two rows.
- **Model preference.** `InsightModelPreference` carries automatic vs
  explicit mode plus `restrictToLocalOnly`, `maxEgressTier`, and
  `deepTranscriptOptIn`. Composers surface the active egress tier and the
  larger-budget warning before any non-local call.
- **Schema gate.** Gateway responses that fail
  `analysisResultSchemaV1` validation are rejected at the engine boundary
  and recorded as `status: schemaViolation`; the engine then falls back to
  rule-based output so the UI never shows a partial canvas.
- **Platform aggregators.** Each platform owns a thin class that bridges
  its native data sources to the shared `InsightAggregator`:
  `MacInsightAggregator` (AgentLens) pulls `DataStore` usage/sessions plus
  prior audit summaries; `MobileInsightAggregator` (OpenBurnBarMobile)
  pulls Firestore-backed `DashboardStore` rollups; `AndroidInsightAggregator`
  pulls the production `FirestoreInsightDataSource` (never the demo
  fixture). All three include the last ~10 audit summaries in
  `priorRunSummaries` so the model has memory of what it already produced.
- **Provider-family picker.** `InsightProviderFamilyCatalog` (core Swift
  helper, mirrored TS / Kotlin types) maps any
  `InsightCatalogModel` into a normalized
  `InsightProviderFamilyEntry` keyed by `InsightProviderFamily`
  (Codex / Claude / MiniMax / Z.ai / Kimi / Ollama / Hermes / OpenAI /
  Pi / OpenRouter / local-rules / other). Section order is stable and
  local-first regardless of catalog churn; composers use `grouped(_:)` to
  render section headers and `entries(from:automaticDefault:)` to mark the
  Hermes-advertised default.

## UI plane — Intelligence Brief

`IntelligenceBriefView` (Swift, in `OpenBurnBarCore/Views/Insights/`) and
`IntelligenceBriefScreen` (Compose, in `android/.../ui/insights/`) render an
`InsightAnalysisResult` identically on every platform. The same arc on each:
hero card (executive summary + model chip + budget chip + token-usage
chip), top findings, anomaly chips, recommendation cards, generated
widgets inline via `InsightWidgetRenderer`, follow-up question chips, and
an audit footer with the result hash and audit row id. Callers wire the
five callbacks (`onCitationTap`, `onFollowUpTap`, `onPinWidget`,
`onConfigureModel`, `onShowAudit`); the view is stateless so it composes
cleanly into AgentLens's 3-pane workspace, OpenBurnBarMobile's stack/split
shells, and the Android `InsightsScreen`. The `IntelligenceBriefFormatting`
helper exposes the same chip/footer text on every surface so audit views
and previews match the live brief.

## Adding a new widget kind

5-step contract:

1. Add a case to `InsightWidgetKind`.
2. Add a matching `InsightWidgetSpec` case + spec struct.
3. Add a matching `InsightDataBinding` case (or reuse one).
4. Teach `InsightExecutor` how to evaluate the binding (a new
   `make…(…)` helper).
5. Add a renderer view in `OpenBurnBarCore/Views/Insights/` and fan
   out the new case in `InsightWidgetRenderer`.

Because every fan-out is an exhaustive `switch`, the compiler points
at every missing place if you forget a step.

## Privacy guarantees (tested)

`InsightDigestPrivacyTests` enforces:

- Encoded digest ≤ 24 KB.
- Device names redacted to `Device · XXXX`.
- Project ids prefixed `project_` and hashed.
- No key-file contents appear anywhere in the encoded digest.
- Content hash is stable across builds for the same snapshot+filter.
- Every focus/use-case tag is a member of the supplied taxonomy.

## Files

```
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/Insights/
   InsightAnalysis.swift, InsightCanvas.swift, InsightWidget.swift, InsightWidgetKind.swift,
   InsightWidgetSpec.swift, InsightWidgetData.swift, InsightDataBinding.swift,
   InsightLayout.swift, InsightFilter.swift, InsightTheme.swift,
   InsightModelTag.swift, InsightCitation.swift, InsightTaxonomy.swift,
   InsightFreshness.swift, InsightDigest.swift, InsightCanvasTemplate.swift,
   InsightTokenUsage.swift, InsightInvestigateRequest.swift,
   InsightInvestigateEvent.swift, InsightGatewayError.swift

OpenBurnBarCore/Sources/OpenBurnBarCore/Services/Insights/
   InsightDataSource.swift, InMemoryInsightDataSource.swift,
   InsightAggregator.swift, InsightAnalysisEngine.swift,
   InsightDigestBuilder.swift, InsightExecutor.swift,
   InsightCanvasStore.swift, InsightAuditLog.swift, InsightCache.swift,
   InsightModelGateway.swift, InsightModelCatalog.swift,
   InsightPromptEngine.swift, InsightJSONSchema.swift,
   InsightToolBroker.swift, InsightInvestigation.swift,
   Adapters/LocalRuleBasedAdapter.swift,
   Adapters/AnthropicInsightAdapter.swift,
   Adapters/OpenAIInsightAdapter.swift,
   Adapters/OpenAICompatibleInsightAdapter.swift,
   Adapters/HermesInsightAdapter.swift,
   Adapters/PiInsightAdapter.swift,
   Adapters/OllamaInsightAdapter.swift

OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Insights/
   InsightWidgetRenderer.swift, InsightWidgetChrome.swift,
   InsightFormatting.swift, plus one file per renderer.

AgentLens/Views/Insights/
   InsightsWorkspaceView.swift, InsightsMacEnvironment.swift,
   InsightsCanvasGrid.swift, InsightsComposerBar.swift,
   InsightsCanvasLibraryView.swift, InsightsTemplateGalleryView.swift,
   InsightsInspectorView.swift, InsightsBuiltInTemplates.swift,
   MacInsightDataSource.swift

OpenBurnBarMobile/
   Models/InsightsStore.swift
   Services/Insights/MobileInsightDataSource.swift
   Views/Insights/InsightsRootView.swift

android/app/src/main/java/com/openburnbar/data/insights/
   InsightAnalysis.kt, InsightCanvas.kt, InsightWidget.kt, InsightDigest.kt

android/app/src/main/java/com/openburnbar/data/insights/services/
   FirestoreInsightDataSource.kt, InsightAnalysisEngine.kt,
   InsightDigestBuilder.kt, InsightExecutor.kt

functions/src/types.ts
   InsightAnalysisRequestDoc, InsightAnalysisContextDoc,
   InsightAnalysisResultDoc, InsightAnalysisAuditEntryDoc
```

## Tests

```
OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Insights/
   InsightFoundationTests.swift       — codecs, layout projection, taxonomy
   InsightDigestPrivacyTests.swift    — 24KB cap, redaction, taxonomy stability
   InsightExecutorTests.swift         — every binding kind
   InsightCanvasStoreTests.swift      — file persistence, append-safe import/merge
   InsightCacheAndAuditTests.swift    — cache keys, audit append/read
   InsightGatewayTests.swift          — LocalRuleBasedAdapter + prompt + broker
   InsightAnalysisTests.swift         — analysis context, selected dispatch, result, widgets
   InsightTestFixtures.swift          — shared synthetic dataset
```

Run with:

```bash
cd OpenBurnBarCore && swift test --filter Insight
cd android && ./gradlew testDebugUnitTest --tests 'com.openburnbar.data.insights.InsightsDataLayerTest'
cd functions && npm run build
```
