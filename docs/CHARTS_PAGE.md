# Charts Page (macOS)

The full-page analytics gallery opened by clicking the burn-rate chart in the
dashboard command deck (route: `DashboardMainRoute.charts`). A curated,
re-arrangeable set of liquid-glass chart cards drawn from the real
`token_usage` data, plus an opt-in AI insight strip driven by the user's
already-connected LLM backends.

## Architecture

```
deck chart tap ──▶ navigate(.charts) ──▶ ChartsPageView
                                            │
                    ┌───────────────────────┤
                    ▼                       ▼
            ChartsDataService        ChartInsightEngine (opt-in)
                    │                       │
      dataStore.usages(in:) capture   Hermes gateway → Claude → Codex
                    │                 (aggregate numbers only)
        ChartsSnapshot.build (off-main, pure)
                    │
                    ▼
     ChartsReorderableGrid ──▶ ChartCardView ──▶ ChartKit renderers
```

| Layer | Files |
|---|---|
| Registry & layout model | `AgentLens/Models/Charts/ChartKind.swift` |
| Pure math | `AgentLens/Models/Charts/ChartBucketing.swift` |
| Prepared data | `AgentLens/Services/Charts/ChartsSnapshot.swift` |
| Service | `AgentLens/Services/Charts/ChartsDataService.swift` |
| AI insights | `AgentLens/Services/Charts/ChartInsightEngine.swift` |
| Page & cards | `AgentLens/Views/Charts/*.swift` |
| Renderers | `AgentLens/Views/Charts/ChartKit/*.swift` |
| Tests | `AgentLensTests/Active/Chart*Tests.swift` |

Performance discipline: same as `DashboardLiveCostCurve` — static Shape/Path
drawing, no timers, no Canvas, snapshot-driven invalidation only (the store's
`usagesVersion` Int, never the `[TokenUsage]` array).

## Chart catalog (v1)

Visible by default: `burnOverTime`, `providerMix`, `modelMix`, `cacheROI`,
`reasoningShare`, `hourOfDayHeatmap`, `weekOverWeekDelta`,
`costPerSessionDistribution`, `sessionOutliers`, `projectFocus`,
`burnForecast`, `provenanceQuality`.

Registered but hidden (surfaced via Edit menu or AI suggestions):
`modelConcentration`, `remoteVsLocal`.

Fixed-window charts: `weekOverWeekDelta` (trailing 7 vs prior 7 days) and
`burnForecast` (trailing 14 days observed, projected to calendar month end)
ignore the selected TimeRange by design.

## Layout persistence

`ChartsPageLayout` — an ordered `[ChartCardConfig {kind, isVisible, span}]` —
is stored as JSON under UserDefaults key `chartsPageLayout.v1`. Decoding is
forward-compatible: unknown kinds are dropped, missing kinds are appended with
defaults, duplicates deduplicate. Reorder = drag any card onto another (native
`draggable`/`dropDestination`); hide/resize via the card context menu; the
header's slider menu restores hidden charts or resets the layout.

## AI insights

Toggle: `chartsPage.llmInsightsEnabled` (`@AppStorage`, off by default).

When on, `ChartInsightEngine` sends **aggregate numbers only** (totals,
shares, ≤31-point daily series — no session ids, project names, prompts, or
device identifiers; enforced by `ChartInsightEngineParsingTests`) to the first
ready backend in local-first order: Hermes gateway → Claude → Codex → any
other enabled backend. The response must be a JSON object:

```json
{
  "insights": [
    {"id": "…", "severity": "info|win|warning", "title": "≤60", "body": "≤240",
     "metricRefs": ["<ChartKind rawValue>"]}
  ],
  "suggestedCharts": [{"kind": "<ChartKind rawValue>", "reason": "≤120"}]
}
```

Parsing strips fences/prose, retries once with a "JSON only" reminder, and
drops unknown kinds. Results cache per `(usagesVersion, timeRange)` with a
15-minute re-ask floor; a 90-second hard timeout bounds wedged CLIs. The strip
footnote always states where the summary went ("Processed locally via Hermes"
vs "Sent to <backend>").

## Adding a chart kind

1. Add the case to `ChartKind` with title/microcopy/symbol/span/visibility.
2. Prepare its data in `ChartsSnapshot.build` (pure — add a test).
3. Add renderer + headline arms to `ChartCardView` (`content`, `headline`,
   `isKindEmpty`).
4. Old persisted layouts pick the new kind up automatically (appended with
   defaults on decode).
