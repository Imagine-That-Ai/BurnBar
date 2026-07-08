# P05 — Insights / editorial observatory

**Wave 1 · Route: `insights`.**

## Mission

Editorial-styled analytics: weekly token/cost trends, provider mix, model mix, cache-hit rate — rendered as a composed "observatory" page with dependency-free SVG charts. This surface carries the Editorial skin's voice: generous type, restrained color, data as typography.

## Read first

- README §1–§2; `src/components/Sparkline.tsx` (extend this idiom, don't import a chart library).
- macOS oracle: insights/observatory views under `AgentLens/Views/Dashboard/Components/` (`CacheHitRateView.swift`, `MiniSparkline.swift`), `InsightBriefCard.swift`.
- Data: same usage RPC family as P01 (`+RPCUsage.swift`); coordinate shapes with P01 in PR bodies (do not share a store — copy the shape, keep lanes decoupled).

## Data contract

Bridge: `usage_insights` → `{ weekly: {label, tokens, costUsd}[], providerMix: {id,label,pct}[], modelMix: {label,pct}[], cacheHitRatePct }`. Fixture with 8 weeks and ≥4 providers.

## Files

Create `src/state/insightsStore.ts`; `src/surfaces/insights/` (`InsightsSurface.tsx`, `TrendChart.tsx`, `MixBar.tsx`, `StatCallout.tsx`) + tests. One-line `SurfaceRouter` edit. `app.css` `/* ---- P05 insights ---- */`.

## Build steps

1. `TrendChart`: SVG area/line chart built like `Sparkline` (normalize → polyline + gradient fill), fixed viewBox, axis labels as plain text under the chart; `role="img"` with a sentence-long `aria-label` summarizing the trend.
2. `MixBar`: single horizontal stacked bar; segments use provider accents from `providerGlyphs.ts`; legend below with percentage text (never color-only).
3. `StatCallout`: display-font number + caption (cache-hit rate, week-over-week delta with explicit "+/−" text).
4. Layout: 12-col-feel grid via `repeat(auto-fit, minmax(280px,1fr))`; charts never reflow on data refresh (fixed heights).

## Required states

Populated / Loading skeleton (fixed chart-height placeholders) / Empty ("Not enough usage yet — insights appear after your first sessions") / Error banner + retry / Offline.

## A11y / Perf / Tests

- Every chart has a text equivalent (summary sentence + data available in a visually-hidden table).
- Static SVG only; zero animation loops; no chart library dependencies.
- Tests: normalization math (min/max/degenerate single-point series), mix percentages sum handling, aria-labels present, five states.

## Done / Forbidden

README §4. Forbidden: chart libraries (d3, recharts, …); canvas; animated charts; color-only encodings.
