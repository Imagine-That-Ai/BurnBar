# iPad SwiftUI API notes (iOS 17–26)

**Status:** research notes only. No app implementation in this file.

**Target:** `OpenBurnBarMobile` ships **iOS / iPadOS 17.0**. APIs listed under “in-target” need no `#available` on this target. Newer APIs stay gated.

**Sources (2026-08-20):**

- Apple Developer Documentation: `NavigationSplitView`, `NavigationSplitViewVisibility`, `NavigationSplitViewColumn`, `inspector(isPresented:content:)`, `inspectorColumnWidth`, `InspectorCommands`, `SidebarCommands`, `keyboardShortcut`, `Commands`, `hoverEffect`, `CustomHoverEffect`, `onHover`, `onKeyPress`, `navigationDestination(item:)`, `toolbar(removing:)`, [Migrating to new navigation types](https://developer.apple.com/documentation/swiftui/migrating-to-new-navigation-types), [TN3154](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view)
- Local latest-API list: [`.claude/skills/swiftui-expert-skill/references/latest-apis.md`](../../.claude/skills/swiftui-expert-skill/references/latest-apis.md) and [sheet-navigation-patterns.md](../../.claude/skills/swiftui-expert-skill/references/sheet-navigation-patterns.md)
- Context7 `resolve-library-id` / `query-docs` for libraryName `SwiftUI` was attempted (`plugin-context7-plugin-context7`) and returned **monthly quota exceeded**. These notes are Apple-doc + skill-list, not Context7 snippets.

Existing iPad chrome already uses `NavigationSplitView(columnVisibility:)` in `RootNavigationView`. Treat that as the pattern, not a third column pretending to be an inspector.

---

## 1. NavigationSplitView + inspector

### In-target (iOS 17+, no gate)

| API | Role |
|---|---|
| `NavigationSplitView { sidebar } detail: { }` | Two-column root. Prefer this for iPad chrome. |
| `NavigationSplitView { sidebar } content: { } detail: { }` | Three-column (sidebar / list / detail). |
| `NavigationSplitView(columnVisibility:)` | Bind `NavigationSplitViewVisibility`. |
| `NavigationSplitView(preferredCompactColumn:)` | Bind `NavigationSplitViewColumn` for the collapsed stack. |
| `NavigationSplitView(columnVisibility:preferredCompactColumn:sidebar:detail:)` | Regular-width visibility **and** compact top column. Same combo exists for three columns. |
| `NavigationSplitViewVisibility` | `.automatic`, `.all`, `.doubleColumn`, `.detailOnly`. |
| `NavigationSplitViewColumn` | `.sidebar`, `.content`, `.detail`. |
| `.navigationSplitViewColumnWidth(_:)` / `.navigationSplitViewColumnWidth(min:ideal:max:)` | Preferred column width. System may ignore it. |
| `.navigationSplitViewStyle(.automatic \| .balanced \| .prominentDetail)` | Column prominence. |
| `.toolbar(removing: .sidebarToggle)` | Remove the system sidebar-toggle toolbar item `NavigationSplitView` inserts. |
| `.inspector(isPresented:content:)` | Trailing inspector. Regular width → column. Compact / iPhone → sheet. Presentation state is restored for trailing-column inspectors. |
| `.inspectorColumnWidth(_:)` | Fixed preferred width (column presentation only). |
| `.inspectorColumnWidth(min:ideal:max:)` | Flexible width. Not all environments honor resize. |
| `InspectorCommands()` | Scene `.commands` set. Toggles inspector with **⌃⌘I**. |
| `.navigationDestination(item:destination:)` | Optional bound value → detail (or stack push). Keep **outside** `List` / `LazyVStack`. |

Column visibility is ignored when the split view **collapses** (iPhone, iPad Slide Over, compact). Use `preferredCompactColumn` for that path.

Inspector is a **presentation**, not a third `NavigationSplitView` column. Do not fake it with `content:` + `detail:`. On compact, customize the sheet with the usual presentation modifiers (`presentationDetents`, `presentationBackgroundInteraction`, `interactiveDismissDisabled`).

```swift
@State private var columnVisibility = NavigationSplitViewVisibility.automatic
@State private var compactColumn = NavigationSplitViewColumn.sidebar
@State private var showInspector = false

NavigationSplitView(
    columnVisibility: $columnVisibility,
    preferredCompactColumn: $compactColumn
) {
    SidebarList()
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
} detail: {
    DetailRoot()
}
.inspector(isPresented: $showInspector) {
    InspectorForm()
        .inspectorColumnWidth(min: 200, ideal: 260, max: 360)
}
```

On `WindowGroup` / `Scene`:

```swift
.commands {
    SidebarCommands()
    InspectorCommands()
}
```

### iOS 18+ (gate)

No new `NavigationSplitView` initializer is required for a correct iPad shell. Use `#available(iOS 18, *)` only if you adopt `Tab` / `Tab(role:)` at the compact root (iPhone), or `CustomHoverEffect` (below).

### iOS 26+ (gate)

Navigation chrome itself is unchanged. Gate **toolbar / glass** APIs when they touch the split view or inspector toolbar:

| API | Use |
|---|---|
| `ToolbarSpacer` | Separate toolbar item groups. |
| `.sharedBackgroundVisibility(.hidden)` | Ungroup a single glass toolbar item. |
| `.scrollEdgeEffectStyle(_:for:)` | Scroll-edge material instead of custom toolbar backgrounds. |
| `.searchToolbarBehavior(.minimize)` | Search collapses to a toolbar button. |
| `.navigationTransitionSource` / `.navigationTransitionDestination` | Zoom a sheet out of a toolbar control. |

---

## 2. Keyboard, Commands, pointer hover (iPad)

### In-target (iOS 17+)

| API | Role |
|---|---|
| `.keyboardShortcut(_:modifiers:)` | Bind a hardware-key shortcut to a `Button` (default modifiers: `.command`). |
| `.keyboardShortcut(.defaultAction)` / `.keyboardShortcut(.cancelAction)` | Return / Escape equivalents. |
| `KeyboardShortcut` + `.keyboardShortcut(_:)` | Localization / discoverability options. |
| `Scene.commands { }` | Main-menu commands on Mac; **Command-key HUD** on iPad. |
| `CommandMenu`, `CommandGroup`, `CommandGroupPlacement` | Categorized commands. Uncategorized view-level shortcuts land in a junk HUD section. |
| `SidebarCommands()` | System sidebar show/hide command. |
| `InspectorCommands()` | System inspector toggle (⌃⌘I). |
| `.onKeyPress(_:action:)` | Focused hardware-key handling. Return `.handled` or `.ignored`. |
| `.hoverEffect()` / `.hoverEffect(_:isEnabled:)` | Pointer platter. `.automatic`, `.highlight`, `.lift`. |
| `.defaultHoverEffect(_:)` | Default effect for nested `.hoverEffect()` / bordered buttons. |
| `.hoverEffectDisabled(_:)` | Disable hover in a subtree (outer wins). |
| `.onHover { isHovering in }` | Pointer enter/exit. Use for state, not as a substitute for `.hoverEffect`. |

Put discoverable iPad shortcuts in `.commands`, not only on an in-window `Button`. View-level `.keyboardShortcut` still fires; the HUD is what users hold **⌘** to see.

```swift
Button("Toggle Inspector", systemImage: "info.circle") {
    showInspector.toggle()
}
.keyboardShortcut("i", modifiers: [.command, .control])
.hoverEffect(.highlight)
```

### iOS 18+ (gate)

| API | Role |
|---|---|
| `CustomHoverEffect` | Reusable hover (also used for look-at on visionOS). |
| `.hoverEffect(in:isEnabled:body:)` | Phase-based custom hover. Does **not** affect layout; may run out of process. |
| `.hoverEffectGroup()` / `.hoverEffectGroup(id:in:behavior:)` | **Unavailable on iOS** (macOS / visionOS). Do not call from OpenBurnBarMobile. |
| `.pointerStyle(_:)` | Pointer shape (selection, etc.). Confirm at the call site; treat as iOS 18 / macOS 15. |

Do not drop to `UIPointerInteraction` unless SwiftUI hover/pointer style cannot express the effect.

### iOS 26+

No new keyboard or hover API is required for an iPad shell. Keep using `Commands` + `.keyboardShortcut` + `.hoverEffect`.

---

## 3. Current navigation APIs (use these)

OpenBurnBarMobile is already iOS 17. **Do not** keep a `NavigationView` fallback.

| Use | Instead of |
|---|---|
| `NavigationStack` | `NavigationView` + `.navigationViewStyle(.stack)` |
| `NavigationSplitView` | `NavigationView` with two/three children + `.navigationViewStyle(.columns)` |
| `NavigationLink(value:)` + `.navigationDestination(for:)` | `NavigationLink(destination:)` |
| `NavigationStack(path:)` / `NavigationPath` | `NavigationLink(..., isActive:)` |
| `.navigationDestination(item:)` | Parallel boolean “show detail” flags |
| `.navigationTitle(_:)` | `navigationBarTitle(_:)` |
| `.toolbar { ToolbarItem(...) }` | `navigationBarItems(...)` |
| `.toolbarVisibility(.hidden, for: .navigationBar)` | `navigationBarHidden(_:)` |
| `.tint(_:)` | `accentColor(_:)` |
| `.onChange(of:) { }` / `{ old, new in }` | `onChange(of:perform:)` |
| `Button` + `.keyboardShortcut` | `onTapGesture` for tappable chrome |
| iOS 18+: `Tab("Title", systemImage:) { }` | `.tabItem { }` |
| iOS 26+: `ToolbarSpacer`, `.scrollEdgeEffectStyle`, `.searchToolbarBehavior` | Custom toolbar background hacks |

Value-based links inside a split-view column still need a matching `.navigationDestination(for:)` on a `NavigationStack` in that column (or a later column). Selection-driven `List` in the sidebar is the iPad default (`RootNavigationView` already does this).

---

## 4. Avoid

- **`NavigationView`** — deprecated. Do not wrap it in `#available` on a 17.0 target.
- **`NavigationLink(destination:)`** and **`NavigationLink(isActive:)`** — old stack automation.
- **`isDetailLink(_:)`** — leftover `NavigationView` detail routing.
- **A third split column as an inspector** — use `.inspector(isPresented:)`.
- **`navigationDestination` inside `List` / `LazyVStack`** — the destination can be missing when the row is off-screen.
- **Driving compact-column UI with `columnVisibility`** — ignored when collapsed; use `preferredCompactColumn`.
- **`navigationBarTitle` / `navigationBarItems` / `navigationBarHidden` / `edgesIgnoringSafeArea` / `foregroundColor` / `actionSheet`**.
- **`tabItem` on new iOS 18+ tab chrome** — use `Tab`. Do not mix `Tab(role:)` with `.tabItem`.
- **Uncategorized iPad shortcuts only on views** — add `CommandMenu` / `CommandGroup` so they appear in the ⌘ HUD.
- **`UIKeyCommand` / `keyCommands` / `addKeyCommand`** for new work — SwiftUI `Commands` + `.keyboardShortcut`.
- **`UIPointerInteraction` / `UIHoverGestureRecognizer`** for standard pointer feedback — SwiftUI hover first.
- **Liquid Glass / `ToolbarSpacer` / `tabBarMinimizeBehavior` without `#available(iOS 26, *)`** and a 17–25 fallback.

---

## 5. `#available` cheat sheet (this target)

```swift
// iOS 17.0 target — call directly
NavigationSplitView(columnVisibility:preferredCompactColumn:sidebar:detail:)
.inspector(isPresented:content:)
InspectorCommands()
.keyboardShortcut(_:modifiers:)
.hoverEffect(_:isEnabled:)
.onKeyPress(_:action:)

if #available(iOS 18, *) {
    // Tab API, CustomHoverEffect, pointerStyle
}

if #available(iOS 26, *) {
    // ToolbarSpacer, scrollEdgeEffectStyle, searchToolbarBehavior,
    // tabBarMinimizeBehavior, navigation zoom transition, glass chrome
}
```
