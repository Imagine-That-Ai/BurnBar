# Design System — OpenBurnBar

## Product Context
- **What this is:** A native macOS menu bar app that tracks token usage and cost across AI coding agents (Claude Code, Factory Droid, Codex, Kimi, MiniMax, etc.)
- **Who it's for:** Developers running multiple AI agents in parallel who want real-time visibility into spend without checking billing dashboards
- **Space/industry:** Developer tools / AI infrastructure observability
- **Project type:** macOS menu bar app + popover dashboard + settings window + Hermes agent interface

---

## Aesthetic Direction
- **Direction:** Industrial/Utilitarian with personality — function-first, data-dense, but with a distinct visual identity through brand accent colors
- **Decoration level:** Intentional — subtle card surfaces and gradients serve data hierarchy, not decoration for its own sake
- **Mood:** "A terminal that knows what it's doing." Precise, fast, opinionated. Not sterile — the accent palette (coral, purple, teal) adds warmth and identity without becoming playful.

---

## Color System

### Philosophy
Colors are **adaptive** — they flip between dark and warm-neutral light based on macOS system appearance. The brand accent colors shift slightly between modes to maintain contrast and saturation.

The dark palette is the primary experience (most developers run dark mode). The light palette is a warm neutral — cream-toned, not clinical white — so the app feels premium in both modes.

### Dark Mode (primary) — Warm Charcoal

Not GitHub dark. Near-black with a brown undertone, off-white text, earthy borders. Cohesive with botanical cream light mode.

| Token | Value | Role |
|-------|-------|------|
| `background` | `#0E0D0B` | Warm near-black |
| `surface` | `#171510` | Dark warm charcoal |
| `surfaceElevated` | `#201E18` | Elevated warm surface |
| `border` | `#302C22` | Earthy dark border |
| `borderSubtle` | `#1E1C16` | Subtle warm separator |
| `textPrimary` | `#F0EBE2` | Warm off-white — not clinical pure white |
| `textSecondary` | `#9A9088` | Warm gray |
| `textMuted` | `#7A7268` | Warm muted |
| `success` | `#38D898` | Vivid green |
| `warning` | `#F0C040` | Rich amber |
| `error` | `#F06070` | Rich red |

### Light Mode — Botanical Cream

Inspired by herbarium paper and botanical illustration: cream with a clear green undertone, sage borders, forest-ink text. Reads premium and distinct — not generic Mac beige.

| Token | Value | Role |
|-------|-------|------|
| `background` | `#EDF0E5` | Herbarium paper — cream with green cast |
| `surface` | `#F4F6EE` | Lighter botanical paper |
| `surfaceElevated` | `#FAFAF5` | Near-white with green tint |
| `border` | `#C5CEB6` | Pressed sage |
| `borderSubtle` | `#D8E2CA` | Light sage separator |
| `textPrimary` | `#1C2014` | Botanical ink — near-black with green cast |
| `textSecondary` | `#4A5442` | Aged ink |
| `textMuted` | `#7A8572` | Faded sage text |
| `success` | `#3A7835` | Forest green |
| `warning` | `#A87018` | Amber |
| `error` | `#BF3030` | Deep red |

### Brand Accents

Accents shift between modes — botanical light uses earthier, nature-grounded variants:

| Color | Dark | Light | Usage |
|-------|------|-------|-------|
| Coral | `#E87060` | `#C8604E` | Claude Code, gradients |
| Purple | `#9080D8` | `#6868B8` | Factory Droid, charts |
| Teal | `#2CCAC0` | `#1A9A8C` | Kimi, cache hits |
| Gold | `#E0A030` | `#A47A1E` | MiniMax, warnings |

### Hermes Mercury (chat identity)

Hermes has two color identities: **provider purple** (`#A855F7`/`#C084FC`) for tracking and charts, and **warm mercury** for the chat interface. The mercury axis is a metallic neutral — silver that catches firelight — sitting between the warm accents (ember/amber/blaze) and the cool contrast (whimsy).

| Token | Dark | Light | Usage |
|-------|------|-------|-------|
| `hermesMercury` | `#C8BFB5` | `#AEA69C` | Warm silver — response bubble strokes, status text, thinking state |
| `hermesAureate` | `#A2ACBA` | `#3F4651` | Dark platinum — Hermes badges, links, send button accent (replaced former gold for a colder, more premium gunmetal pairing with mercury) |

**Mercury gradient:**
```swift
static let mercuryGradient = LinearGradient(
    colors: [hermesMercury, hermesAureate],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)
```

**Mercury shimmer:** A slow sweeping highlight animation over gradient borders and surfaces. Implemented as a secondary overlay layer with an animated background-position offset, cycling every 3 seconds with `easeInOut` timing. The highlight band is a narrow translucent white stripe (~15% center opacity, 25% at peak) that traverses the gradient surface.

```swift
// Shimmer phase: TimelineView(.periodic(from: .now, by: 1/30)) driving a 0→1 phase
// Applied as an overlay mask on mercury gradient borders
```

**Chat bubble strokes:**
- User bubbles: `whimsy` stroke (unchanged)
- OpenBurnBar assistant bubbles (Local Index mode): `ember` stroke (unchanged)
- Hermes assistant bubbles: `mercuryGradient` stroke with shimmer
- Hermes tool cards: `mercuryGradient` stroke, grouped by capability

---

## Typography

All type uses **SF Pro Rounded** (`Font.system(..., design: .rounded)`) — the macOS system font with rounded variant. This ships with macOS and requires no loading. The rounded design adds warmth and friendliness without sacrificing legibility.

| Token | Size | Weight | Usage |
|-------|------|--------|-------|
| `displayLarge` | 36pt | Bold | N/A (reserved for hero moments) |
| `display` | 28pt | Bold | Large cost totals |
| `title` | 20pt | Semibold | Modal headers |
| `headline` | 16pt | Semibold | Card titles, provider names |
| `body` | 14pt | Regular | Toggle labels, row text |
| `caption` | 12pt | Medium | Section headers, subtitles |
| `tiny` | 11pt | Medium | Timestamps, annotations only |
| `mono` / `monoSmall` / `monoTiny` | 14/12/11pt | Medium | Token counts, cost values, paths |

**Section header rule:** Always use `caption` (12pt) + `semibold` + `textSecondary` color. Never use `tiny` + `textMuted` for section headers — contrast fails at that combination.

---

## Spacing

Base unit: **4px**. All spacing is multiples of 4.

| Token | Value | Usage |
|-------|-------|-------|
| `xxs` | 2px | Icon-to-text nudges |
| `xs` | 4px | Tight internal gaps |
| `sm` | 8px | Component internal padding |
| `md` | 12px | Between related elements |
| `lg` | 16px | Card padding, section gaps |
| `xl` | 24px | Between sections |
| `xxl` | 32px | Between major blocks |
| `xxxl` | 48px | Top-level layout gaps |

---

## Layout

- **Border radius scale:** sm=6px, md=10px, lg=16px, xl=22px, full=9999px
- **Settings window:** `NavigationSplitView` with 165–190px sidebar, 720×530 frame
- **Popover/dashboard:** Constrained width (~340px), no resize
- **Card pattern:** `GlassCard` component — `surface` background + `border` stroke at 0.5pt + `lg` corner radius

### Hermes Chat Surfaces

Two surfaces share one identity:

**Surface 1: Popover Hermes Strip**
- Positioned between provider list and action bar in the 340pt popover
- **Collapsed state:** Single-line input — caduceus glyph (`☿`) + "Ask Hermes..." placeholder + mercury gradient border with shimmer on hover
- **Expanded state:** Strip grows to show compact chat thread (max 3 messages visible). Hermes responses render inline with mercury-stroked bubbles. "Open in Dashboard →" link at bottom for deep conversations.
- Height: collapsed ~44px, expanded max ~220px
- Border: 1px `mercuryGradient` with shimmer overlay
- Inner background: `surfaceElevated`
- Animation: `gentle` spring for expand/collapse

**Surface 2: Dashboard Chat Panel (evolved)**
- Existing floating `ChatPanel` overlay gains a mode system
- **Local Index mode** (existing): "Ask your local index..." placeholder, whimsy/ember strokes, stateless per-turn via CLI bridge
- **Hermes mode** (new): "Ask Hermes..." placeholder, mercury-stroked bubbles, multi-turn via hermes webapi (`localhost:8642`), real conversational memory
- Mode toggle in header: subtle segmented pill using `bg` background, `sm` radius. Active state uses `accentGradient` (Index) or `mercuryGradient` (Hermes). Inactive state is transparent + `textMuted`.
- The retrieval pipeline injects OpenBurnBar data as system prompt context in BOTH modes.

**Hermes Tool Cards (Hermes mode only):**
- Uses existing `ChatBubbleStyle.toolShape()` UnevenRoundedRectangle
- Border: 1px `mercuryGradient` (replaces coral/purple gradient in Hermes mode)
- Tool name: `caption` weight semibold, `mercuryGradient` text fill
- Tool detail: `monoTiny`, `textSecondary`
- Running state: shimmer dot (6px, `mercuryGradient`, pulsing) + status text in `textMuted`
- Completed state: collapsed to single line (tool name only), expandable on tap
- Progressive disclosure: tools default collapsed after completion
- Group by capability icon (search, code, file, web, system) — never enumerate all 40+ tools

**Hermes Thinking State:**
- No spinner. Three 8px circles in `mercuryGradient` that pool and separate like liquid mercury droplets.
- Animation: staggered `mercuryPool` keyframes — scale 1→1.4→0.8→1, translateY 0→-2→1→0, opacity 0.5→1→0.6→0.5, 1.8s duration, 0.3s stagger between drops.
- Replaces the streaming caret (`▍`) with a mercury-colored caret when Hermes is the active backend.

**"via Hermes" Badge:**
- Shown above Hermes assistant messages (same pattern as existing `cliUsed` badge)
- `tiny` weight, `hermesAureate` color, prefixed with caduceus glyph

---

## Motion

- **Approach:** Intentional — animations aid comprehension, not decoration
- **Standard:** `spring(response: 0.35, dampingFraction: 0.75)`
- **Gentle:** `spring(response: 0.4, dampingFraction: 0.85)` — for layout shifts
- **Snappy:** `easeOut(duration: 0.15)` — for immediate feedback (toggles, taps)
- **Hover:** `spring(response: 0.25, dampingFraction: 0.8)` — for hover states

Always use `animation(_:value:)` — never `animation(_:)` without a value parameter.

### Hermes-Specific Motion

| Token | Type | Parameters | Usage |
|-------|------|-----------|-------|
| `mercuryShimmer` | linear | duration: 3s, easeInOut, repeat | Sweeping highlight on mercury gradient borders |
| `mercuryPool` | keyframes | 1.8s, stagger: 0.3s | Thinking state droplet animation |
| `mercuryPulse` | spring | 1.5s, easeInOut, repeat | Tool card running indicator dot |
| `stripExpand` | spring | response: 0.4, dampingFraction: 0.85 | Popover Hermes strip expand/collapse |

---

## Hermes Integration: Technical Design

### Backend Architecture

The chat panel gains a dual-backend system:

**Local Index mode (existing):**
- `CLIBridge.Backend` — spawns `codex` or `claude` CLI subprocess
- Stateless per-turn — each message gets fresh retrieval context as system prompt
- `CLIChatStreamEvent` with `.text` and `.toolUse` variants

**Hermes mode (new):**
- `CLIBridge.Backend.hermes` — HTTP to `hermes webapi` at `localhost:8642`
- OpenAI-compatible `POST /v1/chat/completions` with `stream: true`
- SSE streaming parsed into the same `CLIChatStreamEvent` types
- Multi-turn conversation — full message history sent per request
- Tool calls handled server-side by Hermes; results streamed as `.toolUse` events
- OpenBurnBar retrieval context injected as system prompt augmentation (same `ContextBuilder` pipeline)

**Detection:** `CLIBridge.detect()` gains a Hermes probe — check if `localhost:8642/v1/models` responds. If Hermes is available, it becomes the preferred backend. Fall back to existing CLI bridge if not.

**Data flow:**
```
User message
    → ChatSessionController.send()
        → SearchService.runBurnBarQuery() → retrieval context
        → ContextBuilder.buildDatabaseAnalystSystemPrompt() → system prompt
        → CLIBridge.chat() → hermes webapi (stream: true)
            → SSE chunks → CLIChatStreamEvent
                → .text → append to message bubble
                → .toolUse → render collapsible tool card
        → persist to DataStore (chat_messages, chat_threads)
```

### What Hermes Can Query

Through OpenBurnBar's retrieval pipeline (injected as system prompt context):
- Conversations by text, project, provider, date range (via `search_chunks_fts`)
- Skill docs and agent docs (via `source_artifacts`)
- Aggregate pattern counts across `conversations.fullText`
- Token usage and spend data (via `token_usage` table, formatted in system prompt)
- 18 most recent sessions with titles, costs, key files

Through Hermes's own tools (server-side):
- File operations, browser, code execution, terminal, web search
- Hermes memory and skill system
- Any MCP servers configured in Hermes

---

## Implementation: Adaptive Colors

`DesignSystem.Colors` must return adaptive values that respond to `colorScheme`. Use `NSColor`'s dynamic provider:

```swift
// In DesignSystem.swift — replace static lets with adaptive colors

extension Color {
    /// Creates a color that automatically adapts to the macOS appearance.
    static func adaptive(light: String, dark: String) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

// Usage in DesignSystem:
enum Colors {
    static let background    = Color.adaptive(light: "F5F0EB", dark: "0D1117")
    static let surface       = Color.adaptive(light: "FAF7F4", dark: "161B22")
    static let surfaceElevated = Color.adaptive(light: "FFFFFF", dark: "1C2128")
    static let border        = Color.adaptive(light: "DDD8D1", dark: "30363D")
    static let borderSubtle  = Color.adaptive(light: "EDE9E4", dark: "21262D")
    static let textPrimary   = Color.adaptive(light: "1A1208", dark: "FFFFFF")
    static let textSecondary = Color.adaptive(light: "4A4038", dark: "8B949E")
    static let textMuted     = Color.adaptive(light: "8A7E72", dark: "6E7681")
    static let success       = Color.adaptive(light: "2E8B57", dark: "34D399")
    static let warning       = Color.adaptive(light: "C97F1A", dark: "FBBF24")
    static let error         = Color.adaptive(light: "C93D3D", dark: "F45B69")

    // Brand accents also shift between modes
    static let coral         = Color.adaptive(light: "D96B5A", dark: "E07868")
    static let purple        = Color.adaptive(light: "7E74C4", dark: "8E86D0")
    static let teal          = Color.adaptive(light: "1DAAAF", dark: "2CBEC8")
    static let gold          = Color.adaptive(light: "D49A3A", dark: "D49A3A")
}
```

The static `coral`, `purple`, `teal`, `gold` in DesignSystem are currently hardcoded in multiple switch statements for provider colors. Those can remain fixed for provider identity but the general-purpose accent tokens should become adaptive.

---

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-22 | Initial design system documented | Created by /design-consultation based on existing codebase audit |
| 2026-03-22 | Light mode: Botanical Cream palette | Replaced Warm Neutral — herbarium paper (#EDF0E5) with sage borders and forest-ink text; distinct identity vs generic beige apps |
| 2026-03-22 | Dark mode: Warm Charcoal palette | Replaced GitHub dark clone (#0D1117) — warm near-black (#0E0D0B) with brown undertone, off-white text, earthy borders |
| 2026-03-22 | Color.adaptive extracted to ColorAdaptive.swift | Isolated AppKit import from DesignSystem.swift to prevent SourceKit false-positive errors on AgentProvider/Color(hex:) references |
| 2026-03-22 | Light mode activation: follows macOS system appearance | Native macOS behavior, zero extra UI, no settings burden |
| 2026-03-22 | Adaptive color strategy: NSColor dynamic provider | Works with existing Color(hex:) extension, no asset catalog required |
| 2026-03-22 | Settings layout: NavigationSplitView sidebar | Replaced TabView — macOS HIG standard for Settings; fixes text contrast and navigation clarity |
| 2026-03-22 | Section headers: caption 12pt semibold textSecondary | Previous tiny+textMuted failed WCAG AA at 11pt (~4.1:1 contrast); new combo achieves ~5.8:1 |
| 2026-03-25 | Hermes integration: Mercury Rising design | Two surfaces (popover strip + dashboard chat panel mode), warm mercury color axis (hermesMercury/hermesAureate), shimmer animations |
| 2026-03-25 | Hermes chat identity: warm mercury, not provider purple | Provider purple (#A855F7) stays for tracking/charts. Chat uses warm silver-gold mercury gradient — metallic neutral axis between warm accents and cool whimsy |
| 2026-03-25 | Popover Hermes strip | New interactive section between providers and action bar. Compact/expanded states. Raycast Quick AI pattern adapted for menu bar |
| 2026-03-25 | Dashboard chat: dual-backend mode system | Local Index (existing CLI bridge) + Hermes (webapi localhost:8642). Mode toggle in header. Hermes gets multi-turn memory, tool cards, mercury styling |
| 2026-03-25 | Tool visualization: progressive disclosure | Collapsible tool cards with mercury gradient strokes. One-line status while running, expandable I/O. Tools grouped by capability, not enumerated |
| 2026-03-25 | Thinking state: mercury pooling animation | Three 8px droplets that merge/separate. Replaces spinner. Staggered keyframes, 1.8s cycle |
| 2026-03-25 | Hermes backend: OpenAI-compatible webapi | hermes webapi on localhost:8642, SSE streaming, tool calls handled server-side. Same CLIChatStreamEvent types as existing CLI bridge |
| 2026-05-13 | Insights "Editorial Observatory" redesign (iOS / iPadOS) | Replaces the card-grid Intelligence Brief with a single-column editorial story: eyebrow + window subtitle + 22pt headline + mono meta strip + mercury hairline hero; numbered 01/02/03 Top Findings with 3pt severity-bar leading edge, confidence dots, footnote-chip citations, action stripe; horizontal Anomaly Atlas (220pt cards, mono z-score top-left, 2-column wrap in snapshot mode); Recommendations with ember `●` seal top-right and mono impact arrow; inline `InsightWidgetRenderer` for Generated Views; whimsy underlined `AttributedString` follow-ups separated by ` · `; full-width mercury hairline + monoTiny audit footer. Sections cascade in at 0.04s stagger and respect `accessibilityReduceMotion`; Dynamic Type clamped to `.xxLarge`. Snapshot-mode flag swaps the horizontal anomaly scroller for a two-column wrapping grid so `ImageRenderer`, PDF print, and App Store screenshot pipelines render the full atlas. |
| 2026-05-13 | Snapshot fixtures over toy data | Brief snapshot suite uses real-world AI-spend storytelling (Sonnet 4.6 cost dominance + cache decay, MiniMax M2.7 weekend spike, Anthropic 5h quota pressure) so the launch screenshots double as the highest-fidelity demo of the editorial voice. |
| 2026-05-13 | `IntelligenceBriefSnapshotTests` ships PNGs to `.appstore-screenshots/insights-editorial/ios/` | Mobile target doesn't link `swift-snapshot-testing`, so the suite drives SwiftUI's `ImageRenderer` directly. Outputs cover light, dark, minimal (hero + footer only), Dynamic Type `.xLarge`, reduce-motion, and iPad regular. Asserts a contract-order accessibility traversal: hero → 01 → 02 → 03 → anomalies L→R → recommendations → generated → follow-ups → audit. |
| 2026-05-15 | Mercury media Phase 1a ships substrate without UI polish | The Phase 1 file-transfer chat affordance (mercury-stroked attachment row + `ChatBubbleStyle.toolShape` per master plan § E.3) lands in Phase 1b alongside the xcframework reship that activates `publish_blob` / `fetch_blob`. Phase 1a confines its ship surface to protocol + dispatch + types + tests so a botched UI iteration does not block the binary substrate. No new color or motion tokens — Mercury HUD, attachment row, and incoming-call sheet all reuse the existing `mercuryGradient`, `mercuryShimmer`, `mercuryPool`, `mercuryPulse`, `stripExpand`, `ChatBubbleStyle.toolShape`, `GlassCard` per master plan § E. |
| 2026-05-13 | Insights "Editorial Observatory" redesign (Android, parity port) | `IntelligenceBriefScreen.kt` mirrors the iOS story arc: `INTELLIGENCE BRIEF` eyebrow + `Last 7 days` window + 22sp rounded-semibold executive lede + mono meta strip + mercury-gradient hairline with one-shot shimmer hero; ordered 01/02/03 Top Findings with mono ordinals, severity capsule, confidence dots, mono footnote-chip citations and `→` action stripe; horizontal `LazyRow` Anomaly Atlas with mono z-score numerals and a `Canvas`-drawn `ZScoreGauge` instrument scale (±2σ warning bands); Recommendations carry severity-aware ember seal and a mono `↑ impact` arrow; Generated views render via `InsightWidgetRenderer` with `Fig. 01` ordinals + mercury figure captions; Follow-ups are inline `ClickableText` whimsy segments separated by em-space (not chip buttons); audit footer uses a mercury hairline + mono meta. Cascade-in uses `AnimatedVisibility` + `slideInVertically(8.dp)` + `fadeIn` at 40ms stagger; reduce-motion (via `LocalAuroraReduceMotion` driven by `Settings.Global.animator_duration_scale==0`) paints synchronously. Font scale clamped to 1.15× upstream by `InsightsTheme`. |
| 2026-05-13 | Android tests: `IntelligenceBriefScreenTest` (instrumented) | Connected Compose UI suite (`createAndroidComposeRule<ComponentActivity>`) covers smoke, full-render light/dark, sparse + empty fixtures, font-scale 1.15× layout, reduce-motion synchronous paint, TalkBack reading-order contract (asserts monotonic `positionInRoot.y` per `testTag`), citation-chip tap callback wiring, impact-arrow directionality, and 4 screenshot variants (light, dark, fontscale 1.15×, dark + fontscale 1.15×). 14/14 green on Samsung SM-S921U. Screenshots persist to `targetContext.getExternalFilesDir(null)/insights-editorial/` then pulled to `.appstore-screenshots/insights-editorial/android/`. |
| 2026-05-13 | Android audit pass: impact arrow infers direction from sign | `impactArrow(impact, isDark)` reads the leading character of the impact label: `−`/`-` → `↘` + success green (savings); `+` → `↗` + ember warning (cost increase); else → `↗` + success green (the brief only emits non-prefixed strings for net positive recommendations). TalkBack reads `"Estimated impact, savings of $54/week"` instead of the raw glyph. Mirrors the iOS row "Recommendation impact arrow infers direction from sign" so cross-platform readers can't get the same green for cost increases and savings. |
| 2026-05-13 | Android audit pass: `MetaStrip` separators are atomic with their label | `FlowRow` used to render each `·` as a standalone `Text`, so a wrapped row could start with an orphan dot. Folded the separator into the next label as `·\u00A0$label` so the pair stays atomic and the wrap point sits between groups. |
| 2026-05-13 | Android audit pass: `IntelligenceBriefFormattingTest` (JVM) | Pure-function coverage of the shared formatters the brief and the audit log both depend on. 5 cases lock down `windowLabel` (every fixed window + custom range with EN DASH), `budgetLabel` (KB floor + trimmed suffix), `tokenUsageLabel` (cost omission), and `auditFooter` (8-char trim + "Local run" fallback). |
| 2026-05-13 | Android: charts are front-and-center (hero featured widget + reordered sections) | Above-the-fold criticism prompted a layout reorder. (1) The brief now selects the first **chart-bearing** generated widget (`InsightWidget.isChart`: KPI, time-series, ranking, donut, treemap, heatmap, scatter, sankey, radar, cohort, funnel, quota-pulse, forecast, focus-matrix) and renders it INSIDE the hero, right under the 22 sp executive summary, with a `Fig. 01 · <title>` editorial caption + Pin action + figure caption. The renderer's own `WidgetHeader` is suppressed (`showHeader = false`) so the title doesn't duplicate. (2) Reading order changes to hero → **Generated views** → findings → anomalies → recommendations → follow-ups → audit, so the remaining charts sit immediately after the hero instead of below findings. (3) Test fixture now seeds three real chart widgets — provider-mix time-series with the MiniMax burst spike, top-models-by-cost ranking with $42.18 leading bar, spend-distribution donut — so every screenshot variant shows actual graphs above the fold instead of pure typography. Section tag `SECTION_TAG_HERO_CHART` added; `talkback_reading_order_matches_contract` updated; citation-tap test uses `performScrollTo()` since the chip is now below the fold. |
| 2026-05-13 | Benchmark-aware mobile Insights intelligence | iOS and Android local-rule Insights now compare observed model spend and task mix against `modelBenchmarks` evidence from public model-board style sources such as Artificial Analysis, Design Arena, and Terminal-Bench. The rule engine can flag UI/design model-fit mismatches, rank the best benchmarked alternatives in a generated model board, surface cheaper similar-performance swaps, and add advisory guardrails so benchmark scores inform routing decisions without pretending they are absolute truth. Benchmark citations are first-class footnotes and Android citation taps now compose deterministic follow-up prompts instead of no-oping. |
| 2026-05-13 | iOS audit pass: `GeneratedViewRow` no longer duplicates the widget title | `InsightWidgetChrome` already renders the widget title + freshness pill, so the row keeps only the renderer plus a bottom Pin/sidenote/citation strip. Stops the chrome's configure menu and freshness pill from being overlapped by an external Pin button. |
| 2026-05-13 | Recommendation impact arrow infers direction from sign | `↘` + success green when the impact string starts with `−`/`-`, `↗` + ember warning when it starts with `+`. Prevents the surface from rewarding cost increases with the same green it uses for savings. |
| 2026-05-13 | Cascade-in cancels on `.onDisappear` via `Task` | Replaced `DispatchQueue.asyncAfter` chain with a stored `@State Task<Void, Never>` so navigating away mid-cascade cancels pending frames cleanly instead of silently calling `withAnimation` on a torn-down view. |
| 2026-05-13 | Citation taps route through `IntelligenceBriefCitationPrompt` | Tapping a footnote chip composes a deterministic natural-language follow-up (session → "open and summarize", quota → "detail headroom and refresh cadence", etc.) so every chip is wired without a bespoke navigation router. Covered by `IntelligenceBriefWiringTests` (9 tests). |
| 2026-05-13 | `InsightsStore.pinGeneratedWidget` is idempotent | Pinning a generated widget appends to the active canvas, or replaces the existing widget with the same id if the user taps Pin twice. Refreshes the canvas afterward so the pinned tile shows fresh data on first paint. |
| 2026-05-15 | Project Memory detail sheets (macOS) adopt the Editorial Observatory voice | The hero card, page cards, visual cards, and citation chips on `ProjectsView`'s Project Memory section now open into four full editorial sheets — `ProjectMemoryHeroDetailSheet`, `ProjectMemoryPageDetailSheet`, `ProjectMemoryVisualDetailSheet`, `CitationInsightSheet`. Each sheet uses the same language as the iOS Intelligence Brief: `EditorialHero` (eyebrow + subtitle + 22pt rounded-semibold headline + mono meta strip + mercury hairline with one-shot shimmer), `NumberedSectionRow` (01/02/03 mono ordinals + 3pt severity-bar leading edge + sentinel-aware `EmptyEvidenceCallout` + `FootnoteCitationChip` rail + "Open all" combined chip), `VisualChart` (Swift Charts `BarMark`/`LineMark` with `monoTiny` value annotations and tap-through to focused detail), and `CitationQuoteCard` (TRANSCRIPT/SKILL DOC/AGENT DOC/SHARED ARTIFACT mono labels + monospace excerpt + relative timestamp). Sheets cascade in at 0.04s stagger via `CascadeInModifier` and respect `accessibilityReduceMotion`. |
| 2026-05-15 | `ChatSessionController.streamingTick` lets observers mirror live streaming content without polling | A new `var streamingTick: Int = 0` is bumped (`&+= 1`) on every assistant-message content update inside `send()`'s stream loop. `ProjectMemoryInsightController` (`@Observable`) subscribes via `.onChange(of: chatController.streamingTick)` and mirrors the latest assistant message's `content` into `streamingContent` for the `HermesReadingCard` to render character-by-character with `MercuryPoolDots` + `MercuryCaret`. Replaces the broken count-offset polling in the previous `CitationInsightSheet`. State machine: `.idle → .streaming → .complete` (non-empty final) or `.failed(String)` (empty). |
| 2026-05-15 | `CitationWrapper.single(_:)` + fresh UUID per init | Tapping the same citation chip twice presents the sheet again because each `CitationWrapper` (used as the `Identifiable` driver for `.sheet(item:)`) generates a fresh `UUID` per init. `static func single(_:)` lets per-citation taps wrap a single citation into the same flow as the combined "Open all" chip. |
| 2026-05-15 | Empty-evidence callout replaces blank section bodies | `ContextPackService` emits sentinel strings like `"No indexed conversations are available yet."` when a section has no evidence. `NumberedSectionRow.isSentinelBody` detects these (prefix match against a fixed list + length floor) and renders `EmptyEvidenceCallout` — a small mercury-stroked card with `info.circle` glyph and the sentinel text in `textMuted` — instead of a misleading body paragraph. |
| 2026-05-16 | Android Mercury incoming-call uses `Notification.CallStyle.forIncomingCall` + `USE_FULL_SCREEN_INTENT` (Decision 1 parity) | The Mac is the authoritative ring source. Cloud Function `triggerVoIPCall` now writes a fan-out envelope per device: iOS gets an APNs VoIP push (PushKit), Android gets a high-priority FCM data message with `media_incoming_call` shape. Android `MercuryFcmService` constructs a `Notification.CallStyle.forIncomingCall(...)` with `setFullScreenIntent(...)` aimed at `IncomingCallActivity` (declared `showOnLockScreen=true` + `turnScreenOn=true` so a locked device wakes the screen). On Android 14+, when the user has revoked `USE_FULL_SCREEN_INTENT` (Settings → Apps → BurnBar → Notifications → Allow full-screen notifications), the service degrades to a high-priority heads-up notification and surfaces a one-time settings deep link in `MediaSettingsView`. The system call screen is reached via a self-managed `ConnectionService` (`MANAGE_OWN_CALLS`) wrapped in `CallKitFacade`, the closest Android equivalent to CallKit. No bespoke ring sound on Android — we hand the call to the system ringer. Foreground service runs with aggregated types `microphone|camera|mediaProjection|phoneCall` (Android 14+ granular foreground service types) so the OS classifies the session correctly during multi-app usage. |
| 2026-05-16 | Android per-partner save preferences on MediaStore + SAF (Decision 3 parity) | iOS persists per-partner save preferences (Save to Photos / Save to Files / Forget) through `MediaPartnerSavePreferenceStore`. Android mirrors this via `MediaPartnerSavePreferenceStore` (DataStore Proto, keyed by peer NodeId). `SavePolicy.SAVE_TO_PHOTOS` routes images / video to `MediaStore.Images.Media` / `MediaStore.Video.Media` (scoped storage on API 29+, falls back to `MediaStore.Downloads`). `SavePolicy.SAVE_TO_FILES` calls `ActivityResultContracts.OpenDocumentTree` once to remember a partner-specific tree URI, then `DocumentsContract.createDocument` for subsequent writes. Audio routes to `MediaStore.Audio.Media`. Forget per partner: `MediaPartnerSavePreferenceStore.forget(partnerId)`. Forget all (privacy nuke): `forgetAll()`. The `AttachmentBubble` and `MediaSettingsView` UI surfaces the policy with the same mercury-stroked card design language as iOS. Per-partner state survives uninstall through DataStore Proto persistence inside `app_data`; an app-data wipe resets every preference. |
| 2026-05-16 | Android iroh transport over UniFFI/JNI AAR (Decision 6 parity) | iOS hits iroh through `OpenBurnBarIroh.xcframework`. Android hits the same Rust crate (`crates/openburnbar-iroh`) through `Vendor/openburnbar-iroh.aar` — `scripts/build-iroh-android-aar.sh` runs `cargo-ndk` for all four ABIs, generates Kotlin bindings via `uniffi-bindgen-kotlin` pinned to the same `0.28.3` we use for Swift, and packages the binary + classes.jar + manifest. The new `:openburnbar-iroh-relay` Gradle module is a 1:1 port of the Swift `OpenBurnBarIrohRelay` package — same wire format, same ALPN `openburnbar/1`, same big-endian u32 length prefix, same `HermesRealtimeRelayFrame` JSON envelope, same Ed25519 pairing signature (verified via Tink since the JDK Ed25519 provider only ships on API 31+). The reflection-bridged `OpenBurnBarIrohFfiBackend` gates cleanly when the AAR is missing — Android still builds, just falls back to the loopback transport for dev and Firestore for prod. Mercury audio rides a new `MercuryAudioDatagramChannel` over the `openburnbar/mercury/audio/1` ALPN exposed by the new Rust `datagrams.rs` UniFFI surface — same channel design on iOS and Android. |
