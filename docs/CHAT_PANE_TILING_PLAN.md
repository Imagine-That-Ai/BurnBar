# Chat pane tiling (cmux-style) — design + implementation plan

Status: design, pre-implementation. Owner: agent (under ultracode). Target: `AgentLens` macOS app, Chat screen.

## Goal

Turn the right-side conversation viewer of the Chat screen into a cmux-style tiling
workspace: split the active pane horizontally (`cmd+D`) or vertically (`cmd+shift+D`),
close a pane (`cmd+W`), resize panes by dragging dividers, and drag any thread from the
left rail onto a specific pane to load that conversation into that pane. Each pane is a
fully independent conversation (own thread, message stream, model/backend selector, input
box). Layout + sizes + each pane's bound thread survive re-render and app relaunch.

## Success criteria (acceptance)

- Right viewer renders a tiling tree of panes; exactly one pane is active and shows a focus ring.
- `cmd+D` splits the active pane into two side-by-side panes; `cmd+shift+D` into two stacked panes. The new pane becomes active and starts as an empty/new chat.
- `cmd+W` closes the active pane and re-flows its sibling to reclaim the space; with one pane, `cmd+W` falls through to the normal macOS window-close (we never destroy the last pane).
- Dividers drag to resize; fractions persist across the session and relaunch.
- Dragging a thread row onto a pane loads that conversation into that pane only; the hovered pane highlights during drag, others are unchanged.
- Each pane streams independently; sending/streaming/model changes in one pane never affect siblings.
- Layout tree, fractions, and each pane's bound threadID restore on relaunch. Empty/first run → one full-size pane bound to the current thread (today's behavior, unchanged).

## Current architecture (from deep-read)

- `DashboardChatWorkspaceView` (`AgentLens/Views/Chat/DashboardChatWorkspaceView.swift`): `@Bindable var controller: ChatSessionController`, plus injected `dataStore`, `settingsManager`, `sharedFeaturesAvailable`, `mode`, and callbacks. Body = `VStack { DashboardChatWorkspaceToolbar(...); HStack { threadRail.frame(width: 260); conversationColumn } }`. Owns screen `@State`: `brief`, `showClearChatPrompt`, `showCLIAssistantConsent`, `atomRouter`; `private let canvasMaxWidth = 760`, `railWidth = 260`.
- `conversationColumn` = `VStack { (welcomeState | ChatMessagesStream(...)); Divider().opacity(0.35); centered ChatInputRow(...) }`.
- `ChatMessagesStream(controller, settingsManager, maxContentWidth, horizontalPadding=, verticalPadding=, onJumpToConversation)`.
- `ChatInputRow(controller, chatBackend, cliAssistantAllowed=true, onRequestCLIAssistantConsent: (()->Void)?, onSubmit: ()->Void)`. Internal `@State isDropTargeted`.
- Pickers (in the toolbar, all bind to `controller`): `ChatEngineBackendStrip(controller, settingsManager)`, `ChatEngineModelMenu(controller)` (needs `SettingsManager` in `@Environment`), `ChatViewModePicker(controller)`.
- `ChatHistoryRow(thread, isActive, accent, onSelect)` — left-rail row, wrapped in `Button(onSelect)`.
- `ChatSessionController` (`@MainActor @Observable final class`): per-conversation state (`messages`, `activeThreadID` default `DataStore.legacyChatThreadID`, `inputText`, `isStreaming`, `streamTask`, `cliBridge` (own `CLIBridge`/`CLIBridgeStreamRuntimeCoordinator`), `searchService`, `retrievalHealthService`). Isolated `deinit` cancels its Tasks. No timers/NotificationCenter/Combine. `init(dataStore:settingsManager:.shared, searchService:nil, cliBridge:nil, memoryService:nil, memoryExtractionEngine:nil)`. Built once in `AgentLensApp.swift:1046`, stored in `OpenBurnBarRuntimeContext.chatController`.
- `DataStore` = `DataStoreCoordinator` (`@MainActor @Observable`, NOT a singleton; built once `AgentLensApp.swift:1004`, injected). GRDB WAL pool. Chat rows keyed by `threadId`. `createChatThread(id: String = UUID().uuidString) async throws -> String`, `fetchChatMessages(threadID:) async throws -> [ChatMessageRecord]`, `saveChatMessage(_:threadID:...)`. Concurrent reads parallel; writes serialized + safe.
- Design tokens (`AgentLens/Theme/DesignSystem.swift`): `Radius.md`(10)/`sm`(6); `Spacing.sm`(8)/`md`(12)/`lg`(16)/`xl`(24); `Colors.surface`, `Colors.surfaceElevated`, `Colors.border`, `Colors.whimsy` (accent/selection), `Colors.hermesAureate` (Hermes only). Selection idiom: `RoundedRectangle(...).strokeBorder(Colors.whimsy.opacity(0.6), lineWidth: isActive ? 1.0 : 0.5)`.
- Existing reusable patterns: String-payload drag/drop (`SmartDisplayReorderable.swift`: `.draggable(String)` + `.dropDestination(for: String.self){}.isTargeted{}`); native `HSplitView` (`DataControlCenterView.swift`) — but it does NOT persist divider position.

## Key insight

The runtime is **already multi-instance safe**: each pane just needs its own `ChatSessionController`, all sharing the one injected `DataStore`. Streaming, CLI, search, and DB rows are isolated by construction. The **only** hazard is the controller's persistence layer, which writes a single global set of `UserDefaults` keys (`chatPanelThreadID.<backend>`, `chatPanelActiveThreadID`, `chatPanel.model.<backend>`, `chatBackendID`, `chatPanel.viewMode`, geometry). Two naive instances clobber each other and corrupt the legacy single-pane chat keys.

We solve persistence cleanly without per-key namespacing: pane controllers run with **persistence disabled**, and the **workspace model owns all pane persistence** in one JSON blob.

## Design

### 1. Layout tree + workspace model

New file `AgentLens/Views/Chat/PaneWorkspace/PaneWorkspaceModel.swift`.

```swift
enum SplitAxis: String, Codable, Sendable {
    case horizontal   // cmd+D  — two panes side by side (split width)
    case vertical     // cmd+shift+D — two panes stacked (split height)
}

@MainActor @Observable final class PaneLeaf: Identifiable {
    let id: UUID
    let controller: ChatSessionController
    let isPrimary: Bool          // true for the one leaf reusing the app-wide controller
    init(id: UUID = UUID(), controller: ChatSessionController, isPrimary: Bool = false)
}

@MainActor @Observable final class PaneSplit: Identifiable {
    let id: UUID
    var axis: SplitAxis
    var fraction: Double          // 0..1 size of `first` along axis; clamped [0.15, 0.85]
    var first: PaneNode
    var second: PaneNode
}

enum PaneNode: Identifiable {     // value wrapper over @Observable class refs
    case leaf(PaneLeaf)
    case split(PaneSplit)
    var id: UUID { ... }
}

@MainActor @Observable final class PaneWorkspaceModel {
    var root: PaneNode
    var activeLeafID: UUID
    let dataStore: DataStore
    let settingsManager: SettingsManager
    let primaryController: ChatSessionController     // app-wide controller, reused for one leaf

    var activeController: ChatSessionController { leaf(activeLeafID)?.controller ?? primaryController }
    var paneCount: Int { ... }                       // count leaves

    func splitActive(axis: SplitAxis)
    func closeActive()
    func setActive(_ id: UUID)
    func bind(threadID: String, toLeaf id: UUID) async   // load thread into that pane
    func persist()
    static func restore(primaryController:dataStore:settingsManager:) -> PaneWorkspaceModel
}
```

Using `@Observable` classes for `PaneLeaf`/`PaneSplit` makes `fraction` and child-ref
changes observed granularly (live resize, live re-flow) without reassigning the whole tree.
`controllers` are reference types held by the leaves; `PaneNode` reassignment on the parent
or root triggers SwiftUI updates.

**`splitActive(axis:)`**: locate the active `PaneLeaf`; mint `newID = UUID().uuidString`,
`try await dataStore.createChatThread(id: newID)`, build a fresh pane controller bound to
`newID` (see §2), wrap as `newLeaf`. Replace the active leaf in the tree with
`PaneSplit(axis:, fraction: 0.5, first: oldLeaf, second: newLeaf)`. Set `activeLeafID =
newLeaf.id`. `persist()`. (Thread creation is async; the split action kicks a `Task` and
updates the tree on the main actor.)

**`closeActive()`**: if `paneCount <= 1`, do nothing (last pane is indestructible; `cmd+W`
falls through — see §5). Otherwise find the `PaneSplit` parent whose child is the active
leaf; replace that split with the sibling subtree. Choose the new active leaf =
left-most/top-most leaf of the surviving sibling. Tear down the closed pane's controller
(drop the reference; its isolated `deinit` cancels Tasks). The primary leaf is never torn
down — if the user closes the primary leaf, we keep the primary controller alive and rebind
it: the primary controller is reassigned to the surviving leaf only if that leaf was the
fresh one; simplest rule — **the primary leaf cannot be closed if it is the active one and
is the only place the app-wide controller lives**; instead closing it swaps primacy to the
sibling leaf's controller for screen-toolbar/runtime-gate binding. (Decision: keep primary
leaf closable; `primaryController` stays alive and, when its leaf is closed, is re-homed to
the surviving sibling's nearest leaf by pointing that leaf at the primary controller is
overkill — instead `activeController` simply resolves to the active leaf, and
`primaryController` remains referenced by the workspace for the runtime gate. See §9.)

**`bind(threadID:toLeaf:)`**: `leaf(id)?.controller.openHistoryThreadAsync(threadID)`; set
`activeLeafID = id`; `persist()`.

### 2. Per-pane controller construction (minimal, backward-compatible controller change)

Add two optional, defaulted parameters to `ChatSessionController.init` so **every existing
call site is unchanged**:

```swift
init(dataStore: DataStore,
     settingsManager: SettingsManager = .shared,
     searchService: (any ChatSessionSearchProviding)? = nil,
     cliBridge: CLIBridge? = nil,
     memoryService: (any MemoryServing)? = nil,
     memoryExtractionEngine: MemoryExtractionEngine? = nil,
     initialThreadID: String? = nil,        // NEW
     persistsViewState: Bool = true)        // NEW
```

Behavior when `persistsViewState == false` (pane controllers):
- `init` sets `activeThreadID = initialThreadID ?? activeThreadID` and **skips** the
  shared-slot thread resolution (`resolveThreadID`/`loadPersistedMessages`-from-slot). It
  still seeds backend/model defaults from the shared keys (harmless read; gives a sensible
  default), and still runs the idempotent one-time migrations.
- Persistence **writes** become no-ops, guarded by a single stored `let persistsViewState`:
  - `persistActiveThreadSlot()` → `guard persistsViewState else { return }` at top.
  - `persistPanelGeometry()` → same guard.
  - each `chatModel*` `didSet` write → wrapped `if persistsViewState { UserDefaults... }`.
  - `setChatBackendAsync` UserDefaults write → guarded.
  - `chatViewMode` `didSet` write → guarded.

This guarantees pane controllers **never** touch the global chat keys, so the legacy
single-pane chat state can't be corrupted. Per-pane live model/backend selection still works
(in-memory `@Observable` props), satisfying "own model selector"; only cross-relaunch
persistence of per-pane model selection is intentionally out of scope (acceptance requires
persisting layout + bound threadID, not per-pane model).

Pane controller construction:
```swift
let tid = UUID().uuidString
_ = try await dataStore.createChatThread(id: tid)
let c = ChatSessionController(dataStore: dataStore, settingsManager: settingsManager,
                              initialThreadID: tid, persistsViewState: false)
```
Hydration of an existing thread happens in the pane view's `.onAppear` via
`controller.openHistoryThreadAsync(threadID)` (loads messages; the slot-persist inside is a
no-op for panes).

The **primary** leaf reuses the existing app-wide `controller` as-is (`persistsViewState:
true`, unchanged) so single-pane behavior and all other surfaces are untouched.

### 3. `PaneConversationView` (extracted reusable conversation)

New file `AgentLens/Views/Chat/PaneWorkspace/PaneConversationView.swift`. Renders ONE full
conversation for a given controller. Moves the screen-`@State` blockers inside:

```swift
struct PaneConversationView: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var isActive: Bool
    var showsCloseButton: Bool
    var onActivate: () -> Void
    var onClose: () -> Void
    var onJumpToConversation: (ConversationJumpTarget) -> Void = { _ in }

    @State private var brief = InsightBriefSnapshot()
    @State private var showCLIAssistantConsent = false
    @State private var atomRouter = HermesAtomRouter()
    private let maxContentWidth: CGFloat = 760

    // body: VStack {
    //   paneHeader            // compact: ChatEngineBackendStrip + ChatEngineModelMenu + close(X)
    //   conversation body     // welcomeState | ChatMessagesStream(...)
    //   Divider().opacity(0.35)
    //   centered ChatInputRow(...) onSubmit { Task { await controller.send() } }
    // }
    // .environment(settingsManager)                      // for ChatEngineModelMenu
    // .environment(\.hermesAtomNavigator, atomRouter)
    // .popover(item: atomRouter.pending) { HermesAtomDetailPopover(...) }
    // .sheet(isPresented: $showCLIAssistantConsent) { CLIAssistantConsentSheet(...) }
    // .overlay(focus ring when isActive)
    // .contentShape(Rectangle()).onTapGesture { onActivate() }
    // .onAppear { load brief; refreshHistory; (existing thread → openHistoryThreadAsync) }
}
```

`welcomeState`/`suggestionData`/`suggestionCard`/`Suggestion` move from
`DashboardChatWorkspaceView` into this view (their only external dependency is `brief` +
`controller` + `maxContentWidth`). The compact `paneHeader` gives each pane its own
model/backend picker (per-pane selection) and the close affordance.

### 4. Rendering the tree (custom split with live + persisted fraction)

New file `AgentLens/Views/Chat/PaneWorkspace/PaneWorkspaceView.swift`.

```swift
struct PaneWorkspaceView: View {
    @Bindable var workspace: PaneWorkspaceModel
    var settingsManager: SettingsManager
    var onJumpToConversation: (ConversationJumpTarget) -> Void

    func node(_ n: PaneNode) -> some View { /* recursive */ }
}
```

- Leaf → `PaneConversationView(controller: leaf.controller, isActive: leaf.id ==
  workspace.activeLeafID, showsCloseButton: workspace.paneCount > 1, onActivate: {
  workspace.setActive(leaf.id) }, onClose: { workspace.setActive(leaf.id);
  workspace.closeActive() }, ...)` wrapped with `.dropDestination(...)` (see §7).
- Split → a `GeometryReader` `PaneSplitContainer(split:)` that lays the two children along
  the split axis using `split.fraction`, with a draggable divider (6–8pt hit area) updating
  `split.fraction` live (`DragGesture` → `fraction = clamp((value.location.x or .y)/size,
  0.15, 0.85)`), calling `workspace.persist()` on drag end. Divider styled with
  `Colors.border` + hover cursor (`.onHover { NSCursor.resizeLeftRight/.resizeUpDown }`).

(GeometryReader chosen over `HSplitView` per the brief — gives a live ratio binding and a
persisted fraction, which `HSplitView` cannot.)

### 5. Keyboard (cmd+D / cmd+shift+D / cmd+W)

Attach hidden shortcut buttons in `PaneWorkspaceView` (in the key window's responder chain):

```swift
.background {
    Button("") { workspace.splitActive(axis: .horizontal) }
        .keyboardShortcut("d", modifiers: .command).hidden()
    Button("") { workspace.splitActive(axis: .vertical) }
        .keyboardShortcut("d", modifiers: [.command, .shift]).hidden()
    Button("") { workspace.closeActive() }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(workspace.paneCount <= 1)   // fall through to window-close when single pane
        .hidden()
}
```

A disabled shortcut button does not capture its key event, so single-pane `cmd+W` routes to
the standard window close. Pre-implementation check: grep the app for existing
`keyboardShortcut("d"...)` / `("w"...)` and menu `CommandGroup` bindings to confirm no
conflict; if `cmd+D` is taken, scope ours so the workspace wins when focused.

### 6. Active pane + focus ring

`workspace.activeLeafID` drives the ring. Each `PaneConversationView` draws
`RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Colors.whimsy.opacity(isActive ?
0.6 : 0.0), lineWidth: isActive ? 1.5 : 0)` as an overlay, and sets active on tap/focus.
Splitting/closing always targets `activeLeafID`, so the keyboard acts on the visibly-ringed
pane.

### 7. Drag & drop thread → pane

- Left rail: add `.draggable(thread.id)` to each `ChatHistoryRow` in `threadRail`'s `ForEach`
  (String payload; `import UniformTypeIdentifiers`). The existing `Button(onSelect)` still
  click-selects into the active/primary pane.
- Each leaf: `.dropDestination(for: String.self) { ids, _ in if let tid = ids.first { Task {
  await workspace.bind(threadID: tid, toLeaf: leaf.id) } }; return true } isTargeted: {
  hovering in dropTargetLeafID = hovering ? leaf.id : (dropTargetLeafID == leaf.id ? nil :
  dropTargetLeafID) }`. Highlight pane when `dropTargetLeafID == leaf.id` (a
  `Colors.whimsy.opacity(0.08)` fill + brighter ring). Only the dropped pane changes.

### 8. Persistence schema

`UserDefaults.standard`, new key `static let udPaneLayout = "paneWorkspace.layoutTree"`.

```swift
indirect enum PaneLayoutSnapshot: Codable {
    case leaf(paneID: UUID, threadID: String, isPrimary: Bool)
    case split(axis: SplitAxis, fraction: Double, first: PaneLayoutSnapshot, second: PaneLayoutSnapshot)
}
struct PaneWorkspaceSnapshot: Codable { let root: PaneLayoutSnapshot; let activePaneID: UUID }
```

- `persist()` walks the runtime tree → snapshot (`leaf.threadID = leaf.controller.activeThreadID`), `JSONEncoder` → key. Called on split/close/resize-end/bind/active-change and on thread switch within a pane.
- `restore(...)`: decode; if absent/invalid → single primary leaf bound to `primaryController.activeThreadID` (today's behavior). Else rebuild: primary leaf reuses `primaryController`; every other leaf builds a `persistsViewState:false` controller with `initialThreadID = snapshot.threadID`; rebuild splits with fractions. Threads that no longer exist (`dataStore.chatThreadExists`) fall back to a fresh thread for that pane. Set `activeLeafID` (validate it still exists, else first leaf).

### 9. Integration into `DashboardChatWorkspaceView`

- Add `@State private var workspace: PaneWorkspaceModel?` built in `.onAppear` via
  `PaneWorkspaceModel.restore(primaryController: controller, dataStore: dataStore,
  settingsManager: settingsManager)` (controller is the app-wide one passed in).
- Replace `conversationColumn` with `PaneWorkspaceView(workspace: workspace, settingsManager:
  settingsManager, onJumpToConversation: onOpenConversationJump)`.
- Toolbar + `hermesRuntimeGate` bind to `workspace.activeController` (falls back to
  `controller` before the workspace builds). `onNewChat`/clear act on `activeController`.
- Remove now-unused screen `@State` that moved into `PaneConversationView` (`brief`,
  `showCLIAssistantConsent`, `atomRouter`, `welcomeState` and helpers). Keep
  `showClearChatPrompt` (acts on active pane).
- `threadRail` unchanged except the added `.draggable` and that `onSelect` /
  `isActive`/`accent` now read from `workspace.activeController`.

## Backward compatibility

- All `ChatSessionController.init` call sites unchanged (new params defaulted).
- No layout snapshot → exactly one primary pane using the app-wide controller = pixel-identical to today, same global keys, same other-surface behavior.
- Pane controllers never write global chat keys, so the legacy single-pane experience cannot be corrupted by multi-pane usage.

## Edge cases & invariants

- Last pane is indestructible (`closeActive` no-op at `paneCount==1`); `cmd+W` falls through.
- Dropping a thread already open in another pane is allowed (two panes can show the same thread; both fetch independently; saves are row-keyed and serialized — safe, though concurrent sends to the same thread interleave by timestamp; acceptable, document it).
- Active leaf id always references a live leaf (validated after close/restore).
- `fraction` clamped `[0.15, 0.85]` so no pane collapses to zero.
- Primary controller stays alive for the whole screen; runtime gate/toolbar always have a controller.
- Splitting mints + persists a new thread up-front so a never-typed pane still restores as an empty thread (not the legacy thread).
- Never use the 1-arg `dataStore.saveChatMessage(_:)` (defaults to legacy thread) — panes always go through `controller.send()` which uses `activeThreadID`.

## File-by-file changes

New:
- `AgentLens/Views/Chat/PaneWorkspace/PaneWorkspaceModel.swift` — tree types + model + persistence.
- `AgentLens/Views/Chat/PaneWorkspace/PaneConversationView.swift` — extracted conversation + welcome + pane header.
- `AgentLens/Views/Chat/PaneWorkspace/PaneWorkspaceView.swift` — recursive renderer + split container + keyboard.

Edit:
- `AgentLens/Views/Chat/ChatSessionController.swift` — add `initialThreadID`/`persistsViewState` params + guards on the persistence writes + skip auto-resolve when injected.
- `AgentLens/Views/Chat/DashboardChatWorkspaceView.swift` — host the workspace, bind toolbar/gate to active controller, add `.draggable` to rows, remove moved `@State`/welcome.
- Possibly `DashboardChatWorkspaceToolbar.swift` — accept the active controller (already takes `controller`; just pass `workspace.activeController`).
- Xcode project: add the three new files to the `AgentLens` target (pbxproj / folder-synced group — verify how this project adds files).

## Verification plan

1. `xcodebuild` the AgentLens scheme (Debug) → green (quit any running /Applications copy first per memory: Firestore single-process lock).
2. Launch; confirm single pane == today (welcome, send, history, model picker).
3. `cmd+D` → two columns; `cmd+shift+D` on one → 2×2 grid. New pane is active (ring) + empty.
4. Drag four distinct threads onto the four panes → each loads only its target; hover highlight correct.
5. Type+send in each pane; confirm streams isolated (two stream concurrently, no cross-talk).
6. Resize a divider; close a pane (`cmd+W`) → sibling reclaims space; single pane `cmd+W` closes window.
7. Relaunch → layout, fractions, and bound threads restored; active pane restored.
8. Confirm legacy keys uncorrupted (single-pane chat still opens its prior thread).

## Risks & mitigations

- **`cmd+D`/`cmd+W` conflicts** → grep existing shortcuts/menu commands; scope ours to the focused workspace; disabled cmd+W for fall-through.
- **Controller persistence guard misses a write site** → enumerate every `UserDefaults.standard.set` in `ChatSessionController*.swift` and guard each; test that multi-pane never mutates legacy keys (snapshot defaults before/after).
- **Async split race** (thread creation vs. immediate second split) → serialize tree mutations on the main actor; the split builds the leaf, swaps the tree, then awaits thread creation completion before persist.
- **pbxproj file add** → confirm whether the project uses folder-synced groups (no pbxproj edit) or explicit refs; add correctly so the build sees new files.
- **`@Observable` granular updates** → use class nodes so `fraction`/child swaps are observed; reassign `root`/parent child refs to trigger SwiftUI.
- **CMUX factory auto-commit** (memory) → commit pane work promptly.

---

# v2 — resolutions from the adversarial loophole-hunt (authoritative; supersedes conflicts above)

The 5-critic review found 8 blockers + majors. These are the binding decisions.

## Build mechanics (was wrong in v1)
- The project is **XcodeGen**. Target/scheme is **`OpenBurnBar`**, NOT "AgentLens" (that's just the source dir). `project.yml` globs `AgentLens` recursively and does not exclude `PaneWorkspace/`, so **no `project.yml` edit** is needed — but after creating files I must run `xcodegen generate --spec project.yml` and commit the regenerated `OpenBurnBar.xcodeproj/project.pbxproj` (CI has an xcodegen-drift gate; never hand-edit pbxproj).
- Compile check: `xcodegen generate --spec project.yml && xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -configuration Debug -destination 'platform=macOS,arch=arm64' -clonedSourcePackagesDirPath .spm-cache -derivedDataPath .derived-data build`. Full runnable app = `make build` (embeds daemon/framework).

## Controller refactor (§2) — hardened
- Assign `self.persistsViewState` and `self.activeThreadID = initialThreadID ?? <default>` at the **very top** of `init`, before the `chatModel*` reads.
- `persistsViewState == false` ⇒ guard EVERY write site: the `chatModel*` didSets, `chatViewMode` didSet, `persistActiveThreadSlot`, `persistPanelGeometry`, the `udChatBackend` write, **and the previously-missed `resolveThreadID` writes (lines ~1325/1332/1338/1350) + `migrateCodexThreadFromLegacyIfNeeded` (line ~1310)**. Add `guard persistsViewState else { return }` to those two methods too.
- **`setChatBackendAsync` must branch**: when `persistsViewState == false`, do NOT call `resolveThreadID` and do NOT reassign `activeThreadID` — keep the pane's bound thread, set `chatBackend`, re-fetch messages for the SAME thread, and still run the stream-cancel/probe/health side effects. (Otherwise a per-pane engine switch yanks the pane onto the global thread AND writes global keys — the core safety break.)
- **Restore hydration**: `openHistoryThreadAsync` early-returns when `threadID == activeThreadID`, so it can't hydrate a pane whose `activeThreadID` is already its bound thread. Add `func hydratePaneThread() async` that unconditionally fetches `messages` for the current `activeThreadID` (mirrors openHistoryThreadAsync's body minus the guard + minus the slot persist). Pane `onAppear` calls `hydratePaneThread()` + `refreshHistory()` — **never** `loadPersistedMessages()`. The **primary** pane keeps calling `loadPersistedMessages()` (today's behavior).
- **Teardown**: a streaming pane's controller will NOT be freed by ARC (the `streamTask` `guard let self` strongly retains it), and `deinit` never calls `cliBridge.cancel()`. Add `func teardownForPaneClose()` = `streamTask?.cancel(); cliBridge.cancel(); streamTask = nil; isStreaming = false`. `closeActive` calls it on every controller it removes, before dropping the reference.

## Workspace model (§1/§8) — hardened
- **Split ordering is fully synchronous** (no await before the tree mutation): mint `newID`; build the pane controller synchronously with `initialThreadID: newID, persistsViewState: false` (so its `activeThreadID` is `newID`, never the legacy thread); insert the `PaneSplit`, flip `activeLeafID` — all in one main-actor turn; THEN `Task { _ = try? await dataStore.createChatThread(id: newID) }` and `persist()`. (`saveChatMessage` upserts the row and `createChatThread` is `INSERT OR IGNORE` idempotent, so a send before the row exists is safe.)
- **Invariant: exactly one live leaf has `controller === primaryController` (the primary leaf) at all times.** Closing a NON-primary leaf: `teardownForPaneClose()` then drop. Closing the PRIMARY leaf (allowed — acceptance requires close+reflow): pick `survivor` = top/left-most leaf of the sibling subtree; `primaryController.openHistoryThreadAsync(survivor.activeThreadID)`; rebuild that survivor node as a fresh `PaneLeaf(controller: primaryController, isPrimary: true)`; `teardownForPaneClose()` the survivor's discarded pane controller; set `activeLeafID` to the new primary leaf. PrimaryController is thus always rendered and always the relay/toolbar/gate target.
- **persist() triggers** add: controller-initiated thread change. PaneConversationView adds `.onChange(of: controller.activeThreadID) { workspace.persist() }` so New-chat/clear/cmd+N re-snapshot.
- **restore() is synchronous** (decode JSON → build tree + controllers; no DB await) so the workspace is built in the view's `init` via `State(wrappedValue:)` (no first-frame flash / dead-shortcut gap). Message hydration + `chatThreadExists` fallback happen per-pane in `onAppear`. Enforce **exactly-one-primary**: count `isPrimary` leaves — zero ⇒ promote first leaf; >1 ⇒ keep first, demote rest to fresh `persistsViewState:false` controllers. Validate `activePaneID` exists else first leaf.
- Edge note: `AgentCapabilityGrantStore.shared` is keyed by `(runtimeID, threadID)`; two panes on the same thread+backend share one desktop-control grant (revoke in one affects the other). Documented limitation for v1.

## SwiftUI (§4/§5/§6) — hardened
- **Render with mutually-recursive nominal View structs**, not a recursive `some View` function (won't compile): `PaneNodeView` (switches leaf→`PaneConversationView`, split→`PaneSplitContainer`) and `PaneSplitContainer` (embeds two `PaneNodeView`). Tag each with `.id(node.id)` so structural moves preserve sibling identity (scroll/focus/onAppear).
- **Divider drag** uses translation, not absolute location: capture `fractionAtStart` on first `onChanged`, then `fraction = clamp(fractionAtStart + value.translation.(x|y)/size, 0.15, 0.85)`. `persist()` on drag end. Resize cursor via `.onHover`.
- **Pane activation** uses `.simultaneousGesture(TapGesture().onEnded { onActivate() })` (so the composer TextField and message links still get the click) PLUS `@FocusState` on the input → activate on focus.
- **cmd+W**: do not mount the shortcut button at all when `paneCount <= 1` (guaranteed fall-through to window close); mount it only when `paneCount > 1`. cmd+D / cmd+shift+D always mounted. (Grep confirmed no existing cmd+D/cmd+W binding; cmd+N precedent in threadRail proves SwiftUI shortcuts fire in these windows.)

## Integration / UX (§3/§9) — hardened
- Keep `.hermesRuntimeGate(controller: controller, ...)` bound to the **app-wide primary controller** (stays alive whole screen), NOT `activeController` — else the Hermes/Pi setup wizard fires on every pane switch and can capture a torn-down controller. Only the toolbar pickers and `onNewChat`/clear bind to `activeController`.
- When deleting screen `@State`, **relocate** their modifiers into `PaneConversationView`: atom-navigator `.environment` + atom `.popover` + `.task { atomRouter.onPerform }`, the `brief` build (onAppear + per-pane `.onChange(of: dataStore.usagesVersion)`), and the CLI-consent `.sheet`. Keep `controller.refreshRetrievalHealth(...)` at the screen level (split out of the usagesVersion handler) operating on `activeController`.
- **Chrome only when tiled**: `showsChrome = paneCount > 1`. Single pane ⇒ no pane header, no focus ring, no activation gesture = pixel-identical to today; the top toolbar keeps its engine pickers. Multi-pane ⇒ each pane shows a header (`ChatEngineBackendStrip` + `ChatEngineModelMenu` + split-right + split-down + close) and the top toolbar **hides** its engine pickers (new `showsEnginePickers: Bool` param, = `paneCount <= 1`) to avoid duplication.
- **Split affordance** (discoverability for mouse users): split-right / split-down buttons in the pane header (cmux-faithful), calling `workspace.splitActive(axis:)`.
- **Left-rail multi-pane highlight**: add `boundThreadIDs: Set<String>` to `PaneWorkspaceModel`; extend `ChatHistoryRow` with `isOpenInPane: Bool` (subtle dot/indicator) while the strong ring+checkmark stays on `activeController.activeThreadID`.

---

# v3 — fixes from the post-implementation correctness review (5 agents)

The implementation was reviewed by 5 adversarial agents (controller guards, tree algorithms, SwiftUI/observation, integration/parity) with each finding independently re-verified. Two reviewers verified **no blockers** outright; the confirmed defects below were fixed:

1. **`teardownForPaneClose` must NOT revoke desktop control.** Grants are process-global keyed by `(runtimeID, threadID)`; revoking on a pane *close* would yank a sibling pane's active grant when both show the same thread+backend. Reverted to the spec'd teardown (cancel `streamTask` + `cliBridge` only); cancelling the stream already stops the closed pane from issuing tool calls, and the grant TTL-expires. Thread-*switch* paths still revoke (the live controller is leaving the thread, not being destroyed).
2. **Rail staleness across panes.** The shared rail is bound to the primary controller's `historyThreads`; a non-primary pane creating/updating a thread refreshed only its own controller (and `usagesVersion` doesn't bump on save). Fix: `PaneConversationView` refreshes `workspace.primaryController.refreshHistory()` on a non-primary pane's `activeThreadID` and `messages.count` changes.
3. **`hydratePaneThread` clobbered an in-flight stream.** A streaming non-primary pane recreated by a sibling split/close re-runs `onAppear → hydratePaneThread`, which overwrote `messages` with DB rows (no streaming row yet). Fix: guard `!isStreaming` before and after the fetch (mirrors `loadPersistedMessagesAsync`).
4. **Primary re-home race on close.** Closing the active primary pane re-homes `primaryController` via async `openHistoryThread(survivorThread)`, but the recreated primary view re-ran `loadPersistedMessages()` → re-resolved the global slot, racing the re-home. Fix: a `primaryDidInitialLoad` flag on the model (survives view recreation) resolves the slot exactly once; later recreations hydrate the current thread instead.
5. **Divider cursor stack imbalance (minor).** Switched `NSCursor.push()/pop()` to `.set()` so a split/close performed while hovering the divider can't leave a stuck resize cursor.

Reviewers also explicitly checked type/API signatures across the new code and found no compile/signature mistakes.

**Accepted v1 limitations (documented, not bugs):** two panes on the same thread+backend share one desktop-control grant; a non-primary pane mid-stream that is left on screen teardown self-cleans only when its stream ends (parity with the long-lived app-wide controller); splitting/closing re-`onAppear`s the directly-affected pane (scroll/transient `@State` reset) — untouched sibling subtrees keep their state.

# v4 — review-pass polish

- **`setActive` persists.** A plain focus change now snapshots `activePaneID`, so the last-focused pane is restored on relaunch (previously only split/close/bind/thread-change persisted).
- **Divider affordance.** The resize divider thickens slightly (7pt) and brightens to the accent on hover/drag, making the grab target obvious.
- **Tests added.** `AgentLensTests/Active/PaneWorkspaceModelTests.swift` — 16 XCTest cases covering split (axis, isolation, distinct threads), close (non-primary reflow, primary re-home keeps the controller, last-pane indestructible, nested), persistence round-trip, the exactly-one-primary repair (zero/multiple/invalid-active/fraction-clamp corrupt blobs), `boundThreadIDs`, and the Codable snapshot round-trip. Registered in the project via XcodeGen.

# Build verification status (definitive)

A full headless build/test could not be completed **in this background environment** for two independent, environment-level reasons — confirmed across 9 build attempts, neither related to the code:

1. **Xcode 27.0 Beta build-task sandbox** marks the source tree read-only, so `ProcessXCFramework` cannot extract the vendored binary xcframeworks (SQLCipher/Firebase/gRPC/Sentry/absl/…) into the in-repo `.spm-cache`.
2. **Intermittent macOS TCC on `~/Documents` for spawned shell subprocesses.** The agent's own file tools (Read/Edit/Write) and `xcodegen` have reliable access, but `cp`/`ls`/`xcodebuild` subprocesses intermittently get `Operation not permitted` reading repo files (e.g. `Vendor/`, `project.yml`) — so neither building in-place nor copying the source out of Documents completes reliably.

The maintainer path (`make build`, scheme **`OpenBurnBar`**, or Xcode.app) runs in an interactive, TCC-granted context and is unaffected. Verification here rested on two independent multi-agent review rounds (design loophole-hunt + implementation review, both incl. type/API-signature checks) plus the new unit tests. **To get the definitive compile + test run:** `xcodegen generate --spec project.yml && make build`, then run `PaneWorkspaceModelTests` (e.g. via Xcode's test navigator or `xcodebuild test -only-testing:AgentLensTests/PaneWorkspaceModelTests`).
