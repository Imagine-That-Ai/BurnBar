# macOS Dashboard Layout Concepts

The macOS Overview renders in one of six **layout concepts**, selected by the
shared `DashboardLayout` preference. Five are the named concepts from the
*Liquid Glass Studio* design phase; `classic` is the original scroll overview,
retained.

| Layout | Shape | Notes |
|---|---|---|
| `atelier` *(default)* | Full-bleed kernel-forward hero + floating glass stat cards + provider rail | The design phase's "keeper" |
| `aurora` | Provider rail + open swarm field + bottom data band | Signature, balanced |
| `nebula` | Bento: provider rail + burn card + swarm stage + tokens/sessions/curve | Card-dense |
| `constellation` | Centered command column over a full swarm | Calm, search-forward |
| `cockpit` | Spend-share rail + 4 KPI tiles (incl. cache hit) + routing stage + curve + The Wand | Mission control |
| `classic` | Vertical scroll: stat cards → curve → Great Hall → lanes | Information-dense |

## How it's wired

- **Preference** — `DashboardLayout` (`OpenBurnBarCore/.../SharedModels/ThemePrimitives.swift`),
  a `String`/`Codable`/`CaseIterable` enum next to `AppSkin`. Persisted under
  the `dashboardLayout` key in `UserDefaults.standard` (read via
  `DashboardLayout.current`, default `.atelier`) and mirrored through the
  settings coordinator. Stored + observed in `AppearanceSettings.dashboardLayout`
  (posts `.dashboardLayoutDidChange`); surfaced on `SettingsManager.dashboardLayout`.
- **Selection UI** — an inline `DashboardLayoutSwitcher` pinned atop the
  Overview (a top safe-area inset) plus a "Dashboard Layout" picker in
  Settings → Appearance → Theme. Both write the same preference.
- **Dispatch** — `DashboardView.overviewRouteView` switches on the layout. When
  there is no usage data, every layout shows the shared welcome empty state.
- **Layouts** — each concept is a `DashboardView` extension in
  `AgentLens/Views/Dashboard/Layouts/<Name>LayoutView.swift`, so it reaches the
  view's data (`dashboardProviderSummaries`, `liveCostCurveBand`, the lanes)
  without threading state through initializers.
- **Shared building blocks** (`Layouts/Components/` + `Layouts/DashboardConceptComponents.swift`):
  - `ConceptStatTile` — uppercase accent label + big mono value, on `GlassCard`.
  - `ProviderListPanel` — provider rows (logo · name · cost), optional spend-share bar.
  - `SwarmRevealWindow` — a bordered glass stage whose transparent centre reveals
    the **global** kernel + swarm backdrop. Concepts never instantiate a second
    `SwarmCanvasView`/WebGL canvas — there is only ever one swarm instance.
  - `ConceptMoreDrawer` / `conceptMoreDrawer` — the collapsed "more details"
    drawer every concept embeds (narrative + provider/model/activity lanes) so a
    curated concept never loses information relative to Classic.
  - `DashboardLayoutSwitcher` — segmented control that collapses to a menu when
    horizontal space is tight.

The kernel + provider-swarm backdrop itself (`DashboardBackdrop` →
`KernelBackdropView` + `SwarmCanvasView`) is unchanged and shared by every
layout; concepts only compose glass over it.

## Adding a new concept

1. Add a case to `DashboardLayout` (+ `displayName`, `symbolName`,
   `isKernelForward`). Update `DashboardLayoutContractTests`.
2. Add `var <name>Layout: some View` as a `DashboardView` extension under
   `Layouts/`, reusing the shared building blocks and `conceptMoreDrawer`.
3. Add the case to the `switch` in `DashboardView.overviewRouteView`.
4. `xcodegen generate` (the `AgentLens` source glob picks up the new file), then
   build.

## Accessibility & performance

- Glass degrades to solid plates under Reduce Transparency (via `GlassCard` /
  `SwarmRevealWindow`); the backdrop honors Reduce Motion.
- One swarm/WebGL instance only — contained stages are reveal windows, not extra
  canvases (the dashboard is a status-item app; GPU budget is tight).
- Concepts are responsive (wide/narrow branches + `ViewThatFits`); below the
  width threshold structured concepts stack and full-bleed concepts still fit.

## Known gaps

- Cockpit's stage shows the active-provider count and a "real-time routing"
  label; there is no window-level tokens-per-second aggregate, so the
  prototype's TPS figure is intentionally omitted rather than fabricated.
