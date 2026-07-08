# Phase 3 — UI Parity (every macOS surface → WinUI 3): executable plan

**Status:** planned (pre-planned during Phase 1) · **Predecessor:** WINUI-017 (spike builds+runs on real
Windows/ARM64) — **already cleared on x64** by the dev-host test (2026-07-03); ARM64 run still pending.
Scale (measured): app `AgentLens/Views/` = **112,122 LOC / 295 files** (Settings 35k, Dashboard 29k, Chat
15k, Components 10k, Onboarding 5k, Popover 4.6k, SessionLogs 3.1k, Insights 2.6k, +W5/W9 rows); in-core
`OpenBurnBarCore/…/Views/` = **30,729 LOC / 117 files**. Design-system chokepoints are small but
load-bearing (`LiquidGlass.swift` 328, `DesignSystem.swift` 351, Swarm substrate system 9.4k, `PretextEngine`
467). **Phase-3 total ≈ 370–540 PRs** (~⅓–½ of the whole Option-A envelope).

## W6 — design-system foundation (blocks all of W7)
1. **W6-DS-TOKENS (3–5 PRs, LOW risk, blocks all):** add `pensieve/winui-xaml` + `pensieve/csharp` formats to
   `packages/design-tokens/config.mjs` (Style Dictionary v5 already emits Swift+Compose) → `dist/winui/
   PensieveTokens.xaml`+`.cs`; replace the hand-seeded `windows/app/.../Theme/Tokens.xaml`. Port the 32-provider
   `primary/accent(for:)` + `colorForModel` brand tables as C# (mirror `Theme/ProviderTheme.swift`,
   `LLMModelBrand.swift`) with a Swift↔C# parity unit test.
2. **W6-DS-GLASS (6–10 PRs, HIGH design risk R7):** one C# chokepoint mirroring `LiquidGlass.swift` semantics
   (transparency pref `t∈[-1,1]`: `t≤0` MicaBackdrop ⟷ `t>0` DesktopAcrylicBackdrop + scrim; `reduceTransparency`
   clamps t>0→0; `contentSurfacesEnabled=off`→solid fallback). `liquidGlassSurface/Interactive/CircleButton` →
   Acrylic `Border`/templated control styles; `LiquidGlassGroup`→no-op; reduced-transparency via
   `UISettings.AdvancedEffectsEnabled`. **R7:** Acrylic blurs only the window/desktop backdrop, NOT app content
   behind a card — no content refraction / glass-over-glass / interactive lensing → per-surface parity is
   approximate; gate drift at G3 with a per-surface rubric + macOS goldens + a documented accepted-drift list.
3. **W6-DS-SWARM (30–50 PRs, HIGH risk):** 30 substrates / 6 families (Constellation/Flow/Aurora/Mesh/Moire/
   Volumetric; 24 bespoke) + `SwarmCanvasView` + easter-egg physics + 4 backdrops. **Split: keep
   `SwarmSimulation` (murmuration/shape/glyph-sampling math — parity-critical) in Swift Core, vend a per-frame
   `SwarmSubstrateFrame` snapshot over FFI; reimplement the renderer + 30 painters in C#/Win2D**
   (`CanvasAnimatedControl`, `CanvasBlend.Add` for additive bloom, gradient brushes, `GaussianBlurEffect`).
   **Mandatory sub-spike first:** prove Win2D vs Composition hits **60fps on ARM64** with additive bloom + one
   bespoke substrate before fanning out the other 23.
4. **W6-DS-PRETEXT (8–12 PRs, MED risk R22, blocks all of Chat):** `PretextEngine` is a text-LAYOUT engine (an
   offscreen WKWebView running bundled `pretext.bundle.min.js`, JSON bridge `window.__pretextDispatch` ⟷
   `messageHandlers.pretext`, handle cache, returns geometry: prepare/layout/measureLineStats/…). **Port to
   offscreen WebView2 hosting the SAME bundled JS verbatim** (`WebMessageReceived`+`ExecuteScriptAsync`, mirror
   the ID/ok/value/error protocol). **Risk:** Chromium-vs-WebKit text metrics differ even with the same JS →
   Chat layout drift; mitigate with a committed text corpus + a Mac↔Windows layout-parity test (heights/line
   widths within tolerance) as a required check; pin fonts.
5. **W6-SHELL completion (10–15 PRs):** `NavigationView` app frame (→ macOS `NavigationSplitView`), resizable/
   reorderable flyout, Command Palette (`CommandDeckPalette.swift`; = App Intents substitute), window/DPI chrome,
   theme/appearance plumbing (`ThemeManager`, `AppearanceModePickerView`).

## W7 — surface inventory (every surface, classified)
**Bucket A — high-parallelism/low-risk (fan out):** Shared Components (`Views/Components/*` 37 + in-core
`Unified*` — **land first, everything depends on them**); Settings shell + search index/router (portable) →
`NavigationView`+`SettingsCard/Expander`; the ~40 Settings leaf pages; SessionLogs (list-detail); Onboarding
(17-file wizard→`Frame`/`ContentDialog`); Memory (inbox+consent); Popover/menu-bar surfaces.
**Bucket B — real feature work:** Budget (rule editor + live chips + blocked-card + toast; core product);
Data Control Center (DataGrid + custom Basin-swirl canvas + yours↔server flip + callable hub); Account Switcher;
Elder Wand configurator; Mission Control console (RuntimeConstellation/FABGauge on the particle engine +
Firestore dispatch); Insights (**biggest B item:** 38 in-core chart widgets — Sankey/Funnel/Radar/Heatmap/
Cohort/… + `InsightWidgetRenderer` + template gallery/canvas grid).
**Bucket C — custom-canvas (gated on W6-DS-SWARM + W6-DS-PRETEXT):** Dashboard (5 concept layouts + easter-egg
physics + swarm/constellation/depth/kernel backdrops); Chat (`ChatSessionController` 2100-LOC streaming state
machine → ViewModel; `HermesAtomRouter` → `ItemsRepeater`; StreamingBubble height/shrink-wrap **depends on
Pretext**); Quota (`QuotaArcDial` twin animated rings → Win2D arcs; `SubscriptionConstellationHero` orbs).
**Not Phase 3:** ComputerUse views = W5; SmartHub/Media = W9; PetCompanion = W8.

## Dependency graph + G3 acceptance
`WINUI-017 → W6-DS-TOKENS → W6-DS-GLASS → Shared Components → W6-SHELL`; in parallel `W6-DS-PRETEXT` (blocks
Chat) + `W6-DS-SWARM` spike→24 substrates (blocks Dashboard/Quota/MissionControl canvas). Then Buckets A/B fan
out; Bucket C gated on the two engine seams. **Freeze discipline (R10):** tokens/glass/components/Pretext/Swarm
seams semver-freeze on their 2nd consumer; publish stubs day one.
**Per-surface G3 criteria:** 4 states (empty/loading/error/populated) with goldens; named interactions per
surface; DPI 100–200% + mixed; keyboard-only + UIA/Narrator; ARM64 @60fps for canvas surfaces; theme axes
(light/dark/high-contrast/reduced-transparency + the t∈[-1,1] pref); Windows-native snapshot baseline + a
**manual** design-review checkpoint vs macOS goldens (cross-platform snapshots can't auto-gate — W11 §11.7).

## Effort (for scheduling)
TOKENS 3–5 · GLASS 6–10 · SWARM 30–50 · PRETEXT 8–12 · SHELL 10–15 · Shared-Components 15–25 · Settings 40–60 ·
Onboarding 12–18 · SessionLogs/Memory/Popover 17–26 · Budget 12–18 · DataControlCenter 10–16 · Switcher 8–12 ·
ElderWand 8–12 · MissionControl 15–22 · Insights 40–60 · Dashboard 40–55 · Chat 35–50 · Quota 15–22.
**≈ 370–540 PRs.** Hot-spots that push to the upper end: the SWARM ARM64/fidelity spike + the PRETEXT
metric-parity (both named in master-plan §14).

## Top risks
R7 Liquid-Glass→Mica/Acrylic drift (HIGH, top quality risk) · particle-engine ARM64/60fps + 30-material
fidelity (HIGH) · Pretext WebView2 Chromium-vs-WebKit metric drift (MED, blocks Chat) · cross-platform
snapshots can't auto-gate (manual G3 checkpoint) · R10 false-parallelism if the design-system seams aren't
frozen before W7 fans out.

## Critical files
`AgentLens/Theme/LiquidGlass.swift` · `packages/design-tokens/config.mjs` ·
`OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Substrate/{SwarmSubstrate,SubstrateCatalog}.swift` +
`SwarmCanvasView.swift` · `OpenBurnBarCore/Sources/OpenBurnBarCore/Pretext/PretextEngine.swift` ·
`windows/app/OpenBurnBar.App/Theme/Tokens.xaml` + `OpenBurnBar.App.csproj`.
