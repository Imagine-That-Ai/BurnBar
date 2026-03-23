# Design System — BurnBar

## Product Context
- **What this is:** A native macOS menu bar app that tracks token usage and cost across AI coding agents (Claude Code, Factory Droid, Codex, Kimi, MiniMax, etc.)
- **Who it's for:** Developers running multiple AI agents in parallel who want real-time visibility into spend without checking billing dashboards
- **Space/industry:** Developer tools / AI infrastructure observability
- **Project type:** macOS menu bar app + popover dashboard + settings window

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

### Dark Mode (primary)

| Token | Value | Role |
|-------|-------|------|
| `background` | `#0D1117` | Page/window background |
| `surface` | `#161B22` | Cards, panels |
| `surfaceElevated` | `#1C2128` | Input backgrounds, popovers-on-cards |
| `border` | `#30363D` | Dividers, card outlines |
| `borderSubtle` | `#21262D` | Section separators |
| `textPrimary` | `#FFFFFF` | Headings, values |
| `textSecondary` | `#8B949E` | Labels, section headers |
| `textMuted` | `#6E7681` | Hints, annotations, timestamps |
| `success` | `#34D399` | Positive states, "path exists" |
| `warning` | `#FBBF24` | Partial support, alerts |
| `error` | `#F45B69` | Errors, destructive actions |

### Light Mode — Warm Neutral

| Token | Value | Role |
|-------|-------|------|
| `background` | `#F5F0EB` | Page/window background |
| `surface` | `#FAF7F4` | Cards, panels |
| `surfaceElevated` | `#FFFFFF` | Input backgrounds, elevated content |
| `border` | `#DDD8D1` | Dividers, card outlines |
| `borderSubtle` | `#EDE9E4` | Section separators |
| `textPrimary` | `#1A1208` | Headings, values |
| `textSecondary` | `#4A4038` | Labels, section headers |
| `textMuted` | `#8A7E72` | Hints, annotations, timestamps |
| `success` | `#2E8B57` | Positive states |
| `warning` | `#C97F1A` | Partial support, alerts |
| `error` | `#C93D3D` | Errors, destructive actions |

### Brand Accents

Accent colors shift slightly between modes to maintain saturation and contrast:

| Color | Dark | Light | Usage |
|-------|------|-------|-------|
| Coral | `#E07868` | `#D96B5A` | Claude Code, gradients, highlights |
| Purple | `#8E86D0` | `#7E74C4` | Factory Droid, charts |
| Teal | `#2CBEC8` | `#1DAAAF` | Kimi, success states, cache hits |
| Gold | `#D49A3A` | `#D49A3A` | MiniMax, warnings |

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
- **Popover/dashboard:** Constrained width (~380px), no resize
- **Card pattern:** `GlassCard` component — `surface` background + `border` stroke at 0.5pt + `lg` corner radius

---

## Motion

- **Approach:** Intentional — animations aid comprehension, not decoration
- **Standard:** `spring(response: 0.35, dampingFraction: 0.75)`
- **Gentle:** `spring(response: 0.4, dampingFraction: 0.85)` — for layout shifts
- **Snappy:** `easeOut(duration: 0.15)` — for immediate feedback (toggles, taps)
- **Hover:** `spring(response: 0.25, dampingFraction: 0.8)` — for hover states

Always use `animation(_:value:)` — never `animation(_:)` without a value parameter.

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
| 2026-03-22 | Light mode: Warm Neutral palette | Cream tones (#F5F0EB bg) chosen over GitHub cool-gray for warmer feel alongside light-mode IDEs |
| 2026-03-22 | Light mode activation: follows macOS system appearance | Native macOS behavior, zero extra UI, no settings burden |
| 2026-03-22 | Adaptive color strategy: NSColor dynamic provider | Works with existing Color(hex:) extension, no asset catalog required |
| 2026-03-22 | Settings layout: NavigationSplitView sidebar | Replaced TabView — macOS HIG standard for Settings; fixes text contrast and navigation clarity |
| 2026-03-22 | Section headers: caption 12pt semibold textSecondary | Previous tiny+textMuted failed WCAG AA at 11pt (~4.1:1 contrast); new combo achieves ~5.8:1 |
