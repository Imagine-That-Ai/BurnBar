# Dashboard and UI

The macOS app surfaces spend data through three primary UI regions: the menu bar icon, a compact popover, and a full-screen dashboard window. All views consume tokens from `AgentLens/Theme/DesignSystem.swift` — raw hex values are not used in view files.

## UI surfaces

| Surface | File | Width | Notes |
|---|---|---|---|
| Menu bar icon | `AgentLens/App/AppDelegate.swift` | 22 pt icon | Shows live spend or budget-pressure indicator in the menu bar |
| Popover | `AgentLens/Views/Popover/MenuBarPopoverView.swift` | 340 pt | Provider list, quick totals, Hermes strip, action bar |
| Quick-switch popover | `AgentLens/Views/Popover/PopoverQuickSwitchView.swift` | 340 pt | Switches active account / provider context |
| Dashboard window | `AgentLens/Views/Dashboard/DashboardView.swift` | Resizable | Full spend breakdown, per-provider lanes, sessions, projects |
| Settings window | `AgentLens/Views/Settings/SettingsView.swift` | 720×530 | `NavigationSplitView`, 165–190 pt sidebar |
| Mission Console | `AgentLens/Views/Dashboard/MissionConsoleMacHost.swift` | Floating panel | Daemon mission runs and approvals |

## Key view files

### Popover (`AgentLens/Views/Popover/`)

| File | Purpose |
|---|---|
| `MenuBarPopoverView.swift` | Root popover layout: provider rows, totals, Hermes strip, quick actions |
| `HermesPopoverStrip.swift` | Collapsed/expanded Hermes chat strip |
| `HermesPopoverChatView.swift` | Full Hermes chat thread within the popover |
| `MercuryTraySection.swift` | Mercury media tray within the popover |
| `CloudWhisperStrip.swift` | Cloud sync status strip |

### Dashboard (`AgentLens/Views/Dashboard/`)

| File | Purpose |
|---|---|
| `DashboardView.swift` | Root dashboard: sidebar + content area |
| `DashboardUsageViewModel.swift` | `@Observable` view model; aggregates usage across date ranges |
| `DashboardOverviewView.swift` | Top-level summary: total spend, model breakdown, trend sparkline |
| `DashboardProviderLaneView.swift` | Per-provider spend row with quota bar |
| `DashboardProjectSpendLaneView.swift` | Per-project spend breakdown |
| `DashboardCredentialLaneView.swift` | Credential health indicators per provider |
| `SessionDetailView.swift` | Single session drill-down: token timeline, model used, conversation excerpt |
| `ProjectsView.swift` | Projects memory overview with editorial detail sheets |
| `ProviderDashboardView.swift` | Expanded per-provider analytics panel |
| `DatabaseWorkspaceView.swift` | Raw database workspace for power users |
| `MissionsLaneView.swift` | Mission run status and history lane |

### Settings (`AgentLens/Views/Settings/`)

| File | Purpose |
|---|---|
| `SettingsView.swift` | Root `NavigationSplitView` container |
| `GeneralSettingsView.swift` | Refresh interval, launch-at-login, menu bar display |
| `ConnectionsSettingsView.swift` | Provider credential entry for all API-backed providers |
| `BudgetSettingsView.swift` | Monthly spend cap, per-provider budget limits |
| `CloudStoreSettingsView.swift` | Firebase / iCloud sync configuration |
| `ProviderPlanWizardView.swift` | Step-by-step wizard to connect a new provider |
| `DaemonSettingsView.swift` | Daemon process control, socket path, log level |
| `ChatGatewaySettingsView.swift` | Hermes webapi endpoint, model routing configuration |

### Chat (`AgentLens/Views/Chat/`)

Hermes chat panel (full dashboard mode) and Local Index mode chat. Connected to `CLIBridge` (CLI subprocess) or Hermes webapi (`localhost:8642`).

### Computer Use (`AgentLens/Views/ComputerUse/`)

Agent Watch mirror, `ComputerUseApprovalSheet`, trust-mode picker, audit chain panel. See [Computer Use](../features/computer-use.md).

### Insights (`AgentLens/Views/Insights/`)

Editorial Observatory intelligence brief — eyebrow + headline + ordered findings + anomaly atlas + recommendations. See [Usage tracking](../features/usage-tracking.md).

## Design system

All visual constants are defined in `AgentLens/Theme/DesignSystem.swift`. Views must use these tokens; never use raw hex values or hardcoded sizes in view files.

### Typography

SF Pro Rounded (`Font.system(..., design: .rounded)`) throughout. Key tokens:

| Token | Size | Weight | Usage |
|---|---|---|---|
| `display` | 28 pt | Bold | Large cost totals |
| `headline` | 16 pt | Semibold | Card titles, provider names |
| `body` | 14 pt | Regular | Row text, toggle labels |
| `caption` | 12 pt | Medium | Section headers, subtitles |
| `mono` / `monoSmall` | 14/12 pt | Medium | Token counts, cost values |

Section headers always use `caption` (12 pt) + `semibold` + `textSecondary`. Using `tiny` + `textMuted` for headers is a known contrast failure.

### Adaptive colors

Colors adapt to macOS system appearance via `NSColor`'s dynamic provider (implemented in `AgentLens/Theme/ColorAdaptive.swift`). Two palettes:

**Dark — Warm Charcoal** (primary)

| Token | Value |
|---|---|
| `background` | `#0E0D0B` |
| `surface` | `#171510` |
| `textPrimary` | `#F0EBE2` |
| `border` | `#302C22` |

**Light — Botanical Cream**

| Token | Value |
|---|---|
| `background` | `#EDF0E5` |
| `surface` | `#F4F6EE` |
| `textPrimary` | `#1C2014` |
| `border` | `#C5CEB6` |

Brand accents (coral `#E87060` / `#C8604E`, purple `#9080D8` / `#6868B8`, teal `#2CCAC0` / `#1A9A8C`) shift slightly between dark and light. Per-provider mappings live in `AgentLens/Theme/ProviderTheme.swift`.

## Hermes strip (popover)

`AgentLens/Views/Popover/HermesPopoverStrip.swift` implements the collapsible Hermes input strip between the provider list and action bar.

- **Collapsed**: single-line input — caduceus glyph (`☿`) + "Ask Hermes..." placeholder + `mercuryGradient` border with shimmer on hover. Height ~44 pt.
- **Expanded**: strip grows to show a compact chat thread (max ~3 messages). Height up to ~220 pt. "Open in Dashboard →" link at the bottom.
- **Border**: 1 pt `mercuryGradient` (`LinearGradient([hermesMercury, hermesAureate], topLeading → bottomTrailing)`) with a `mercuryShimmer` overlay (3 s `easeInOut` linear sweep).
- **Animation**: `stripExpand` spring (`response: 0.4, dampingFraction: 0.85`).

Mercury color tokens: `hermesMercury` (`#C8BFB5` dark / `#AEA69C` light), `hermesAureate` (`#A2ACBA` dark / `#3F4651` light).

## Computer Use empty state

`AgentLens/Views/ComputerUse/AgentWatchEmptyStateView.swift` — injected into `AgentWatchView` via a generic `Placeholder` parameter. Replaces the former dashed-rectangle placeholder with an editorial onboarding card matching the Editorial Observatory voice:

1. **Hero** — caduceus glyph, "COMPUTER USE" eyebrow, 24 pt headline, phase badge (STANDBY / DIALING / RECONNECTING / LIVE / ERROR).
2. **Setup checklist** — 3 rows (Signed in / Hermes Remote Relay selected / Live session), each with a green check or red dot and a wired CTA pill.
3. **Ordered guide** — 01/02/03 mono ordinals with the active step highlighted.
4. **Capability strip** — 2×2 grid: Live mirror / Tap to drive / Full audit / Panic halt.
5. **Permissions footer** — explains the enablement wizard lives on the Mac.

CTAs wire through `HermesService.connectToSuggestedRelay(refresh:)` and existing `ShowHermesChat` / `ShowSettings` notifications for cross-tab navigation. The legacy red coral pill overlay from `AgentWatchScreen` was removed; the same blocker now reads inline in the checklist.

## Related pages

- [macOS app overview](index.md)
- [Log parsers](parsers.md)
- [Hermes chat](../features/hermes-chat.md)
- [Computer Use](../features/computer-use.md)
- [Usage tracking](../features/usage-tracking.md)
