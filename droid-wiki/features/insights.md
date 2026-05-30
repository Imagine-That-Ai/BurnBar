# Insights

## Purpose

The Insights surface surfaces AI spend patterns, anomalies, and recommendations from recent usage data. It is rule-based: `WorkflowInsightRollupService` materialises a snapshot of `Insight` structs by running rules against the local data store, then caches the result until the data changes.

## InsightEngine

**`AgentLens/Services/InsightEngine.swift`** (~528 lines) defines the core types and service:

- `InsightType` — `costChange`, `newSessions`, `rankMovement`, `modelShift`, `cacheEfficiency`, `narrative`, `neutral`
- `Insight` — `id`, `type`, `icon`, `sentiment`, `headline`, `detail`, `metric`, `delta`
- `WorkflowInsightRollupService` — materialises and caches the rollup; returns a `WorkflowInsightRollupSnapshot` with `freshness: .fresh | .stale | .rebuilding | .unavailable`

The service only recomputes when the rollup is stale, no rebuild is in progress, and the data store has inputs.

## Finding types

| Type | Description |
|---|---|
| `costChange` | Spend up or down vs prior period |
| `cacheEfficiency` | Cache hit rate drop or improvement |
| `modelShift` | Active model changed (e.g. Sonnet → Haiku) |
| `rankMovement` | Provider rank changed |
| `narrative` | Free-text editorial summary |

## Generated views

`InsightWidgetRenderer` renders chart widgets embedded in the brief. Chart-bearing widget types: KPI, time-series, ranking, donut, treemap, heatmap, scatter, sankey, radar, cohort, funnel, quota-pulse, forecast, focus-matrix. The first chart widget is promoted into the hero section above the fold.

## Editorial Observatory UI

Both platforms use the same editorial layout pattern:

- **Eyebrow** — `INTELLIGENCE BRIEF` label + window subtitle (`Last 7 days`)
- **Hero** — 22pt rounded-semibold executive summary + mercury hairline with one-shot shimmer + first chart widget
- **Numbered findings** — mono ordinals `01` / `02` / `03`, 3pt severity-bar leading edge, confidence dots, footnote citation chips
- **Anomaly atlas** — horizontal scroll of anomaly cards with z-score numerals
- **Recommendations** — severity-aware action rows with impact arrow (↘ green for savings, ↗ ember for cost increase)
- **Follow-ups** — inline citation chips; tapping composes a deterministic follow-up prompt via `IntelligenceBriefCitationPrompt`
- **Audit footer** — mercury hairline + mono meta (model, run id)

## iOS implementation

**`AgentLens/Views/Intelligence/IntelligenceBriefView.swift`**

- Cascade-in animations at 0.04s stagger via `CascadeInModifier`; cancelled on `.onDisappear` via stored `Task`
- Dynamic Type clamped to `.xxLarge`
- `accessibilityReduceMotion` respected: skips cascade delays, paints synchronously
- Citation chips route through `IntelligenceBriefCitationPrompt` (9 wiring tests in `IntelligenceBriefWiringTests`)
- Snapshot tests: `IntelligenceBriefSnapshotTests` — drives `ImageRenderer` directly; outputs to `.appstore-screenshots/insights-editorial/ios/`
- Covers: light, dark, minimal, Dynamic Type `.xLarge`, reduce-motion, iPad regular

## Android implementation

**`android/app/src/main/java/.../IntelligenceBriefScreen.kt`**

- `AnimatedVisibility` + `slideInVertically(8.dp)` + `fadeIn` at 40ms stagger
- Font scale clamped to 1.15× upstream by `InsightsTheme`
- `Canvas`-drawn `ZScoreGauge` instrument scale (±2σ warning bands) in the anomaly atlas
- Reduce-motion via `LocalAuroraReduceMotion` (driven by `Settings.Global.animator_duration_scale == 0`) paints synchronously
- Impact arrow infers direction from sign: `−`/`-` → `↘` + success green, `+` → `↗` + ember warning
- Instrumented UI tests: `IntelligenceBriefScreenTest` (14 tests including TalkBack reading-order contract)
- Screenshots persist to `.appstore-screenshots/insights-editorial/android/`

## Benchmark-aware rules

The rule engine compares observed model spend and task mix against `modelBenchmarks` data (Artificial Analysis, Design Arena). It can flag model-fit mismatches, surface cheaper alternatives with similar benchmark scores, and add advisory guardrails. Benchmark citations appear as first-class footnote chips.

## Snapshot test fixtures

Fixtures use real-world spend scenarios (Sonnet 4.6 cost dominance + cache decay, MiniMax M2.7 weekend spike, Anthropic 5h quota pressure) so screenshots double as editorial demos. Three chart widgets are seeded: provider-mix time-series, top-models-by-cost ranking, spend-distribution donut.
