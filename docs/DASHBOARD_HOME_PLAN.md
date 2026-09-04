# Dashboard Home — Inbox-First Launch Surface

**Date:** 2026-08-16 · **Status:** **implemented 2026-08-17** — builds clean, 64 tests green. Stage 3 (a real `awaitingUser`) remains out of scope, as planned.
**Follows from:** [PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md](PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md) — the AI Inbox is the surface where watch / remember / route become a decision, so it becomes the front door.

---

## Context

BurnBar opens on `.overview` today — a spend dashboard rendered through one of six layout concepts. That makes the product read as a meter. The inbox is the only surface that converts the system's signals into a next move, so it should be what the app opens on, with the fleet and quota state readable beside it without leaving the screen.

**Layout:** AI Inbox fills the main area. A right-hand rail is split by a draggable horizontal divider — live agent fleet above, quota below. Both the rail and each panel are resizable, collapsible, reorderable, and every region has multiple persisted view modes.

**Decisions taken (2026-08-16):**

| Decision | Choice |
|---|---|
| Scope | **Replace** the launch destination |
| Empty inbox | **Celebrate + today's brief** |
| Side panel | **Resizable + collapsible**, persisted |
| Fleet data | **Stage 1 + Stage 2** — ship the FSEvents watchers so external CLI agents are genuinely live |
| View modes | **Full set including** the inbox priority board |

---

## 1. The honesty problem, and the model that solves it

This is the most important section. **No live agent-fleet view exists today**, and the available data is thinner than the phrase "live fleet" implies.

- `AgentPresenceModel` ([DashboardChatWorkspaceToolbar.swift:287](../AgentLens/Views/Chat/DashboardChatWorkspaceToolbar.swift#L287)) is instant and has 8 states, but `controllers` is `workspace.allLeaves.map(\.controller)` — **only chat panes inside this app.** A Claude Code in Terminal is invisible.
- **"Waiting on you" does not exist anywhere in the codebase.** The only thing wearing the name, `MissionConsoleActiveTile.Phase.awaitingApproval`, sits behind an approve action that is a **no-op posting a success toast** ([MissionConsoleMacHost.swift:363](../AgentLens/Views/Dashboard/MissionConsoleMacHost.swift#L363)).
- `MissionConsoleActiveTile` also has a hardcoded `progressFraction` (`.running→0.35`), an always-nil `currentToolName`, and a `startedAt` that is really `mission.updatedAt`. **Do not build the panel on it.**
- The App Store build cannot see external agents at all — `OpenBurnBarMAS.entitlements` sandboxes with `files.user-selected.read-only`, while `OpenBurnBar.entitlements` disables the sandbox and names `~/.claude/projects/` explicitly.

### The two-axis model

Collapsing liveness into one enum is how a panel ends up printing "idle" for an agent it never watched. Split it:

```swift
enum FleetEvidenceSource {
    case appChatController, statuslineSnapshot,
         sessionLogWrite(String), processLatch(String), parsedUsageRow
}

enum FleetLiveness {
    case workingHere(AgentPresence, location: String?)  // ONLY source allowed to say "running"
    case wroteRecently(at: Date, source: FleetEvidenceSource)
    case quietSince(Date, source: FleetEvidenceSource)
    case standingBy
    case blocked(AgentPresence)
    case unobservable(reason: String)                    // the honest default
}
```

**Three deliberate absences — these are the design:**

1. **There is no `.idle`.** The word never appears in the panel, at any stage.
2. **`.running` is reachable only via `.workingHere`**, fed only by in-app chat panes.
3. **There is no `.awaitingUser`.** It cannot be synthesized.

The inference, to be stated in code and in the UI: *a write at time T is evidence the agent was active at T. Absence of writes is **not** evidence of idleness* — the agent may be thinking, blocked on a tool, or sitting on a permission prompt, all of which write nothing. Hence "quiet 6m", never "idle".

**Staleness ladder:** `activeWindow = 90s` → "wrote 12s ago" (filled dot, pulse under 15s) · `recentWindow = 15min` → "quiet 6m" (hollow) · beyond → timestamp, muted.

**Footer honesty line, non-negotiable** — one 11pt line naming the evidence floor: *"In-app turns live · external agents watched live"*, or after wake, *"Not watched while asleep"*. This is the `docs/PROVIDERS.md` exact/estimated/unavailable discipline applied to liveness.

---

## 2. Route: a new `.home` case

**New case, not a re-composition of `.inbox`.** Three reasons:

1. **Deep-link asymmetry.** `DashboardRoute.inbox(itemID:)` fires from notification taps ([NavigationCoordinator.swift:46](../AgentLens/Services/NavigationCoordinator.swift#L46)). Someone tapping "your CI is burning money" wants the focused inbox on that item, not a home whose 320pt rail eats the reading pane.
2. **Root semantics.** `canGoBack` is `!routeHistory.isEmpty || mainRoute != .overview`. The launch surface must *be* the root or the back button lies.
3. `.id(mainRoute)` gives identity for free; one case rendering two shapes creates a state `routeHistory` can't record.

**`.home` stays OUT of `primarySections`** — same reason `.controlDeck` does. That array is positional and drives ⌘1–⌘8; inserting at index 0 shifts Inbox→⌘2 and pushes `.memoryReview` off the end. The tests at `DashboardViewIntegrationTests.swift:95` and `:103` are the regression fence — **leave them untouched.**

Reachability instead: **⌘⇧H** (verified free), **the app logo becomes the Home button** (`AppLogoView` at [DashboardToolbarContent.swift:175](../AgentLens/Views/Dashboard/DashboardToolbarContent.swift#L175) is already 44pt of dead pixels, and costs zero width — the deck strip is `.fixedSize(horizontal:)` and a 7th button would push past 1040pt), the section switcher, and the command palette.

**Launch default:** change `@State var mainRoute` at [DashboardView.swift:42](../AgentLens/Views/Dashboard/DashboardView.swift#L42) from `.overview` to `.home`. **No last-route persistence** — the route isn't persisted today, `DashboardMainRoute` has associated values so it isn't `RawRepresentable`, `@SceneStorage` is unavailable (the window is an AppKit `NSWindow`), and "restore last route" would defeat the whole point. Instead add `AppearanceSettings.dashboardLaunchSurface` (`.home` / `.overview`) as the honest opt-out.

---

## 3. Layout

```
DashboardHomeView
└── GeometryReader                        // ONE measurement drives every breakpoint
    └── VStack(spacing: 0)
        ├── homeHeaderStrip               // ~30pt: inbox mode switcher + rail toggle
        └── HStack(spacing: 0)
            ├── inboxRegion               // .frame(maxWidth: .infinity)
            ├── ResizableSectionDivider(axis: .vertical)     // 7pt — drags rail WIDTH
            └── DashboardHomeRail.frame(width: resolvedRailWidth)
                └── ForEach(orderedPanels) { panel in
                        panelHeader(panel)                    // eyebrow + switcher + chevron
                        panelBody(panel).frame(height: resolvedHeight(...))
                        ResizableSectionDivider(axis: .horizontal)  // 7pt — drags FRACTION
                    }
```

Not a `NavigationSplitView` — `InboxView` is already a hand-rolled `HStack`, and the shell is already inside one split view. Three column systems is one too many.

**Persisted dimensions:**

| Key | Default | Clamp |
|---|---|---|
| `dashboard.home.rail.width` | 320 | 280…460 |
| `dashboard.home.rail.splitFraction` | 0.58 | 0.25…0.78 |
| `dashboard.home.rail.collapsed` | false | — |
| `dashboard.home.rail.panelOrder` | `fleet,quota` | normalized ∩ available |
| `dashboard.home.rail.panelState` | `{}` | JSON `{collapsed, fraction?}` |

**Fraction, not absolute height** — this overrides the popover precedent deliberately. The popover stores absolute section heights, which works only because its own height is user-fixed and clamped. The dashboard window resizes freely: an absolute 400pt fleet panel becomes the entire rail at the 650pt window minimum and quota vanishes. `PaneSplitContainer` uses a fraction for exactly this reason.

At the 820pt preferred height, detail ≈ 624pt → 0.58 gives 362pt fleet / 255pt quota (five ~46pt quota rows plus a header). At the 650pt minimum, the 0.25 floor yields ~112pt — a header plus two rows, honest. Below the clamps panels **collapse**, they don't squeeze.

### Width breakpoints — dead bands, not thresholds

At the 1040pt window minimum with the rail at 320 + 7pt divider, the inbox gets 709pt, so `listPaneWidth(forTotalWidth: 709)` hits its 260pt floor and the inbox detail pane is 448pt. Usable — but the rail must be what yields further.

| Band | Enter | Rail |
|---|---|---|
| wide | > 1180 | stored width, 280…460 |
| medium | 1000 < w ≤ 1180 | clamped at render to `min(stored, 300)` |
| narrow | < 980 | auto-collapse to the 28pt stub |
| *hold* | 980…1000, 1160…1180 | keep current band |

Two details that matter: **the medium clamp must not mutate storage** (so widening restores the user's 460), and **the narrow auto-collapse must not write `rail.collapsed`** — model it as `effectiveRailVisible = userWantsRail && band != .narrow`, the same separation `resolvedSidebarVisibility` keeps. An automatic collapse must never be mistaken for intent.

**Collapsed ≠ blind.** The 28pt stub shows the fleet count and `ProviderQuotaChip(style: .compact)`, which self-hides when there's no signal.

---

## 4. View modes

Copy the **`QuotaViewMode`** template (plain `String` enum + `@AppStorage`), **not** `DashboardLayout` — the latter's `SettingsManager` round-trip and `NotificationCenter` post exist only because `DashboardLayout.current` is read from non-SwiftUI color resolvers. Nothing here is.

**Inbox** — `dashboard.home.inbox.mode`, default `.reader`
- `.reader` — today's `InboxView` list+detail. Zero cost.
- `.triage` — list-only, full width. ~8 lines (one additive `paneStyle` property). Earns its place: at the narrow band the detail pane is only ~448pt, and triage is the right shape for clearing 30 items. **Opening an item navigates to `.inbox`** rather than presenting a sheet — precisely why `.inbox` stayed a separate route.
- `.board` — P0/P1 · P2 · P3+ columns. **The only substantial new rendering code in the plan.** Build cards from `InboxRowView`'s lighter parts, *not* `InboxRowView` itself, which carries a 12-field `InboxRowActions` and drag-and-drop. `InboxModel.sections` and `InboxPresentation` already supply the grouping and the icon/tint vocabulary.

**Quota** — `dashboard.home.quota.mode`, default `.bars`. All four are **pure assembly, zero new rendering code**:

| Mode | Component | Height/provider |
|---|---|---|
| `.bars` | `QuotaPrimaryBar` in the popover's row | ~46pt |
| `.windows` | `QuotaDualWindowStrip` | ~60pt — the only compact view showing 5h **and** 7d |
| `.dials` | `QuotaArcDial(diameter: 96)` in an adaptive grid | 2/row at 320pt |
| `.chips` | `ProviderQuotaChip(style: .full)` | ~22pt — the only mode still true below ~110pt |

Do **not** reuse `QuotaViewMode` itself — its `.cards` is `SubscriptionCard`, sized for the full-width workspace, and sharing the key `quotaTab.viewMode` would make a rail change silently reconfigure the Quota page.

**Fleet** — `dashboard.home.fleet.mode`, default `.rows`
- `.rows` — dot · mark · name · "project · evidence phrase" · relative time. ~44pt/row, cap 6 with a "+N" overflow chip.
- `.strip` — `AgentGhostRow` geometry, no text, ~34pt. Says the least, so it cannot lie. **This is also what collapse collapses to** — never to nothing.
- `.timeline` — 60-minute lane, one row per provider, a tick per observed write. Gated out of `availableCases` until watchers are armed (the `OnboardingWizardStep.availableCases` precedent). **Unwatched intervals — sleep windows, MAS — render as a hatched band, not empty space.** Empty space reads as "nothing happened", which is the lie.

**Switcher:** generalize `DashboardLayoutSwitcher` into `GlassSegmentedSwitcher<Option>`, keeping `DashboardLayoutSwitcher` as a thin wrapper so `DashboardLayoutShelf` and the `dashboard.layoutSwitcher` a11y id don't move. Use `labelStyle: .iconOnly` in the rail — 320pt cannot afford the word "Constellation". **View modes get no keyboard shortcuts** — three more collisions to police for a preference set once.

---

## 5. Fleet implementation (Stage 1 + Stage 2)

**Stage 0 — prerequisite (~30 lines).** `AgentPresenceModel.refresh` is called from exactly one place: `AgentSigil.task(id: presenceRefreshKey)`. On a home with no chat pane on screen, **presence is never recomputed.** Extract `presenceRefreshKey` + `refreshPresence` into a shared `AgentPresenceDriver` both call. Do not duplicate the key — an input missing from it is an input the dot never reacts to.

**Stage 1** — merge three existing sources: `AgentPresenceModel` → `.workingHere`; latest `TokenUsage` per provider (which *does* cover external CLIs, bounded by the 60s scan) → `.wroteRecently` / `.quietSince`; `AgentPresenceFacts` → `.blocked`. Everything else → `.unobservable`.

**Stage 2 — FSEvents watchers.**

- **Paths come from the generated catalog**, not hardcoded: `AgentProviderIngestionCatalog.entries` carries `macOSLogicalPath` + `filePattern` for all 37 providers, expanded by `AgentProviderLogDiscovery.resolveLogSource(for:)`. A second hardcoded list would drift from `contracts/provider-ingestion-catalog.json` within a release.
- **Choose the mechanism by shape.** Single fixed file (Claude statusline, Junie's `processes/*.json`) → keep `DispatchSource`. Directory trees (`~/.claude/projects/**`, `~/.codex/sessions/**`) → **FSEvents**: `makeFileSystemObjectSource` needs one FD per node and does not recurse, and `~/.claude/projects` can be hundreds of dirs. **The pattern is already in-repo** — `BurnBarProjectCodeMemoryStore.makeFileSystemEventStream(root:queue:watcher:)` at [BurnBarProjectCodeMemoryStore+ProjectWatching.swift:209](../OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+ProjectWatching.swift#L209), including the retained-`info` context and the invalidate-then-release teardown ordering. Lift it into a shared `FileTreeEventStream`.
- **Two changes from the daemon's flags:** latency `1.0` not `0.2` (kernel coalescing is the biggest battery lever), and **drop `kFSEventStreamCreateFlagNoDefer`** — it fires the first event in a burst immediately, which is right for a reindexer and wrong here. Keep `FileEvents` for per-file paths.
- **Never open or read the file.** Path + mtime via `URLResourceValues` is the entire honesty budget. Seed initial values from existing parsed `TokenUsage` rows, not a directory walk.
- **Arm only** providers enabled in settings whose resolved dir exists — realistically 3–6 streams.
- **On display sleep, tear the streams down entirely.** A stream that survives sleep wakes the process on every write from a CLI running with the lid closed — strictly worse than the 60s poll it replaced. Register with `BackgroundCadenceCoordinator`, which already models sleep/wake; do not add a second observer. **On wake, re-arm with `kFSEventStreamEventIdSinceNow` and mark every external row `.unobservable("not watched while asleep")`** until fresh evidence arrives.
- `#if DISTRIBUTION_MAS`: never arm; all external rows `.unobservable("App Store build cannot read agent logs")`.
- **Junie is the one special case** — `~/.junie/processes/*.json` are genuine process latches, the only external provider where file *existence* is a liveness claim. Verify the semantics (deleted on clean exit? stale after crash?) before treating it as such.

**`AgentPresenceDot` is not backdrop-safe as written** — its `.offline`/`.notInstalled` branch returns `DesignSystem.Colors.textMuted` ([:635](../AgentLens/Views/Chat/DashboardChatWorkspaceToolbar.swift#L635)), the 3.77:1 token that `BackdropLegiblePlateTests.testInactiveDotTintClearsNonTextContrast` already pins as a failure. Add an `inactiveTint` parameter and pass `backdropInk.icon`.

---

## 6. Empty state

Trigger: `visibleRows.isEmpty && filter == .active && hasEverRun`. `InboxEmptyState` (reusing its existing "Nothing needs you" copy verbatim) above a hairline, then `InboxSectionLabel("TODAY'S BRIEF")` and `IntelligenceBriefView(result:snapshotMode: true)`.

**Two corrections to the obvious approach:**

1. **`IntelligenceBriefView` cannot be dropped in as-is.** It takes an `InsightAnalysisResult`, and the only producer in the app is `InsightsMacEnvironment`, whose `init` builds an on-disk canvas store, an audit log, an analysis cache, a model catalog, and fires `loadInitialCanvases()`. Never construct that from the home. **The free path:** `RuleBasedInsightAnalysisEngine` is a pure, deterministic, offline `struct` — no network, no keys, no audit log, no privacy question. Build the brief locally from `MacInsightDataSource` + `InsightAggregator`, cached in a `.task(id:)` keyed on `dataStore.usagesVersion` + the calendar day. `snapshotMode: true` is required (it replaces the brief's own `ScrollView` with a plain stack). `maxGeneratedWidgets: 3` — a calm celebration should not be six screens of scroll.
2. **`InboxEmptyState` needs two small fixes**: it ends with a greedy `.frame(maxHeight: .infinity)` that must be bounded inside a scrolling stack, and it reads `DesignSystem.Colors.textPrimary/.textSecondary` directly — add an optional `ink: BackdropInk?` defaulting to `nil` so the existing `.inbox` route is untouched.

**Cut from scope:** `BurnBarInboxPlanStep.nextMoveMarkdown` is *not* the free win it looked like. It's modeled and daemon-written, but the Mac read path (`ControlPlaneStore+AIInbox.swift`) has **no plan-step accessor at all** — surfacing it needs a new query plus a new `InboxModel` closure.

---

## 7. Auto-refresh

`InboxView`'s only load is a one-shot `.task` — **the open list never auto-refreshes today.** `InboxModel.load()` short-circuits on an unchanged marker, so a repeated call is one aggregate query.

Reuse `DashboardView.inboxBadgeRefreshNotification`, already posted on the shared cadence and already paused during display sleep, with `ControlDeckView` as an existing second consumer. Attach it on the **home's** inbox region via an additive, defaulted `refreshNotification: Notification.Name?` — not inside `InboxView`'s body, because `InboxView` copies the model into `@State` deliberately and because changing it unconditionally would alter the focused `.inbox` route too. Use `load()`, **not** `load(force: true)` — forcing defeats the marker and re-sorts the list under the user's cursor.

**Quota:** follow `ProviderQuotaChip`, not `QuotaWorkspaceViewModel`. Hold `ProviderQuotaService.shared` and let `@Observable` drive redraw, plus one `.task { await refreshIfNeeded(dataStore:) }`. The workspace view model needs six `.onChange` triggers to stay alive and recomputes a 30-day spend map per rebuild.

---

## 8. File manifest

**Create — `AgentLens/Views/Dashboard/Home/`**: `DashboardHomeView.swift` (shell, hysteresis, storage, empty state) · `DashboardHomeRail.swift` (panel order, state codec, reorder controls) · `DashboardHomeQuotaPanel.swift` (four modes) · `DashboardHomeModes.swift` (enums + keys) · `DashboardHomeBrief.swift` · `InboxPriorityBoard.swift`

**Create — `AgentLens/Services/Fleet/`**: `FleetLiveness.swift` (pure values + resolver, no SwiftUI) · `LiveFleetModel.swift` · `ProviderSessionActivityWatcher.swift` · `FileTreeEventStream.swift`

**Create — `AgentLens/Views/Dashboard/Fleet/`**: `LiveAgentFleetPanel.swift` · `FleetRowsView.swift` · `FleetStripView.swift` · `FleetTimelineView.swift`

**Create — shared**: `AgentLens/Views/Components/ResizableSectionDivider.swift` (promoted from `MenuBarPopoverView`'s private `ResizableTraySectionDivider`, plus an `axis`, unified on `NSCursor.set()` + an `.onDisappear` guard — the home rail *can* vanish mid-hover, and an unbalanced `pop()` leaves a stuck cursor) · `AgentLens/Views/Components/GlassSegmentedSwitcher.swift`

**Modify**: `DashboardNavigationModel.swift` (`case home` + 4 exhaustive switches) · `DashboardView.swift` (default route, sidebar predicate, `goBack`/`canGoBack`/`backButtonHelpText`, `detailView`, shortcuts, and **extract `InboxModel(...)` into a shared `makeInboxModel()`** so home and the focused route can't fork the 9 closures) · `DashboardDetailView.swift` (legacy switch is non-defaulted — a new case forces an edit even though the file has zero call sites) · `NavigationCoordinator.swift` · `DashboardToolbarContent.swift` (logo → Home; `quickAccessRoute` `case "home"`) · `DashboardSectionSwitcher.swift` · `CommandDeckPalette.swift` · `InboxView.swift` (three additive defaulted changes) · `MenuBarPopoverView.swift` (use the promoted divider) · `DashboardLayoutSwitcher.swift` (become a wrapper) · `AccessibilityIdentifiers.swift` · `AppearanceSettings.swift` · `docs/PROVIDERS.md` (**add a liveness column**: watched / scan-only / unavailable) · `OpenBurnBar.xcodeproj` (**regenerate — it's committed**)

---

## 9. Tests

**New:** `DashboardHomeRouteTests` (home not in `primarySections`, `primarySectionIndex == nil`, count still 8; metadata; quick-access round-trip; no provider sidebar) · `DashboardHomeLayoutTests` (**every layout rule a `static func`** so it's testable without mounting — hysteresis at 970/990/1010/1170/1200, clamps, medium band not mutating storage, panel-order normalization, JSON round-trip incl. corrupt input, and the composition check that `listPaneWidth(forTotalWidth: 1036 - 320 - 7) == 260`) · `DashboardHomeModeSettingsTests` · `FleetLivenessResolverTests` (**assert the negative invariants explicitly, because they are the product**: no input yields "running" without an in-app controller; no input yields "idle" at all; missing evidence yields `.unobservable`, never `.quietSince`) · `LiveFleetModelTests` · `ProviderSessionActivityWatcherTests`

**FS-watch determinism is already solved in-repo** — copy `ClaudeStatuslineWatcherTests`' harness: per-test temp dir with `tearDownWithError` cleanup, `Configuration` injection for debounce/backoff, and poll-until-deadline loops instead of fixed sleeps. **Inject the clock** so every classification test runs on fixed dates with zero sleeping. Pin the two lessons that watcher already learned: atomic rename-replace re-arm, and no busy-loop when the directory is absent. Expose `handleWillSleep()` / `handleDidWake()` as callable methods and assert post-wake rows are `.unobservable`.

**Update:** `DashboardViewIntegrationTests` — `:43` → `.home`, `:51`, `:56` → "Back to Home", `:79` add `.home`. **Leave `:95` and `:103` untouched** — the ⌘1–⌘8 fence.

**Must stay green:** `ChartsRouteTests`, `DashboardLayoutSettingsTests`, `DashboardToolbarTests`, `InboxModelTests`, `InboxManagementTests`, `InboxShelfTests`, `AIInboxViewFormattingTests`, `AIInboxControlPlaneStoreTests`, `QuotaPopoverCopyTests`, `ProviderQuotaChipTests`, `QuotaWorkspaceViewModelTests`, `BackdropLegiblePlateTests`.

---

## 10. Verification

1. `xcodegen generate` then build — the new directories are picked up by the `AgentLens` glob, but the `.xcodeproj` is committed.
2. `xcodebuild test` for the suites above.
3. **Run the app and look at it** (per `docs/` run guidance): confirm it opens on Home; drag both dividers and relaunch to confirm persistence; resize the window through all three bands and confirm the rail stubs at narrow without writing the collapsed key; toggle every view mode in all three regions.
4. **Backdrop legibility** — turn on a live backdrop and confirm nothing goes invisible, especially the fleet dots and the 11pt footer. This is the failure mode `DashboardView.swift:695-707` exists to warn about.
5. **Fleet honesty pass** — with a Claude Code running in Terminal, confirm the row shows "wrote Ns ago" and updates sub-second. Sleep the display, wake it, and confirm rows read "not watched while asleep" rather than showing stale pre-sleep timestamps.
6. Empty the inbox (archive everything) and confirm the celebration + brief renders without constructing `InsightsMacEnvironment`.
