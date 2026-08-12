# Agent Deck — macOS Chat window agent switcher redesign

**Status:** implementation spec, ready to build.
**Surface:** `DashboardChatWorkspaceView` (embedded `mainRoute == .chat` **and** the `.popOut` NSWindow — one view, two hosts) plus every tiled `PaneConversationView` header.
**Ships as:** three independently landable PRs (§9). PR 1 alone fixes the headline problem.
**Every line/file reference below was verified against the working tree on 2026-08-09.** Where a proposal's claim did not survive verification, the correction is called out inline.

---

## 1. The problem, in the owner's terms

> *I have twelve agents. The chat window has one job beyond rendering text: tell me which one is about to spend my money, and let me change it in under a second. Right now it does neither.*

### 1.1 What is actually broken

Everything below is a defect in shipped code, not an aesthetic opinion.

**a. The active agent has no name.** The only two places the window says the agent's name in words are the composer placeholder (`ChatInputRow.swift`, "Ask Codex…") and the empty-state subtitle (`PaneConversationView.welcomeState`). The placeholder dies on the first keystroke. The subtitle dies on the first message. From message one onward the sole identification is a ~12pt logo inside a gradient capsule (`ChatEngineBackendStrip.swift:52-80`) whose name exists only in an `.accessibilityLabel` and a hover tooltip.

**b. The tab-title fallback is a decoy.** `PaneWorkspaceModel.displayTitle(for:)` (`:367-381`) falls through to `chatBackend.displayName`, so a fresh tab reads "Hermes" — and stops reading "Hermes" the instant the thread earns a title. It never tracked the agent; it filled a blank.

**c. Ten of twelve agents are the same colour.** `ChatBackendID.gradient` returns `mercuryGradient` for Hermes, `piGradient` for Pi, and one shared `accentGradient` for the other ten. Colour distinguishes Hermes from not-Hermes and nothing else.

**d. Tiling deletes the control.** `DashboardChatWorkspaceView.swift:63` passes `showsEnginePickers: !workspace.isTiled`. Split a pane and the top of the window goes anonymous; the only agent control left is an 11pt strip inside each pane header.

**e. With one agent enabled the control stops being a control.** `ChatEngineBackendStrip.swift:41-47` renders a bare `Image` — not a `Button`, no capsule, no selection state. With zero enabled it renders the dead 9pt string `"Settings → Chat: enable engines"`, which names a destination it cannot navigate to.

**f. Nine of twelve agents are unknowable from this window.** The strip iterates `settingsManager.enabledChatBackends` only. Nothing in the Chat window tells a user that Junie, Antigravity, or Droid exist.

**g. One click, two opposite meanings.** `setChatBackendAsync` (`ChatSessionControllerBackendGatewayRouting.swift:675`) gates its whole thread-swap block on `persistsViewState`. On the primary single-pane surface, clicking a different agent **navigates away from your conversation** into that agent's own thread. In a tiled pane (`persistsViewState == false`, `PaneWorkspaceModel.makePaneController` at `:826`) it **keeps the conversation** and only changes the driver. Same pixel, opposite outcome, zero labelling.

**h. The same click silently cancels and revokes.** That function cancels `streamTask`, calls `cliBridge.cancel()`, clears `selectedContext` / `conversationJumpTargets`, and calls `revokeDesktopControl()` unconditionally (≈`:691`). The desktop-control grant the user just approved dies on an unlabelled icon tap.

**i. The engine pill lies under Elder Wand.** `isElderWandActive` re-targets the send to the BurnBar daemon fusion gateway with a different catalog while the pill still reads "Hermes".

**j. The model is under-stated and, for Hermes, wrong.** `chatModelMenuTitle()` (`:465`) renders `abbreviateChatModelName(effectiveChatModel(for:))` at 9pt. For Hermes with a cold catalog, `effectiveChatModel` returns the literal gateway self-alias `"hermes"` (`:334`, constant at `:353`) or a bare family token like `"claude"`. The picker therefore reads **"Hermes · hermes"**. And `HermesModelStrip` — the second-level family picker that makes Hermes' routing legible — is wired into `ChatPanelHeader` and the menu-bar popover but **not** into this surface at all.

**k. Provenance is unrecoverable.** `ChatMessageRecord` (`ConversationRecord.swift:40-57`) has exactly one attribution field, `cliUsed: String?`, stamped only on the first assistant message of a thread. No model, no provider, no account, ever. Combined with (g), a stored thread can mix four agents with no durable record of which turn came from where.

**l. Three shortcut collisions, all unverified.** `DashboardView.swift:691` binds ⌘1–⌘8 to `primarySections`; `PaneWorkspaceView.swift:75` binds ⌘1–⌘9 to tabs; `MacAgentInsightsWorkspace.swift:254` binds ⌘1–⌘n again. All are enabled hidden buttons in one responder chain. Separately **⌘K is registered twice** — `DashboardView.swift:705` and `BurnBarTopRail.swift:491` — and ⌘L twice (`DashboardQuickSwitchView.swift:879` and `:907`). `docs/qa/CHAT_PANE_TABS_QA.md` marks the ⌘1–9 row **NOT RUN**.

### 1.2 The bar this spec is held to

After PR 1, at every window width, in every mode (embedded, pop-out, single-pane, tiled), with 0/1/12 agents enabled, with the composer full of text and the thread titled: **the agent's name and its model are on screen in words, and the presence dot says what it is doing.** No `ViewThatFits` tier, no degenerate count, no tiling state removes them.

---

## 2. Concept model

### 2.1 The commitment

**In this window, "agent" means exactly one thing: a `ChatBackendID` case.** Twelve of them. That is what the picker has always changed; it just never said the word.

| User-facing noun | Type | What it is | Switchable here? |
|---|---|---|---|
| **Agent** | `ChatBackendID` | The harness that drives the turn. Two families: **gateway agents** (Hermes 8642, OpenClaw 18789, Pi 8765 — OpenAI-compatible HTTP) and **local agents** (the nine CLI subprocesses, `requiresCLIAssistantConsent == true`). | **Yes** — this spec's whole subject |
| **Brand** | `AgentProvider` → `ProviderID` | Who gets billed and whose logo is drawn. Every `ChatBackendID` maps to exactly one via `agentProvider`. | No (never here) |
| **Model** | `String`, per-agent, resolved by `effectiveChatModel(for:)` | The string the harness is told to run. App-wide per agent — **not attached to the thread**. | **Yes** — Sigil model segment / roster `/` scope |
| **Route** (Hermes only) | `HermesModelID` | Hermes is a router. Its fifth layer picks the family it routes to: codex / claude / zai / kimi / minimax / ollama. | **Yes** — new on this surface (§3.4) |
| **Account** | `SwitcherProfileRecord` | Which credential is burning. Codex can fail over mid-send via `CLIProfileStreamFailoverRunner`. | **No** — explicit non-goal (§10) |
| **Chat** | thread id (UUID) in `chat_threads` | One conversation. Lives in a pane; panes live in tabs. | Yes (rail, tabs, panes) |

**Copy law:** the word "engine", "backend", "runtime", "harness", and "surface" never appear in user-facing strings on this window again. Everything the user reads says **agent**, **brand**, **model**, **route**, **chat**. The kind sub-label is borrowed verbatim from the mobile twin (`OpenBurnBarMobile/Views/Hermes/AgentSwitcherSheet.swift`), the only place in the repo that already ships explanatory copy: **"Agent harness"** (Hermes), **"Empathy agent"** (Pi), **"CLI agent"** (the nine local ones), **"Gateway agent"** (OpenClaw).

### 2.2 What is renamed, merged, or migrated

- **Renamed:** display copy only. `ChatBackendID` raw values are frozen (they are persisted in `chatBackendID`, in `PaneLeafSnapshotV2.backend`, in `enabledChatBackendIDsCSV`, and mirrored by `AssistantRuntimeID` whose `"hermes"`/`"pi"` raws are declared frozen for Android DataStore). **No type is renamed in these three PRs.** Renaming `ChatBackendID` → `ChatAgentID` is a separate mechanical PR with zero user-visible effect; it is deliberately not bundled here.
- **Merged:** nothing. The four layers stay four layers; the redesign's job is to *show* them, not to collapse them.
- **Migration:** PR 1 and PR 2 require **none** — every fact they render already exists in memory or in `PaneWorkspaceSnapshotV2`. PR 3 adds **DB migration v61** (`chat_messages.engineID TEXT`, `chat_messages.modelID TEXT`); latest shipped is `v60_billing_kind` (`OpenBurnBarDatabase+MigrationV60.swift:28`). v61 invalidates the byte-compat fixture kit — budgeted in §9.3.
- **UserDefaults added:** `agentDeck.recentAgents.v1` (JSON array of raw values, MRU, same pattern as `burnRailSearch.recents.v1` at `CommandDeckPalette.swift:25`). Nothing else.

---

## 3. The design

Two objects and one model.

1. **The Sigil Bar** — always-on, in the toolbar and in every pane header. Answers *who is answering, on what model, doing what.* Owns the mouse path.
2. **The Agent Roster** — a ⌘⇧A palette over `CommandDeckPalette`'s vocabulary. Answers *who else exists, and what happens if I switch.* Owns the keyboard path and discovery.
3. **`AgentPresenceModel`** — one `@Observable`, fleet-wide, computed from state that already exists. Owns truth.

### 3.1 Window wireframe — embedded, single pane, 1440pt

```
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ◆ Codex · gpt-5-codex ⌄  │ ☿ ✦ ⚡ ◆ ➤ +7 │ [Agent|CLI] [78%] 📁 ✋ ⌘⇧A  ✎  ⋯  ⧉  ▣      │  ← toolbar 26pt row
│ └─ the Sigil ─────────────┘ └─ ghosts ────┘                                                │
├──────────────┬─────────────────────────────────────────────────────────────────────────────┤
│  ⊕ New chat  │ ┌ ✦Claude ─────┐┌ ☿Hermes ●┐┌ ◆Codex ⚡ ┐  +   ↺                            │  ← tab strip 26pt
│  🔍 Search   │ └──────────────┘└──────────┘└──────────┘                                    │     (agent marks, §3.5)
│              ├─────────────────────────────────────────────────────────────────────────────┤
│  ▸ Refactor  │                                                                             │
│    the parse │                        (transcript, maxWidth 760)                            │
│  ▸ Cost by…  │                                                                             │
│  ▸ Where did │                                                                             │
│              ├─────────────────────────────────────────────────────────────────────────────┤
│              │ ┃ 📎 │ Ask Codex…                                        │ ⬆              │  ← 3pt sigilTint bar
│   260pt      │ ↑ leading tint bar survives the first keystroke                              │
└──────────────┴─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 The Sigil — anatomy

`AgentSigil` is a single interactive capsule, ~26pt tall, in the toolbar's leading slot. **Two segments in one plate**, separated by a hairline `Divider().frame(height: 12).opacity(0.35)`:

```
┌─────────────────────────────────────────────────────────┐
│ ●  ◆  Codex          │  gpt-5-codex ⌄       ⌘⇧A         │
│ │  │  │              │  │                    │           │
│ │  │  └ 12pt semibold│  └ 10pt medium        └ 9pt mono, │
│ │  │    rounded         rounded, textSecondary  hover only│
│ │  │    textPrimary     max 132pt, .middle trunc          │
│ │  └ ProviderLogoView(size: 14, useFallbackColor: false)  │
│ └ presence dot, 6pt, leading, inset Spacing.xs           │
└─────────────────────────────────────────────────────────┘
   ↑ agent segment: click → roster in @ scope
                          ↑ model segment: click → the model Menu
```

- **Agent segment** (`dot + logo + name`) is a `Button` → opens the Agent Roster pre-scoped to `@`.
- **Model segment** (`model text + chevron`) is a `Menu` whose content is **the existing `ChatEngineModelMenu` rows, unchanged**. `ChatEngineModelMenu` is *not* deleted; its body is extracted to `@ViewBuilder static func modelRows(controller:)` and the old view becomes a thin wrapper so `ChatPanelHeader` and `ChatMenuPopover` keep working untouched. *(Both runner-up proposals claimed to delete this menu and neither said where the model went. That is the single biggest defect in the runners-up and it is corrected here.)*
- **Right-click anywhere on the Sigil** → the same model menu as a context menu, plus "Agent settings…", "Restart gateway" (Hermes/OpenClaw/Pi), "Set as default agent".
- **When `workspace.isTiled`**, the Sigil prefixes the focused pane's 6pt `PaneColorChip` and its menu header reads `Focused pane · <pane title>`. The Sigil's plate tint and the focused pane's 1.5pt ring are **the same colour**, which is what ties a window-level control to the pane it drives.
- **When `controller.isElderWandActive`**, an 8pt `wand.and.stars` in `hermesAureate` sits between the name and the divider, and the model segment reads `Fusion → BurnBar gateway · <judge model>`. The pill stops lying (defect **i**).

### 3.3 The model segment is never allowed to lie or vanish

Three rules, all enforced in one function `AgentSigil.modelLabel(controller:)`:

1. **Alias never leaks.** If `effectiveChatModel(for: .hermes) == ChatSessionController.hermesCanonicalModelAlias` (`"hermes"`, `:353`), render **`Auto (gateway picks)`**. If it resolved to a bare family token (`"claude"`, `"codex"`, … — the `:328-329` branch), render **`Auto → Claude`**. Never print the raw alias.
2. **Route is shown, not hidden.** For `.hermes`, the label is `<model> · via <family>` when a `HermesModelID` family is selected and the catalog resolved a concrete model — e.g. `claude-sonnet-4-6 · via Claude`. This is the first time the Hermes routing ladder is legible on the full-canvas surface.
3. **The model never yields to a timer.** During `.streaming` the model text stays exactly where it is; elapsed time appears as a separate 9pt monospaced suffix after the dot (`● 41s`), and drops out first under width pressure. *(The winning proposal swapped the model for the timer. Rejected: the model matters most while a turn is running.)*

### 3.4 Hermes route picker, finally on this surface

`HermesModelStrip(controller:settingsManager:)` already exists, already renders `EmptyView()` unless `chatBackend == .hermes`, and already writes through `SettingsManager.applyHermesModelSelection`. It gets two homes on this window:

- As a **section header + rows inside the model Menu** when the agent is Hermes: `ROUTE` (9.5pt bold tracking-1.0, matching the palette header at `CommandDeckPalette.swift:197`), then one row per enabled `HermesModelID` with the family's provider logo, then a divider, then the existing model rows.
- As a **section in the roster's `/` scope**, same rows.

No second toolbar row, no 24pt layout jump on tab switch. *(The Agent Rail proposal put the strip in a conditional second rail row; that makes the transcript jump 24pt every time you select a Hermes tab. Rejected.)*

### 3.5 The ghost row — the mouse path, protected

Trailing the Sigil, the *other* enabled agents render as one-click 18pt `Button`s: `ProviderLogoView(size: 18)` at 0.62 opacity / 0.55 saturation, each with its own 5pt presence dot and a `.popoverTooltip("Claude Code — CLI agent — Ready — ⌘⌥2")`. Hover restores to 1.0 with `DesignSystem.Animation.hover` and scale 1.06; press 0.96 `snappy`. Cap at **5 ghosts**; beyond that a `+N ⌄` chip opens the roster.

> **This is a deliberate correction to the winning proposal.** It specified 14pt nameless ghosts at 0.55 opacity as the *first* thing `ViewThatFits` discards — which would make one-click switching disappear on a narrow pop-out and in tiled mode, i.e. make the roster *less* visible, inverting the goal. Here the ghost row collapses to a single `N ⌄` chip but is **never** dropped to nothing.

### 3.6 `ViewThatFits` tier ladder (replaces the two-variant `controlRow`)

`DashboardChatWorkspaceToolbar.swift` keeps its `ViewThatFits(in: .horizontal)` shape and grows from 2 tiers to 6. Order of sacrifice, widest first:

| Tier | Drops |
|---|---|
| 1 | — (everything) |
| 2 | folder button, "Restore floating chat", "Pop out" (all three already duplicated in `ChatMenuPopover`) |
| 3 | `ChatViewModePicker`, `ProviderQuotaChip` (both already duplicated in `ChatMenuPopover`) |
| 4 | ghost row → single `N ⌄` chip |
| 5 | elapsed-time suffix; model segment narrows to 60pt with `.truncationMode(.middle)` |
| 6 | `displayName` → `shortLabel` |

**Floor, never crossed:** `presence dot + logo + shortLabel + model(≥40pt) + N⌄ + desktop-control + new-chat + ellipsis`. The `showsEnginePickers: !workspace.isTiled` parameter is **deleted** — the toolbar never goes anonymous again.

### 3.7 Tab agent marks (zero schema cost)

`PaneLeafSnapshotV2` has carried `backend` per leaf since V2; it was simply never drawn. `ConversationTabStrip` gains, left of the existing 8pt `PaneColorChip`, a stack of up to three 10pt `sigilTint`-ringed squircle marks for the distinct agents live in that tab, overlapping 4pt, `+N` at 8pt beyond three. `PaneWorkspaceModel.displayTitle(for:)` **drops its `chatBackend.displayName` fallback**; the chain becomes tab title → thread title → leaf custom title → "Tab N". Tab height is unchanged at 26pt.

This also answers what "the tab's agent" means when `paneCount > 1`: **the marks are plural because the tab is plural.** *(The Agent Rail proposal's "every tab is an agent" thesis breaks on ⌘D; the mark stack is the honest version of the same idea.)*

### 3.8 The Roster — wireframe

```
                         ┌──────────────────────────────────────────────────────┐  560 × 460
                         │ 🔍 codex                                        esc  │
                         ├──────────────────────────────────────────────────────┤
                         │ AGENTS                                               │  9.5pt bold, tracking 1.0
                         │ ┃◆ Codex            CLI agent · Ready · 47% left     │  ← selected, fill tint@0.12
                         │ │                   ↩ switch · keeps this chat       │  ← consequence hint
                         │  ✦ Claude Code      CLI agent · answering in Tab 2 · 41s│
                         │                     ↩ switch · opens Claude's chat   │
                         │  ☿ Hermes           Agent harness · needs setup      │
                         │                     ↩ opens the Hermes setup wizard  │
                         │  π  Pi Agent        Empathy agent · offline          │
                         │                     ↩ launches Pi, then switches     │
                         ├──────────────────────────────────────────────────────┤
                         │ MODELS  (/)                                          │
                         │  ⌁ gpt-5-codex               applies to your next msg│
                         ├──────────────────────────────────────────────────────┤
                         │ NOT ENABLED — ↩ to turn on                           │
                         │  ✽ Junie            CLI agent · not installed        │
                         │  ✧ Antigravity      CLI agent · ready to install     │
                         ├──────────────────────────────────────────────────────┤
                         │ ↩ switch   ⇧↩ hand off   ⌘↩ second opinion           │  persistent legend, 9.5pt
                         └──────────────────────────────────────────────────────┘
```

Row vocabulary is copied verbatim from `CommandDeckPalette.swift`: `.padding(.horizontal, 16).padding(.vertical, 7)`, `RoundedRectangle(cornerRadius: 8, style: .continuous)` selection fill, `.onKeyPress(.upArrow/.downArrow/.escape)` (`:39/:43/:47`), 200ms debounce, `matchesSubsequence` fuzzy match (`:374`), `ScrollViewReader` + `scrollTo(_, anchor: .center)` on `Animation.snappy`, `.focusable().focusEffectDisabled()`.

Deltas: frame **560 × 460** (rows carry two lines, 520 × 420 crowds); selection fill is `row.tint.opacity(0.12)` not a fixed ember, so arrowing previews each agent's colour; every row carries a **consequence hint**; scopes are `@` agents / `/` models + route / `#` chats / `>` panes & tabs.

**The `NOT ENABLED` group enumerates `ChatBackendID.allCases` minus `settingsManager.enabledChatBackends`.** It is the only place in the app where a user who has never opened Settings → Chat can learn the other nine agents exist. ↩ on a disabled row appends to `enabledChatBackendIDsCSV` and switches in one action.

---

## 4. Switching, in full

### 4.1 Mouse

| Gesture | Result |
|---|---|
| Click a ghost logo | Verb 1 — switch the focused pane's agent |
| ⌥-click a ghost | Verb 3 — second opinion (split right, same thread, other agent) |
| Click the agent segment of the Sigil | Roster in `@` scope |
| Click the model segment | The model Menu (+ `ROUTE` section when Hermes) |
| Right-click the Sigil | Model menu as context menu + agent settings + restart gateway |
| Click the `+N ⌄` chip | Roster in `@` scope, scrolled to the first hidden agent |
| Click a tab's agent mark | `workspace.focusPane(paneID, inTab:)` for that agent's pane |

### 4.2 Keyboard — proposed bindings, audited against every registration in `AgentLens/`

Full inventory (`grep -rn 'keyboardShortcut' AgentLens/ --include='*.swift'`, 60 hits) and what it proves:

| Binding | Registered at | Verdict |
|---|---|---|
| ⌘1–⌘8 | `DashboardView.swift:691` | **Keep.** App-global nav wins the digit key. |
| ⌘1–⌘9 (tabs) | `PaneWorkspaceView.swift:75` | **DELETE.** Ambiguous against the above in one responder chain; `docs/qa/CHAT_PANE_TABS_QA.md` marks it NOT RUN, so no verified behaviour is lost. ⌘⇧[ / ⌘⇧] already cover tab navigation. |
| ⌘1–⌘n, ⌘0 | `MacAgentInsightsWorkspace.swift:254,262` | Out of scope (different route), but note it in the QA doc. |
| ⌘K | `DashboardView.swift:705` **and** `BurnBarTopRail.swift:491` | **Double-bound today.** PR 1 removes the `BurnBarTopRail` registration and leaves `DashboardView` as the single owner. **The roster does not take ⌘K.** |
| ⌘L | `DashboardQuickSwitchView.swift:879` **and** `:907` | Also double-bound. Flagged, not fixed here. |
| ⌘⇧M | `MissionFAB.swift:55` | **Taken.** The winning proposal wanted ⌘⇧M for models; it is unavailable. |
| ⌘⇧S | `DashboardQuickSwitchView.swift:825` | Taken. |
| ⌘⇧D/T/[/]/←/→/↩/U, ⌘D, ⌘T, ⌘W | `PaneWorkspaceView.swift:50-71` | Unchanged. |
| ⌘N | `DashboardChatWorkspaceView.swift:187`, `MissionsLaneView.swift:166`, `AccountSwitcherSettingsView+Rendering.swift:649` | Triple-bound. Flagged, not fixed here. |
| any `.option` modifier | only `AgentLensApp.swift:513` (⌘⌥⌃I, DEBUG) | **⌘⌥ + digit is completely free.** |
| any `"a"` shortcut | none anywhere | **⌘⇧A is completely free.** |

**The map:**

- **⌘⇧A — open the Agent Roster.** Free, mnemonic, and it does not join a three-way ⌘K fight. The Sigil prints `⌘⇧A` as its keycap hint.
- **⌘⌥1 … ⌘⌥9 — switch the focused pane to the Nth enabled agent.** Order is `settingsManager.enabledChatBackends` = Settings order = left-to-right Sigil-Bar order, so the number you see is the number you press. Printed in ghost tooltips and roster rows.
  - *Why not ⌃1–9:* macOS Mission Control claims "Switch to Desktop N" on ⌃-digit by default.
  - *Why not ⌥1–9:* it would eat ¡™£¢∞§¶•ª in the composer.
  - *Why not ⌘⇧1–9:* ⌘⇧3/4/5/6 are system screenshot shortcuts and win system-wide.
- **Numeric tab selection is deleted, not moved.** Tabs keep ⌘⇧[ / ⌘⇧], ⌘T, ⌘⇧T, ⌘W, and the roster's `#`/`>` scopes let you jump to a tab by name. Removing a broken binding beats relocating it.
- **Inside the roster:** ↑/↓ move · ↩ switch · ⇧↩ hand off · ⌘↩ second opinion · esc dismiss and return focus to the composer · `@ / # >` scope prefixes · **⌘⇧A ↩ = swap to your last agent** (the Agents section is MRU-ordered from `agentDeck.recentAgents.v1`).
- **⌘K keeps opening the Command Deck** and gains an Agents section there too, so agent names are findable from the global palette without a second ⌘K owner.

Registration mirrors `ChatWorkspaceShortcuts` (`PaneWorkspaceView.swift:44-80`): hidden zero-size `Button`s in an `AgentDeckShortcuts` view installed via `.background { }`, so AppKit's `performKeyEquivalent` dispatch fires them even while the composer holds first responder. The `.popOut` NSWindow installs its own copy (it has no `DashboardView`).

### 4.3 The three verbs

Every roster row states its consequence *before* commit, computed live from `activeController.persistsViewState`, `isSendBusy`, and `desktopControlEnabled`.

**Verb 1 — ↩ Switch.** `controller.setChatBackend(_:)`.
- Primary surface (`persistsViewState == true`): hint reads ***"↩ switch · opens Codex's chat"***. After the switch an ephemeral 4s line under the Sigil reads *"Switched to Codex — showing Codex's last conversation."* with an **Undo** that calls `setChatBackend(previous)`.
- Tiled pane (`persistsViewState == false`): hint reads ***"↩ switch · keeps this chat"***. Line reads *"Codex answers from here. Claude's turns stay in this chat."*

**Verb 2 — ⇧↩ Hand off** — switch the agent *and keep this conversation*, even on the primary surface. New method in `ChatSessionControllerThreadLifecycle.swift`:

```swift
func handOffCurrentThread(to target: ChatBackendID) async {
    guard persistsViewState else {            // panes already keep the thread
        await setChatBackendAsync(target); return
    }
    let carried = activeThreadID
    await setChatBackendAsync(target)         // resolves target's own slot
    await openOrCreateChatThread(id: carried) // …then points that slot back here
}
```
Hint: ***"⇧↩ hand off · Codex continues this chat"***. One pane, one thread, one writer — no reconciliation problem.

**Verb 3 — ⌘↩ Second opinion** — `workspace.splitActive(axis: .horizontal)` (`PaneWorkspaceModel.swift:532`), set the new leaf's backend, then `await workspace.bindExistingThread(threadID, toLeaf: newLeafID)` (`:629` — **this is the call that actually loads the messages**; `newTab(bindingThreadID:)` at `:419` mints the pane but does not), then `workspace.persistPaneControlChange(leafID)` (`:857`). Two agents, one question, side by side. Hint: ***"⌘↩ second opinion · splits right"***.

> **Known limitation, stated rather than hidden:** verb 3 puts two live controllers on one thread id. Both may write; neither sees the other's rows until it refreshes. Mitigation shipped with it: `PaneConversationView` refetches from the store on gaining focus (`onChange(of: workspace.activeLeafID)`), and the split pane opens **focused** so the source pane is the background one. A single-writer lock is out of scope; the test in §9.2 pins the refetch.

### 4.4 In-flight responses — never silently killed

- When any pane running the target agent — or the focused pane itself — is busy (`isSendBusy`, `ChatSessionController.swift:219`), the hint turns `Colors.warning`: ***"↩ switch · stops Hermes mid-answer"***.
- **The first ↩ does not switch.** It expands an inline confirm strip *inside the palette* — never a modal sheet, which would break the keyboard flow the palette exists to protect:
  > **Hermes is still answering.** ↩ again to stop and switch · **⌘↩** opens Codex in a split instead · esc cancels.
- Second ↩ proceeds. Destructive-by-default becomes destructive-by-two-keys, with the non-destructive alternative offered in the same breath.
- **Mouse parity:** clicking a ghost while busy opens `AgentHandoffPopover` anchored to that ghost, with the same three choices — **Open Codex in a split** (`.defaultAction`), **Stop & Switch** (`error` tint), **Cancel** (`.cancelAction`).
- **Desktop control:** when `controller.desktopControlEnabled`, every switch hint appends ***"· revokes desktop control"***, and the popover adds *"Keep it by opening a split instead."* This consequence exists today only in a source comment.
- **Model rows never confirm.** `setChatModelSelection(_:for:)` is a property assignment with a UserDefaults `didSet` — nothing cancels, nothing reloads, the in-flight request already captured its model. The hint says exactly that: ***"applies to your next message"***.
- **Elder Wand:** with `isElderWandActive`, gateway agents' subtitles read *"routed through Elder Wand fusion → BurnBar gateway"*, and the nine CLI agents render **disabled** with *"Elder Wand fusion needs Hermes, OpenClaw, or Pi. Deactivate it to use Codex."* The existing hard-fail moves from after the click to before it.
- **Involuntary switches get announced.** `syncChatBackendWithEnabledBackendsAsync()` force-switches when Settings drops the active agent. It now records `lastInvoluntarySwitch: (from: ChatBackendID, to: ChatBackendID, at: Date)?`; the Sigil animates the tint on `Animation.gentle` and holds a 4s `textMuted` sub-line: *"Switched to Codex — Hermes was disabled in Settings."* Today this happens with no notice at all.

### 4.5 What is preserved per agent (unchanged by this redesign — documented so the copy is accurate)

| Preserved | Where it lives |
|---|---|
| Model selection | one of twelve `chatModel*` properties → `chatPanel.model.<backend>` |
| Active thread | `chatPanelThreadID.<backend>` (+ legacy `chatPanelActiveThreadID`) |
| View mode | `chatPanel.viewMode` (app-wide, **not** per agent) |
| Hermes route | `selectedHermesModelIDRaw` → `hermesChatModelOverride` |
| Per-pane agent/model/view mode | `PaneWorkspaceSnapshotV2` leaf snapshot |
| **Not preserved:** desktop-control grant | revoked on every switch (§4.4) |

---

## 5. Presence vocabulary

`AgentPresence` is a pure enum with a pure resolver — no SwiftUI, fully unit-testable. It answers the requested six states and two more the code actually distinguishes.

```swift
enum AgentPresence: Equatable {
    case ready
    case thinking(since: Date)   // sendInFlight && !isStreaming
    case streaming(since: Date)  // isStreaming
    case exhausted               // quota bucket at 0%
    case needsAuth(AuthGate)     // .hermesSetup | .hermesCatalog | .cliConsent
    case offline                 // gateway probe false
    case notInstalled            // CLIExecutableResolver.resolveExecutable(named:) == nil
    case error(String)           // streamError != nil
}
```

**Precedence, highest first:** `streaming` → `thinking` → `notInstalled` → `offline` → `needsAuth` → `exhausted` → `error` → `ready`.
Rationale: liveness beats everything because it is happening *now*; structural gates beat faults because they explain them; `exhausted` beats `error` because it is the specific diagnosis of the generic failure.

**Fleet-wide, not focused-pane-only.** The resolver walks `workspace.allLeaves` (`PaneWorkspaceModel.swift:343`), so a Codex turn landing in a background tab pulses the Codex ghost and reads *"answering in Tab 2 · 41s"* in the roster.

| State | Word | Dot | Extra channel (never colour alone) | Source of truth |
|---|---|---|---|---|
| `.ready` | "Ready" | `Colors.success` filled 6pt | — | probe OK / executable resolved |
| `.thinking` | "Thinking" | `sigilTint` filled | 3-dot ellipsis micro-glyph, 1.5s `Animation.mercuryPulse` | `sendInFlight && !isStreaming` (`ChatSessionController.swift:216,219`) |
| `.streaming` | "Answering" | `sigilTint` filled | `mercuryShimmer(active:)` sweep on the Sigil rim + `● 41s` suffix | `isStreaming` (`:44`) |
| `.exhausted` | "Out of quota" | `Colors.amber` filled | quota meter at 0 with `error`-tinted track | `ProviderQuotaChip.resolve(...)` fraction == 0 |
| `.needsAuth` | "Needs setup" / "Needs sign-in" / "Needs permission" | `Colors.warning` **hollow ring**, 1.25pt | `wrench.and.screwdriver` / `key.fill` / `lock` at 5pt | `!hermesSetupWizardCompleted` · `hermesCatalogAuthRejected` · `requiresCLIAssistantConsent` ungranted (`ChatBackendID.swift`, the predicate `ChatInputRow.shouldRequestCLIAssistantPermission` reads) |
| `.offline` | "Not running" | `textMuted` **hollow ring** | `play.fill` prefix at 7pt — identical to today's `ChatEngineBackendStrip.shouldShowPlayAffordance` | `hermesAvailable` `:124` / `openClawAvailable` `:145` / `piAgentAvailable` `:147` |
| `.notInstalled` | "Not installed on this Mac" | `textMuted` **hollow, dashed** `StrokeStyle(lineWidth: 1, dash: [2,2])` | `arrow.down.circle` at 5pt | `CLIExecutableResolver.resolveExecutable(named:) == nil` |
| `.error` | "Failed" | `Colors.error` filled | `exclamationmark` at 5pt; Sigil rim → `error.opacity(0.7)` | `streamError != nil` (`:53`) |

**Filled vs hollow vs dashed is the redundant channel**: filled = the agent can work, hollow = it needs you, dashed = it is not there. Colour is never the only signal, which is what makes this survive colourblindness *and* the Editorial skin.

**Click semantics preserve today's asymmetry** (`ChatEngineBackendStrip.handleBackendTap`): Hermes with an incomplete wizard opens `HermesSetupWizard` and does **not** switch; unavailable Hermes switches first then launches; unavailable Pi launches first and only switches if the re-probe succeeds. The roster hints say which of the three will happen.

**Quota honesty.** Only **6 of the 12 agents have a quota signal at all** — verified against `AgentProvider.quotaSignalProviders` (`AgentProvider.swift:89-108`): codex ✓, claude→claudeCode ✓, omp ✓, droid→factory ✓, antigravity ✓, cursorAgent ✓; and hermes ✗, openclaw ✗, openClaude ✗, piAgent ✗, forge→forgeDev ✗, junie ✗. For the six without, the meter **self-hides** and the roster subtitle says *"no quota signal"* rather than rendering an empty bar. `.exhausted` is unreachable for those six, and the spec says so instead of pretending otherwise.

**One additive API change:** `ProviderQuotaChip.Resolution` (`ProviderQuotaChip.swift:55-60`) exposes `text/tint/tooltip/accessibilityLabel` and **no number**, so nothing today can draw a meter. Add one field:

```swift
struct Resolution: Equatable {
    …
    let remainingFraction: Double   // 0…1, already computed at :88 as `fraction`
}
```

**Performance.** `AgentPresenceModel` is **one** `@Observable` resolved once per render pass — never one subscription per chip. CLI executable probes are cached with a 60s TTL layered on `CLIExecutableResolver`'s own actor cache (`clearCache()` is the invalidation hook), refreshed on roster open, on window-key, and on `dataStore.usagesVersion`. Gateway probes reuse the existing published `*Available` flags — zero new network traffic. Streaming state is an O(panes) walk over `allLeaves`.

---

## 6. Visual spec (real tokens only)

Source of truth: `AgentLens/Theme/DesignSystem.swift`, `AgentLens/Theme/LiquidGlass.swift`, `AgentLens/Views/Charts/ChartCardView.swift`, `AgentLens/Views/Components/ProviderLogoView.swift`.

### 6.1 Per-agent tint derivation

```swift
// AgentLens/Models/ChatBackendID.swift — beside `gradient` / `activeForeground`
/// Identity tint for chat surfaces. Hermes keeps the mercury axis: DesignSystem.swift:57
/// says so verbatim — "Hermes mercury identity (chat surfaces — not provider purple)".
@MainActor var sigilTint: Color {
    switch self {
    case .hermes: return DesignSystem.Colors.hermesAureate      // B8942E / D4AA3C
    default:
        guard let p = agentProvider else { return DesignSystem.Colors.whimsy }
        return DesignSystem.Colors.primary(for: p)              // exhaustive table, :117-201
    }
}
```

Resolved values: codex `2563EB` · claudeCode `CC785C` · factory(droid) `8B5CF6` · forgeDev `F97316` · antigravity `6C63FF` · cursorAgent `00E5FF` · openClaw `FF6B6B` · openClaude `D97757` · omp `EC4899` · junie `48E054` · piAgent `7C3AED` · hermes → aureate. Every `ChatBackendID` returns a non-nil `agentProvider`, so the switch is total; a `sigilTint` exhaustiveness test (§9) makes a thirteenth backend impossible to ship colourless.

**No new hexes are invented.** Zero.

**THE CONTAINMENT LAW — non-negotiable.** `sigilTint` may draw **only**: the Sigil plate wash and rim, the presence dot, the ghost ring, the composer's 3pt leading bar, the tab agent-mark rings, the pane focus ring, and the roster row selection fill. It may **never** draw body text, a fill wider than 3pt, or **the assistant bubble stroke**.

> This is the sharpest correction to the winning proposal. It routed `sigilTint` into `ChatMessageView.swift:396-449`, replacing `chatAssistantStroke` (ember `F45B69`) / `hermesMercury` on the most-repeated object in the app. That would put saturated third-party neon (`00E5FF`, `48E054`) — colours that appear nowhere else in the shell — on every bubble of a forty-turn transcript, and, because per-message attribution does not exist until PR 3, would retroactively repaint a mixed thread's history in the *wrong* agent's colour. Bubbles keep `chatUserStroke` / `chatAssistantStroke` / `hermesMercury` exactly as they are. This is `ChartCardChrome.swift`'s own law applied to chat: colour enters through the ink, never the plate.

`sigilInk` (dark `151210` when the tint's relative luminance > 0.5, else `.white`, via `BackdropReadability.relativeLuminance`) exists for the one place a tint is a *fill* — the `+N` overflow chip and the glyph-fallback backdrop — and keeps `48E054` / `00E5FF` legible. One unit test asserts every backend's ink clears 4.5:1 against its own tint.

### 6.2 The Sigil plate — glass recipe

```swift
let shape = Capsule(style: .continuous)   // Radius.full
Group {
    if #available(macOS 26, *) {
        shape
            .fill(tint.opacity(washAlpha))
            .liquidGlassInteractive(in: shape)       // Theme/LiquidGlass.swift:183
    } else {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
            shape.fill(tint.opacity(washAlpha))
        }
    }
}
.overlay(shape.strokeBorder(tint.opacity(rimAlpha), lineWidth: rimWidth))
.clipShape(shape)                                    // clip AFTER the overlay — house rule
```

| Token | Aurora dark | Aurora light | Editorial (light-locked) |
|---|---|---|---|
| `washAlpha` | 0.10 | 0.06 | 0.06 |
| `rimAlpha` | 0.35 | 0.35 | 0.55 |
| `rimWidth` | 0.75 | 0.75 | 1.0 |

These sit **one step** above the plate law (`ChartCardView.swift:50-72`: wash 0.08/0.04, rim 0.22 @ 0.75pt) because the Sigil is the window's identity *control*, not a plate — and `liquidGlassInteractive`'s own doc sanctions tinting interactive glass when the tint conveys meaning. It is the only tinted glass in the toolbar.

**Editorial is handled explicitly, not assumed.** `DesignSystem.Colors.primary(for:)` returns a raw `Color(hex:)` — it is **not** a `Color.adaptive` triple, so Editorial gets no variant for free. The raised rim above is the fix, using no new tokens. Adding `editorial:` triples for the twelve chat-relevant provider primaries is a separate `DesignSystem.swift` PR and must not block this one.

Never call `glassEffect` directly. Wrap the Sigil + ghost row in `LiquidGlassGroup(spacing: Spacing.xs)` (`LiquidGlass.swift:301`) — glass cannot sample glass and they sit 4pt apart. `LiquidGlassTransparency` (`:52`) then honours the user's transparency slider and Reduce Transparency for free.

The roster palette plate reuses `ChartGlassCard` (`ChartCardChrome.swift`) verbatim: no tint, rim `LinearGradient(white .14 dark / .55 light → border .5)` top→bottom @ 0.75pt, `.shadow(black .28 dark / .12 light, radius 12, y 5)` — required so it stays legible over all six animated dashboard substrates (classic, aurora, nebula, constellation, cockpit, atelier).

### 6.3 Typography, spacing, radius

| Element | Spec |
|---|---|
| Agent name | `.system(size: 12, weight: .semibold, design: .rounded)`, `textPrimary` |
| Model text | `.system(size: 10, weight: .medium, design: .rounded)`, `textSecondary`, `maxWidth 132`, `.truncationMode(.middle)` |
| Elapsed suffix | `.system(size: 9, design: .monospaced)`, `textMuted` |
| Keycap hint | `.system(size: 9, design: .monospaced)`, `textMuted.opacity(0.6)` |
| Kind sub-label (roster) | `DesignSystem.Typography.tiny` (11 medium rounded), `textMuted` |
| Roster row title | `.system(size: 13, weight: .medium, design: .rounded)`, `textPrimary` |
| Consequence hint | `Typography.tiny`, `textMuted` (→ `Colors.warning` when destructive) |
| Section header | `.system(size: 9.5, weight: .bold, design: .rounded).tracking(1.0)`, `textMuted` — matches `CommandDeckPalette.swift:197` |
| Sigil height / padding | 26pt · `.padding(.horizontal, Spacing.sm)` (8) · segment gap `Spacing.xs` (4) |
| Sigil / ghost radius | `Radius.full` (Capsule) / `Radius.sm` (6) |
| Roster frame · row radius | 560 × 460 · `cornerRadius: 8` (matches palette `:245,:248`) |
| Agent mark shape | `RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)` — free from `ProviderLogoView.swift:49-50`; the app-wide agent-mark squircle. Never a circle, never on hover. |
| Mark sizes | Sigil 14 · ghost 18 · tab 10 · roster row 20 |
| Presence dot | 6pt (Sigil) / 5pt (ghost) — filled `Circle` or `Circle().strokeBorder(lineWidth: 1.25)` per §5 |
| Motion | `Animation.standard` (tint/name change) · `.hover` (ghost) · `.snappy` (press, scroll) · `.gentle` (involuntary switch) · `.mercuryPulse` (thinking) · `mercuryShimmer` (streaming) |

Glyph fallback when `agentProvider`'s logo asset is missing: `Text(backend.glyph)` at the mark size, semibold rounded — ☿ π ↻ ✦ ⚡ ✸ ⌘ ◆ ▰ ✧ ➤ ✽, the table already in `ChatBackendID.swift`. **No avatars, no monograms, no initials** — none exist anywhere in `AgentLens` and inventing them would mint new vocabulary.

### 6.4 Doc correction shipped in the same PR

`DESIGN.md:72` claims `hermesAureate` is gunmetal `#A2ACBA` / `#3F4651`. The shipped token (`DesignSystem.swift:59`) is gold `B8942E` / `D4AA3C`. The brand-accent table in `DESIGN.md` is likewise stale. **Fix the hexes; keep the §"Hermes Chat Surfaces" intent prose, which is still correct.** Anyone building the Sigil from `DESIGN.md` today gets the wrong colour.

---

## 7. Empty and degenerate states

**Zero agents enabled.** Today: the dead 9pt string `"Settings → Chat: enable engines"`. Now: the Sigil becomes `exclamationmark.triangle` + **"No agents enabled"** in `Colors.warning` with a `warning`-dashed rim, still a full 26pt `Button`. Click or ⌘⇧A opens the roster straight into the `NOT ENABLED` list, whose empty-state copy is *"0 of 12 agents enabled. ↩ any greyed row to turn it on."* The destination is now reachable, not merely named.

**Exactly one agent enabled.** Today: a bare non-interactive icon — the user who most needs to discover the other eleven gets the least affordance. Now **nothing degrades**: the Sigil is the identical object at any count (dot + logo + name + model + keycap, clickable, ⌘⇧A-able), the ghost row is simply empty, and ⌘⌥1 resolves to the only agent — a harmless no-op that keeps muscle memory valid as agents are added. Roster empty-state copy: *"1 of 12 agents enabled. ↩ any greyed row to turn it on."*

**Two to five agents.** The common case. Sigil + every other agent as a one-click ghost with its own live dot. Zero overflow.

**Six to twelve agents.** Ghosts cap at 5 in MRU order; the rest collapse into `+N ⌄`. The roster is the complete list and is one key away.

**Tiled.** The `showsEnginePickers` gate is gone. The toolbar Sigil always shows the *focused* pane's agent (prefixed with that pane's colour chip, plate tint == pane ring tint), and each pane header carries its own interactive Sigil. The top of the window never goes anonymous again.

**Pop-out window.** Same view, same Sigil, its own `AgentDeckShortcuts` registration. Window minimum stays **780 × 560** — the Sigil replaces two controls with one, so horizontal chrome does not grow.

**Fresh install, first launch, no thread.** The `welcomeState` (`PaneConversationView`) gains an `AGENTS` block between the per-agent subtitle and `SUGGESTIONS` — the same 10pt bold `.tracking(1.1)` uppercase `textMuted` label `ChartCardView.swift:83-99` uses — holding a `LazyVGrid` of agent chips inside the existing 760pt `canvasMaxWidth`. Enabled chips open a new tab on that agent; disabled ones sit at 0.4 with a `lock` and enable on click. A first-run user meets the roster without hunting.

---

## 8. Accessibility

**Composed labels, children ignored** — the pattern `ChartCardView` and `AgentSwitcherSheet` already use.

- Sigil: `.accessibilityElement(children: .ignore)`, label `"Agent: Codex, CLI agent, answering, 41 seconds, model gpt-5-codex, 47 percent quota remaining"`, hint `"Command Shift A opens the agent roster"`, traits `.isButton`. The model segment is a **separate** element: label `"Model: gpt-5-codex"`, trait `.isButton`.
- Ghost: label `"Codex, CLI agent, ready, 47 percent remaining"`, hint `"Switches this chat to Codex. Command Option 2."`, `.isButton`.
- Roster row: label `"<Name>, <kind>, <status>"`, value `"<quota>"`, hint = the consequence string verbatim (*"Return switches and stops Hermes mid-answer"*), `.isSelected` on the highlighted row.

**Announcements on switch** — `AccessibilityNotification.Announcement(_:).post()` on the main actor:

| Event | Announced |
|---|---|
| Verb 1, primary surface | *"Switched to Codex. Showing Codex's last chat."* |
| Verb 1, tiled pane | *"Switched to Codex. This chat kept."* |
| Verb 2 | *"Handed this chat to Codex."* |
| Verb 3 | *"Codex opened in a split. Claude still answering."* |
| Any switch while a grant is live | *"…Desktop control revoked."* appended |
| Involuntary sync switch | *"Switched to Codex. Hermes was disabled in Settings."* |
| First ↩ on a busy agent | *"Hermes is still answering. Press Return again to stop and switch."* |

**Focus order.** Toolbar left→right: Sigil agent segment → Sigil model segment → ghost 1…N → `+N` → view mode → quota → folder → desktop control → new chat → ellipsis → pop out → restore → close. Roster: search field (auto-focused on open) → the list (arrow-driven, single focus stop) → the confirm strip when expanded. **esc always returns focus to the composer** from any roster state, and never leaves focus stranded on a dismissed view.

**Reduced motion** (`@Environment(\.accessibilityReduceMotion)`): `mercuryShimmer` already goes static (`MercuryShimmerModifier.swift`); `.thinking`'s `mercuryPulse` becomes a static filled dot plus the ellipsis glyph; the tang/tint cross-fade becomes an instant swap; the roster's `scrollTo` animation drops to `nil`. No repeating animation is ever forced.

**Reduced transparency** is honoured automatically because every glass call routes through `liquidGlassSurface` / `liquidGlassInteractive`, which fold into `LiquidGlassTransparency.effective(_:reduceTransparency:)` where Reduce Transparency always beats the user's "clearer" slider.

**Keyboard-only path is complete:** ⌘⇧A → type → ↩/⇧↩/⌘↩ → esc. Every mouse gesture has a keyboard equivalent. No affordance is hover-only.

---

## 9. Delivery — three independently shippable PRs

### 9.1 PR 1 — "Say who is answering" (view layer only; no schema, no send-path change)

The headline fix. Ships alone and is worth shipping alone.

**Adds:** `ChatBackendID.sigilTint` / `.sigilInk` / `.kindLabel`; `AgentPresence` + `AgentPresenceModel` + resolver; `AgentSigilBar` / `AgentSigil` / `AgentGhostRow` / `AgentPresenceDot`; tab agent-mark stack; composer 3pt tint bar; `ProviderQuotaChip.Resolution.remainingFraction`; Hermes alias/route label rules (§3.3); Elder Wand suffix.
**Changes:** `ChatEngineModelMenu` body extracted to `static func modelRows(controller:)` (view kept as a wrapper — **not deleted**); `DashboardChatWorkspaceToolbar` gains the 6-tier ladder and loses `showsEnginePickers`; `DashboardChatWorkspaceView.swift:63` drops the `!isTiled` argument; `PaneConversationView.paneHeader` swaps strip+menu for a Sigil; `PaneWorkspaceModel.displayTitle(for:)` drops its backend fallback; `HermesModelStrip` rows hosted inside the model menu.
**Deletes:** `PaneWorkspaceView.swift:75` (⌘1–9 tab selection); `BurnBarTopRail.swift:491` (duplicate ⌘K).
**Docs:** `DESIGN.md` hex corrections (§6.4); `docs/qa/CHAT_PANE_TABS_QA.md` shortcut rows updated and **run**.

**Gates:**
- `AgentPresenceTests` — all 8 states + the full precedence order, driven by an injected executable resolver and a fake quota service.
- `ChatBackendIDIdentityTests` — `sigilTint` total over `allCases`; all 12 pairwise distinct; `.hermes == hermesAureate` and **≠** provider purple `A855F7`; `sigilInk` clears 4.5:1 against its own tint for all 12; `sigilTint` for each backend checked **against `Colors.error` / `warning` / `success`** so a brand rim is never mistakable for a semantic one (`FF6B6B` vs error `FA5053`, `F97316` vs warning, `48E054` vs dark success `38D898` are the three near-collisions — resolved by the filled/hollow/dashed dot channel, and the test pins the reasoning).
- `AgentSigilLabelTests` — Hermes cold catalog renders `Auto (gateway picks)`, never the literal `"hermes"`; family fallback renders `Auto → Claude`; Elder Wand renders the fusion route.
- Screenshot pass: 4 chat surfaces (workspace toolbar, pane header, `ChatPanelHeader`, `HermesPopoverStrip`) × Aurora/Editorial × light/dark = 16 frames, plus the 6 tiers at 1440/1100/900/780pt.
- Manual: `docs/qa/CHAT_PANE_TABS_QA.md` shortcut and visual rows move from NOT RUN to PASS.

### 9.2 PR 2 — "The roster" (⌘⇧A palette, verbs, consequences, discovery)

**Adds:** `AgentRosterPalette` + `AgentRosterRow` + `AgentHandoffPopover`; `agentDeck.recentAgents.v1` MRU; scope prefixes; consequence-hint resolver; the streaming double-↩ confirm strip; disabled-with-reason rows; the `NOT ENABLED` discovery group; `ChatSessionController.handOffCurrentThread(to:)`; `lastInvoluntarySwitch` + its Sigil sub-line and announcement; `AgentDeckShortcuts` (⌘⇧A, ⌘⌥1–9) installed in both hosts; `welcomeState` AGENTS grid; an Agents section in `CommandDeckPalette`.

**Gates:**
- `AgentRosterPaletteTests` — consequence string is correct for the cartesian product of {primary, pane} × {idle, busy} × {grant, no grant}; first ↩ on a busy agent does **not** switch; second ↩ does; `⌘↩` never cancels a stream.
- `PaneWorkspaceModelTests` (36 today) extended: `handOffCurrentThread` preserves `activeThreadID` across a primary-surface switch; verb 3 binds the **same** threadID into both leaves; a palette-minted pane controller has `persistsViewState == false` and **writes no global UserDefaults keys** — the hazard `docs/CHAT_PANE_TILING_PLAN.md` calls "the only hazard"; the source pane refetches on refocus after verb 3.
- Shortcut regression: with `mainRoute == .chat`, ⌘1–⌘8 reaches `primarySections` and nothing else; ⌘⌥1–9 reaches agents; ⌘K opens the Command Deck exactly once.
- VoiceOver pass over the full keyboard path.

### 9.3 PR 3 — "Provenance" (migration v61 + per-message attribution)

Required for the transcript to survive the multi-agent threads PR 2 makes normal. **Deliberately last**, because shipping its rendering before its data would convert honest silence into confident misattribution.

**Adds:** `OpenBurnBarDatabase+MigrationV61.swift` — `ALTER TABLE chat_messages ADD COLUMN engineID TEXT`, `ADD COLUMN modelID TEXT` (latest shipped is `v60_billing_kind`); `ChatMessageRecord.engineID` / `.modelID`; stamping on **every** assistant message at send time in `ChatSessionController+SearchSend.swift`; `ChatMessagesStream.chatAssistantModelKey(for:)` reads `msg.modelID` instead of `controller.chatBackend` (`:205-211`); `showViaBadge` / `isHermes` (`:178-179`) move off `cliUsed` to `engineID`, with the "via" badge's render condition explicitly narrowed to *first turn of a run by that agent* so it does not appear on every row; a handoff divider in `ChatMessagesStream` — `Divider().opacity(0.35)` + a centred `QuotaMicroBadge`-recipe capsule (`ProviderQuotaStripViews.swift:392`) reading *"Handed to Claude Code · 14:32"*; agent marks on `ChatHistoryRow`.
**Keeps:** `cliUsed` written exactly as today, so old threads render byte-identically and rollback is a view-layer revert.

**Gates:**
- Byte-compat fixture kit **regenerated as one unit** — endpoint, `fixtureBaseName`, vector JSON, and the `.sqlcipher` binary all move together; the vector is SHA-256 over the DDL and can never be hand-edited. Budget this; it is the real cost of PR 3.
- Migration test: v60 → v61 on a populated DB; existing rows get NULL; reads tolerate NULL.
- `ChatSessionControllerPaneModeTests` extended: a pane-mode agent switch mid-thread produces messages with two distinct `engineID`s in one thread, and the stream renders exactly one divider between them.
- Screenshot: a four-agent mixed thread, both skins.

---

## 10. Non-goals and risks

### 10.1 Non-goals (deliberate, with reasons)

1. **The provider account axis.** `SwitcherProfileRecord` / `DrainTargetSwitcher` stays out of the chat window. Codex's mid-send failover (`CLIProfileStreamFailoverRunner`) can change which account is billed while the Sigil keeps saying "Codex". The honest minimum shipped here is that `.exhausted` turns the dot amber when the *active* profile is spent. Surfacing account identity in the Sigil is the obvious next increment and would make the meter exact rather than approximate.
2. **Thread rename / delete / pin.** `chat_threads` has no `title` column (`OpenBurnBarDatabase+MigrationsV1toV20.swift:573-600`); titles are computed at query time from the first user message. Adding rename needs its own migration.
3. **Renaming the types.** `ChatBackendID` → `ChatAgentID` is a mechanical PR with zero user-visible effect. Bundling it would make three reviewable PRs unreviewable.
4. **Tab drag-reorder** and **rail auto-collapse.** Orthogonal.
5. **Mobile/Android parity.** `AssistantRuntimeID` raws stay frozen; the mobile `AgentSwitcherSheet` is the *source* of this spec's copy, not its target.
6. **A single-writer lock on a bound thread.** Verb 3's two-controller case is documented and mitigated (§4.3), not solved.

### 10.2 Risks, ranked

1. **Horizontal budget in the toolbar.** The Sigil is wider than the strip it replaces. Mitigated by absorbing `ChatEngineModelMenu` into it (net −1 control), the 6-tier ladder with a guaranteed floor, and an unchanged 780pt window minimum. *If it still crowds at 780pt, the retreat is dropping the ghost row one tier earlier — not the model, and never the name.*
2. **Twelve tints could read as confetti.** Guarded by the containment law (§6.1): rim, dot, 3pt bar, mark ring, selection fill only — never text, never a fill wider than 3pt, never a bubble. If QA still reads it busy, the cheapest retreat is tint-on-the-Sigil-only.
3. **Editorial skin.** `primary(for:)` is raw hex with no `editorial:` variant. Mitigated by the raised rim (§6.2) and required in the 16-frame screenshot gate. Adding `editorial:` triples is a follow-up.
4. **Removing ⌘1–9 tab selection breaks someone's muscle memory.** But it is ambiguous today against `DashboardView.swift:691` in the same responder chain and QA-unverified, so there is no reliable behaviour to preserve. Ship with a one-time 4s toast on the tab strip: *"Tab shortcuts are ⌘⇧[ and ⌘⇧]. ⌘⌥1–9 switches agents."*
5. **The toolbar Sigil is window-level chrome but pane-level state.** The riskiest *comprehension* bet. Mitigated by the pane colour chip prefix, the plate-tint == pane-ring-tint identity, the "Focused pane · <title>" menu header, and the tab mark stacks. Needs real manual QA — the tiling QA doc's visual rows are all still NOT RUN.
6. **v61 invalidates the whole byte-compat fixture kit.** Known, priced, and confined to PR 3. It is the reason PR 3 is last and separable.
7. **Presence polling.** Twelve agents × executable probes could spawn `which` storms. Mitigated by one shared resolver, a 60s TTL over `CLIExecutableResolver`'s actor cache, and reuse of existing gateway probe state. The gate is a test asserting ≤1 resolver call per agent per TTL window across 100 renders.
8. **Removing the `chatBackend.displayName` tab fallback** briefly removes a name before the agent marks land — same PR, same commit, so never observable, but the two edits must not be split across commits.

---

## Appendix A — deviations from the winning proposal, and why

| Winner said | This spec says | Why |
|---|---|---|
| ⌘K opens the roster | **⌘⇧A** opens it; ⌘K keeps the Command Deck and its duplicate registration is deleted | ⌘K is already double-bound (`DashboardView.swift:705`, `BurnBarTopRail.swift:491`); adding a third scope-dependent owner would make the keycap printed on the Sigil teach a shortcut that does not fire deterministically |
| ⌘⇧M opens models | Model scope is `⌘⇧A` then `/`, or a click | ⌘⇧M is taken by `MissionFAB.swift:55` |
| ⌃1–9 selects agents | **⌘⌥1–9** | ⌃-digit is Mission Control's "Switch to Desktop N"; ⌘⇧3/4/5/6 are system screenshots; ⌥-digit eats composer characters |
| `sigilTint` drives the assistant bubble stroke | Containment law: identity surfaces only | Neon third-party hexes on the most-repeated object, and — before PR 3 — a rim that retroactively lies about who answered |
| `chatAssistantModelKey` fix in PR 1, migration in PR 2 | Both in **PR 3**, together | Otherwise historical turns in a mixed thread render the *current* agent's model logo: honest silence becomes confident misattribution |
| Model swaps to an elapsed timer while thinking | Model stays; elapsed time is a separate suffix that drops first | The model matters most while a turn is running |
| Ghosts are 14pt, nameless, and dropped first by `ViewThatFits` | 18pt one-click Buttons that collapse to `+N ⌄` but never to nothing | Dropping them would make the mouse roster *less* visible — inverting the stated goal |
| `ChatEngineModelMenu` removed from the toolbar | Absorbed as the Sigil's second segment; the file survives for its other three call sites | All three proposals left the model homeless on the full-canvas surface; that was the judges' single loudest complaint |
| Hermes route not addressed | `HermesModelStrip` rows hosted in the model menu + roster; alias never printed | Hermes is a router; a 12pt "Hermes" with no route is the app's least honest label |

**Grafted from the runners-up:** the eight-state presence enum with filled/hollow/dashed redundancy and mobile's kind labels, the tab agent-mark stack and the `displayTitle` fallback removal (from *Agent Rail*); the pure testable resolver and the "new tab / split is the non-destructive default" structural insight (from *Agent Rail*); the Elder Wand cuff, the disabled-with-reason CLI rows, the quota-honesty audit, and the single-shared-resolver performance rule (from *The Roster Rail*).

## Appendix B — file manifest

**New**
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/AgentDeck/AgentSigilBar.swift`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/AgentDeck/AgentSigil.swift`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/AgentDeck/AgentGhostRow.swift`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/AgentDeck/AgentPresence.swift`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/AgentDeck/AgentPresenceModel.swift`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/AgentDeck/AgentRosterPalette.swift`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/AgentDeck/AgentHandoffPopover.swift`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/AgentDeck/AgentDeckShortcuts.swift`
- `/private/tmp/bb-founder-lens/AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV61.swift` *(PR 3)*
- `/private/tmp/bb-founder-lens/AgentLensTests/Active/AgentPresenceTests.swift`
- `/private/tmp/bb-founder-lens/AgentLensTests/Active/ChatBackendIDIdentityTests.swift`
- `/private/tmp/bb-founder-lens/AgentLensTests/Active/AgentSigilLabelTests.swift`
- `/private/tmp/bb-founder-lens/AgentLensTests/Active/AgentRosterPaletteTests.swift`

**Modified**
- `/private/tmp/bb-founder-lens/AgentLens/Models/ChatBackendID.swift` — `sigilTint`, `sigilInk`, `kindLabel`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/DashboardChatWorkspaceView.swift` — drop `showsEnginePickers`, host the handoff popover
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/DashboardChatWorkspaceToolbar.swift` — 6-tier ladder, Sigil Bar
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/Components/ChatEngineModelMenu.swift` — extract `modelRows(controller:)`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/Components/HermesModelStrip.swift` — expose its rows for embedding
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/Components/ChatInputRow.swift` — 3pt leading tint bar
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/PaneWorkspace/PaneConversationView.swift` — Sigil in the pane header, welcome-state AGENTS grid
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/PaneWorkspace/ConversationTabStrip.swift` — agent-mark stack
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/PaneWorkspace/PaneWorkspaceModel.swift` — `displayTitle` fallback removal
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/PaneWorkspace/PaneWorkspaceView.swift` — delete the ⌘1–9 tab binding
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/ChatSessionControllerThreadLifecycle.swift` — `handOffCurrentThread(to:)`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/ChatSessionControllerBackendGatewayRouting.swift` — `lastInvoluntarySwitch`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Components/ProviderQuota/ProviderQuotaChip.swift` — `Resolution.remainingFraction`
- `/private/tmp/bb-founder-lens/AgentLens/Views/Dashboard/Components/BurnBarTopRail.swift` — delete the duplicate ⌘K
- `/private/tmp/bb-founder-lens/AgentLens/Views/Dashboard/Components/CommandDeckPalette.swift` — Agents section
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/Components/ChatMessagesStream.swift` *(PR 3)* — per-message attribution + handoff divider
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/ChatSessionController+SearchSend.swift` *(PR 3)* — stamp `engineID` / `modelID`
- `/private/tmp/bb-founder-lens/AgentLens/Models/ConversationRecord.swift` *(PR 3)* — record fields
- `/private/tmp/bb-founder-lens/AgentLens/Views/Chat/Components/ChatHistoryRow.swift` *(PR 3)* — rail agent marks
- `/private/tmp/bb-founder-lens/DESIGN.md` — hermesAureate + brand-accent hex corrections
- `/private/tmp/bb-founder-lens/docs/qa/CHAT_PANE_TABS_QA.md` — shortcut rows rewritten and run

**Untouched on purpose:** `ChatEngineBackendStrip.swift` survives for `ChatPanelHeader` and `HermesPopoverStrip` until those surfaces migrate; `ChatMessageView.swift` bubble strokes are never touched.
