# Design system

Adaptive color system, typography, spacing, and motion tokens used across all OpenBurnBar surfaces.

## Purpose

Maintain visual consistency across macOS, iOS, and Android while supporting both dark and light mode. The design system is documented in `DESIGN.md` and implemented in `DesignSystem.swift`.

## Color system

### Dark mode — Warm Charcoal

| Token | Value | Role |
|-------|-------|------|
| `background` | `#0E0D0B` | Warm near-black |
| `surface` | `#171510` | Dark warm charcoal |
| `surfaceElevated` | `#201E18` | Elevated warm surface |
| `border` | `#302C22` | Earthy dark border |
| `textPrimary` | `#F0EBE2` | Warm off-white |
| `textSecondary` | `#9A9088` | Warm gray |
| `textMuted` | `#7A7268` | Warm muted |

### Light mode — Botanical Cream

| Token | Value | Role |
|-------|-------|------|
| `background` | `#EDF0E5` | Herbarium paper — cream with green cast |
| `surface` | `#F4F6EE` | Lighter botanical paper |
| `surfaceElevated` | `#FAFAF5` | Near-white with green tint |
| `border` | `#C5CEB6` | Pressed sage |
| `textPrimary` | `#1C2014` | Botanical ink |
| `textSecondary` | `#4A5442` | Aged ink |
| `textMuted` | `#7A8572` | Faded sage text |

### Brand accents

| Color | Dark | Light | Usage |
|-------|------|-------|-------|
| Coral | `#E87060` | `#C8604E` | Claude Code, gradients |
| Purple | `#9080D8` | `#6868B8` | Factory Droid, charts |
| Teal | `#2CCAC0` | `#1A9A8C` | Kimi, cache hits |
| Gold | `#E0A030` | `#A47A1E` | MiniMax, warnings |

### Mercury identity

| Token | Dark | Light | Usage |
|-------|------|-------|-------|
| `hermesMercury` | `#C8BFB5` | `#AEA69C` | Warm silver — response bubble strokes, status text |
| `hermesAureate` | `#A2ACBA` | `#3F4651` | Dark platinum — Hermes badges, links, send button accent |

## Typography

All type uses **SF Pro Rounded** (`Font.system(..., design: .rounded)`):

| Token | Size | Weight | Usage |
|-------|------|--------|-------|
| `display` | 28pt | Bold | Large cost totals |
| `title` | 20pt | Semibold | Modal headers |
| `headline` | 16pt | Semibold | Card titles, provider names |
| `body` | 14pt | Regular | Toggle labels, row text |
| `caption` | 12pt | Medium | Section headers, subtitles |
| `tiny` | 11pt | Medium | Timestamps, annotations |
| `mono` | 14pt | Medium | Token counts, cost values, paths |

## Spacing

Base unit: **4px**. All spacing is multiples of 4.

| Token | Value |
|-------|-------|
| `xs` | 4px |
| `sm` | 8px |
| `md` | 12px |
| `lg` | 16px |
| `xl` | 24px |
| `xxl` | 32px |

## Motion

| Token | Parameters | Usage |
|-------|-----------|-------|
| Standard | `spring(response: 0.35, dampingFraction: 0.75)` | General animations |
| Gentle | `spring(response: 0.4, dampingFraction: 0.85)` | Layout shifts |
| Snappy | `easeOut(duration: 0.15)` | Toggles, taps |
| Hover | `spring(response: 0.25, dampingFraction: 0.8)` | Hover states |

Always use `animation(_:value:)` — never `animation(_:)` without a value parameter.

## Entry points for modification

- Update tokens in `AgentLens/Theme/DesignSystem.swift`.
- Add new provider colors in `AgentLens/Theme/ProviderTheme.swift`.
- Update `DESIGN.md` when changing cross-platform color contracts.

## Related pages

- [macOS app](../apps/macos-app/index.md)
- [iOS app](../apps/ios-app/index.md)
- [Android app](../apps/android-app.md)
