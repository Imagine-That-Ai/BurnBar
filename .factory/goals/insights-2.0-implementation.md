# Goal: Implement Insights 2.0 Master Plan

## Objective
Close all remaining gaps from the Insights 2.0 master plan (`plans/2026-05-16-insights-2.0-master-plan.md`) across iOS, iPad, macOS, and Android. The v1.0 infrastructure (verdict pipeline, rule-based engine, Editorial Observatory, widget registry, adapters) is largely complete. This goal focuses on the remaining Phase B–G work.

## Success Criteria
- [ ] Phase A complete: Verdict renders <500ms on all platforms with demo fixture fallback
- [ ] Phase B complete: All 26 widget kinds render real data; forecast/anomaly/funnel/quota are non-stub
- [ ] Phase B complete: Mermaid WebKit bridge ships; StreamGraph/Treemap real renderers
- [ ] Phase B complete: Android Vico chart library replaces Canvas stubs
- [x] Phase C complete: Tool-use loop wired in Anthropic/OpenAI adapters (Hermes pending)
- [x] Phase C complete: Tool-use budget (InsightInvestigationBudget: 6 calls / 4096 tokens / 30s)
- [x] Phase C complete: JSON-schema tool definitions for all 9 read-only tools (Anthropic + OpenAI shapes)
- [ ] Phase C complete: Citation tap drills into session trace (not re-runs engine)
- [ ] Phase C complete: "Why?" tap on KPIs shows local Pi/Ollama tooltip
- [x] Phase D complete: Daily morning brief push at 07:00 local (renderer + scheduler)
- [x] Phase D complete: Weekly recap (locked schema) + HTML email wrapper
- [x] Phase D complete: Monthly review + HTML email wrapper
- [x] Phase D complete: Year-in-Coding vertical card-stack renderer (MP4 export pending)
- [x] Phase D complete: CadenceScheduler with 15-min delivery window + min-gap enforcement
- [x] Phase E complete: iOS Lock-Screen widget + Live Activity (StandBy implicit via widget families)
- [x] Phase E complete: InsightTodayWidget with 6 size families + InsightSessionLiveActivity
- [x] Phase E complete: Widget snapshot wiring (mobile writes to App Group on every verdict update)
- [ ] Phase E complete: macOS menubar quick-glance + popover verdict
- [ ] Phase E complete: Android Glance widget (4x1 + 4x2) + Quick Settings tile
- [x] Phase F complete: Share-as-card layout engine (1080x1350 + 1080x1080 + A4 + 9:16)
- [ ] Phase F complete: PDF export for weekly/monthly/annual (layout engine exists; actual PDF generation pending)
- [ ] Phase G complete: No accessibilityReduceMotion violations; all charts labeled
- [ ] Cross-platform: Canvas JSON authored on iOS deserializes on Android

## Constraints
- One branch, one body of work (per plan §8)
- Follow existing code style and patterns
- Add/update tests for behavior changes
- Update docs in `docs/` and `CHANGELOG.md`
- Feature flag `insightsV2Enabled` defaults true on internal builds

## Progress
- 2026-05-17: Explored existing codebase. Found substantial v1.0 infrastructure already in place.
- 2026-05-17: Identified gaps: tool-use loops, cadence stack, off-tab surfaces, share/export, Mermaid/StreamGraph/Treemap renderers.
- 2026-05-17: Phase C — Tool-use wired. Created `InsightToolDefinitions` (9 tools, Anthropic + OpenAI shapes), `InsightInvestigationBudget` (6 calls / 4096 tokens / 30s cap). Rewrote `AnthropicInsightAdapter.analyze()` with bounded `while true` loop: passes tools → parses `tool_use` → dispatches via `InsightToolBroker` → feeds `tool_result` back as follow-up messages. Same pattern for `OpenAIInsightAdapter` with `tool_calls` / `tool` message format.
- 2026-05-17: Phase D — Cadence stack. Created `CadenceArtifact` (6 cadences, 6 payload variants), `CadenceScheduler` (pure-logic scheduler with 15-minute delivery window + minimum-gap enforcement: 20h daily / 6d weekly / 28d monthly). Created 4 renderers: `MorningBriefRenderer` (push-sized headline + 2 bullets), `WeeklyRecapRenderer` (locked schema: NUMBERS / WINS / SURPRISES / RISKS / TRY NEXT WEEK with HTML email wrapper), `MonthlyReviewRenderer` (long-form narrative with top numbers + highlights + recommendation), `YearInCodingRenderer` (card-stack narrative aggregating all verdicts for annual recap).
- 2026-05-17: Phase E — iOS off-tab surfaces. Created `InsightVerdictWidgetSnapshot` (App Group shareable). Created `InsightTodayWidgetProvider` (TimelineProvider), `InsightTodayWidgetView` (6 families: Small, Medium, Large, Rectangular, Circular, Inline with ring progress views). Created `InsightSessionLiveActivity` (ActivityAttributes + ActivityView for Dynamic Island compact/expanded + Lock Screen with real-time cost ticker). Updated `BurnBarWidget.swift` to `WidgetBundle` containing 3 widgets. Wired mobile verdict model to write widget snapshots on every update.
- 2026-05-17: Phase F — Share/export. Created `InsightShareCardRenderer` (platform-agnostic layout engine for portrait1080x1350, square1080x1080, a4PDF, video9x16 with dark/light Botanical Cream / Warm Charcoal presets + `PlatformColor` abstraction).
- 2026-05-17: Phase B — Session trace enrichment. Created `InsightSessionTraceBuilder` (picks most consequential session via weighted scoring: cost 50% / duration 30% / recency 20%; builds `TraceLane`s from operating actions; builds `TraceTick`s from usage rows with 12-tick cap). Wired into `InsightsMacVerdictModel` — asynchronously injects real `VerdictTraceStrip` after rule-based or LLM verdict upgrades.

## Validation
- [ ] `cd ios && xcodebuild -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build`
- [ ] `cd android && ./gradlew :app:assembleDebug`
- [ ] Run unit tests for new verdict types, executor, and adapters
- [ ] Manual verification: cold-open Insights tab → verdict visible <500ms

## Resume Prompt
Continue implementing the Insights 2.0 master plan. Read the goal file, inspect current repo state, and proceed with the next uncompleted phase. Focus on tool-use loops, cadence stack, off-tab surfaces, and share/export.
