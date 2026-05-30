# Design system

All design tokens for OpenBurnBar. Implemented in `AgentLens/Theme/DesignSystem.swift` with adaptive colors via `AgentLens/Theme/ColorAdaptive.swift`.

## Typography

All type uses **SF Pro Rounded** (`Font.system(..., design: .rounded)`). Ships with macOS — no loading required.

| Token | Size | Weight | Usage |
|---|---|---|---|
| `displayLarge` | 36pt | Bold | Reserved for hero moments |
| `display` | 28pt | Bold | Large cost totals |
| `title` | 20pt | Semibold | Modal headers |
| `headline` | 16pt | Semibold | Card titles, provider names |
| `body` | 14pt | Regular | Toggle labels, row text |
| `caption` | 12pt | Semibold | Section headers, subtitles |
| `tiny` | 11pt | Medium | Timestamps, annotations only |
| `mono` | 14pt | Medium | Token counts, cost values |
| `monoSmall` | 12pt | Medium | Inline cost figures |
| `monoTiny` | 11pt | Medium | Paths, audit ordinals |

**Section header rule:** always `caption` (12pt semibold) + `textSecondary`. Never `tiny` + `textMuted` — contrast fails at that combination.

## Adaptive colors

Colors use `NSColor`'s dynamic provider (via `Color.adaptive(light:dark:)` in `ColorAdaptive.swift`) so they flip automatically with macOS appearance. No asset catalog required.

### Dark mode — Warm Charcoal (primary)

| Token | Value | Role |
|---|---|---|
| `background` | `#0E0D0B` | Warm near-black |
| `surface` | `#171510` | Dark warm charcoal |
| `surfaceElevated` | `#201E18` | Elevated surface |
| `border` | `#302C22` | Earthy dark border |
| `textPrimary` | `#F0EBE2` | Warm off-white |
| `textSecondary` | `#9A9088` | Warm gray |
| `textMuted` | `#7A7268` | Warm muted |
| `success` | `#38D898` | Vivid green |
| `warning` | `#F0C040` | Rich amber |
| `error` | `#F06070` | Rich red |

### Light mode — Botanical Cream

| Token | Value | Role |
|---|---|---|
| `background` | `#EDF0E5` | Herbarium paper |
| `surface` | `#F4F6EE` | Lighter botanical paper |
| `surfaceElevated` | `#FAFAF5` | Near-white with green tint |
| `border` | `#C5CEB6` | Pressed sage |
| `textPrimary` | `#1C2014` | Botanical ink |
| `textSecondary` | `#4A5442` | Aged ink |
| `textMuted` | `#7A8572` | Faded sage |

## Brand accents

| Accent | Dark | Light | Usage |
|---|---|---|---|
| `coral` | `#E87060` | `#C8604E` | Claude Code, gradients |
| `purple` | `#9080D8` | `#6868B8` | Factory Droid, charts |
| `teal` | `#2CCAC0` | `#1A9A8C` | Kimi, cache hits |
| `gold` | `#E0A030` | `#A47A1E` | MiniMax, warnings |

Provider identity colors in switch statements can remain fixed; only general-purpose accent tokens need to be adaptive.

## Hermes mercury identity

| Token | Dark | Light | Usage |
|---|---|---|---|
| `hermesMercury` | `#C8BFB5` | `#AEA69C` | Response bubble strokes, status text, thinking state |
| `hermesAureate` | `#A2ACBA` | `#3F4651` | Badges, links, send button accent |

`mercuryGradient`: `LinearGradient([hermesMercury, hermesAureate], topLeading → bottomTrailing)`

## Spacing

Base unit: **4px**. All spacing is multiples of 4.

| Token | Value | Usage |
|---|---|---|
| `xxs` | 2px | Icon-to-text nudges |
| `xs` | 4px | Tight internal gaps |
| `sm` | 8px | Component internal padding |
| `md` | 12px | Between related elements |
| `lg` | 16px | Card padding, section gaps |
| `xl` | 24px | Between sections |
| `xxl` | 32px | Between major blocks |
| `xxxl` | 48px | Top-level layout gaps |

## Layout

- **Border radius:** sm=6px, md=10px, lg=16px, xl=22px, full=9999px
- **Settings window:** `NavigationSplitView`, 165–190px sidebar, 720×530 frame
- **Popover:** ~340px constrained width, no resize
- **Card pattern:** `GlassCard` — `surface` background + `border` 0.5pt stroke + `lg` corner radius

## Motion tokens

| Token | Type | Parameters | Usage |
|---|---|---|---|
| standard | spring | response: 0.35, dampingFraction: 0.75 | Default animations |
| gentle | spring | response: 0.4, dampingFraction: 0.85 | Layout shifts |
| snappy | easeOut | duration: 0.15s | Toggles, immediate feedback |
| hover | spring | response: 0.25, dampingFraction: 0.8 | Hover states |
| `mercuryShimmer` | linear | 3s easeInOut repeat | Sweeping highlight on mercury gradient borders |
| `mercuryPool` | keyframes | 1.8s, 0.3s stagger | Thinking state droplets |

Always use `animation(_:value:)` — never `animation(_:)` without a value.

## Files

| File | Purpose |
|---|---|
| `AgentLens/Theme/DesignSystem.swift` | All tokens, `GlassCard`, `BrandGradients` |
| `AgentLens/Theme/ColorAdaptive.swift` | `Color.adaptive(light:dark:)` NSColor dynamic provider |
| `AgentLens/Theme/ProviderTheme.swift` | Per-provider color and icon mapping |
| `AgentLens/Theme/ThemeManager.swift` | Theme lifecycle and appearance observation |
| `AgentLens/Theme/LLMModelBrand.swift` | Per-model brand colors |
