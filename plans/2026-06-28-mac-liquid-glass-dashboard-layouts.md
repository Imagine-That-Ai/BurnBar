# Plan — Native macOS dashboard layout concepts (Aurora · Nebula · Constellation · Cockpit · Atelier)

**Surface:** macOS app (AgentLens)
**Scope:** All 5 named layout concepts from the *Liquid Glass Studio* design phase, as selectable dashboard layouts.
**Date:** 2026-06-28
**Status:** ✅ Implemented — all 6 layouts on `feat/mac-dashboard-layout-concepts-20260628`. macOS app builds clean; 9 Core + 9 AgentLens tests pass. Default = Atelier; curated + "more" drawer. Pending: live visual pass + commit/PR (awaiting Alberto).

---

## 1. Why this exists / what's actually missing

The design-phase prototype lives at `~/Downloads/Liquid glass dashboard concepts/` (`Liquid Glass Studio.dc.html`, `HANDOFF.md`). It defined **two** deliverables:

1. **5 named full-dashboard layout concepts** — a top-rail switcher: `Aurora · Nebula · Constellation · Cockpit · Atelier` (`CONCEPTS = [...]`, HTML line 407; Atelier flagged "the keeper — kernel-forward, full-bleed").
2. The §7 **modular** glass-card dashboard (drag/resize grid + wizard).

What landed where (verified):

| Piece | Status | Location |
|---|---|---|
| Kernel WebGL2 backdrop + provider swarm + glass skin | ✅ in Mac app | `KernelBackdropView`, `SwarmCanvasView`, `DashboardBackdrop` |
| §7 **modular** grid dashboard | ✅ web only | `apps/console/app/dashboard` (PR #921, `3da529e2`) |
| **5 named layout concepts** | ❌ never ported anywhere | — (`git grep atelier` → empty) |

False friends in the Mac app: **"Aurora"** = a color *skin* (`AppSkin.aurora`), **"Constellation"** = a *swarm style* toggle. Neither is a layout. The Mac app's only "layout" enum is `DashboardViewMode { agents, models }` — a content toggle. **The named layouts have never existed in a shipping surface.**

## 2. Goal

Add a `DashboardLayout` preference with **6 options** — `classic` (today's overview, retained) + the 5 concepts — selectable via an inline switcher on the overview and a Settings → Appearance row, persisted like the other appearance prefs. Each concept is a responsive SwiftUI composition of glass cards floating over the **already-shared** kernel + swarm backdrop, reusing existing data and card components.

## 3. The native dashboard as it is today (ground truth)

- **Root** (`DashboardView.body`, `AgentLens/Views/Dashboard/DashboardView.swift:148`): `NavigationSplitView { sidebarView } detail: { detailView }` with `.background { DashboardBackdrop(moodBand:) }`. The nav sidebar is **app chrome** (routes), not the prototype's provider sidebar.
- **Backdrop** (`DashboardBackdrop`, `Components/DashboardToolbarAndBackdrop.swift:54`): editorial skin → `WebsiteBackgroundView`; else dynamic → `KernelBackdropView` (WebGL2) + native `SwarmCanvasView`; else static gradient. **This is the always-on kernel+swarm the concepts float over — already done.**
- **Overview** (`overviewView`, `DashboardView.swift:~600`): `ZStack { DashboardDepthBackdrop(); ScrollView { LazyVStack { 3×StatCard grid → liveCostCurveBand → CastleGreatHallContainer → NarrativeCardView → provider/model/activity lanes } } }`. **This becomes the `classic` layout.**
- **Reusable content** (all keepers):
  - Stats: `StatCard` (`Components/DashboardChromeComponents.swift:5`)
  - Cost curve: `DashboardLiveCostCurve` (`Components/DashboardLiveCostCurve.swift:11`)
  - The Wand verdicts: `CastleGreatHallContainer` (`CastleGreatHallView.swift:4`)
  - Cache hit: `CacheHitRateView`
  - Provider / model / activity lanes: `providerLane`/`modelLane`/`activityLane` (`DashboardProviderLaneView.swift:53/92/131`, extension vars on `DashboardView`)
  - Swarm: `SwarmCanvasView` (`OpenBurnBarCore/.../Views/SwarmCanvasView.swift:25`, public)
- **Data** (extension vars on `DashboardView`, `DashboardComputedProperties.swift`): `totalCostForTimeRange`, `totalTokensForTimeRange`, `dashboardUsageWindow.sessionCount`, `dashboardProviderSummaries` (provider + cost; spend-share = cost/total), `activeProviderCount`, `heroSubheadline`.
- **Settings pattern**: `AppearanceSettings` property w/ `didSet` → `persistence.set(...)` + `UserDefaults` + `NotificationCenter.post` (model: `appearanceSkin`, `Stores/AppearanceSettings.swift:108`); `SettingsManager` get/set accessor gated by `appearanceMutationVersion` (`SettingsManager.swift:337`); enum w/ `storageKey`, `displayName`, `CaseIterable` (model: `AppSkin`, `OpenBurnBarCore/.../ThemePrimitives.swift:17`).
- **Glass primitives**: `LiquidGlass.swift` — `liquidGlassEffect(_:in:)`, `liquidGlassSurface(...)`, `LiquidGlassWindowBlend`; `.toolbarPill()`. Build cards on these (no new blur engine).

## 4. Concept → native mapping

Each concept keeps the NavigationSplitView nav sidebar (app chrome) and floats glass over the shared backdrop. "Provider sidebar" in the mockups = a **provider list panel** built from `dashboardProviderSummaries` (not the nav sidebar).

| Concept | Native composition | Backdrop/swarm treatment |
|---|---|---|
| **Aurora** (0) | Left provider-list panel (266) + right hero: transparent swarm stage on top, bottom data band = big Burn card + cost-curve card + stacked Tokens/Sessions | Global backdrop shows through the hero stage |
| **Nebula** (1) bento | Provider panel (244) + right column: top row [Burn card + framed swarm "stage"] / bottom row [Tokens, Sessions, cost-curve] | Stage = clear **reveal window** (bordered glass with transparent center revealing global swarm) |
| **Constellation** (2) | Centered column: search/Hermes bar → full swarm stage (one logo at a time) → 3 stat pills (Burn/Tokens/Sessions) → wrap of provider chips | Full-bleed global backdrop; content centered over it |
| **Cockpit** (3) | Provider panel w/ spend-share bars (296) + right: top row 4 stats (Burn/Tokens/Sessions/**Cache Hit**) → swarm stage w/ TPS + "real-time routing" overlay → bottom [cost-curve + **The Wand** verdicts] | Stage = reveal window |
| **Atelier** (4) *keeper* | Provider panel w/ big logo chips + Pro-plan/quota card + profile footer (284) + right: **full-bleed** swarm behind a hero headline + 3 floating glass stat cards | Full-bleed global backdrop is the hero; cards float on top |

Data dependencies & graceful degradation:
- **Cache Hit** → `CacheHitRateView` ✅.
- **The Wand** → `CastleGreatHallContainer` ✅.
- **TPS** (Cockpit overlay) → no window-level aggregate today; compute `tokens / activeSeconds` from `dashboardUsageWindow`, or omit the chip if unavailable. Non-blocking.
- **Pro-plan/quota card** (Atelier) → reuse `SubscriptionCard`/quota data if cheap; else a simple plan glass card. Optional.
- **Search/Hermes bar** (Constellation) → reuse existing chat/search entry (opens chat panel) rather than a new search surface.

## 5. Architecture

1. **`DashboardLayout` enum** — new, in `OpenBurnBarCore/.../SharedModels/ThemePrimitives.swift` next to `AppSkin` (shared so future iOS/Android parity is free). `String, CaseIterable, Codable, Sendable`; cases `classic, aurora, nebula, constellation, cockpit, atelier`; `storageKey = "dashboardLayout"`; `displayName`; `static var current`.
2. **Persistence** — add `dashboardLayout: DashboardLayout` to `AppearanceSettings` (didSet → persistence + UserDefaults + `NotificationCenter.post(.dashboardLayoutDidChange)`), plus `SettingsManager` accessor gated by `appearanceMutationVersion`. Mirror `appearanceSkin` exactly.
3. **Switcher (inline)** — a 6-segment liquid-glass control at the top of `overviewView` (the prototype's iconic top-rail switcher), bound to `settingsManager.dashboardLayout`. Reuse `.toolbarPill()`/glass styling.
4. **Settings row** — a "Dashboard Layout" picker in `AppearanceCorkboardSection` next to the existing skin picker (discoverability + thumbnails optional via `AppearancePreviewCard`).
5. **Overview dispatch** — refactor `overviewView` to `switch settingsManager.dashboardLayout`: `.classic` → today's body (extracted verbatim into `classicOverview`); each concept → a new view. Empty-state and `DashboardDepthBackdrop` handling preserved.
6. **New layout views** — one file per concept under `AgentLens/Views/Dashboard/Layouts/`: `AuroraLayoutView`, `NebulaLayoutView`, `ConstellationLayoutView`, `CockpitLayoutView`, `AtelierLayoutView`. Each takes a small context struct (data + reusable subviews) so they're testable in isolation and don't balloon `DashboardView`.
7. **Shared building blocks** (`Layouts/Components/`): `DashboardGlassCard` (label + big mono value, on `liquidGlassEffect`), `ProviderListPanel` (rows from `dashboardProviderSummaries`, w/ optional spend-share bar), `SwarmRevealWindow` (bordered glass with clear center revealing the global backdrop — **one** swarm instance, no second GPU canvas), `LayoutSwitcher`.
8. **Responsiveness** — concepts are flex compositions (HStack/VStack/Grid/`ViewThatFits`) that fill available space. Below a min width/height (reuse the existing ~910pt hysteresis pattern from `updateOverviewLaneLayout`), structured concepts fall back to a vertical stack; full-bleed concepts always fit. No brittle absolute insets.

## 6. File-by-file change list

**New**
- `OpenBurnBarCore/.../SharedModels/ThemePrimitives.swift` → add `DashboardLayout` enum (same file as `AppSkin`).
- `AgentLens/Views/Dashboard/Layouts/{Aurora,Nebula,Constellation,Cockpit,Atelier}LayoutView.swift`
- `AgentLens/Views/Dashboard/Layouts/Components/{DashboardGlassCard,ProviderListPanel,SwarmRevealWindow,LayoutSwitcher}.swift`

**Edit**
- `AppearanceSettings.swift` → `dashboardLayout` property + `.dashboardLayoutDidChange` Notification.Name.
- `SettingsManager.swift` → `dashboardLayout` accessor.
- `DashboardView.swift` → extract `classicOverview`; `overviewView` dispatches on layout; mount `LayoutSwitcher`.
- `AppearanceCorkboardSection.swift` → "Dashboard Layout" picker row (builds on current uncommitted edits — rebase, don't clobber).
- `OpenBurnBarCoreTests` + `AgentLensTests/Active` → tests (below).

**Working-tree caution:** you have uncommitted edits to `DashboardDepthBackdrop.swift`, `DashboardToolbarAndBackdrop.swift`, `AppearanceCorkboardSection.swift`, `DashboardToolbarTests.swift`. Work on a branch; layer on top of these.

## 7. Phasing (each phase independently shippable)

- **P1 — Foundation + Atelier (the default):** enum + persistence + accessor + `LayoutSwitcher` + Settings row; `overviewView` dispatch with `classic` = current body; build `DashboardGlassCard`, `ProviderListPanel`, `ConceptMoreDrawer`, and **`AtelierLayoutView`** (since it's the default). The other 4 concepts fall back to `classic` until built. Tests for enum/persistence/dispatch.
- **P2 — Structured concepts:** `AuroraLayoutView`, `NebulaLayoutView`, `CockpitLayoutView` (+ `SwarmRevealWindow`). Reuse StatCard data, curve, cache, wand.
- **P3 — Constellation:** `ConstellationLayoutView` (centered column, search/Hermes bar, full swarm stage, stat pills, provider chips).
- **P4 — Polish:** responsive fallbacks, Reduce Motion/Transparency degradation, editorial (light) skin pass, accessibility labels, analytics (`layout_selected`), snapshot/smoke tests, docs (`docs/` + mem0).

## 8. Testing

- **Unit** (`OpenBurnBarCoreTests`): `DashboardLayout` raw values stable, `current` round-trips via UserDefaults, `displayName` non-empty, `allCases` count = 6.
- **Settings**: persistence round-trip + notification posted on change (mirror existing appearance-store tests).
- **View smoke** (`AgentLensTests/Active`, ViewInspector): each layout view builds with mock data without crashing; switcher renders 6 segments and selection mutates the binding. Coordinate with the in-flight `DashboardToolbarTests.swift` edits.
- **Manual**: `/run` the app, cycle all 6 layouts at large + small window, dark + editorial skin, Reduce Motion + Reduce Transparency on.

## 9. Accessibility & performance

- Glass cards degrade to solid plates under Reduce Transparency (existing pattern); backdrop already honors Reduce Motion.
- **One swarm instance** — concepts reveal the *global* backdrop via `SwarmRevealWindow`; never instantiate a second `SwarmCanvasView`/WebGL canvas (status-item app; GPU budget matters — see `DashboardDepthBackdrop` header note).
- All concept chrome `accessibilityLabel`'d; switcher is keyboard-navigable.

## 10. Product decisions (DECIDED 2026-06-28)

1. **Default layout = `.atelier`.** The store default is Atelier (the handoff's "keeper"); installs with no stored `dashboardLayout` open full-bleed kernel-forward. Because the default is a real concept, **Atelier is built first** (P1) so the out-of-box experience is never a stub.
2. **Curated + "more" drawer.** Concepts render the curated card set AND each gets a scrollable "more" drawer beneath the hero exposing `NarrativeCardView`, `modelLane`, `activityLane` (and update banner) so no information is lost in any layout. A shared `ConceptMoreDrawer` builds this once and every concept embeds it.

## 11. Risks / loopholes

- **Resizable window vs fixed-canvas mockups** — the prototype assumes a fixed large canvas with absolute insets; native windows resize small. Mitigated by flex compositions + min-size fallback. Highest-fidelity risk is Atelier/Constellation hero typography at small widths → cap with `ViewThatFits`/`minimumScaleFactor`.
- **Reveal-window alignment** — a "clear center over the global backdrop" must align with the moving swarm; if the backdrop ever becomes inset/transformed this breaks. Low risk (backdrop is full-bleed at root).
- **TPS / Pro-plan data** may not exist at window granularity → degrade gracefully (omit chip / simple card), don't fabricate.
- **God-file pressure** — `DashboardView.swift` is already 859 lines; keep concepts in `Layouts/` files, pass a context struct, avoid growing the root.
- **Scope realism** — 5 bespoke layouts is large; P1 lands the skeleton + switcher safely, P2–P3 are additive and individually reviewable.

## 12. Out of scope

- Porting the §7 modular drag/resize grid to Mac (already exists in console).
- The glass *tuner dock* (frost/particle-count sliders) — appearance tuning already exists in Settings; not re-creating the dock.
- iOS/Android parity (the shared `DashboardLayout` enum leaves the door open later).
