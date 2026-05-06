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
