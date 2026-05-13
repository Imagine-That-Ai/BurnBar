# Insights — Architecture

This document is the internal map of the Insights system. For the
user-facing overview, see [`INSIGHTS.md`](INSIGHTS.md).

## Layers

```
┌──────────────────────────────────────────────────────────────────────────┐
│              OpenBurnBarCore.Insights — shared, platform-agnostic         │
│   Canonical Codable types + executor + gateway + JSON-Schema contract    │
│                                                                          │
│   SharedModels/Insights/      — types (canvas, widget, layout, digest)   │
│   Services/Insights/          — digest builder, executor, store, cache,  │
│                                  audit log, model gateway, prompt,       │
│                                  tool broker, investigation orchestrator │
│   Services/Insights/Adapters/ — adapters (Anthropic / OpenAI / Ollama /  │
│                                  Hermes / Pi / LocalRules)               │
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
DataStore / DashboardStore
        │
        ▼
InsightDataSource.snapshot(window:) → InsightDataSnapshot
        │
        ├─────────────┐
        ▼             ▼
InsightDigestBuilder  InsightExecutor
        │                 │
        ▼                 ▼
   InsightDigest    InsightWidgetData (per widget)
        │
        ▼
InsightInvestigation
        │
        ▼
InsightModelGateway (per provider)
        │
        ▼
InsightCanvas (typed JSON)
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

## LLM plane

- `InsightModelGateway` — protocol every adapter conforms to. Streams
  `InsightInvestigateEvent` values.
- `InsightModelCatalog` — actor that aggregates registered gateways and
  exposes their models for the picker.
- `InsightInvestigation` — orchestrator that: privacy-gates, cache-checks,
  dispatches to the gateway, persists the result, and writes audit.
- `InsightPromptEngine` — builds the system prompt + user payload.
- `InsightJSONSchema.canvasSchemaV1` — JSON Schema for strict-mode generation.
- `InsightToolBroker` — read-only tool plane for follow-up queries.
- `InsightCapabilityTier` — `.strictJSONSchema` | `.jsonObject` | `.narrativeOnly`.
  Gateways advertise capabilities; the orchestrator picks the best
  supported tier and falls back gracefully.

## Adapters

```
Anthropic (Claude)    — strict schema + thinking + tools
OpenAI (GPT)          — strict schema + thinking + tools
OpenRouter            — json_object fallback
Hermes                — uses existing relay transport
Pi                    — uses existing Pi runtime transport
Ollama                — local-only json_object
LocalRules            — no model call; rule-based canvas authoring
```

`HermesInsightTransport` is the plug-in seam for Hermes and Pi — shells
provide a concrete transport so we don't pull the entire Hermes
codebase into Core.

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
   InsightCanvas.swift, InsightWidget.swift, InsightWidgetKind.swift,
   InsightWidgetSpec.swift, InsightWidgetData.swift, InsightDataBinding.swift,
   InsightLayout.swift, InsightFilter.swift, InsightTheme.swift,
   InsightModelTag.swift, InsightCitation.swift, InsightTaxonomy.swift,
   InsightFreshness.swift, InsightDigest.swift, InsightCanvasTemplate.swift,
   InsightTokenUsage.swift, InsightInvestigateRequest.swift,
   InsightInvestigateEvent.swift, InsightGatewayError.swift

OpenBurnBarCore/Sources/OpenBurnBarCore/Services/Insights/
   InsightDataSource.swift, InMemoryInsightDataSource.swift,
   InsightDigestBuilder.swift, InsightExecutor.swift,
   InsightCanvasStore.swift, InsightAuditLog.swift, InsightCache.swift,
   InsightModelGateway.swift, InsightModelCatalog.swift,
   InsightPromptEngine.swift, InsightJSONSchema.swift,
   InsightToolBroker.swift, InsightInvestigation.swift,
   Adapters/LocalRuleBasedAdapter.swift,
   Adapters/AnthropicInsightAdapter.swift,
   Adapters/OpenAIInsightAdapter.swift,
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
   InsightTestFixtures.swift          — shared synthetic dataset
```

All 45 tests pass; run with:

```bash
cd OpenBurnBarCore && swift test --filter Insight
```
