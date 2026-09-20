# iPad input and windowing

**Status:** inspection note, 2026-08-20. Nothing in this file is shipped. The iPad regular shell is a sidebar; Watch is an overlay on the same scene; the mobile `WindowGroup` has no `.commands` and no second window.

**Sibling:** [iphone-hero-ia.md](iphone-hero-ia.md) (compact tray). **Plan:** [plans/2026-08-20-iphone-remote-continuation-master-plan.md](../../plans/2026-08-20-iphone-remote-continuation-master-plan.md). **Port ADR:** [docs/IPADOS_PORT_PLAN_2026.md](../IPADOS_PORT_PLAN_2026.md) ADR-4 (`NavigationSplitView` replaces the tab bar on iPad).

**North star:** an iPad with a Magic Keyboard and a pointer is a desk remote, not a stretched phone. Inbox stays a real surface. Watch (mirror + computer use + halt) can sit in its own Stage Manager window. The four iPhone tray destinations remain one keystroke away. Transport and safety do not change: **iroh + HPKE Auth v3 + trusted-device roots**. Approval is still ground truth. Panic still has to work when the composer has focus.

---

## What the code does today

Read these, not the 2026 research notes that claim Split View is gone.

| Surface | File | Behavior |
|---|---|---|
| Scene | `OpenBurnBarMobile/App/OpenBurnBarMobileApp.swift` | One `WindowGroup { AuthGateView() }`. Deep links, tint, appearance. **No** `.commands`. **No** `Window(id:)`. **No** `openWindow`. |
| Root branch | `OpenBurnBarMobile/App/AuthGateView.swift` | Sidebar only when `userInterfaceIdiom == .pad` **and** `horizontalSizeClass == .regular`. iPhone stays on the tray root even in landscape regular so a live Mercury session is not torn down. |
| iPad regular | `OpenBurnBarMobile/Views/RootNavigationView.swift` | `NavigationSplitView`, sidebar width 220–280. Agents sets `columnVisibility` to `.detailOnly` because Hermes Square is already a split. |
| iPad compact / iPhone | `OpenBurnBarMobile/Views/RootTabView.swift` | Aurora floating pill. Compact tray is Inbox · Agents · Quota · You. Watch is not a tab. |
| Sidebar defaults | `OpenBurnBarMobile/Models/AppCustomization.swift` | Primary: Pulse · Quota · Insights · Streams · Agents. Secondary: You · Providers · Devices · Settings. **Inbox is a reachable `AppDestination`, not a default sidebar row.** |
| Inbox width | `OpenBurnBarMobile/Views/Inbox/AIInboxSplitLayout.swift` | List + detail at **≥ 720 pt of given width**. Below that, rows push. Slide Over is a layout change, not a different host. |
| Watch | `AgentLiveStage` + `AgentWatchOverlaySingleton` | Same overlay on both roots. Regular split is 60/40 in **this** window. Maximize covers Inbox. `burnbar://agent-watch` pushes You → Agent Control. |
| Pointer | `AuroraGlassCard`, `HoverScale`, Hermes / Inbox resize handles | A few `onHover` scales. Sidebar rows are `.buttonStyle(.plain)` with selection fill only. No `.hoverEffect()`. |
| Hardware keys | OpenBurnBarMobile | **Zero** `.keyboardShortcut` / `CommandMenu` registrations. Hermes Return-to-send and Inbox `.searchable` exist; they are not app commands. |

Physical proof of split-view / Stage Manager / keyboard IME is still `blocked` in [mobile-os-integration-matrix.json](mobile-os-integration-matrix.json) (`os.durable.split-screen`, `os.durable.keyboard-ime`).

---

## Hardware keyboard shortcuts to ship

Register these on the **scene** (`WindowGroup.commands` / `Window.commands`), not as hidden zero-size buttons inside a destination that unmounts when the sidebar changes. Publish enablement with `@Entry` `FocusedValues` / `@FocusedBinding` from the focused column (`focus-patterns.md`). Prefer `.defaultFocus` and `.searchFocused` over `onAppear` focus writes.

Do **not** copy Mac `⌘1…⌘8`. Those numbers are pinned to `DashboardMainRoute.primarySections` (Home is `⌘⇧H`, Control Deck is `⌘0` so the map never shifts). iPad destinations are a different set, and `AppCustomization` can reorder the sidebar. Shortcuts are **identity-stable**.

### Always-on (main window)

| Shortcut | Action | Why this chord |
|---|---|---|
| `⌘1` | Inbox | Matches the iPhone launch tab. Must work even when Inbox is missing from the default sidebar. |
| `⌘2` | Agents | Hermes Square. Same as selecting `.agents` / `.hermes`. |
| `⌘3` | Quota | Enum stays `.burn`. |
| `⌘4` | You | Account, devices, manual Agent Control. |
| `⌘5` | Pulse | iPad-default home; still a first-class sidebar row. |
| `⌘,` | Settings | Same as Mac `CommandGroup(replacing: .appSettings)`. Lands on the iPad Settings hub, not a fake Preferences scene. |
| `⌘F` | Focus the nearest `.searchable` | Inbox already has a search drawer. Bind `.searchFocused`. Do **not** invent a Mac command palette (`⌘K` stays Mac). |
| `⌘⇧[` / `⌘⇧]` | Previous / next primary destination | Walk the **current** `customization.primaryDestinations` plus Inbox if it is absent. Skip secondary Account rows. |
| `⌘\` | Toggle sidebar | `NavigationSplitView` column visibility. No-op when Agents has already forced `.detailOnly`. |

`⌘6` Insights and `⌘7` Streams are allowed as reachable extras. Do not add `⌘8` Recap or a Control Deck key.

### Inbox (when the inbox list or detail is focused)

Port the Mac inbox verbs that already have store methods. Skip Mac-only pin/reorder until mobile has the same model.

| Shortcut | Action |
|---|---|
| `↑` / `↓` | Move selection in the list (two-column and push). |
| `Return` | Open / focus the selected item (inline detail on ≥ 720 pt). |
| `⌘⇧A` | Archive the selected item(s). |
| `⌘⌫` | Same as archive if that is the destructive verb; do not invent a second delete. |
| `/` or `⌘F` | Search field (`.searchFocused`). |

Do not steal `Return` from a focused Hermes composer in another column or window.

### Agents (when Hermes Square is focused)

| Shortcut | Action |
|---|---|
| `⌘N` | New thread (`hermesService.startNewSession()`). Same letter as Mac new conversation. |
| `Return` | Send. Already wired via `onSubmit` + newline guard; keep it. Do not add a second send command. |
| `Esc` | Blur the composer (`.focused` → `nil`). |

### Watch (when the Watch **window** or overlay is key)

Hardware panic is a third kill path next to the on-screen Halt control and the existing three-finger long-press. It must fire even if a text field in **this** scene is focused.

| Shortcut | Action |
|---|---|
| `⌃⌥⌘.` | Panic halt. Same chord as the Mac global hotkey (`ComputerUsePanicHaltCoordinator`). App-scoped on iPad, not a system-wide grab. |
| `⌘⇧W` | Open / focus the Watch window (regular) or raise the overlay (compact). |
| `⌘W` | Close the Watch **window** only. Does not halt the Mac session. Overlay may return to dock. |
| `Return` | Approve the current request when the approval strip is the focused accessory. |
| `Esc` | Reject without halt when that strip is focused. Never panic. |
| `⌘⇧.` | Reject and halt (the dock tile’s “reject + halt” verb). |

When the user is **driving** the Mac (Watch maximize / Watch window key, passthrough on), printable keys and unmodified arrows go to the signed input stream. The panic chord, `⌘W`, and `⌘⇧W` stay local. Implement that with a focus section around the mirror and command handlers that do not require the mirror to be unfocused.

### Do not ship

- Mac `⌘1…⌘8` section map, `⌘0` Control Deck, `⌘⇧H` Home, `⌘K` palette, `⌘⌥R` rail toggle.
- View-mode / layout-switcher keys ([docs/DASHBOARD_HOME_PLAN.md](../DASHBOARD_HOME_PLAN.md) already refuses those on Mac).
- A second send shortcut that races Hermes `onSubmit`.
- Shortcuts that only exist inside a `Menu` body (they register only after the menu opens — the Mac inbox comment is the warning).

Implementation shape: `OpenBurnBarMobileApp` `.commands { CommandMenu("Go") { … } ; CommandGroup(replacing: .appSettings) { … } }` plus Watch-window commands. Disable with `@FocusedValue` when the focused scene has no inbox / no live session. iPadOS shows these in the menu bar when a keyboard is attached; that is the discoverability path, not a custom cheat sheet.

---

## Pointer hover

iPad with a trackpad or mouse is a pointer device. Touch must keep working. Hover is highlight and cursor, not a hidden verb.

### Ship

| Target | Treatment |
|---|---|
| Sidebar rows | System `.hoverEffect()` (or `.hoverEffect(.highlight)`) on the existing 50 pt row. Selection fill stays as-is. Do not invent a second selected-dot on hover. |
| Inbox rows, Agents thread rows, You rows | Same system hover. Rows are `Button`s, not `onTapGesture`. |
| Hermes / Inbox resize handles | Keep `onHover` brightness; add a horizontal-resize pointer style while hovering. |
| Pulse / dashboard cards | Existing `HoverScale` / `AuroraGlassCard` `onHover` scale (~1.012–1.02) is enough. Do not add a second scale. |
| Watch Halt / Approve / Reject | Hover highlight on the controls. Chrome may fade; hover **reveals** it. The verb is still the click. |
| Toolbar / sidebar footer “Quick ask Hermes” | System hover. The mercury-foil button stays opaque; do not glass-under-glass. |

Use `.hoverEffect()` for list chrome. Keep custom `onHover` only where we already change scale, brightness, or cursor (cards, dividers). Do not write `@FocusState` from a hover or tap-to-focus gesture (`focus-patterns.md`: redundant focus writes revoke focus).

### Do not

- Hover-only Halt, Approve, or archive. Pointer users get hover; VoiceOver and touch still need a visible control.
- `onHover` on every compact-phone chip “because iPad compiles it.” `BudgetStatusChip` already documents that choice.
- Hover as the only selected state. Keyboard focus (`isFocused` / focus ring) is separate; use `.focusable(interactions: .activate)` on custom rows if they need arrow-key landing.
- A custom cursor everywhere. Resize handles yes; sidebar rows no.

---

## Stage Manager: extra window for Watch vs Inbox

This is the iPad product decision. The iPhone overlay contract stays: Inbox (or whatever tab) remains selected underneath; a session docks / splits / maximizes in-process.

On a regular iPad, maximize-in-the-same-window **hides Inbox**. Split-in-the-same-window **steals 60% of Inbox**. That is the phone composition stretched. Stage Manager is how two real surfaces sit side by side.

### Ship

1. **Keep** the primary `WindowGroup` as the dashboard shell (`AuthGateView` → `RootNavigationView` / compact tray). One signed-in graph: stores, Hermes runtime, `AgentWatchOverlaySingleton`.
2. **Add** a second scene, not a second app root:

   ```swift
   Window("Agent Watch", id: "agent-watch") {
       AgentWatchWindowRoot(/* binds to AgentWatchOverlaySingleton.shared */)
   }
   ```

   `AgentWatchWindowRoot` is the live stage (mirror, approval strip, halt, driving chrome). It is **not** `AuthGateView`, **not** another sidebar, **not** another `HermesService()` instance.

3. **Open that window** with `@Environment(\.openWindow)` when **all** of these are true:
   - idiom is iPad
   - horizontal size class is regular
   - a Computer Use or Mercury session becomes live, **or** the user hits `⌘⇧W` / Agent Control / `burnbar://agent-watch`
4. **Stay on the overlay** when any of these are true:
   - iPhone
   - iPad compact (Slide Over, Stage Manager slot narrower than regular, Split View half that reports compact)
   - the Watch window cannot be created

5. **Inbox (or Pulse, or Agents) stays in the main window.** Opening Watch does not change `RootNavigationView.selection`. Deep link `burnbar://inbox/{id}` still selects Inbox in the main scene. Watch does not steal the sidebar highlight.

6. **One control stream.** The extra window observes the existing singleton. Closing the Watch window returns the overlay to dock (or hidden if the session ended). It does **not** call `panicHalt` and does **not** tear down iroh. Halt is an explicit control.

7. **Key-window commands.** Approve / panic / `⌘W` apply to the Watch scene via `@FocusedSceneValue`. Main-window `⌘1` Inbox still works while Watch is open.

### Placement

| Situation | Watch | Inbox |
|---|---|---|
| iPhone | Overlay dock → split → maximize | Selected underneath |
| iPad compact | Overlay (same as phone) | Tray or stacked split |
| iPad regular, session starts | `openWindow("agent-watch")` | Main `WindowGroup` unchanged |
| iPad regular, user closes Watch window | Overlay dock if session still live | Unchanged |
| `burnbar://agent-watch` on regular iPad | Focus/create Watch window | Do not push You → Agent Control unless the window API is unavailable |
| `burnbar://inbox/{id}` | Ignore | Select Inbox + item in the main window |

### Do not use these for Watch-beside-Inbox

| API | Why not |
|---|---|
| `.inspector` | Trailing supplementary column / compact sheet. Watch is a live session, not an inspector. `InspectorCommands` is the wrong shortcut. |
| `.sheet` / `.fullScreenCover` | Blocks Inbox. Fine for mission console and incoming Mercury **ringtone** sheets; not for a session the user wants beside mail. |
| Second `WindowGroup { AuthGateView() }` | Duplicates auth, stores, overlay, and Hermes. Stage Manager “New Window” of the **root** group is this bug. Disable extra instances of the main group or make them share the composition root without remounting services. |
| `NavigationSplitView` third column | Watch is not a selected sidebar row. |
| PiP as the only iPad answer | PiP is the leave-the-app path. Stage Manager is the stay-in-app dual-surface path. |

Mac already uses a dedicated `WindowGroup(id: "mercury.chrome")` so call chrome is not trapped in the menu-bar popover. iPad Watch is the same idea: session chrome is a named window, not a ZStack on the dashboard.

---

## What not to do

### Stretched tab bar (the hard no)

`AuroraNavigationTray` is a **compact pill**: 56 pt per tab, intrinsic width, floating above the home indicator. `RootTabView` already documents that the iPad sidebar root inherits `mobileTrayInset = 0` because it does not draw a tray.

Do **not**:

- Pin that pill to the full width of a 13" landscape detail column (~1000 pt) or a Stage Manager tile.
- Put `TabView` / `Tab("Inbox")` / `.tabItem` across the bottom of `RootNavigationView`.
- Call `trayDestinations(compact: false)` (all eight `AuroraNavDestination` cases) and lay them on a regular iPad as a tab bar.
- Use `RootTabView` as the regular-width iPad root. Compact iPad (Slide Over / narrow Stage Manager) may keep the **phone** pill. Regular iPad uses the sidebar.
- Stretch the four iPhone tabs to “use the space.” Empty space on iPad is for `NavigationSplitView` columns, Inbox list+detail, Pulse `CardRowPacker`, Hermes Square — not for a wider tab bar.

ADR-4 already chose this. Pulse’s own comment is the other half: a phone layout at iPad width is a letterbox, not a product.

### Other hard nos

- **Watch is not a sidebar tab.** Overlay + optional window. Manual entry stays You → Agent Control when no window exists.
- **Do not swap iPhone to `RootNavigationView` in landscape.** `AuthGateView` refuses that so Mercury does not die.
- **Do not use `UIScreen.main.bounds`** for gutters, tray width, or Watch split. Inbox and Hermes already key off **given** width (720 pt). Pulse already keys off content width + hysteresis.
- **Do not use `NavigationView`.** The shell is `NavigationSplitView` + `NavigationStack`.
- **Do not add a Mac-style command palette** on iPad to paper over missing `⌘1…⌘4`.
- **Do not hover-only** safety actions.
- **Do not** treat Stage Manager as “overlay maximize is good enough.”
- **Do not** claim `os.durable.split-screen` validated from this note. Named-device receipts still required.

---

## Layout rules (so the next patch does not fight the shell)

From `layout-best-practices.md` and the views that already do this:

- Views are context-agnostic. Inbox / Hermes / Pulse resolve columns from the width they are given (720 pt / `LivingSpaceBudget`), so Stage Manager resize and Split View are the same code path.
- Own the container you are. `RootNavigationView` owns the sidebar. Hermes Square owns the Agents detail. Do not wrap Agents in another split.
- Prefer `.frame(maxWidth: .infinity, alignment:)` over spacer stacks for full-width chrome.
- Gate geometry updates; Pulse already refuses a hard width cutoff on every drag frame.

From `sheet-navigation-patterns.md`:

- Destination changes stay selection-driven (`AppDestination` / `AuroraNavDestination`), not a pile of `sheet(isPresented:)` flags.
- Mission console and incoming call stay item/flag sheets. Watch does not join them on regular iPad.

From `latest-apis.md`:

- `Tab` / `tabBarMinimizeBehavior` are iPhone-tray APIs. They are not the iPad regular shell.
- `#available` for Liquid Glass on sidebar footer stays; glass is not a hover substitute.

---

## Implementation order (when someone builds this)

1. `WindowGroup.commands` + focused values for `⌘1…⌘5`, `⌘,`, `⌘F`, panic `⌃⌥⌘.` (overlay path first).
2. `.hoverEffect()` on sidebar and inbox rows; pointer on resize handles.
3. Named `Window(id: "agent-watch")` bound to the existing singleton; `openWindow` on regular iPad session start; overlay fallback on compact.
4. Point `ShowAgentWatch` / `burnbar://agent-watch` at the window on regular iPad.
5. Physical receipts for Magic Keyboard, pointer hover, Stage Manager two-window, compact overlay fallback. Then, and only then, talk to `os.durable.split-screen`.

---

## Security invariants (cannot vary)

Same as [iphone-hero-ia.md](iphone-hero-ia.md):

- Relays, Firestore, gateways: untrusted transport only.
- Mac-bound CU/control: authenticated v3 HPKE envelope + trusted-device bind.
- Approval is ground truth; iPad trust only downgrades.
- Locked Mac / loginwindow / SecurityAgent ends normal mirror and CU.
- Panic from the Watch window is the same signed halt as the overlay button and the three-finger press.
- No daemon-RPC remote from iPad.
- A second Watch window must not open a second authority session.
