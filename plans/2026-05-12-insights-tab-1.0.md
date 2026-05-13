# Insights Tab — Cross-Platform AI-Authored Analytics Canvas

**Date:** 2026-05-12
**Version:** 1.0
**Status:** Plan — ready for implementation
**Platforms:** macOS (AgentLens) · iPadOS (OpenBurnBarMobile) · iOS (OpenBurnBarMobile)
**Author:** Claude (Opus 4.7) on `launch/self-hosted-runner-keychain-tests`

---

## 1. Vision

> A dedicated **Insights** destination on macOS, iPad, and iPhone that turns OpenBurnBar's local SQLite, JSONL ledgers, and Firestore rollups into a **living, AI-authored analytics canvas**. The user picks any reachable model — Claude, GPT-5, Hermes relay, local Ollama, Pi — and that model **investigates, summarizes, comments, and recommends** across the user's agent activity. Output is rendered as **modular widgets on a customizable grid** (the Chart Studio philosophy, but persistent, multi-canvas, multi-model). Each widget is a typed JSON spec produced by either a deterministic local engine or the selected LLM under a strict JSON-Schema contract. Cards can be dragged, resized, reordered, edited, and remixed. Canvases save, sync, export, and template.

**Hard requirements (Alberto's brief):**

1. Available on iOS, iPadOS, and macOS — feature parity, platform-native feel.
2. User-selected model performs the analysis.
3. Surfaces: insightful recommendations · usage patterns · per-agent focuses · per-model focuses · per-agent use cases · per-model use cases · anything else cleanable from logs/traces.
4. Beautiful and intuitive.
5. Highly modular and customizable — Chart Studio-class flexibility.
6. State-of-the-art for every decision.
7. Frontier, durable, extensible, elegant, future-proof.

**Success bar:** a user opens Insights, asks "what did I waste money on this week?", and within seconds gets a beautifully rendered, drag-rearrangeable, citation-linked, drill-downable canvas of widgets that wouldn't look out of place in a Linear or Figma product.

---

## 2. What we will NOT do (and why)

To keep scope honest:

- **Not** a generic "BI tool". We optimize narrowly for *AI-coding-agent observability* (the data we actually have).
- **Not** a web app. Native SwiftUI everywhere; web export is JSON/Markdown/PDF only.
- **Not** a replacement for the existing **macOS popover `InsightEngine`** (rule-based, latency-critical) — we *extend* it. The popover keeps generating its rule-based insights as cheap pre-cooked tiles; Insights tab consumes the same `Insight` value type for narrative cards and adds LLM-authored widgets on top.
- **Not** a replacement for the iOS **Chart Studio**. Chart Studio remains the *exploratory single-canvas* surface. Insights is the *persistent multi-canvas dashboard*. They share their JSON spec grammar and renderers.

This dual integration means we **reuse two existing pipelines** rather than build a third.

---

## 3. Architecture at a glance

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                       OpenBurnBarCore.Insights (new)                          │
│   Canonical Codable types + prompt engine + JSON-Schema contract             │
│                                                                              │
│   ┌──────────────┐  ┌────────────────┐  ┌──────────────────────────────┐    │
│   │ InsightDigest│  │ InsightWidget* │  │ InsightCanvas / Layout / Bin │    │
│   └──────────────┘  └────────────────┘  └──────────────────────────────┘    │
│   ┌──────────────────────┐  ┌──────────────────────────────────────────┐    │
│   │ InsightPromptEngine  │  │ InsightModelGateway (protocol + adapters)│    │
│   └──────────────────────┘  └──────────────────────────────────────────┘    │
│   ┌──────────────────────┐  ┌──────────────────────────────────────────┐    │
│   │ InsightExecutor       │  │ InsightCanvasStore (file + Firestore)   │    │
│   │ (local data binding)  │  │                                          │    │
│   └──────────────────────┘  └──────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
                        ▲                                ▲
                        │                                │
        ┌───────────────┴────────────────┐  ┌────────────┴───────────────┐
        │   AgentLens (macOS)            │  │  OpenBurnBarMobile (iOS/iPad)│
        │   Views/Insights/*             │  │  Views/Insights/*            │
        │   DashboardMainRoute.insights  │  │  AuroraNavDestination.insights│
        │   Sidebar + Detail + Inspector │  │  Tab (iPhone) /              │
        │                                │  │  Split (iPad: rail+detail)   │
        └────────────────────────────────┘  └──────────────────────────────┘
```

**Two layers, three shells.** Shared core does all the analysis, persistence, prompting, and rendering grammar. Each platform owns layout/navigation/affordances.

---

## 4. Shared core — `OpenBurnBarCore.Insights`

A new sub-namespace inside `OpenBurnBarCore` (no new SwiftPM target; lives alongside `SharedModels/`). Pure value types + actor-isolated services. No SwiftUI in core except a small `InsightWidgetRenderer` view-builder file under `Views/Insights/` in Core (Core already has a `Views/` directory; SwiftUI is allowed there per existing convention).

### 4.1 Canonical Codable types

```
SharedModels/Insights/
├── InsightCanvas.swift           — top-level board document
├── InsightWidget.swift           — widget value type (id, kind, spec, layout, meta)
├── InsightWidgetKind.swift       — exhaustive enum + registry
├── InsightWidgetSpec.swift       — sealed sum: kpi/timeSeries/.../narrative/recommendation
├── InsightLayout.swift           — grid coords + spans + revision counter
├── InsightTheme.swift            — visual presets (Aurora, Mercury, Ember, Whimsy, Mono)
├── InsightFilter.swift           — time range, provider, model, project, agent, dimension
├── InsightCitation.swift         — drill-down anchors (sessionID, conversationID, query)
├── InsightModelTag.swift         — which model produced what
└── InsightCanvasTemplate.swift   — built-in templates registry
```

`InsightCanvas`:
```swift
public struct InsightCanvas: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var summary: String?
    public var icon: String                  // SF Symbol
    public var theme: InsightTheme
    public var widgets: [InsightWidget]
    public var layout: InsightLayout         // explicit grid placement
    public var filter: InsightFilter         // canvas-level default
    public var modelTag: InsightModelTag?    // which model authored most recently
    public var schemaVersion: Int            // future-proof migration
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRefreshedAt: Date?
    public var origin: Origin                // .userCreated | .template(id) | .composed(prompt)
    public enum Origin: Codable, Hashable, Sendable { /* … */ }
}
```

`InsightWidget`:
```swift
public struct InsightWidget: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: InsightWidgetKind
    public var title: String
    public var subtitle: String?
    public var spec: InsightWidgetSpec       // sealed sum, see §4.2
    public var layout: InsightLayout.CellPlacement
    public var filter: InsightFilter?         // widget-level override
    public var dataBinding: InsightDataBinding // see §6
    public var freshness: InsightFreshness   // fresh|stale|computing|error|locked
    public var modelTag: InsightModelTag?    // who wrote/refreshed it
    public var lockedAt: Date?               // user-pinned snapshot
    public var schemaVersion: Int
}
```

### 4.2 Widget catalog (the "registry")

`InsightWidgetKind` is the **single registry**. New widgets are added by extending the enum and the `InsightWidgetSpec` sum. Renderers fan out via exhaustive `switch` (compiler-enforced completeness).

| # | `kind` | Renderer | What it shows | Primary data source |
|---|---|---|---|---|
| 1 | `kpiTile` | Big-number card | Single metric + delta + sparkline | `token_usage` rollup |
| 2 | `timeSeriesLine` | Swift Charts line | Daily/hourly trend, anomaly markers | `RollupDailyPoint` |
| 3 | `timeSeriesArea` | Stacked area | Per-provider/model trend | Daily rollups |
| 4 | `streamGraph` | ThemeRiver-style | Provider mix over time | Daily rollups |
| 5 | `barRanking` | Horizontal bars | Top-N agents / models / projects / files | Aggregated rollups |
| 6 | `donut` | Donut + legend | Cost / token share | Window rollup |
| 7 | `treemap` | Squarified treemap | Spend by provider×model | Window rollup |
| 8 | `heatmap` | Hour×Day grid | Usage rhythm | Hourly histogram |
| 9 | `scatter` | Cost-per-Mtoken × volume | Model efficiency frontier | Per-model rollup |
| 10 | `sankey` | Sankey diagram | agent → model → project flow | Joined rollups |
| 11 | `radar` | Radar polygon | Per-agent "focus fingerprint" (6 axes: code, write, debug, research, refactor, ops) | LLM-clustered conversations |
| 12 | `cohort` | Cohort retention grid | Weekly retention by first-session week | Conversations |
| 13 | `funnel` | Funnel bars | Conversation-stage drop-off | Operating action history |
| 14 | `quotaPulse` | Provider quota gauges | Live caps remaining | `ProviderQuotaBucket` |
| 15 | `forecast` | Line with uncertainty band | 7/30/90 day projection | Holt-Winters on rollups |
| 16 | `anomalyTable` | List with scores | Outlier sessions/days | Robust z-score local |
| 17 | `narrative` | Glass card prose | LLM written paragraph + bullets + cite chips | LLM authored |
| 18 | `recommendation` | Action card | Suggested change + impact estimate + confidence | LLM authored |
| 19 | `useCaseCluster` | Tag cloud + chips | LLM-clustered conversation topics with examples | LLM clustered |
| 20 | `agentFocusMatrix` | Matrix card | Per-agent×focus heat | LLM tagged |
| 21 | `modelFocusMatrix` | Matrix card | Per-model×focus heat | LLM tagged |
| 22 | `drilldownList` | Session list | Sessions matching filter w/ click-through | SQL query |
| 23 | `mermaid` | WebKit Mermaid (existing) | Diagrams the LLM emits | LLM |
| 24 | `ascii` | Mono terminal art (existing) | TUI-style snapshots | LLM |
| 25 | `composed` | Stack | Multiple widgets stacked atomically | Recursive |
| 26 | `error` | Glass card | Diagnostic if a widget fails | Local |

The same enum is the menu population source for "Add widget" picker — `CaseIterable` + `displayName` + `symbolName` + `defaultSpec()` (like `SmartDisplayKind`).

### 4.3 InsightLayout — grid system

```swift
public struct InsightLayout: Codable, Hashable, Sendable {
    public var columnCount: Int           // 12 on macOS, 6 on iPad, 2 on iPhone (auto-derived but persisted as "intent")
    public var rowHeight: CGFloat         // 96pt baseline
    public var gap: CGFloat               // 12pt
    public var placements: [UUID: CellPlacement]  // widget id → position
    public var revision: Int              // monotonic, for conflict-free reorder
    public struct CellPlacement: Codable, Hashable, Sendable {
        public var column: Int
        public var row: Int
        public var colSpan: Int           // 1…columnCount
        public var rowSpan: Int           // 1…N
        public var anchor: Anchor         // .topLeading by default
    }
}
```

Layout is **deterministic** (no auto-flow surprises). Drag/drop mutates `placements` and bumps `revision`. iPad/iPhone read the canvas's layout and project it to fewer columns via a single `projected(toColumnCount:)` helper (collapses spans, never overlaps). Users see the same content, **same intent**, adapted.

### 4.4 InsightDigest — what the LLM actually sees

Extends `TrendDataDigest` (already a 3–12KB privacy-scrubbed snapshot) into a richer **InsightDigest** with:

- All `TrendDataDigest` fields.
- `agents: [AgentSnapshot]` — per-AgentProvider: sessions, total cost, top 3 models, top 5 inferred task titles, top 5 referenced files, top 5 commands.
- `models: [ModelSnapshot]` — per-model: cost, tokens, cache hit rate, avg session length, top 5 inferred task titles, top 3 referencing projects.
- `useCaseHistogram: [UseCaseBin]` — coarse topic histogram derived from `conversations.inferredTaskTitle` and `keyTools` (counted, not full text).
- `agentFocusSignals: [AgentFocusSignal]` — `(agent, focus, weight)` triples computed from `keyCommands` + `keyTools` heuristics (e.g. `git diff`/`pytest` → `code`; `grep`/`Read` → `research`).
- `modelFocusSignals: [ModelFocusSignal]` — same shape for models.
- `quotaSnapshots: [QuotaSnapshotSummary]` — last-known per-provider bucket %used + reset.
- `operatingActions: [ActionDigest]` — last 50 daemon `operating_action_history` rows summarized.
- `summaryRunsLog: [SummaryRunDigest]` — which models summarized what, when, cost (so the LLM can comment on the LLM!).
- `anomalies: [PrecomputedAnomaly]` — local robust-z anomalies (so the LLM doesn't reinvent).
- `glossary: InsightTaxonomy` — controlled vocab of allowed `focus`/`useCase` tags so model output is consistent across runs.

**Privacy ceiling:** digest never contains conversation full text, file contents, code, secrets, credential labels, or device names. Just identifiers, counts, timestamps, and inferred titles (which are themselves LLM-summarized rollups, already privacy-bounded). Cap at **24 KB** (enforced by test). For deeper analysis, the LLM uses the `drilldown_search` tool (§5.3) which returns redacted summaries.

### 4.5 InsightTaxonomy — controlled vocabulary

We force the LLM into a stable tagging space so multi-run outputs are comparable.

```swift
public struct InsightTaxonomy: Codable, Sendable {
    public static let `default` = InsightTaxonomy(
        focuses: ["code", "write", "debug", "research", "refactor", "ops",
                  "test", "review", "design", "data", "doc", "explore"],
        useCases: ["feature-add", "bug-fix", "refactor", "test-write",
                   "doc-write", "code-explain", "code-review", "data-analysis",
                   "shell-script", "spike", "spike-cleanup", "infra-change",
                   "migration", "perf-investigation", "security-investigation",
                   "third-party-eval", "learning"]
    )
    public let focuses: [String]
    public let useCases: [String]
}
```

The prompt enforces "only return tags from this list". This is what makes `agentFocusMatrix` and `modelFocusMatrix` widgets comparable week-over-week, and what makes `useCaseCluster` deterministic.

---

## 5. LLM integration — `InsightModelGateway`

### 5.1 Model selection

The user can pick any reachable model per-canvas. We expose a `InsightModelCatalog` that aggregates:

| Source | Adapter | Reachable via |
|---|---|---|
| Anthropic API | `AnthropicInsightAdapter` | User's API key (Keychain) |
| OpenAI API | `OpenAIInsightAdapter` | User's API key |
| OpenRouter | `OpenRouterInsightAdapter` | User's API key |
| Hermes relay | `HermesInsightAdapter` | Existing `HermesService` / `OpenBurnBarHTTPGatewayServer` — reuses `ChartStudioHermesBridge` plumbing |
| Pi (local) | `PiInsightAdapter` | Existing `PiService` |
| Ollama (local) | `OllamaInsightAdapter` | Local URL from provider catalog |
| Codex CLI | `CodexInsightAdapter` | Local CLI (macOS only) |
| Claude Code | `ClaudeCodeInsightAdapter` | Local CLI (macOS only) |

All implement the same protocol:

```swift
public protocol InsightModelGateway: Sendable {
    var capabilities: InsightModelCapabilities { get }   // jsonSchema | jsonObject | toolUse | thinking | streaming
    func investigate(
        request: InsightInvestigateRequest
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error>
}
```

`InsightInvestigateEvent` cases: `.thinkingDelta(String)`, `.partialCanvas(InsightCanvas)`, `.widgetReady(InsightWidget)`, `.toolCall(InsightToolCall)`, `.toolResult(InsightToolResult)`, `.usage(InsightTokenUsage)`, `.finalCanvas(InsightCanvas)`, `.error(InsightGatewayError)`.

### 5.2 Structured generation

State-of-the-art = **JSON Schema-constrained generation**.

- **Tier 1 (preferred)**: `response_format: { type: "json_schema", schema: InsightCanvas.jsonSchema, strict: true }` — Anthropic and OpenAI both support this. The schema is generated from the Codable types at build time (a tiny `swift-codable-to-jsonschema` helper script under `tools/insights-schema/` runs in a Swift Package executable). Schema versioned with `schemaVersion`.
- **Tier 2 (fallback)**: `response_format: { type: "json_object" }` + a system prompt with the schema. Used for Hermes/OpenRouter/Pi/Ollama. The renderer is forgiving (reuses `ChartSpecRenderer.decode(...)` resilience: strip fences, walk brace depth).
- **Tier 3 (free-form)**: very small local models — we fall back to a single `narrative` widget and skip the structured analysis with a clear inline notice.

Each tier reports its `confidence` to the UI (badge on the canvas: "Strict JSON · Claude Sonnet 4.6").

### 5.3 Tool-use plane

The LLM can call **bounded, side-effect-free** tools while investigating:

```
drilldown_search(query, filter)            → top-20 redacted conversation summaries
drilldown_session(sessionID)               → single session summary (title + key tools + cost)
agent_usage(agent, window)                 → per-agent rollup slice
model_usage(model, window)                 → per-model rollup slice
operating_actions(window)                  → daemon actions in window
quota_snapshot(provider)                   → last-known quota bucket
anomaly_detail(anomalyID)                  → precomputed anomaly with related sessions
list_focuses() / list_use_cases()          → taxonomy
```

Tools are implemented in `InsightToolBroker` (actor) that wraps `DataStore` (macOS) and Firestore/`DashboardStore` (mobile). They are **read-only** by construction; the actor enforces it. The MCP server's existing `tools/openburnbar-mcp/server.py` already implements the read-only pattern — we mirror that surface inside the app process for low latency, and optionally expose the same surface to the MCP server for external agents to use.

### 5.4 Streaming, thinking, and cancellation

- **Streaming**: events flow into a per-canvas `InsightInvestigation` actor. UI subscribes via `AsyncStream`.
- **Thinking tokens**: when the provider supports them (Claude extended thinking, GPT-5 reasoning), we surface them in a dedicated "Hermes Thinking" panel using the existing `MercuryThinkingIndicator` component. Reduce-motion: collapsed by default.
- **Partial canvas**: widgets become visible *as they're authored*. Each widget materializes with a tasteful entrance animation (`UnifiedDesignSystem.Animation.standard` with cascading delay).
- **Cancellation**: a single tap on the running pill aborts the stream; the partial canvas is preserved with a "Resume" affordance.
- **Cost accountancy**: every investigation is itself a token-usage event. We write it to `usage-events.jsonl` via the daemon's `BurnBarUsageEvent` (already supported). This means **the Insights tab measures its own cost**, beautifully.

### 5.5 Caching

Investigation requests are content-addressed on `(digest hash, prompt hash, model id)`. Cache key TTL = freshness window of the digest. A cache hit is shown as "Replayed · 14:32 · $0 saved". Stored in `Application Support/Insights/cache/`.

---

## 6. Local execution — `InsightExecutor`

Most widgets shouldn't need the LLM for *data*; only for *narrative*. `InsightExecutor` is a pure-Swift evaluator that turns an `InsightDataBinding` into concrete data:

```swift
public enum InsightDataBinding: Codable, Hashable, Sendable {
    case kpi(metric: KPIMetric, window: TimeWindow)
    case timeSeries(metric: TimeSeriesMetric, dimension: Dimension?, window: TimeWindow)
    case ranking(metric: RankingMetric, dimension: Dimension, limit: Int, window: TimeWindow)
    case distribution(metric: DistributionMetric, bins: Int, window: TimeWindow)
    case heatmap(window: TimeWindow)
    case sankey(source: Dimension, mid: Dimension, target: Dimension, window: TimeWindow)
    case cohort(window: TimeWindow)
    case quota(providerID: String?)
    case forecast(metric: TimeSeriesMetric, horizon: Int)
    case useCaseClusters
    case agentFocusMatrix
    case modelFocusMatrix
    case anomalyTable(window: TimeWindow)
    case drilldown(filter: InsightFilter, limit: Int)
    case narrative(modelTag: InsightModelTag, body: String, citations: [InsightCitation])
    case recommendation(...)
    case mermaid(source: String)
    case ascii(spec: AsciiSpec)
    case composed([InsightDataBinding])
    case raw(JSONValue)                 // escape hatch
}
```

The executor's job is to convert `binding → InsightWidgetData` (a value type with the concrete numbers/series/cells/etc.). Renderers read `InsightWidgetData`, never raw stores. This means:

- The LLM can author bindings (e.g. `.ranking(.cost, .model, 10, .last30d)`) without seeing the data.
- Widgets refresh deterministically when data changes — no LLM round-trip.
- The same widget renders identically on macOS, iPad, iPhone.

The executor is split into platform-specific data sources behind a `InsightDataSource` protocol:

- **macOS**: `LocalDataStoreInsightDataSource` (SQLite via `DataStore` + `UsageAggregator`).
- **iOS/iPad**: `FirestoreInsightDataSource` (via `DashboardStore` + `ActivityStore` + `QuotaStore`).
- **Daemon-only / test**: `InMemoryInsightDataSource` (for `OpenBurnBarDaemonTests` & `OpenBurnBarCoreTests`).

This is identical to how `TrendDataDigest` is built today — extended, not reinvented.

---

## 7. Canvas storage, sync, and templates

### 7.1 Storage

`InsightCanvasStore` (actor) persists canvases as a single JSON file `Application Support/Insights/canvases.json` (macOS + iOS use platform-correct support directory). Mirrors `ChartStudioStore` design: load-on-init, atomic write, soft cap of **200 canvases** with LRU eviction (Chart Studio's 20 is too few for a dashboard-class feature).

### 7.2 Sync (opt-in)

If the user is signed in **and** has cloud sync enabled, the canvas store mirrors to Firestore at `users/{uid}/insight_canvases/{id}` with `lastWriterWinsAt` semantics. We reuse the existing **`CloudSyncService`** pattern; the layout's `revision` counter is the conflict-resolution key. This is the same model as `smartDisplayOrder` sync, just at canvas granularity.

Firestore rules: owner-only read/write, no list across users. No PII (titles are user-authored, but no body text).

### 7.3 Templates

We ship **8 built-in templates** as Swift literals (registered in `InsightCanvasTemplate.builtIn`). Each is opinionated, beautiful, and immediately useful:

| Template | What's in it |
|---|---|
| **Today** | KPI tiles (cost, sessions, tokens, cache%) · today's heatmap strip · top-3 narrative · live quota gauges |
| **Cost Audit (7d)** | Cost trend · treemap (provider×model) · cost-per-Mtoken scatter · ranked overspenders · forecast next 7d · recommendation |
| **Agent Focus** | Per-agent radar fingerprint · agentFocusMatrix · useCaseCluster filtered per agent · drilldown of recent sessions |
| **Model Focus** | Per-model donut · modelFocusMatrix · model efficiency scatter · model-shift narrative |
| **Use-Case Library** | useCaseCluster (large) · agent×useCase matrix · top 5 example sessions per cluster |
| **Quota Health** | quotaPulse gauges for all providers · stream graph of headroom · narrative + recommendation |
| **Quarterly Review** | 90d cost trend · top 10 ranking · cohort retention · forecast · 5 LLM-written highlights |
| **Anomalies** | anomalyTable (90d) · annotated time series · drilldown · narrative per anomaly |

Templates are not "fixed" — they instantiate as fully editable canvases. New templates can be saved from any user canvas via "Save as template".

### 7.4 Export / import

- **Export**: Canvas → `.openburnbar-insights` JSON (versioned schema), `.png` (full-canvas screenshot via `ImageRenderer`), `.pdf` (multi-page via `PDFKit`), `.md` (one section per widget — narrative widgets render verbatim, charts render as a Markdown image + table).
- **Import**: drag-and-drop JSON onto the workspace or open via file picker on iOS.
- **Share sheet**: iOS/iPad presents native share sheet with all formats; macOS uses `NSSharingServicePicker`.

---

## 8. Platform shells

### 8.1 macOS — AgentLens

**Navigation:** extend `DashboardMainRoute` (`/AgentLens/Views/Dashboard/DashboardNavigationModel.swift`) with `.insights`. Add to sidebar order between `.overview` and `.database`. Sidebar icon: `sparkles.tv` (SF Symbol 5) tinted with `whimsyGradient`.

**Layout** (split into 3 panes; widths persisted in `AppearanceSettings`):

```
┌────────────┬──────────────────────────────────────┬──────────────┐
│  Canvas    │       Active Canvas (grid)           │  Inspector   │
│  Library   │                                      │              │
│            │  ┌─KPI─┐ ┌─KPI─┐ ┌─KPI─┐ ┌─KPI─┐    │  Widget      │
│  · Today   │  └─────┘ └─────┘ └─────┘ └─────┘    │  · Title     │
│  · Cost…   │  ┌──Trend──────────┐ ┌──Donut─┐     │  · Filter    │
│  · Models  │  └─────────────────┘ └────────┘     │  · Binding   │
│  · …       │  ┌──Narrative──────────────────┐    │  · Model     │
│            │  │ "Spend up 12% led by …"    │    │  · Cite      │
│  + New     │  └─────────────────────────────┘    │              │
│            │                                      │  Canvas      │
│  Templates │  Composer:  [Ask the model anything…│  · Time      │
│  …         │   ↳ Model: Claude Sonnet 4.6 ▾]    │  · Theme     │
└────────────┴──────────────────────────────────────┴──────────────┘
```

**Components (new files under `AgentLens/Views/Insights/`):**

```
InsightsWorkspaceView.swift          — three-pane host
InsightsCanvasLibraryView.swift      — left rail, drag-to-reorder canvases
InsightsCanvasView.swift             — main grid host
InsightsCanvasGrid.swift             — custom Layout protocol implementation
InsightsWidgetView.swift             — switch over WidgetKind → renderer
InsightsWidgetHeader.swift           — title bar + freshness pill + model chip + menu
InsightsInspectorView.swift          — right rail
InsightsComposerBar.swift            — prompt bar + model picker + chip rail
InsightsModelPicker.swift            — searchable model picker w/ cost-per-Mtoken badges
InsightsThinkingPanel.swift          — collapsible reasoning view (MercuryThinkingIndicator)
InsightsAddWidgetMenu.swift          — adds widgets manually by kind
InsightsTemplateGallery.swift        — first-run / empty-state gallery
Renderers/
  ├── KPITileRenderer.swift
  ├── TimeSeriesRenderer.swift
  ├── DonutRenderer.swift
  ├── HeatmapRenderer.swift
  ├── TreemapRenderer.swift          (custom, no SwiftCharts native treemap)
  ├── SankeyRenderer.swift           (custom)
  ├── RadarRenderer.swift            (custom)
  ├── ScatterRenderer.swift
  ├── CohortRenderer.swift
  ├── FunnelRenderer.swift
  ├── QuotaPulseRenderer.swift
  ├── ForecastRenderer.swift
  ├── AnomalyTableRenderer.swift
  ├── NarrativeRenderer.swift        — markdown via existing pretext views
  ├── RecommendationRenderer.swift
  ├── UseCaseClusterRenderer.swift
  ├── AgentFocusMatrixRenderer.swift
  ├── ModelFocusMatrixRenderer.swift
  ├── DrilldownListRenderer.swift
  ├── MermaidRenderer.swift          — reuse WKWebView shell
  ├── ASCIIRenderer.swift            — reuse iOS implementation port
  └── ComposedRenderer.swift         — recursive
```

**Drag/drop/resize:** Built on SwiftUI `Layout` protocol with a custom `InsightsGridLayout` that snaps widgets to a 12-column grid. Drag handles appear on hover (grab strip pattern from `SmartDisplayReorderable`); a thin "drop lane" highlights the target cell on drop. Resize via 4 corner handles when the widget is selected. While dragging, the widget renders at 0.85 opacity with a soft `cardHover` shadow.

**Liquid Glass (macOS 15+):** background uses `.ultraThinMaterial` with `whimsyGradient` sheen and a hairline border (`borderSubtle`), matching the existing `UnifiedGlassCard` treatment. Behind the grid: a subtle aurora-ribbon backdrop (port of `AuroraDesign.auroraRibbon`) so the canvas feels alive but never noisy.

**Toolbar:** time range picker · "Refresh all" button · "New canvas" menu (template gallery) · share/export · privacy-mode indicator.

**Keyboard:** ⌘N new canvas · ⌘⇧N from template · ⌘K command palette to add widget · arrow keys to navigate selection · ⌫ delete · ⌘D duplicate · space to "pop out" widget into a full-bleed modal (Mac analogue of iOS Chart Studio).

### 8.2 iPad — OpenBurnBarMobile

**Navigation:** extend `RootNavigationView.SidebarDestination` with `.insights` (between Streams and Hermes). Sidebar icon matches macOS.

**Layout:** Two-column NavigationSplitView:
- **Sidebar column**: canvas library (same as macOS left rail) + "New canvas" footer.
- **Detail column**: canvas grid + composer (composer pinned to bottom via `.safeAreaInset`).

**Inspector** is a `.sheet` on iPad (drag-to-dismiss), not a permanent rail, to keep the canvas dominant. Tapping a widget's "configure" icon shows the inspector.

**Layout reflow**: 12 → 6 columns via `InsightLayout.projected(toColumnCount: 6)`. Widgets that were `colSpan: 4` become `colSpan: 6` (full width); `colSpan: 6` becomes 6 (full); `colSpan: 3` becomes 3 (half). Vertical reordering preserved.

**Multitasking**: works in slide-over and split-view; the grid reflows further (4-column intent) when narrower than 700pt.

### 8.3 iPhone — OpenBurnBarMobile

**Navigation:** add `.insights` to `AuroraNavDestination` (between Burn and Streams: 5 → 6 tabs is acceptable; the existing `AuroraNavigationTray` already supports a flexible count).

**Layout** (2-column reflow):
- **Canvas list**: bottom-sheet driven (`.presentationDetents([.fraction(0.5), .large])`) — pull-up to see all canvases; tap to switch.
- **Canvas grid**: scrollable, single-column layout default with a "compact 2-col" toggle for landscape and large-screen iPhones. Widgets that were 12-col on macOS render full width.
- **Composer**: floating bar at the bottom with the same model picker. Reuses the existing `AuroraNavigationTray` aesthetic but in a richer state.
- **Inspector**: full-screen sheet.

**Drag/reorder on iPhone**: long-press → lift → drag, with `UIImpactFeedbackGenerator.medium` haptic on lift/drop. Resize is **disabled on iPhone**; resizing happens on macOS/iPad and projects down.

**Per-widget pop-out**: tap → full-screen presentation reusing the existing `ChartStudioPresenter` mechanism. This is the single best polish: a small KPI tile expands into a beautiful full-canvas detail view with the underlying drill-down list visible.

### 8.4 Mobile files

```
OpenBurnBarMobile/Views/Insights/
├── InsightsRootView.swift           — iPad split / iPhone tab host
├── InsightsCanvasListView.swift     — sidebar / bottom-sheet
├── InsightsCanvasDetailView.swift   — main grid
├── InsightsCanvasGrid.swift         — projected layout
├── InsightsWidgetCard.swift         — universal wrapper
├── InsightsComposerBar.swift
├── InsightsModelPicker.swift
├── InsightsInspectorSheet.swift
├── InsightsThinkingSheet.swift
├── InsightsTemplateGallery.swift
└── Renderers/   (mirrors macOS list; many renderers shared via OpenBurnBarCore.Views.Insights)

OpenBurnBarMobile/Models/
└── InsightsStore.swift              — observable wrapper around InsightCanvasStore

OpenBurnBarMobile/Services/Insights/
├── MobileInsightDataSource.swift    — FirestoreInsightDataSource binding
└── MobileInsightToolBroker.swift    — tool plane wiring
```

### 8.5 Shared renderers in core

The renderers for `kpiTile`, `timeSeriesLine`, `donut`, `heatmap`, `scatter`, `bar*`, `narrative`, `recommendation`, `mermaid`, `ascii`, `useCaseCluster`, `agentFocusMatrix`, `modelFocusMatrix`, `drilldownList`, `composed`, `error` live in `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Insights/` so both apps render identically. macOS/iOS-only chrome (drag handles, inspectors) stays in the shell layer.

Renderers that need platform-specific APIs (e.g. macOS-only Treemap layout details, hover affordances) declare platform-conditional code with `#if os(macOS)`.

---

## 9. Visual design

### 9.1 Card chrome

Every widget uses the same chrome:

```
┌────────────────────────────────────────────┐
│ ●●● TITLE                  freshness · ⋯ │   header: 28pt tall, system bold caption
│                                            │
│   [renderer content fills the body]       │   body: dynamic, padding 12pt
│                                            │
│ ▸ "Why" · Sonnet 4.6 · 0.6¢ · 4s ▾        │   footer (collapsed by default):
└────────────────────────────────────────────┘     short LLM rationale + cost + model + duration
```

- **Background**: `UnifiedGlassCard` (`.ultraThinMaterial`) with `glassEdgeGradient` border.
- **Tint**: provider-derived (e.g. a Claude-driven card has subtle ember rim; a GPT-driven card has whimsy rim). Computed via `DesignSystem.Colors.primary(for:)`.
- **Freshness pill**: `fresh` green dot · `stale` amber · `computing` shimmering · `error` red · `locked` lock glyph.
- **Drag handle**: grab strip top-left on macOS/iPad; long-press on iPhone.
- **Selected state**: 2pt accent border, `ember` glow at 30% opacity, slight scale `1.01`.
- **Entrance**: cascading fade + 8pt offset on first appearance, `UnifiedDesignSystem.Animation.standard`, 60ms stagger.
- **Hover (macOS)**: scale `1.005` and elevate shadow to `cardHover`.

### 9.2 Themes

`InsightTheme` lets the user pick the canvas palette without changing global app theme:

- **Aurora** (default): full warm/whimsy gradient mix.
- **Ember**: red/orange dominant — feels like a control room.
- **Mercury**: cool silver + Hermes shimmer — feels analytical.
- **Whimsy**: purple/violet — feels editorial.
- **Mono**: high-contrast B&W with a single accent — feels archival.
- **Print**: paper-tone, ideal for export to PDF.

All themes pull from existing `DesignSystem`/`UnifiedDesignSystem` tokens — we don't introduce new color primitives.

### 9.3 Motion

- Springs from `UnifiedDesignSystem.Animation` (`standard`, `gentle`, `snappy`, `hover`).
- `MercuryThinkingIndicator` for live model reasoning.
- `EmberSparkline` for KPI mini-trends.
- `RollingNumberText` for KPI big numbers.
- All motion respects `accessibilityReduceMotion`.

### 9.4 Empty / loading / error states

- **Empty** (no data yet): hero illustration + "Run a scan or connect a provider" CTA that deep-links into the provider wizard.
- **First-run** (data but no canvases): template gallery as primary content, not a modal — invites a choice.
- **Loading**: skeleton widgets (we already have `SkeletonView` and `EmberSkeleton`).
- **Error**: a renderer that explains what went wrong + a "Retry" button. Critical: never crash, never blank.
- **Privacy fence triggered**: the offending widget swaps to a "this widget would send data externally — adjust privacy mode or pick a local model" card.

---

## 10. Privacy, security, and trust

### 10.1 Egress tiers

Every model in the catalog declares its **egress tier**:

| Tier | Examples | Default UI label |
|---|---|---|
| `localOnly` | Pi, Ollama | "Stays on device" |
| `userKey` | Anthropic API w/ user's key, OpenAI, OpenRouter | "Your API key" |
| `userRelay` | Hermes relay with `userOwned` mode | "Your relay" |
| `hosted` | Hermes hosted (paid OpenBurnBar entitlement) | "OpenBurnBar hosted" |

The composer shows a small **data-egress preview** before send: "Sending **23 KB digest** to **Anthropic Claude Sonnet 4.6** · 1,200 input tokens · est. $0.004 · No source code, no secrets." User can expand to see the redacted digest fields.

A global **"Privacy mode"** toggle (in Settings → Insights) restricts the model picker to `localOnly` tier and grays out everything else, with one-tap re-enable.

### 10.2 What is never sent

Enforced in `InsightDigestBuilder` and unit-tested:

- No file contents, no code.
- No conversation full text (only `inferredTaskTitle` + counts).
- No API keys, no Keychain references, no provider credential labels (only redacted labels).
- No device names (replaced with stable hashed IDs).
- No project paths (replaced with stable `project_xxx` IDs and a user-visible mapping kept *locally*).
- No prompt content.

### 10.3 Audit trail

Every investigation is logged locally in `Application Support/Insights/audit.jsonl`:
`{ id, canvasID, prompt, modelID, egressTier, digestBytes, tokenUsage, cost, startedAt, completedAt, status }`. Settings → Insights → "Audit log" lists them with a "clear" action. This is critical for trust.

### 10.4 Threat model alignment

Reviewed against `docs/THREAT_MODEL.md` and `docs/PRIVACY.md`:

- Daemon: no change — the daemon already exposes the read-only quota/usage surface we need; we add **no** new daemon endpoints unless privacy-mode hosted features need them. Tool broker calls happen in-process for both apps.
- App: unsandboxed on macOS (status quo), App-store sandboxed on iOS — file storage uses `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask)` which works on both.
- Cloud: opt-in only, owner-scoped Firestore rules.

---

## 11. Performance and reliability

### 11.1 Hot paths

- **Digest build**: O(rows in window). Cached for 60s in memory; invalidated when `UsageAggregator` reports a refresh.
- **Local widget refresh**: pure functions over the digest + local executor; typically <5ms each. Refreshed lazily when widget enters view.
- **LLM investigation**: streamed; first widget visible <1s for fast models, <5s for slow ones.
- **Canvas open**: instant — last-known widget data deserialized from disk; freshness pills indicate stale state.

### 11.2 Memory

`InsightsCanvasView` uses `LazyVStack`/`LazyVGrid` for the canvas content. Heavy renderers (treemap, sankey) cache layout results keyed on `WidgetData.contentHash`.

### 11.3 Backgrounding

iOS: on background, paused streams persist; on foreground, prompt to resume. macOS: streams continue.

### 11.4 Migration safety

`InsightCanvas.schemaVersion = 1`. The decoder is strict-but-tolerant: unknown widget kinds decode to `.error` with a "needs newer app version" message, exactly like `SmartDisplayKind` does today (`normalize()` pattern). Unknown spec fields are dropped (additive evolution).

---

## 12. Testing strategy

Tests live in **active** suites (per `AGENTS.md`). No quarantined suites.

### 12.1 Unit tests (Core)

`OpenBurnBarCoreTests/Insights/`:

- `InsightDigestBuilderTests` — 24KB cap, privacy fields, taxonomy stability, redaction rules.
- `InsightLayoutTests` — projection 12→6→2, conflict-free reorder, span clamping.
- `InsightWidgetCodecTests` — round-trip for every widget kind; tolerant decode for unknown kinds.
- `InsightExecutorTests` — every binding kind against an `InMemoryInsightDataSource` golden fixture.
- `InsightPromptEngineTests` — JSON schema generated == golden; system prompt contains required sections.
- `InsightModelGatewayMockTests` — streaming events, partial canvas, cancellation, error tier-fallback.
- `InsightToolBrokerTests` — every tool returns redacted data; bounded result sizes; no PII leak.
- `InsightCanvasStoreTests` — load/save/atomic write/LRU eviction/sync revision.

### 12.2 Snapshot / pixel tests

`OpenBurnBarCoreTests/Insights/Renderers/`: a small `ViewInspector`-driven smoke that every renderer can render against a representative `InsightWidgetData` fixture without throwing. Acceptable bar for shared core; per-platform polish covered by app suites.

### 12.3 macOS app tests

`AgentLensTests/Active/Insights/`:

- `InsightsWorkspaceModelTests` — sidebar selection, route hand-off from `DashboardMainRoute`.
- `InsightsCanvasGridDragTests` — drag mechanics, drop targets, revision bumps.
- `InsightsInspectorBindingTests` — config edits persist.
- `InsightsModelPickerTests` — catalog ordering, capability badges, privacy-mode filter.

### 12.4 Mobile app tests

`OpenBurnBarMobileTests/Insights/`:

- `MobileInsightsStoreTests` — Firestore round-trip stub, canvas projection.
- `MobileInsightsLayoutTests` — 6-col and 2-col projection.
- `MobileInsightsModelPickerTests` — local-only mode gating.

### 12.5 Daemon tests

`OpenBurnBarDaemonTests/InsightToolBrokerHTTPTests` — if we expose tool broker via gateway for external MCP, confirm read-only contract.

### 12.6 Property tests

We add `swift-testing`-style property tests for: layout projection idempotency, schema decode tolerance, executor determinism.

### 12.7 Performance assertions

- `InsightDigestBuilder` builds under 50ms on a 10K-row corpus (XCTest measure).
- `InsightExecutor` for any single widget under 5ms on warm cache.

### 12.8 End-to-end

`AgentLensTests/Active/Insights/EndToEndTests`: with a recorded mock gateway (deterministic streamed events), simulate "user opens Today template, asks the model a question, drags a widget, edits filter, saves" — verify the resulting on-disk canvas matches a golden.

---

## 13. Documentation

Two doc files (per `AGENTS.md` doc convention; cross-linked from `README.md` and `CHANGELOG.md`):

1. **`docs/INSIGHTS.md`** — feature overview, widget catalog, model selection guide, privacy tiers, keyboard shortcuts, export formats, troubleshooting.
2. **`docs/INSIGHTS_ARCHITECTURE.md`** — schemas, gateway protocol, executor pipeline, JSON-Schema generation, sync semantics, extension recipe ("how to add a new widget kind in 5 steps").

`CHANGELOG.md`: a single entry under the next minor version: "Add Insights tab — AI-authored, modular analytics canvas across macOS, iPad, iPhone."

Update `docs/IOS_APP_ARCHITECTURE.md` and `docs/IPADOS_PORT_PLAN_2026.md` with a one-paragraph cross-link.

Update `CLAUDE.md` / `AGENTS.md`: no change (the completion bar is already in force).

---

## 14. Phased delivery — but one PR

Per Alberto's brief ("the answer is the finished product, not a plan to build it"), we ship the whole thing in one branch as a single coherent body of work. Internal phases for *self-management* during execution:

### Phase A — Core foundation
- `InsightCanvas`, `InsightWidget`, `InsightWidgetKind`, `InsightWidgetSpec`, `InsightLayout`, `InsightFilter`, `InsightCitation`, `InsightTheme`, `InsightModelTag`, `InsightTaxonomy`, `InsightDigest`, `InsightDataBinding`, `InsightWidgetData`, `InsightCanvasTemplate`, `InsightFreshness`.
- `InsightExecutor` + `InsightDataSource` + `InMemoryInsightDataSource`.
- `InsightDigestBuilder` (privacy-scrubbing, 24KB cap).
- `InsightCanvasStore` (file persistence).
- Core test suite green.

### Phase B — LLM plane
- `InsightModelGateway` protocol + `InsightModelCatalog`.
- Adapters: Anthropic, OpenAI, OpenRouter, Hermes (reuses bridge), Pi, Ollama, Codex (macOS), Claude Code (macOS).
- `InsightPromptEngine` + JSON Schema generator (`tools/insights-schema/Package.swift`).
- `InsightToolBroker` (read-only) + 8 tools.
- `InsightInvestigation` actor + streaming event stream.
- Cache layer.
- Audit log writer.
- Tests pass with a mocked gateway and a recorded fixture for each real adapter.

### Phase C — Shared renderers
- Renderers in `OpenBurnBarCore/Views/Insights/` for every widget kind.
- Smoke tests for each.

### Phase D — macOS shell
- `InsightsWorkspaceView` + three-pane layout.
- Drag/resize on custom `InsightsGridLayout`.
- Composer with model picker.
- Sidebar/library + template gallery.
- Inspector.
- Thinking panel.
- Toolbar + keyboard shortcuts.
- Hooked into `DashboardMainRoute.insights`.
- AgentLens test suite green.

### Phase E — iPad shell
- `InsightsRootView` (split).
- Sidebar entry.
- Sheet inspector.
- 6-col projection.
- Mobile test suite green.

### Phase F — iPhone shell
- Tab entry.
- Bottom-sheet canvas list.
- Compact composer.
- Long-press reorder + haptics.
- Per-widget pop-out.
- Polish.

### Phase G — Polish & ship
- Templates seeded.
- Export (JSON/PNG/PDF/MD) on macOS, share sheet on mobile.
- Empty/loading/error states.
- Audit log UI in Settings.
- Privacy-mode toggle UI.
- Docs: `INSIGHTS.md` + `INSIGHTS_ARCHITECTURE.md`.
- `CHANGELOG.md`.
- `docs/CHART_STUDIO.md` updated to cross-link Insights.
- Build clean on macOS + iOS + iPad; all test targets green; type-check + lint clean.

**Feature flag:** `BehaviorSettings.insightsEnabled` (defaults `true` on internal builds, default-on for users once the test suite is fully green; we leave the flag in for one release for rollback safety, then delete it — per the "no half-finished implementations" guidance, the flag *will* be removed).

---

## 15. Detailed file-level plan

**Total new files:** ~95. (~30 in `OpenBurnBarCore`, ~35 in `AgentLens`, ~20 in `OpenBurnBarMobile`, ~10 tests across all targets, 2 docs, 1 schema-gen tool.)

```
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/Insights/
  InsightCanvas.swift
  InsightWidget.swift
  InsightWidgetKind.swift
  InsightWidgetSpec.swift
  InsightWidgetData.swift
  InsightDataBinding.swift
  InsightLayout.swift
  InsightFilter.swift
  InsightTheme.swift
  InsightModelTag.swift
  InsightCitation.swift
  InsightTaxonomy.swift
  InsightFreshness.swift
  InsightDigest.swift
  InsightCanvasTemplate.swift
  InsightCanvasTemplates+BuiltIn.swift
  InsightTokenUsage.swift
  InsightInvestigateRequest.swift
  InsightInvestigateEvent.swift
  InsightGatewayError.swift

OpenBurnBarCore/Sources/OpenBurnBarCore/Services/Insights/
  InsightDigestBuilder.swift
  InsightExecutor.swift
  InsightDataSource.swift
  InMemoryInsightDataSource.swift
  InsightCanvasStore.swift
  InsightInvestigation.swift
  InsightToolBroker.swift
  InsightToolDefinitions.swift
  InsightPromptEngine.swift
  InsightJSONSchema.swift
  InsightModelCatalog.swift
  InsightModelGateway.swift
  Adapters/
    AnthropicInsightAdapter.swift
    OpenAIInsightAdapter.swift
    OpenRouterInsightAdapter.swift
    HermesInsightAdapter.swift
    PiInsightAdapter.swift
    OllamaInsightAdapter.swift
  InsightAuditLog.swift
  InsightCache.swift
  InsightCanvasSyncCoordinator.swift

OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Insights/
  InsightWidgetRenderer.swift
  KPITileView.swift
  TimeSeriesView.swift
  AreaSeriesView.swift
  StreamGraphView.swift
  BarRankingView.swift
  DonutView.swift
  TreemapView.swift
  HeatmapView.swift
  ScatterView.swift
  SankeyView.swift
  RadarView.swift
  CohortView.swift
  FunnelView.swift
  QuotaPulseView.swift
  ForecastView.swift
  AnomalyTableView.swift
  NarrativeWidgetView.swift
  RecommendationView.swift
  UseCaseClusterView.swift
  AgentFocusMatrixView.swift
  ModelFocusMatrixView.swift
  DrilldownListView.swift
  ComposedWidgetView.swift
  ErrorWidgetView.swift

AgentLens/Views/Insights/
  InsightsWorkspaceView.swift
  InsightsCanvasLibraryView.swift
  InsightsCanvasView.swift
  InsightsCanvasGrid.swift
  InsightsGridLayout.swift
  InsightsWidgetView.swift
  InsightsWidgetHeader.swift
  InsightsInspectorView.swift
  InsightsComposerBar.swift
  InsightsModelPicker.swift
  InsightsThinkingPanel.swift
  InsightsAddWidgetMenu.swift
  InsightsTemplateGallery.swift
  InsightsToolbar.swift
  InsightsKeyboardCommands.swift
  InsightsPopOutWindow.swift
  InsightsExportSheet.swift
  InsightsAuditLogView.swift            (in Settings tree but lives with feature)
  Adapters/
    CodexInsightAdapter.swift           (macOS-only via CLI bridge)
    ClaudeCodeInsightAdapter.swift      (macOS-only)
  InsightsRoutingExtensions.swift       (extends DashboardMainRoute)

OpenBurnBarMobile/Views/Insights/
  InsightsRootView.swift
  InsightsCanvasListView.swift
  InsightsCanvasDetailView.swift
  InsightsCanvasGridMobile.swift
  InsightsWidgetCard.swift
  InsightsComposerBarMobile.swift
  InsightsModelPickerMobile.swift
  InsightsInspectorSheet.swift
  InsightsThinkingSheet.swift
  InsightsTemplateGalleryMobile.swift
  InsightsPopOutSheet.swift
  InsightsExportShareSheet.swift

OpenBurnBarMobile/Models/
  InsightsStore.swift

OpenBurnBarMobile/Services/Insights/
  MobileInsightDataSource.swift
  MobileInsightToolBroker.swift

Tests
  OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Insights/...
  AgentLensTests/Active/Insights/...
  OpenBurnBarMobileTests/Insights/...
  OpenBurnBarDaemonTests/InsightToolBrokerHTTPTests.swift   (if exposed)

tools/insights-schema/
  Package.swift
  Sources/InsightsSchemaGen/main.swift   (Codable → JSON Schema at build time)
  Makefile target: `make insights-schema`

Docs
  docs/INSIGHTS.md
  docs/INSIGHTS_ARCHITECTURE.md

CHANGELOG.md                              (entry)
README.md                                 (cross-link)
docs/CHART_STUDIO.md                      (cross-link "see also: Insights")
```

**Existing files modified (surgical changes only):**

```
AgentLens/Views/Dashboard/DashboardNavigationModel.swift          (+1 enum case)
AgentLens/Views/Dashboard/DashboardSidebarView.swift              (+1 sidebar item)
AgentLens/Views/Dashboard/DashboardDetailView.swift               (+1 route case → InsightsWorkspaceView)
AgentLens/Services/SettingsManager.swift                          (+ insightsSettings store, audit log path)
AgentLens/Services/DataStore/DataStore.swift                      (+ thin pass-through for InsightDataSource)
OpenBurnBarMobile/Views/RootTabView.swift                         (+ AuroraNavDestination.insights)
OpenBurnBarMobile/Views/RootNavigationView.swift                  (+ SidebarDestination.insights)
OpenBurnBarMobile/App/OpenBurnBarMobileApp.swift                  (+ deep-link route burnbar://insights)
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudSyncModels.swift (+ InsightCanvas sync envelope)
OpenBurnBarMobile/Views/You/SettingsHubView.swift                 (+ Insights settings page route)
AgentLens/App/AgentLensApp.swift                                  (+ deep-link openburnbar://insights)
OpenBurnBar.xcodeproj/project.pbxproj                             (Xcode adds the new files)
project.yml                                                       (if XcodeGen-driven)
```

---

## 16. Why this is the state-of-the-art choice

| Decision | Alternative considered | Why we picked it |
|---|---|---|
| **JSON-Schema strict generation** | Free-form prose + parser | Eliminates a class of "model emitted English instead of JSON" failures. Native on Claude & GPT today. |
| **Local executor + LLM only for narrative/binding** | LLM computes all the numbers | Fast, free, deterministic, no token waste; LLM is great at *what to show*, not *math on rollups*. |
| **Codable-driven type system** | Dynamic JSON | Compile-time safety; new widgets = new enum case; renderers can't forget a kind. |
| **Custom SwiftUI `Layout` grid (12-col)** | `LazyVGrid` | Predictable drag/resize; exact placements survive cross-platform projection. |
| **Per-canvas model selection** | One global model | Different jobs want different brains; cost auditing wants reasoning, daily summary wants speed. |
| **Tool-use plane for drill-downs** | Stuff everything into the digest | Keeps digest small (privacy + cost); model can ask follow-ups. |
| **Egress tiers + audit log** | Trust dialog | Aligns with `docs/PRIVACY.md` posture; turns trust into a UI primitive. |
| **Cross-platform shared renderers in Core** | Re-implement per platform | One source of truth for the visual grammar; saves ~50% of code. |
| **Reuse Chart Studio spec grammar** | New parallel grammar | Renderers, sanitizers, and Hermes bridge work day one; new widget kinds extend, don't fork. |
| **Reuse `SmartDisplayReorderable` drag pattern** | New drag/drop | Battle-tested; users already know the affordance. |
| **Cache investigations content-addressed** | TTL only | "Replayed · $0 saved" is a delightful trust signal. |
| **iPhone 6th tab vs. nesting under "You"** | Hide on iPhone | This is a flagship feature; it deserves a tab. |
| **iPad split with sheet inspector vs. 3-pane** | 3 columns on iPad | Insights *want* horizontal canvas room; sheet inspector preserves it. |
| **Template gallery as first-run content** | Empty state | Templates are the right entry point; "create from scratch" is the secondary path. |

---

## 17. Acceptance checklist — the "holy shit, that's done" bar

Before declaring complete, all of the following must be true:

- [ ] A new user opens Insights and within 2 seconds sees a beautiful, non-empty canvas (template gallery on first run; last canvas on subsequent runs).
- [ ] Picking any reachable model (Claude/GPT/Hermes/Pi/Ollama) authors a fresh canvas from a free-form prompt within 5s for fast models.
- [ ] Streaming partial widgets land as they're authored, with smooth entrance animation.
- [ ] Every one of the 26 widget kinds renders correctly on macOS, iPad, and iPhone against representative data.
- [ ] Drag, drop, and resize behave correctly on macOS and iPad; long-press reorder works on iPhone with haptic feedback.
- [ ] Inspector edits to filter/dimension/model on a widget refresh the data within 1s on cached digest.
- [ ] All 8 built-in templates load, render, and refresh cleanly.
- [ ] Canvas export to JSON, PNG, PDF, MD works on macOS; share sheet works on iOS/iPad.
- [ ] Cloud sync (opt-in) round-trips canvases between two devices without conflict.
- [ ] Privacy mode hides non-local models and shows a clear explanation.
- [ ] Egress preview shows accurate byte count and redacted field list.
- [ ] Audit log captures every investigation; "clear" works.
- [ ] All existing tests pass; new tests cover the surface; no quarantined suites added.
- [ ] No lint warnings; `swift build` clean on Core, AgentLens, OpenBurnBarMobile, OpenBurnBarDaemon.
- [ ] Reduce-motion respects every animation.
- [ ] Dark mode + light mode look intentional, not "the other one".
- [ ] Accessibility: every widget has a useful `accessibilityLabel` and `accessibilityValue`; charts expose `accessibilityChartDescriptor` where possible.
- [ ] `docs/INSIGHTS.md` and `docs/INSIGHTS_ARCHITECTURE.md` reflect what's shipped.
- [ ] `CHANGELOG.md` updated.
- [ ] Feature flag deleted at the end of phase G (no leftover gating).

When the checklist is empty, Alberto opens the app and says "holy shit, that's done." That's the ship gate.

---

## 18. Open questions to confirm before kickoff

Two decisions need Alberto's explicit nod, because reversing them later costs real work:

1. **iPhone tab count → 6.** Today there are 5 (Pulse, Burn, Streams, Hermes, You). Insights becomes #6 between Burn and Streams. Alternative: replace one (e.g. merge Streams into Burn) to keep 5. **Default proposed:** add a 6th — `AuroraNavigationTray` already supports flex counts.
2. **Default model when the user has no provider configured.** Options: (a) gate the tab until a provider exists, (b) ship with a local Pi/Ollama hint and a "demo with a sample canvas" mode, (c) gate the LLM-authored widgets but show local-executor-only widgets immediately. **Default proposed:** (c) — Insights is useful from day one without any LLM, and the AI composer is the upgrade.

If both defaults are acceptable, no further input is needed.
