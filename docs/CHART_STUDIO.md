# Chart Studio (iOS)

> Tap **Trend Atlas** on Pulse → Chart Studio opens. The screen leads with **3 quick-fact tiles + 6 evocative auto-charts** built locally from your data. The chat composer at the bottom is for "ask anything else."

## What is it

**Chart Studio** is the iOS insights canvas. The default state is a curated, locally-rendered gallery so the user gets value the second the screen opens. Hermes is invited in only when the user types — and answers stream into a dedicated "HERMES ANSWER" slot above the gallery, never replacing it.

### Gallery (always-on, zero round-trip)

| Slot | Card | Source |
|------|------|--------|
| Quick Facts strip (top) | `TODAY` · `TOP PROVIDER` · `CACHE HITS` (or `TOP MODEL`) | `StandardGallery.quickFacts(from:)` |
| 1. Spend | **Burn trajectory** — area chart with 7-day rolling baseline | `StandardGallery.items(...)[0]` |
| 2. Mix   | **Daily mix** — stacked area by top-4 providers | …`[1]` |
| 3. Mix   | **Token share donut** | …`[2]` |
| 4. Models | **Model performance** — cost-per-million × volume scatter | …`[3]` |
| 5. Time  | **Hour-of-day heat strip** — ASCII heatmap with peak hour | …`[4]` |
| 6. Cache | **Cache health insight** — narrative + sparkline of last 20 sessions | …`[5]` |

Each gallery card has an "Open" button that pops the rendering into the AI canvas slot for full-bleed study (no Hermes call).

### Hermes-driven canvas (on demand)

When the user types something, Hermes streams back a typed JSON envelope that decodes to one of:

| Kind | Renderer | When Hermes uses it |
|------|----------|---------------------|
| `swift_chart` | Swift Charts (`NativeChartView`) | Time series, bars, scatter, donuts, heatmaps, streams |
| `mermaid`     | `WKWebView` + bundled `mermaid.min.js` | Flowcharts, sequence diagrams, state diagrams, ER diagrams |
| `ascii`       | `AsciiCanvasView` (terminal-frame card) | Quick-glance bars/sparklines/heatmaps; "TUI" / "terminal" prompts |
| `insight`     | `InsightCardView` (glass card) | Narrative answers, "why" / "what changed" prose |
| `composed`    | Vertical stack of any of the above | "Insight + the chart that proves it" |

Chart Studio replaces the old single-purpose `TrendSparkCard`. The Pulse home now shows **Trend Atlas** — three rotating intricate scenes (Spend stream graph, Models lane racer, Cache constellation) that all open Studio on tap.

## Architecture

```
TrendAtlasCard ─────────► tap ─────────► ChartStudioView
       │                                       │
       │                                       ▼
       │                              ChartStudioPromptEngine
       │                                       │  (system prompt + digest)
       │                                       ▼
       │                              ChartStudioHermesBridge
       │                                       │  (SSE stream)
       │                                       ▼
       └──► TrendDataDigest ─────────► Hermes (LAN or Remote Relay)
                                                │
                                                ▼
                                       ChartSpecRenderer.decode(...)
                                                │
                       ┌────────────────────────┼─────────────────────┐
                       ▼                        ▼                     ▼
                 NativeChartView          MermaidWebView         InsightCardView
```

### Data flow

1. **`TrendAtlasCard`** builds a `TrendDataDigest` from `DashboardStore` + `ActivityStore` data.
2. The user taps the card → `ChartStudioView` is presented as a `.fullScreenCover`.
3. The user types a prompt (or taps a chip from `ChartStudioPromptCarousel`).
4. `ChartStudioPromptEngine` produces a strict system prompt that:
   - documents the JSON schema for the response,
   - lists the legal `kind` values,
   - injects the digest as a read-only data block,
   - includes 3 worked examples (line, mermaid, insight).
5. `ChartStudioHermesBridge` posts to `POST /v1/chat/completions` (LAN or Relay) with `stream: true` and `response_format: { "type": "json_object" }`.
6. SSE chunks accumulate in `ChartStudioView.streamingText` (shown in a side panel).
7. On `[DONE]`, `ChartSpecRenderer.decode(...)` parses the final string into `ChartStudioRendering`.
8. The matching renderer is mounted on the canvas.
9. The result is persisted to `ChartStudioStore` (a JSON file in `Application Support`) for replay in the recent canvases strip.

### Wire format

The model **must** respond with a single JSON object:

```json
{
  "kind": "swift_chart" | "mermaid" | "insight" | "composed",
  "title": "Short title shown above the canvas",
  "swift_chart": { ... },
  "mermaid":     { "title": "…", "source": "…" },
  "insight":     { "title": "…", "body": "…", "sparkline": [n], "tone": "positive|neutral|warning" },
  "components":  [ Envelope, … ]
}
```

`swift_chart` schema:

```json
{
  "kind": "line | bar | stacked_bar | area | stacked_area | stream | scatter | heatmap | donut | rule",
  "title": "...",
  "subtitle": "...",
  "xAxis": { "title": "Date", "kind": "time | linear | category" },
  "yAxis": { "title": "Cost (USD)", "kind": "linear" },
  "series": [
    {
      "name": "Claude Code",
      "color": "#E07868",
      "points": [
        { "x": "2026-04-30", "y": 18.42, "group": "Claude Code", "label": "Today" }
      ]
    }
  ],
  "annotations": [
    { "kind": "ruleX | ruleY | text", "x": "2026-04-30", "y": 0, "label": "Today" }
  ],
  "valueFormat": "currency | tokens | percent | raw"
}
```

`ChartSpecRenderer` is forgiving:
- Strips Markdown code fences and prose around the JSON.
- Walks brace depth to extract the first valid `{...}` block.
- Falls back to a "couldn't parse" `error` rendering rather than crashing.

### Trend Data Digest

Pure value type built from `DashboardStore` + `ActivityStore` snapshots. Capped sizes:

| Field | Cap |
|------|-----|
| `totals` | 3 (today / 7d / 30d) |
| `providers` | 6 |
| `models` | 8 |
| `projects` | 6 |
| `devices` | 4 |
| `daily` | 21 days |
| `daily.perProvider` | top 4 per day |
| `hourly` | 24 buckets |
| `recentSessions` | 15 |

Realistic payload size: **3–10 KB**. The unit test enforces a 12 KB ceiling.

### Mermaid sandbox

The Mermaid renderer is a `WKWebView` loading a bundled HTML shell at `OpenBurnBarMobile/Resources/Mermaid/index.html`. The shell:
- imports the bundled `mermaid.min.js` (Mermaid 11.4.1, MIT, ~2.5 MB),
- themes nodes with the Aurora palette (light/dark adaptive via `prefers-color-scheme`),
- exposes `window.renderMermaid(source)` and `window.webkit.messageHandlers.mermaidStatus` so Swift can drive it,
- blocks navigation (no anchor activation),
- is sandboxed: `allowsLinkPreview = false`, `allowsBackForwardNavigationGestures = false`.

`ChartSpecRenderer.sanitizeMermaid(...)` strips `<script>`, `<iframe>`, `javascript:` pseudo-protocols, `data:` URIs, and inline `on*=` event handlers before injection.

### Persistence

`ChartStudioStore` keeps the most recent 20 canvases in `Application Support/chart-studio-canvases.json`. Each canvas stores prompt + title + summary + raw rendering JSON. Replays are pure local — no Hermes round-trip on tap.

## Trend Atlas Insights

`TrendInsightEngine` is a pure function over `TrendDataDigest`. Rules ranked by `priority`:

| Rule | Priority | Tone |
|------|---------:|------|
| `cacheLow` (cache hit < 15%) | 90 | warning |
| `providerDominance` (≥80% share) | 95 / 80 | warning / neutral |
| `cacheHigh` (cache hit ≥ 50%) | 85 | positive |
| `reasoningSpike` (≥40% reasoning) | 75 | warning |
| `modelChampion` | 70 | positive |
| `costPerOutputToken` (top model 2× pricier) | 65 | warning |
| `peakHour` | 60 | neutral |
| `weekendBurn` / `weekendCool` | 55 / 50 | neutral / positive |
| `writingSpeed` | 45 | positive |
| `fallback.empty` | 0 | neutral |

The `InsightAutoRotator` shows the top-priority insight first and rotates every 6 s with a cross-fade. Reduce-motion mode disables rotation and shows the first insight statically.

## Future work

The current digest uses **output token velocity** as a "writing speed" proxy because we don't yet ingest git diff stats. Adding `linesAdded` / `linesDeleted` is tracked separately:

1. Add `RunDiffStats { added: Int, removed: Int, files: Int }` to `TokenUsage`.
2. Hook `git diff --shortstat` into `OpenBurnBarDaemon`'s session-finalize step.
3. Backfill from `~/.claude/projects` and `~/.codex/sessions` where possible.
4. Surface a 4th Atlas scene: "Code" — lines added/deleted by model.

## Files

- `OpenBurnBarMobile/Views/Pulse/TrendAtlasCard.swift`
- `OpenBurnBarMobile/Views/Pulse/Atlas/StreamGraphScene.swift`
- `OpenBurnBarMobile/Views/Pulse/Atlas/ModelLaneScene.swift`
- `OpenBurnBarMobile/Views/Pulse/Atlas/CacheConstellationScene.swift`
- `OpenBurnBarMobile/Views/Pulse/Atlas/HourOfDayHeatStrip.swift`
- `OpenBurnBarMobile/Views/Pulse/Atlas/InsightAutoRotator.swift`
- `OpenBurnBarMobile/Views/ChartStudio/ChartStudioView.swift`
- `OpenBurnBarMobile/Views/ChartStudio/NativeChartView.swift`
- `OpenBurnBarMobile/Views/ChartStudio/MermaidWebView.swift`
- `OpenBurnBarMobile/Views/ChartStudio/InsightCardView.swift`
- `OpenBurnBarMobile/Views/ChartStudio/ChartStudioPromptCarousel.swift`
- `OpenBurnBarMobile/Models/ChartStudioStore.swift`
- `OpenBurnBarMobile/Services/ChartStudio/TrendDataDigest.swift`
- `OpenBurnBarMobile/Services/ChartStudio/TrendInsightEngine.swift`
- `OpenBurnBarMobile/Services/ChartStudio/ChartStudioPromptEngine.swift`
- `OpenBurnBarMobile/Services/ChartStudio/ChartSpecRenderer.swift`
- `OpenBurnBarMobile/Services/ChartStudio/ChartStudioHermesBridge.swift`
- `OpenBurnBarMobile/Resources/Mermaid/index.html`
- `OpenBurnBarMobile/Resources/Mermaid/mermaid.min.js`
- `OpenBurnBarMobileTests/TrendDataDigestTests.swift`
- `OpenBurnBarMobileTests/TrendInsightEngineTests.swift`
- `OpenBurnBarMobileTests/ChartSpecRendererTests.swift`
- `OpenBurnBarMobileTests/ChartStudioPromptEngineTests.swift`
