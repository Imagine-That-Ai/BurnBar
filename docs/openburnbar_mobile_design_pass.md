# OpenBurnBar Mobile — Visual Depth & Polish Pass

## Overview

This document captures the comprehensive visual depth pass applied to the iOS and iPad surfaces of OpenBurnBar. The goal was singular: transform functional-but-flat screens into an experience that feels **breathtaking, fun to use, and mesmerizing** — while maintaining accessibility, performance, and cross-platform consistency.

## Before / After Summary

| Surface | Before | After |
|---------|--------|-------|
| Dashboard | Flat `surface` cards, SF Symbol badges, stock `BarMark` chart | `UnifiedGlassCard` hero with aurora avatar, `AreaMark` + `LineMark` chart with gradient, trend delta, iPad velocity sparkline |
| Quota | Plain cards, stock `ProgressView`, generic badges | Glass cards with `ProviderAvatar` (aurora), `UnifiedQuotaSignalView` battery bars, warning/healthy halos |
| Activity | Flat rows, no grouping, SF Symbol badges | Glass rows with provider-colored rail, grouped by day with sticky headers, monospaced token badges |
| Session Detail | Flat sections, no visual hierarchy | Hero panel with aurora avatar, animated token-mix bar, inset glass panels |
| Account | Flat cards, plain sync health | Animated gradient halo avatar, pulsing sync dot, overlapping provider avatars |
| Chat (Hermes) | Plain bubbles, 3-dot pulse | Mercury-stroked assistant bubbles, mercury pooling indicator, caduceus badge, glass input bar |
| Provider Connections | Plain rows, generic badges | Aurora avatars, glass card styling |
| Widgets | Text-only provider label | `UnifiedProviderLogoView` for top provider, sparkline with glow dot |
| iPad Sidebar | Default styling | Glass sync health pill, keyboard shortcuts wired |
| iPad Placeholders | Empty state text | Animated SF Symbol scenes over ember backdrop |

## Architecture

### ProviderAvatar — The Canonical Avatar

```
AgentProvider.bundledLogoName → UnifiedProviderLogoView → ProviderAvatar
                                    ↓
                        ┌───────────┼───────────┐
                        ↓           ↓           ↓
                      .plain      .tile      .aurora
                     Bare logo   Rounded     Haloed circle
                                square +    + gradient ring
                                stroke      + glass (iOS 26+)
```

- **`.plain`** — Inline chips, compact lists
- **`.tile`** (default) — List rows, 0.5pt stroke, tinted background
- **`.aurora`** — Hero cards, radial glow + gradient ring + `glassEffect()` on iOS 26+

### EmberSurfaceBackground — Brand Identity Everywhere

Promoted from `SignInScene` into a reusable `OpenBurnBarCore` component:

- **Dark mode**: Warm charcoal base + 3 drifting ember orbs + 8 floating particles
- **Light mode**: Botanical cream wash + softer orbs + fern-toned particles
- **Respects**: `accessibilityReduceMotion` (stops animations), `accessibilityReduceTransparency` (drops blurs/particles)

Surfaces using it: `DashboardView`, `QuotaView`, `ActivityView`, `AccountView`, `ChatView`, `ProjectsView`, `MissionsView`, `ModelDashboardView`, `iPadSettingsView`, `iPadOnboardingWizardView`.

### UnifiedGlassCard — One Visual Language

Already existed in core; now adopted everywhere on mobile. Frosted glass (`ultraThinMaterial` on iOS 17–25, `glassEffect()` on iOS 26+), gradient sheen, luminous border, interactive scale effects.

### UnifiedQuotaSignalView — Battery-Bar Quota

Replaced the local `QuotaBucketView` and stock `ProgressView`. Cross-platform battery visualization with provider-tinted gradient fill, glow shadow, and status labels.

## iOS Version Fallback Matrix

| Feature | iOS 17 | iOS 18 | iOS 26+ |
|---------|--------|--------|---------|
| Tab API | `.tabItem` legacy | Value-based `Tab` | Value-based `Tab` |
| Tab(role: .search) | Inline `.searchable` | Dedicated search tab | Dedicated search tab |
| tabBarMinimizeBehavior | Stock tab bar | Stock tab bar | `.onScrollDown` |
| glassEffect | `.ultraThinMaterial` | `.ultraThinMaterial` | `glassEffect(.regular)` |
| scrollEdgeEffectStyle | Stock edge | Stock edge | `.soft` (not yet applied, reserved) |
| Navigation zoom transitions | Standard push | Standard push | `navigationTransitionSource` (reserved) |
| @Animatable macro | Manual `animatableData` | Manual `animatableData` | `@Animatable` macro (reserved) |
| @Previewable | Standard preview | `@Previewable` | `@Previewable` |
| symbolEffect | Not available | `.bounce`, `.pulse`, `.variableColor` | Full symbol effects |

All gated through `#available` with back-deploy paths already working first.

## Accessibility

- **Reduce Motion**: All shimmer, pulse, ember drift, mercury pool, and halo animations are conditional. Skeleton shimmer, backdrop particles, and entrance modifiers all check `accessibilityReduceMotion`.
- **Reduce Transparency**: `EmberSurfaceBackground` drops particles/orbs when `accessibilityReduceTransparency` is true.
- **Dynamic Type**: Typography capped at `.accessibility2`. Hero numbers use `minimumScaleFactor(0.6)`; body text never shrinks.
- **VoiceOver**: Every `ProviderAvatar` has `accessibilityLabel(provider.displayName)`. Chips use `accessibilityElement(children: .combine)`.
- **Haptics**: Debounced `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` hooked to period switches, refresh, quota thresholds, Hermes send, and errors.

## Files Changed / Added

### New Components
- `OpenBurnBarMobile/Views/Components/ProviderAvatar.swift`
- `OpenBurnBarMobile/Views/Components/EmberSkeleton.swift`
- `OpenBurnBarMobile/Views/Components/Haptics.swift`
- `OpenBurnBarMobile/Views/Components/MercuryThinkingIndicator.swift`
- `OpenBurnBarMobile/Views/Components/MercuryShimmerOverlay.swift`
- `OpenBurnBarMobile/Views/Components/FlameRefreshIndicator.swift`
- `OpenBurnBarMobile/Views/Components/RollingNumberText.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/EmberSurfaceBackground.swift`

### New Assets
- 35 new `.imageset` directories in `OpenBurnBarMobile/Resources/Assets.xcassets/` copied from `AgentLens/Resources/Assets.xcassets/`

### Refactored Views
- `DashboardView.swift` — Glass hero, aurora avatar, trend delta, velocity sparkline (iPad), area chart
- `QuotaView.swift` — Glass cards, `UnifiedQuotaSignalView`, warning/healthy halos
- `ActivityView.swift` — Day grouping, provider rail, glass rows, search transitions
- `SessionDetailView.swift` — Hero panel, animated token-mix bar, glass sections
- `AccountView.swift` — Animated halo, account health line, pulsing sync dot, overlapping avatars
- `ChatView.swift` — Mercury strokes, mercury pooling indicator, caduceus badge, glass input bar
- `RootTabView.swift` — iOS 18 `Tab` API, iOS 26 `tabBarMinimizeBehavior`
- `RootNavigationView.swift` — Glass sync pill, keyboard shortcuts, placeholder upgrades
- `iPadOnboardingWizardView.swift` — Animated SF Symbol scenes over ember backdrop
- `QuotaDetailSheet.swift` — Aurora hero, account carousel, stat chips
- `ProviderConnectionsView.swift` — Aurora avatars
- `AddProviderConnectionView.swift` — Aurora avatars
- `BurnBarLiveActivityWidget.swift` — Provider logo in expanded center
- `HeroSmallView.swift`, `CostSparklineMediumView.swift`, `DashboardLargeView.swift` — Provider logos

### Tests
- `OpenBurnBarMobileTests/ProviderAvatarTests.swift` — Asserts every `AgentProvider` has a bundled asset

## Design Principles

1. **Depth over decoration** — Every surface has a reason for its depth (glass cards reveal hierarchy, aurora halos signal hero importance, rails indicate provider identity).
2. **Motion with meaning** — Animations guide attention (staggered entrances reveal content flow, mercury pooling indicates thinking, flame flicker warms the hero).
3. **Brand continuity** — The ember warmth from `SignInScene` now extends through the entire app. Users don't "leave" the brand identity after authentication.
4. **Graceful degradation** — iOS 26 features are luxuries, not requirements. The app is breathtaking on iOS 17 and only gets better.
