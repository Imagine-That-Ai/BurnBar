# macOS Dashboard Layouts

The macOS Overview **and Home** render in one of eight **layouts**, selected by
the shared `DashboardLayout` preference. A layout is not a background — it is a
different way of reading the same data, so each one has its own information
density, primary axis, and dominant element.

The enum raw values are opaque storage ids and never change; the names, symbols
and taglines are presentation. That is why `classic` displays as "Ledger" and
`atelier` as "Canvas" — renaming the layouts migrated no preferences on any
platform.

| Layout | Storage id | For | Enforced rule |
|---|---|---|---|
| **Canvas** *(default)* | `atelier` | Ambient, for a second screen | The only layout where the kernel is the subject; at most one plate on screen |
| **Ledger** | `classic` | Every row, in order | No hero — one ordered top-to-bottom scroll, no number is bigger than its neighbours |
| **Focus** | `aurora` | One number, front and centre | Exactly one number above the fold |
| **Bento** | `nebula` | Equal tiles, scan anywhere | No dominant tile — uniform grid, no reading order |
| **Ask** | `constellation` | Ask first, results follow | The ask field is the first and largest element |
| **Cockpit** | `cockpit` | Instruments and alarm states | The only layout with gauges |
| **Stream** | `stream` | What happened, newest first | Every row is anchored to a timestamp |
| **Atlas** | `atlas` | Side by side, with deltas | Every row carries a comparison |

The "enforced rule" column is the design constraint that keeps the layouts from
converging back into the same tile grid. Before adding an element to a layout,
check it against that layout's rule.

## How it's wired

- **Preference** — `DashboardLayout`
  (`OpenBurnBarCore/.../SharedModels/ThemePrimitives.swift`), a
  `String`/`Codable`/`CaseIterable` enum next to `AppSkin`. Persisted under the
  `dashboardLayout` key in `UserDefaults.standard` (read via
  `DashboardLayout.current`, default `.atelier`) and mirrored through the
  settings coordinator. Stored + observed in `AppearanceSettings.dashboardLayout`
  (posts `.dashboardLayoutDidChange`); surfaced on
  `SettingsManager.dashboardLayout`.
- **Mirrors** — the ids are duplicated in
  [apps/linux-desktop/src/dashboard/dashboardLayout.ts](../apps/linux-desktop/src/dashboard/dashboardLayout.ts)
  and
  [windows/app/OpenBurnBar.App.Dashboard/Layout/DashboardLayout.cs](../windows/app/OpenBurnBar.App.Dashboard/Layout/DashboardLayout.cs)
  so a synced preference never falls back to the default on another platform.
  Both mirror ids and labels only; the compositions are macOS-side. Each mirror
  has a test pinning the id order and the display names against Swift.
- **Selection UI** — a `DashboardLayoutSwitcher` pinned atop the Overview and a
  "Dashboard Layout" picker in Settings → Appearance → Theme. The switcher is a
  compact glass pill that opens a **preview gallery** popover: a vector
  wireframe thumbnail per layout with its name and tagline, arrow-key
  navigable. Eight layouts do not fit in a segmented control, and a wireframe
  answers "what will this look like" better than a word does.
- **Dispatch** — `DashboardView.overviewRouteView` switches on the layout. When
  there is no usage data, every layout shows the shared welcome empty state.
- **Layouts** — each is a `DashboardView` extension in
  `AgentLens/Views/Dashboard/Layouts/<Name>LayoutView.swift`, so it reaches the
  view's data (`dashboardProviderSummaries`, `dashboardUsageWindow`, the lanes)
  without threading state through initializers. Ledger's content lives in
  `LedgerLayoutView.swift` but renders through `overviewView`, which keeps the
  scroll probe and analytics wiring the classic route already owned.

## Home shells

The layout governs Home as well, because Home is where most sessions actually
live: a picker that only restyled Overview was a backdrop picker wearing a
layout's name. Each layout keeps its thesis on Home, expressed against **inbox
items** instead of spend.

| Layout | Home shell | What Home becomes |
|---|---|---|
| **Ledger** | `ledger` | `InboxView` — the dense list, with the Reader/Triage/Board switcher |
| **Focus** | `focus` | The single item that needs you, at headline size, plus a one-line queue |
| **Bento** | `bento` | `InboxPriorityBoard` — equal-weight cards in urgent/today/later columns |
| **Ask** | `ask` | A question box first; prompts derived from the live inbox; items as context |
| **Cockpit** | `cockpit` | Attention-load / unread / fleet gauges over an alarm panel and queue |
| **Canvas** | `canvas` | An editorial headline, one sentence, three quiet lines. No plates competing |
| **Stream** | `stream` | A timestamped river grouped by day, newest first |
| **Atlas** | `atlas` | Needs-you against everything else, with the split and per-kind ladder |

- **Mapping** — `DashboardHomeComposition.resolve(layout:)` in
  `AgentLens/Views/Dashboard/Home/DashboardHomeComposition.swift`. Pure, so the
  contract is testable without mounting a window:
  `DashboardHomeCompositionTests` pins the mapping, asserts no two layouts
  collapse onto the same shell, and asserts the Reader/Triage/Board switcher only
  appears where its options change something.
- **Data** — every bespoke shell reads one `HomeInboxDigest`, the single
  definition of urgent/today/later, the lead item, the ratios, the per-kind
  ranking, and the day grouping. Four shells deriving "urgent" four ways is how
  dashboards start disagreeing with themselves.
- **Views** — `DashboardHomeShells.swift`. Containers are `DashboardSection`, ink
  is passed in rather than read from the environment, and empty is a designed
  state in each shell's own voice.
- **Rail** — `prefersRail` is a default, not a lock. Rail-forward shells read
  `dashboard.home.rail.collapsed`; the ambient shells (Focus, Ask, Canvas) read
  `dashboard.home.rail.ambientOptIn`, so hiding the rail on Ledger does not hide
  it on Cockpit. The header button and ⌘⌥R both go through
  `DashboardHomeComposition.toggleRail(in:)` so they cannot disagree about which
  key they write.
- **No route change on switch** — selecting a layout does not navigate. Home and
  Overview both re-render themselves through the preference.

## Shared building blocks

In `Layouts/Components/` and `Layouts/DashboardConceptComponents.swift`:

- **`DashboardSection`** — the single container primitive. A legible plate, a
  hairline edge, an optional eyebrow label and accessory, and one consistent
  gutter, with `density` (`compact`/`regular`/`roomy`) and `emphasis`
  (`quiet`/`standard`/`featured`) axes. Every layout containerizes through this
  rather than hand-rolling glass cards, which is what keeps eight layouts from
  reading as eight different card mosaics. `DashboardSectionMetric`,
  `DashboardSectionValue` and `DashboardSectionRule` are its interior parts.
- **`DashboardRankedRow` / `DashboardRankedTable`** — rank, logo, title,
  subtitle, value, share bar and optional delta chip. Used by Ledger, Cockpit,
  Ask and Atlas so a ranked list looks identical everywhere it appears.
  `DashboardDeltaChip` renders a signed percentage.
- **`CockpitGauge` / `CockpitAlarmRow`** — a 240° arc gauge with a redline, and
  a stateful alarm row. Deliberately scoped to Cockpit; that is the layout's
  enforced rule.
- **`conceptCanvas`** — the shared scroll scaffold, so every layout gets the
  same safe-area insets and max-width behaviour.
- **`SwarmRevealWindow`** — a bordered glass stage whose transparent centre
  reveals the **global** kernel + swarm backdrop. Layouts never instantiate a
  second `SwarmCanvasView`/WebGL canvas — there is only ever one swarm instance.
- **`conceptMoreDrawer` / `conceptDetailsDrawer`** — the collapsed drawer a
  curated layout embeds so it never loses information relative to Ledger.

The kernel + provider-swarm backdrop (`DashboardBackdrop` →
`KernelBackdropView` + `SwarmCanvasView`) is shared by every layout; layouts
only compose over it.

## Chrome: the command deck

The two top bars are one merged glass body, not two stacked pills. The command
deck and the status rail sit inside a single `LiquidGlassGroup` so sibling glass
merges into continuous specular edges.

- **Height** — the deck defaults to 72pt
  (`@AppStorage("dashboard.commandDeck.height")`, clamped 60...116) and the rail
  to 40pt (clamped 36...64). A single drag handle at the bottom of the merged
  body resizes both proportionally, and interior sizes scale with it rather than
  being clipped.
- **Surface** — `BackdropChromePlate` puts a legible plate *under* the glass so
  the glass has something to refract, then adds a specular top hairline and a
  soft downward shadow. It honors `LiquidGlassTransparency`, so the Clear/Frost
  preference reaches the chrome.

## Legibility contract

Glass refracts; it does not darken. Everything above rests on three rules, each
pinned by a test:

1. **Ink follows appearance.** `BackdropReadabilityProfile.nativeFallback`
   respects `colorScheme` when a live backdrop is active but no sampled profile
   exists. Before, any live backdrop returned the dark-canvas profile, which put
   white ink on a bright kernel in light mode.
2. **A live field is always veiled.** `reinforcingScrim` floors a live
   backdrop's scrim at the darkest static canvas's opacity, in both appearances.
   Editorial is exempt and that is correct — its "live" backdrop is paper with a
   slow transparent swarm, not a WebGL kernel, so `nativeFallback` answers
   Editorial before it consults the backdrop flag.
3. **`textMuted` is for hairlines only.** It cannot clear 4.5:1 even on the
   app's own `surface`, which `BackdropLegiblePlateTests` asserts directly. Body
   and eyebrow copy in the chrome and in every section uses a `BackdropInk` role
   instead.

`DashboardLayoutMatrixTests` walks appearance × skin × live-backdrop and asserts
every layout composes and resolves the expected ink family and scrim. It is
structural rather than pixel-based on purpose: `ImageRenderer` cannot compile
Metal shaders headlessly, so a snapshot of a glass surface renders blank and
would assert nothing.

## Adding a new layout

1. Add a case to `DashboardLayout` with a `displayName`, `tagline`,
   `symbolName`, and `isKernelForward`. Keep the raw value opaque and stable.
2. Add a `ThemeGlassPalette` identity — `ThemeGlassPaletteTests` asserts one
   distinct sidebar identity per layout.
3. Update `DashboardLayoutContractTests` (case set, raw values, display names)
   and mirror the id into the Linux TS and Windows C# enums plus their tests.
4. Add `var <name>Layout: some View` as a `DashboardView` extension under
   `Layouts/`, composing through `DashboardSection` and `conceptCanvas`.
5. Add the case to the `switch` in `DashboardView.overviewRouteView`, and to the
   Windows `KernelForLayout`/`CreateLayoutView`/`FamilyFor` switches.
6. Write down the layout's enforced rule in the table above. A layout without a
   rule drifts into being a copy of Bento.
7. `xcodegen generate` (the `AgentLens` source glob picks up the new file), then
   build.

## Accessibility & performance

- Glass degrades to solid plates under Reduce Transparency (via
  `DashboardSection` / `SwarmRevealWindow` / `BackdropChromePlate`); the backdrop
  honors Reduce Motion.
- One swarm/WebGL instance only — contained stages are reveal windows, not extra
  canvases (the dashboard is a status-item app; GPU budget is tight).
- Layouts are responsive (wide/narrow branches + `ViewThatFits`); below the
  width threshold structured layouts stack and full-bleed layouts still fit.
- The switcher gallery is arrow-key navigable with `Return`/`Space` to select
  and `Escape` to dismiss.
- The deck resize handle keeps its `accessibilityAdjustableAction`
  increment/decrement behaviour, so height is adjustable without dragging.

## Known gaps

- Cockpit's routing band shows the active-provider count and a "real-time
  routing" label; there is no window-level tokens-per-second aggregate, so the
  prototype's TPS figure is intentionally omitted rather than fabricated.
- Cockpit's budget-pace gauge derives from today's spend against the rolling
  7-day average rather than a configured budget, because a per-window budget
  target is not yet part of `DashboardUsageWindowSummary`.
- Windows maps `stream` and `atlas` to existing compositions so a synced
  preference renders something sensible; the native Windows layouts for those two
  ids are not built yet.
