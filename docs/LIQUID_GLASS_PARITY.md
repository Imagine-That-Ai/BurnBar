# Liquid Glass — cross-platform parity (iOS → macOS → Android)

The Liquid Glass design language shipped first in the iOS app
(`OpenBurnBarMobile/Theme/LiquidGlass.swift`). This document is the canonical
inventory of every iOS adapter call site, grouped by visual cluster, and the
mapping of each cluster onto the macOS app (AgentLens target) and the Android
app (`android/`). Update it when a platform gains or loses a glass surface.

## The adapter contract (identical vocabulary on all three platforms)

| Adapter | Role | iOS / macOS | Android (Compose) |
|---|---|---|---|
| `liquidGlassSurface(in:fallback:)` | passive plate: trays, floating bars, cards, sheet inserts | `glassEffect(.regular, in: shape)` on 26+, material fallback | `Modifier.liquidGlassSurface(shape, wash, washBrush, shadow)` |
| `liquidGlassInteractive(tint:in:fallback:)` | tappable controls: buttons, chips, pills; `tint` = meaning only | `.regular.interactive()` (+`.tint`) on 26+, tint-over-material fallback | `Modifier.liquidGlassInteractive(tint, shape, shadow)` |
| `liquidGlassCircleButton(diameter:)` | recurring circular overlay control (close ✕, call controls) | frame + interactive circle | `Modifier.liquidGlassCircleButton(diameter, tint)` |
| `LiquidGlassGroup(spacing:)` | shared sampling scope (glass cannot sample other glass) | `GlassEffectContainer` on 26+, passthrough earlier | `LiquidGlassGroup {}` + `Modifier.liquidGlassBackdrop()` |

Files:

- iOS: `OpenBurnBarMobile/Theme/LiquidGlass.swift` (+ `Views/Aurora/LiquidGlassFallback.swift` variant-card system)
- macOS: `AgentLens/Theme/LiquidGlass.swift` — kept in lockstep with the iOS file, gated `#available(macOS 26, *)`, deploys to macOS 14
- Android: `android/app/src/main/java/com/openburnbar/ui/components/LiquidGlass.kt` — sits beside the pre-existing `auroraGlass` variant-card system (`AuroraGlassSurface.kt`), mirroring how iOS keeps both layers

### Fallback ladder

- **iOS 26+ / macOS 26+**: native `glassEffect`; tint/sheen washes ride ON the glass — never a material underneath (glass samples the content behind it).
- **iOS 17–25 / macOS 14–15**: shape-bounded material (`.ultraThinMaterial` default, per-site override). Hand-tuned ZStack fallbacks (material + surface tint + sheen) stay inline at the call site when the legacy look can't be reproduced by the adapter (sanctioned iOS pattern).
- **Android API 31+ inside a `LiquidGlassGroup`**: true backdrop sampling — the group records the composable marked `liquidGlassBackdrop()` into a `GraphicsLayer`; every glass child re-draws that recording blurred (`RenderEffect`) and clipped to its shape. This is NOT the self-content blur that `auroraGlass` correctly removed (that blurred the card's own text); it blurs what's *behind* the plate.
- **Android below 31 / outside a group**: flat translucent stack (surface fill + sheen gradient + 0.75dp `glassStroke` edge) — same recipe as `auroraGlass`.
- **Reduce Transparency (macOS `GlassCard`)** falls back to an opaque surface fill.

### Invariants (all platforms)

1. Exactly **one glass layer per visual cluster**; grouped elements share one sampling container.
2. Glass sits **on top of content** — chips/buttons inside a glass plate stay plain tint/material, never a second glass layer.
3. The **foil/holo membership world stays glassless** (iOS `CloudTierComponents`, macOS `Views/Components/Pro/*`, Android `ui/pro/*` + store tier/holo cards). Glass appears only on system chrome there (close buttons, sheet material).
4. `tint`/`wash` conveys meaning (state, primary action, legibility smoke over a bright mirror) — never decoration.

## Cluster inventory and per-platform mapping

Roles: **S** = surface (passive), **I** = interactive, **I-P** = interactive-primary (tinted).

| # | Cluster (iOS origin) | Role | iOS call sites | macOS (AgentLens) | Android |
|---|---|---|---|---|---|
| 1 | Mercury cards (header / recent transfers / customize sheet) | S | `MercuryHeaderCard.swift:47`, `MercuryRecentTransfersCard.swift:97`, `MercuryCustomizeSheet.swift:125` | `Views/Popover/MercuryTraySection.swift` — `liquidGlassSurface(in: .rect(12))`, mercury stroke kept | no transfers UI; nearest (PairedMacControls dock) already on `auroraGlass` — N/A |
| 2 | Floating overlay circle buttons (close ✕ / collapse / PiP) | I | `ScreenShareViewerView.swift:1212`, `CapabilityDetailSheet.swift:155`, `CloudStoreView.swift:184` | `CallHUD.swift` collapse chevron → `liquidGlassCircleButton(24)`; `ScreenShareViewer.swift` PiP badge → `liquidGlassSurface(in: .circle)` | `CloudStoreViewSections.kt` close ✕ → `liquidGlassInteractive(CircleShape, isDark = true)` |
| 3 | Floating pill toolbars / status capsules | S/I | `AgentLiveStageBadges.swift:24`, `MobileMissionFAB.swift:136/185`, `ScreenShareViewerView.swift:1220/3092`, `SmartHubCastButton.swift:36`, `TextExpansionSettingsView.swift:112` | `ChatMinimizedPill.swift` (inline 26+ branch), `CallHUD.swift` collapsed pill, `DashboardChromeComponents.swift` `toolbarPillSurface` (segmented picker + every toolbar pill), `TextExpansionSettingsView.swift` toast → `liquidGlassSurface(in: Capsule())` | `ComputerUseAgentWatchScreenSections.kt` StatusStrip/TimelinePreview/ApprovalRow (smoke wash on glass), `MissionActivityOverlaySections.kt` TooltipPill |
| 4 | Call HUD control row (grouped circles) | I | `CallHUDView.swift:35/63` | `CallHUD.swift` — `LiquidGlassGroup(spacing: 24)` + `liquidGlassCircleButton(44)` ×4 | `CallHUDViewSections.kt` `CallHUDControl` → `liquidGlassCircleButton(56.dp)`; no group (camera video is a SurfaceView — not capturable) |
| 5 | Inline agent mirror (key panel + toggle pill) | S+I | `InlineAgentMirrorView.swift:283/300` | N/A — the Mac is the mirror *source*; no inline mirror UI | `InlineAgentMirrorView.kt` key panel → `liquidGlassSurface(rect 12, black wash)`; no toggle pill exists (mode switch is host-level) |
| 6 | Settings capsules / device chips | S | `ConnectedDevicesRow.swift:60/72`, `SmartDisplayReorderableSection.swift:80` | covered by `GlassCard` house primitive upgrade (`MenuBarPopoverView.swift`) — real glass on 26+, Reduce-Transparency opaque path | `TextExpansionSettingsScreenSections.kt` section cards → `liquidGlassSurface(rect md)`; `ConnectedDevicesRow.kt` already on `AuroraGlassCard` |
| 7 | Mission Control FAB / chart-studio FAB | I / I-P | `MobileMissionFAB.swift:222`, `ChartStudioFloatingButton.swift:94` | `MissionFAB.swift` + `ChatFAB.swift` discs → interactive glass on 26+ (inline branch keeps the opaque pre-26 face) | `MissionActivityOverlaySections.kt` orb discs → `liquidGlassInteractive(CircleShape)`; `ChartStudioFabSections.kt` → `liquidGlassCircleButton(56.dp, tint = ember)` |
| 8 | Store/paywall chrome (foil stays glassless) | I | `CloudStoreView.swift:184`, `CapabilityDetailSheet.swift:155` | `FeatureUnlockSheet.swift` close ✕ → `liquidGlassCircleButton(28)`; holo crest untouched | `CloudStoreViewSections.kt` close ✕ (see #2); foil/holo exclusion list intact |
| 9 | Wallpaper generator controls | S/I | `WallpaperGeneratorView.swift:381/426/479/549` | N/A — no wallpaper generator on macOS | `WallpaperGeneratorScreenSections.kt` — `LiquidGlassGroup` + `liquidGlassBackdrop()` on the live canvas (true blur on 31+); pills → interactive/surface; Set-Live CTA stays opaque ember |
| 10 | Insights composer / bottom bar | S | `InsightsRootView.swift:343` | `InsightsComposerBar.swift` → `liquidGlassSurface(in: .rect(lg))` | `InsightsScreenSections.kt` `InsightsComposerBar` → `liquidGlassSurface(RectangleShape, surface wash)` |
| 11 | Chart/graph inset cards & callouts | S | `StreamGraphScene.swift:96`, `ProjectDetailView.swift:411` | `DashboardLiveCostCurve.swift` (inline 26+ branch: accent wash on glass); `ProjectsView` insets via `GlassCard` | streams cards already on `AuroraGlassCard`; stat pills stay plain (chips-inside rule) |
| 12 | Status strips (popover) | S | — (macOS-only surface, same family as #3) | `CloudWhisperStrip.swift` backdrop → brand wash on glass (26+ inline branch); icon chip stays material | N/A |
| 13 | Mission live tile / nav tray | S | `AuroraNavigationTray.swift:65` (inline) | — | `AuroraNavigationTraySections.kt` `auroraTrayPillChrome` rebuilt on `liquidGlassSurface` (fixes shadow-order bug, adds glass edge); `SkillRunLiveTile` → glass + accent border |

### Documented substitutions / platform gaps

- **macOS `GlassCard`/`GlassButton`** (`MenuBarPopoverView.swift`) are the house variant-card system (analogue of iOS `.auroraGlass()`): on 26+ the sheen/style wash rides on real glass, material+surface fills remain pre-26 only; `GlassCard` adds a Reduce-Transparency opaque path.
- **Android has no native `glassEffect`**: depth/translucency/specular edge are expressed as translucent fill + sheen gradient + `glassStroke` edge; *refraction* is approximated by the group-scoped backdrop blur on API 31+. Video-backed clusters (call HUD, agent watch, screen mirror) cannot be sampled (SurfaceView) — they use the flat stack plus a legibility smoke wash, mirroring the iOS smoke-on-glass pattern.
- **iOS inline `glassEffect` bypasses** (opacity-tweaked or safe-area-bleeding fallbacks, state-tinted washes, the two sanctioned button-style systems `LiquidGlassButtonStyle` / `AuroraButtonStyle`) are intentional and stay; macOS mirrors the same inline pattern where the pre-26 look is a hand-tuned stack (`ChatMinimizedPill`, `DashboardLiveCostCurve`, `CloudWhisperStrip`, FAB faces).
- **No macOS equivalents** for: wallpaper generator, chart-studio session FAB (Insights canvas has no FAB; `ChatFAB`/`MissionFAB` carry the role), inline agent mirror (Mac is the source), scroll-to-bottom overlay buttons.
- **No Android equivalents** for: Mercury recent-transfers card, scroll-to-bottom chat pill, mirror toggle pill.
