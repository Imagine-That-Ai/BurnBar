# War Room Master Plan
## Two computers, one flame — every Hermes is a place

**Date:** 2026-08-17
**Owner:** Alberto
**Author:** Cursor × Claude Fable 5 (plan mode) — from Alberto's own words, against the real tree
**Status:** Master plan — **all decisions closed** (2026-08-17, per Alberto's directive to close every call, business calls included). **No product code ships from this document.** §14 is the decision record: the five product calls and the business calls (packaging ladder, naming, metrics, rollout), each locked with its profitability and defensibility rationale.
**Branch baseline:** `main` @ `cf7aa2de` (post v1.0.35 cut — this plan does not touch the release, the tag, or any existing workflow run)
**Substrate baselines:**
- Hermes chat + Agent Deck on the Mac dashboard (`AgentLens/Views/Dashboard/DashboardChatWorkspaceView.swift`, `ChatBackendID.hermes`)
- iroh QUIC transport, ALPN `openburnbar/1`, HPKE v3 relay crypto, sealed Firestore fallback (`crates/openburnbar-iroh/`, `docs/HERMES_IROH_TRANSPORT.md`, `plans/2026-06-04-burnbar-hpke-v3-migration.md`)
- Live Agent Fleet, local-only, 15 s cadence, 10-agent roster including `hermes` and `grok-bot` (`docs/fleet/BURNBAR_FLEET_API.md`, `docs/fleet/BURNBAR_FLEET_SIGNALS.md`)
- The Wand fan-out with tier caps 1 / 3 / 8 / 16 (`packages/entitlements/src/wandFanOut.ts`, `OpenBurnBarCore/Sources/OpenBurnBarKernel/Membership/GatedFeature.swift`, `firestore.rules`)
- Daemon provider router with five-dimension scoring + JSONL decision log (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderRouter.swift`)
- Mission dispatch: phone → Firestore claim queue → trusted Mac, approval-gated (`functions/src/types/legacy/media.ts` `CLIAgentMissionRequestDoc`, `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener*.swift`)
- Computer Use / Agent Control trust + audit + panic substrate (`plans/2026-05-16-computer-use-master-plan.md`, `docs/HERMES_COMPUTER_USE.md`)

**Upstream trigger:** Nous Research shipped **Bot Mode for Hermes Desktop** (2026-08-17): named bots with their own role, model, memory, skills, and avatar; bots message each other (`@hermes` handoffs); cronjobs land runs in their own chat history; the archived plugin is now built into Hermes Desktop. BurnBar already builds its Hermes assistant and gateway on the upstream `hermes-agent` (`NAMES.md`, `third_party/hermes-agent/`).

---

## 0. How to read this plan

- **§1 is the vision, returned.** Read it first. If §1 does not read as Alberto's idea, the rest is scaffolding on the wrong lot.
- **§2–§5 are the four load-bearing concepts**: the identity law, the three faces, the Wire, the Flame. Each names what exists in the tree today, what is new, and the seam between them.
- **§6–§7 are the engineer's contract**: the fountain inventory with real files, and the `RoutingDecision` / `DistillRecord` / `HermesBody` schemas.
- **§8–§10 make it concrete and honest**: a day in the life, the empty/offline/dry states, privacy.
- **§11–§13**: exists-vs-new inventory, phasing with exit criteria, risks — including the one that kills this product if ignored (§13.1, the second-chat-app trap).
- **§14 is the decision record**: the five product calls plus the business calls (packaging, naming, metrics, rollout), each **CLOSED** with the chosen option, the rejected options, and the rationale. §2–§13 read consistently with those decisions.

Vocabulary note: Alberto's words for the aesthetic — *night desk, liquid glass, grain, ember, amber, living flame* — map to real tree assets in §3.4. Two are literal tokens today (`ember` `#FA5053`, `amber` `#FFA800` dark, in `AgentLens/Theme/DesignSystem.swift`); the others name real components (`LiquidGlass.swift`, `GrainOverlay`, `BurnBarLogoFormationView`) and one gap (no living-flame chrome component yet — §3.4 specifies it).

---

## 1. The vision, returned

### 1.1 What Alberto said

Kept close to verbatim, because these are the requirements:

1. *"Hermes just came out with Hermes bot which is basically open source grok bot… we need it to work seamlessly within BurnBar so users can manage their Hermes bots."*
2. *"I would like Hermes on different computers to be identified as such so users can have the two Hermes bots communicate with each other over the BurnBar connection we offer Pro and premium members."*
3. *"This allows Hermes to control both computers and for BurnBar to see both and manage both… not only a command center but a war room general; it can monitor resources on both machines and decide when and where to execute. That is our advantage."*
4. *"I don't want the UI to match theirs — we have our own design language and tokens, we use those."*
5. *"When you click the Hermes bot button on the chat screen it should transform / animate elegantly into a screen that basically looks like Grok Bot but with a back button to go back to your other agents and CLIs."*
6. *"Another button to swap out which grok bot you are looking at if you have multiple computers — **not bots from within the same computer**, the toggle is to toggle grok bot **computers**."*
7. *"One more button that animates and transforms the page beautifully into a CLI dashboard so we can see what CLIs are working as a result of our own orchestrating and Grok's orchestrating; **who started which session should be denoted**."*
8. *"The BurnBar Pro and Ultra 'wire' is what feeds this connection."*
9. *"An orchestrator built into the agent/chat page that uses the BurnBar logo; a CLI that is our own BurnBar creation that basically serves as a **router** using everything we collect — quotas, account subs, session logs, memories from our MCP, suggestions from the AI inbox, information about grok bots and the computers they are running on, the hardware they have, and what resources are currently used and available. Its basic purpose is to see everything going on underneath it via the APIs and information BurnBar feeds it; take a prompt from a user; use all of the context collected via our many fountains of information; **distill** them; and based on all that and available system resources, **make a decision on what model, harness, machine, time, number of agents etc. to send each task to**."*

### 1.2 The product, in prose

Today BurnBar is the desk you sit at. The popover knows your burn. The dashboard knows your sessions. Hermes answers questions about both. The Wand casts parallel workers. Agent Control lets an agent drive the Mac while your phone watches. Every one of those is **one machine deep**.

The War Room is what happens when BurnBar stops being a desk and becomes the room where a fleet is run.

Here is the moment this plan builds. You own two Macs. Each one runs Hermes — and with Bot Mode, each Hermes is no longer a chat window, it is a **staffed office**: named bots with their own roles, models, memories, and schedules, working and messaging each other on that machine. Nous gave every computer a crew. Nobody — not Nous, not xAI — gave the **owner of several computers** a room to run them from.

BurnBar is uniquely positioned to be that room, because the room is only as good as its intelligence, and BurnBar already has the intelligence. We know the quotas on every provider account, with honest confidence labels. We know the subscriptions and what they're worth. We know every session ever run, what it cost, and what it produced. We hold the memories agents saved and the suggestions the AI Inbox raised overnight. We watch, every 15 seconds, which CLIs are alive on the machine and how hard the machine is working. **These are the fountains.** No chat app has them. No model company has them. They only exist where the meter has been running all along — and the meter is us.

So the War Room is three things, deliberately in this order:

**A room per computer.** In BurnBar's chat, Hermes stops being just a backend in a picker and becomes a **place you can enter**. Click the Hermes sigil and the chat screen transforms — elegantly, in our own skin, night-dark glass and ember light, nothing borrowed from Nous's chrome — into that computer's Hermes room: its bots, its running sessions, its cron rhythm, its live pulse of CPU and memory. A back control returns you to your other agents and CLIs. A swap control flips you to the *other computer's* Hermes room — and it only ever flips **computers**, never bots within a computer, because in BurnBar's model *"Hermes" is a name bound to a machine*. MacBook Hermes and Mini Hermes are different officers in the same uniform.

**A board over all of it.** A third control transforms the room again into the Command Board: every CLI session across every machine, live — the ones you started, the ones BurnBar's orchestration started, the ones Hermes's own bots and cronjobs started — each row honestly labeled with **who started it**, on which machine, on which harness and model, burning what. Two chains of command, one board. That is the "war room general" view: BurnBar sees both, manages both.

**A flame that decides.** On the chat page, alongside Claude and Codex and Hermes, sits one more sigil — the BurnBar flame itself. It is not another chatbot, and it never pretends to be one. It is a **router with a voice**: give it a goal, and it drinks from every fountain — quotas, plans, session history, memories, inbox, the bodies and their hardware, the live load on each machine — distills them into a written record, and returns a **decision**: this model, this harness, this machine, this many agents, now or later, at this estimated cost and this quota draw, under these caps. You approve; it dispatches through the same mission machinery BurnBar already trusts; the board attributes every resulting row back to the decision that caused it. *Decision is never dispatch.* The Flame proposes; grants and approvals dispose.

And the thing that carries all of it between machines — presence, telemetry, room relays, bot handoffs — is the **Wire**: the encrypted BurnBar Cloud connection that Pro and Ultra members already pay for, extended machine-to-machine. Not Discord. Not Nous's cloud. Fail-closed: when the entitlement or the encryption isn't there, the Wire does not degrade — it goes dark, and says so.

### 1.3 Why this wins

The advantage Alberto named is real and it is structural: **execution placement needs information nobody else is collecting.** Deciding *where* and *when* to run a task requires simultaneously knowing quota headroom (we parse it from every CLI and OAuth surface, with confidence labels — `ProviderQuotaConfidence`), plan economics (we classify subscription vs API burn — `billingKind`), machine load (we probe it — `BurnBarFleetMachineStatusProbe`), harness availability (we detect every CLI on the machine — the fleet roster), history (we hold the ledger — `token_usage`), and intent (we hold the memories and the inbox). Hermes Bot Mode has the crew; xAI has the models; **BurnBar has the operations picture.** The War Room monetizes the operations picture.

---

## 2. Identity law: a Hermes is a machine

### 2.1 The law

> **A "Hermes" in BurnBar is a name bound to a MACHINE.** MacBook Hermes and Mini Hermes are different Hermes. The computer-swap control toggles **machines**. It never, under any circumstance, toggles bots, personas, or profiles within one machine. Bot-level structure (Bot Mode's roster, handoffs, cronjobs) lives *inside* a machine's room and belongs to that machine's Hermes.

This law resolves the ambiguity Nous's launch created. Bot Mode multiplies identities *within* a desktop ("Hermes, Cloudy, Maroon, Mr Tester…"). Alberto's product multiplies identities *across* desktops. BurnBar's chrome navigates the second axis only. The first axis renders as content inside Face B (§3.2), owned end-to-end by that machine's Hermes.

Corollaries:

- **Naming**: the user names the machine-Hermes, defaulting to the Mac's name (`Host.current().localizedName`, already published as `deviceName` by `UsageSyncService.publishDeviceHeartbeat` in `AgentLens/Services/CloudSync/UsageSyncService.swift`). "MacBook Hermes" / "Mini Hermes" are display names over stable machine identity, editable in Devices & Sync.
- **Presence** is machine presence. A Hermes room is "online" when its machine's heartbeats are fresh, "reachable" when the Wire session is up, "offline" otherwise. Bot-level liveness inside the room is Hermes's own data, relayed, never invented by us.
- **Hermes Square personas are a different axis and stay out.** Square's `AgentIdentity`/`AgentPersona` roster (`OpenBurnBarCore/Sources/OpenBurnBarAssistantModels/`, `OpenBurnBarMobile/Views/Hermes/Square/`) are *chat personas* on the companion apps. They are not machines and must never appear in the computer-swap control. The one Square citizen that maps cleanly is the existing `device://paired-mac/<connectionID>` tile — that URI scheme is the precedent this plan generalizes.

### 2.2 What machine identity exists today (all real, all cited)

| Primitive | What it is | Where |
|---|---|---|
| `com.openburnbar.deviceId` | Per-install UUID in UserDefaults (legacy aliases honored) | `OpenBurnBarIdentity.deviceIDKey`, `AccountManager.loadOrCreateDeviceId()` (`AgentLens/Services/AccountManager.swift`) |
| `users/{uid}/devices/{deviceId}` | Presence/registry doc: `deviceName`, `platform`, `lastSeenAt` | written by `UsageSyncService.publishDeviceHeartbeat`; consumed by `functions/src/voipPush.ts` |
| `relay-host-<installationUUID>` | **Canonical per-Mac Hermes connection id** (survives shared-device-ID restores; legacy `relay-<deviceId>` marked `replacedByConnectionId`) | `HermesRelayHostService.relayConnectionID` (`AgentLens/Services/CloudSync/HermesRelayHostService.swift`), `HermesConnectionDoc` (`functions/src/types/legacy/connections.ts`) |
| iroh NodeId + signed NodeAddr | Dialable P2P endpoint per host, 3-minute freshness | `users/{uid}/iroh_pairing/{connectionId}` (`IrohPairingRecordDoc`), `users/{uid}/iroh_pairing_keys/host` |
| Escrow device enrollment | Trusted-device state + key fingerprints (the thing `firestore.rules` requires for mission claims) | `users/{uid}/escrow_devices/{deviceId}`, `DevicesAndSyncSettingsView.swift` |
| Hermes gateway `clientId` | A paired external `hermes-agent` process (device-code flow) | `hermes_gateway_clients` (`docs/HERMES_GATEWAY_PLATFORM.md`) |
| `devices.hardwareModel` | `sysctlbyname("hw.model")` string, used for device icons | `DeviceHardwareIcon.swift`, migration `v23_device_hardware_model` |
| Hermes liveness probe | Gateway heartbeat, 120 s freshness window, on the fleet roster | `hermesHeartbeatFreshnessSeconds` (`docs/fleet/BURNBAR_FLEET_SIGNALS.md`) |

**The honest gap:** these primitives are *parallel*, not *joined*. There is no single record that says "this machine = this device doc = this Hermes connection = this iroh endpoint = this gateway client = this hardware." And the iroh pairing key registry is a **singleton** (`iroh_pairing_keys/host`) designed for phone↔one-Mac; a second Mac is only anticipated in a code comment (`IrohHostKeyPinStore.swift`: "a second Mac pins independently"). `MercuryPeer` v1 is explicitly "one paired Mac per iOS device" (`OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryPeer.swift`).

### 2.3 The `HermesBody` registry (new)

One new joined record per machine — the noun the whole War Room navigates by. "Body" because Bot Mode gave Hermes many minds; BurnBar gives each Hermes exactly one **body**: the machine it inhabits.

- **Doc:** `users/{uid}/hermes_bodies/{bodyId}` where **`bodyId` = the existing `relay-host-<installationUUID>` connection id** — no new identity is minted; the body is the join, keyed by the one id that already survives device-ID restores.
- **Written by:** the owning Mac only (its `HermesRelayHostService` already publishes the connection; body publication extends the same path). Schema lands in `tools/schema-sync/` TypeSpec first, per repo law.
- **Fields:** §7.3.
- **Rendered in:** the computer-swap control (§3.5), Devices & Sync settings, and Face B headers. Free/Cloud users see their single body; the *swap* affordance appears only when ≥2 bodies exist and the Wire tier is active (§4.4).

### 2.4 What the toggle is not

To keep the law enforceable in review, these are **forbidden** in the swap control: Hermes Desktop bots (Bot Mode roster entries), Square personas, CLI backends (`ChatBackendID` cases), provider accounts, Wand workers, gateway clients that share a machine with an existing body (a machine has one body; a second gateway client on the same device folds into the same body). The swap control's data source is exactly `hermes_bodies` and nothing else.

---

## 3. The three faces

### 3.0 One surface, three faces

The War Room is **not a new window and not a new tab**. It is the existing chat workspace (`DashboardMainRoute.chat` → `DashboardChatWorkspaceView`) gaining the ability to *transform* — the same canvas wearing three faces, with continuity of place preserved by shared-element animation. Nothing detaches; the user never loses the room they were in.

```
      ┌────────────────────────────────────────────────────────────┐
      │  FACE A — The Desk                                         │
      │  today's chat workspace: Agent Deck sigils, thread rail,   │
      │  panes. Claude, Codex, Hermes, … and the Flame sigil.      │
      └────────────────────────────────────────────────────────────┘
         │  click the Hermes sigil                     ▲  Back (⌘[ / esc)
         ▼                                             │
      ┌────────────────────────────────────────────────────────────┐
      │  FACE B — The Hermes Room (one per machine)                │
      │  MacBook Hermes: bots, sessions, cron rhythm, live pulse.  │
      │  [Back]                [⇄ swap computer]      [▦ board]    │
      └────────────────────────────────────────────────────────────┘
         │  board control                              ▲  room control
         ▼                                             │
      ┌────────────────────────────────────────────────────────────┐
      │  FACE C — The Command Board                                │
      │  every CLI session, every machine, STARTED BY on each row: │
      │  you · the Flame · the Wand · a mission · a Hermes bot ·   │
      │  external. Both chains of command, one board.              │
      └────────────────────────────────────────────────────────────┘
```

Face A already ships. Faces B and C are new. The three controls Alberto specified — **back**, **computer swap**, **board** — live in a fixed chrome position across faces B and C so the hand never hunts.

### 3.1 Face A — the Desk (exists; two additions)

What ships today (verified): `DashboardChatWorkspaceView` with the `AgentSigilBar` agent deck (Hermes renders in aureate, not provider purple), a 260 pt thread rail, `PaneWorkspaceView` conversation panes, plus the floating `ChatPanel`/`ChatFAB` overlay on non-chat routes and the popover `AssistantsPopoverStrip` (`AgentLens/Views/Dashboard/DashboardChatWorkspaceToolbar.swift`, `AgentLens/Views/Chat/`).

Additions:

1. **The Hermes sigil becomes a door.** Today selecting Hermes in the deck switches the chat backend. With the War Room flag on, the Hermes sigil gains a machine-count badge (one dot per online body) and its activation *transforms* into Face B for the last-visited body (§3.4). Plain backend-switch behavior remains available (right-click / long-press → "Chat here instead"), because Face B contains a full composer anyway — the door is the default, not a wall.
2. **The Flame sigil joins the deck** (§5.2). It renders with `AppLogo` (the flame mark), never a provider glyph, and its "conversation" is the router console.

Nothing else on Face A moves. The Desk is sacred ground — it is the face users already know.

### 3.2 Face B — the Hermes Room

One room per machine. The room answers, at a glance: *what is this computer's Hermes, what is it doing, and what has it done lately?* — and lets you talk to it.

**Anatomy (top to bottom):**

| Region | Content | Source |
|---|---|---|
| **Room header** | Machine-Hermes name ("MacBook Hermes"), presence dot (online / reachable / offline with last-seen), hardware line (`devices.hardwareModel` mapped through `DeviceHardwareIcon`), and the **pulse strip**: CPU %, memory, load, disk-free as compact `monoSmall` gauges | `hermes_bodies` + `BurnBarMachineStatus` (local: `daemon.fleet.snapshot`; remote: over the Wire, §4.5; remote cadence is adaptive — **Decision #4, §14**) |
| **Bot shelf** | That machine's Bot Mode roster: named bots with avatars, role line, last-message preview, running/idle state; a cron glyph on bots that own schedules. Selecting a bot scopes the conversation canvas to that bot's thread. **This is content, not navigation** — the shelf never switches machines (§2.1) | Hermes's own data via the relay operations that already exist: `HermesRelayOperation.sessions` / `sessionDetail` / `profiles` / `jobs` (`functions/src/types/legacy/connections.ts`); local bodies read the same shapes from `localhost:8642`. Rendered **native** in BurnBar chrome — **Decision #3, §14** |
| **Conversation canvas** | The selected bot's chat: messages, tool cards, thinking state — in BurnBar chrome: mercury-stroked assistant bubbles, `HermesToolCard`, `HermesThinkingView` mercury pooling | Existing chat pipeline (`ChatSessionController`, `CLIChatStreamEvent`) pointed at the body: local via `CLIBridge.Backend.hermes(baseURL:)`, remote via the Wire relay lane |
| **Handoff chips** | When bots message each other ("Handoff — sent to agent 'hermes', waiting for reply…" → "[Message from agent 'hermes']"), render as a distinct chip: caduceus glyph, both bot names, waiting/answered state — visually related to the existing `cliUsed` badge family, stroked in `hermesAureate` | Parsed from Hermes session events; cross-**machine** handoffs (one Hermes messaging another over the Wire) get a second glyph showing both machine names |
| **Cron rhythm rail** (collapsed by default) | Upcoming and recent scheduled runs ("Runs land in their own chat history" — each entry deep-links to that bot's thread) | `HermesRelayOperation.jobs` |
| **Composer** | Full composer, placeholder **"Start with a goal for MacBook Hermes…"** — machine name always present so intent can't land on the wrong body. A flame button in the composer's accessory row hands the drafted goal to the Flame instead ("let the room decide where this runs") | Existing composer component; the flame accessory routes to §5 |

**Room chrome:** `liquidGlassSurface` panels over the standard canvas, room border stroked with `mercuryGradient` + one shimmer pass on entry (`DesignSystem.Animation.mercuryShimmer`), header set in SF Pro Rounded per the type ramp. No Nous chrome, no cloned tabs ("SESSIONS | BOTS" is theirs; the shelf/canvas split is ours).

**What Face B refuses to do** (the anti-second-chat-app clauses, enforced here and re-argued in §13.1):

- BurnBar never *creates* Hermes bots. "+ New Agent" is Hermes's affordance; the shelf's empty slot deep-links to Hermes on that machine, it does not open a BurnBar bot-builder.
- BurnBar never owns the message history. The room renders and relays Hermes's threads; export, memory, and skills stay Hermes's.
- No BurnBar-side "bot personality" settings. Model/skills/avatar are edited in Hermes; the room shows them read-only with a jump-out.

### 3.3 Face C — the Command Board

The board answers the general's question: *what is running, where, and on whose orders?*

**Row anatomy** — one row per live or recent CLI session, across **all** bodies:

```
◉  droid        worker 2/3     MiniMax M2.7    Mini Hermes     ⚑ Flame · d-a3f2      running 4m   $0.31
◉  claude-code  fixtures fix   Sonnet 4.6      MacBook Hermes  ● you (this Mac)      running 12m  $1.87
◉  hermes/…     Mr Tester      (bot model)     Mini Hermes     ☿ Hermes cron 07:00   running 1m   —
○  codex        —              —               MacBook Hermes  ◌ external            idle 3h      —
```

| Column | Content | Source |
|---|---|---|
| Agent | Fleet wire id + glyph (`claude-code`, `codex`, `factory-droid`, `hermes`, `grok-bot`, …) | `BurnBarFleetSnapshot` agent rows (local + relayed) — the existing 10-agent roster (`docs/fleet/BURNBAR_FLEET_SIGNALS.md`) |
| Work | Session title / mission title / bot name | mission docs (`CLIAgentMissionRequestDoc.title`), run journal, Hermes `sessions` |
| Model | Canonical model id when known, `—` when not | mission `selectedModelID`, `token_usage.model`, else `—` (never invented) |
| Machine | Body display name | `hermes_bodies` |
| **STARTED BY** | The column Alberto asked for by name: `you (this Mac)` · `you (from iPhone)` · `Flame · d-<id>` (deep-links to the RoutingDecision) · `Wand · group <id>` · `mission · <source>` · `Hermes <bot> · cron/handoff` · `external` | The new **originator** field (§7.4). External sessions — started outside anything BurnBar dispatched — are labeled `external`, honestly, with attribution confidence |
| State + age | `running / idle / stale / unknown` with the fleet confidence vocabulary (`exactProcess / activeSessionFile / logHeartbeat / estimated / unsupported`) rendered **in text, color secondary** — the shipped fleet honesty rule | fleet snapshot |
| Burn | Live cost tally when derivable; token-burn proxy rows labeled **Proxy** exactly as the fleet dashboard already mandates; `—` otherwise | `token_usage` joins + `FleetTokenBurnEstimator` |

**Grouping:** by machine (default) or by originator ("show me everything the Flame started"). A thin **machine cost strip** per group reuses the shipped fleet component family (`FleetAgentCardViews.swift` lineage).

**Both chains of command:** the board's whole point is that BurnBar-orchestrated rows (Flame/Wand/missions) and Hermes-orchestrated rows (bots, cronjobs, handoff-spawned work) sit in the same table with the same honesty rules. Hermes-originated rows come from the body's `sessions`/`jobs` relay data joined to fleet liveness; BurnBar-originated rows come from mission/run/journal state. When the two disagree (Hermes says a session exists, the probe can't see it), the row renders with the lower confidence label — never the prettier one.

**Naming note (collision avoidance):** the shipped "Live Agent Fleet" (`FleetView.swift`) is a *single-machine* dashboard section and its API doc explicitly promises "local-only… not a multi-machine transport" (`docs/fleet/BURNBAR_FLEET_API.md`). Face C is the *cross-machine* board built by **relaying each machine's local fleet snapshot over the Wire** — the fleet plane itself stays local-only and keeps its promise. Docs must keep calling the local plane "Fleet" and this face the "Command Board."

### 3.4 The transform (motion spec)

Alberto asked for the page to "transform / animate elegantly," twice. This is the spec, built entirely from tokens and precedents already in the tree.

**Vocabulary mapping** (his words → our assets):

| His word | Tree reality |
|---|---|
| *night desk* | The dark canvas ramp: `background #0D1117`, `surface #161B22`, `surfaceElevated #1F2630` (`AgentLens/Theme/DesignSystem.swift`). Not a shipped token name — do not invent a new palette; the night desk **is** the existing dark ramp |
| *liquid glass* | `liquidGlassSurface` / `liquidGlassInteractive` / `LiquidGlassGroup` + `LiquidGlassTransparency` preference (`AgentLens/Theme/LiquidGlass.swift`), `.ultraThinMaterial` fallback on macOS 14–15 |
| *grain* | `GrainOverlay` (Canvas noise, today Pro-poster-scoped in `ProPosterScaffold.swift`) — Face B/C may apply it at ≤3% opacity as room texture; this is the one place grain graduates beyond posters |
| *ember / amber* | `ember #FA5053` / `amber #FFA800` (dark) — the Flame's identity gradient is the existing `primaryGradient` (ember→amber) |
| *living flame* | **Gap, now specified:** `FlameSigilView` — a small always-alive flame mark for the deck and Face C rows. Derived from `BurnBarLogoFormationView`'s particle system (`OpenBurnBarCore/.../BurnBarLogoFormationView.swift`) at rest: 8–12 embers drifting within the logo silhouette, 1.8 s loop, amber→ember. Under `accessibilityReduceMotion` it is a static `AppLogo` with a subtle gradient — the flame stops moving, never disappears |

**Choreography — A → B (the door opens):**

| Beat | t (ms) | What moves | Token |
|---|---|---|---|
| 1 | 0–120 | Hermes sigil lifts and glides toward the room-header slot — `matchedGeometryEffect(id: "war.sigil", in: warNS)` (precedent: `DashboardLayoutSwitcher`'s selection pill) | `DesignSystem.Animation.standard` (spring 0.35/0.75) |
| 2 | 0–200 | Thread rail slides left 24 pt and fades; pane content fades | `gentle` (0.4/0.85) |
| 3 | 80–480 | Room regions cascade in: header → pulse strip → bot shelf → canvas → composer, each rising 8 pt with 40 ms stagger (the shipped Editorial Observatory cascade pattern) | `gentle`, 0.04 s stagger |
| 4 | 120–520 | Room border draws with one `mercuryShimmer` pass; **composer does not animate** — it persists in place across the transform, the anchor of continuity (you were about to type; you still are) | `mercuryShimmer` once |

Total ≤ 520 ms — the same budget as the shipped Pensieve flip (`PensieveTokens.motionFrostFlipMs = 520`).

**Choreography — B → C (the room becomes the board):** Y-axis 3-D flip at perspective 0.6, directly reusing the `YoursVsServerFlip` implementation pattern (`AgentLens/Views/Settings/DataControlCenterFlip.swift`): the room is the obverse, the board the reverse of the same card. Board rows cascade at 0.04 s. C → B flips back; C ⇄ C machine swap re-sorts rows with `matchedGeometryEffect` per row id rather than flipping.

**Choreography — B ⇄ B (computer swap):** the room header performs a horizontal card exchange: outgoing body slides 32 pt toward its edge and fades, incoming enters from the opposite edge (`standard` spring); bot shelf and canvas crossfade 200 ms. Direction is stable per body order so the same machine always lives on the same side of the gesture.

**Reduced motion (house rule, non-negotiable):** every beat above collapses to a 150 ms `snappy` crossfade with zero translation, shimmer suppressed, cascade synchronous, flame static — gated on `@Environment(\.accessibilityReduceMotion)` exactly as `HermesThinkingView`, `MercuryShimmerModifier`, and `DataControlCenterFlip` already do. All animation uses `animation(_:value:)` — never valueless.

**Back semantics:** back control (top-left), `esc`, and `⌘[` all return exactly one face (C→B, B→A). Face A is never more than two steps away.

### 3.5 The computer-swap control

- **Placement:** top-right of faces B and C, adjacent to the face control. A capsule showing the current body's name + presence dot; activating it opens a compact liquid-glass switcher listing **bodies only** (§2.4): name, hardware icon, presence, one-line pulse (CPU/mem), and a per-body ember dot when the Flame has active decisions there.
- **Data:** `hermes_bodies` where the machine has been seen recently; offline bodies render dimmed with last-seen, selectable (entering an offline room is allowed — you get the offline state, §9, not a dead click).
- **Keyboard:** `⌘⇧]` / `⌘⇧[` cycle bodies; the switcher is fully keyboard-navigable.
- **One body only:** the control renders as a static machine label (no chevron). Below the Wire tier, a second paired body renders locked with the standard `FeatureUnlockSheet` upsell (§4.4; Pro carries **2** bodies, Ultra **8** — Decision #1, §14) — visible, honest, not hidden.

### 3.6 Face-level empty and failure states

Full matrix in §9; the three that shape the faces' first-run experience, written to the fleet plane's shipped honesty bar (typed not-ready, never fabricated emptiness — `docs/fleet/BURNBAR_FLEET_API.md`):

- **Face B, Hermes not running on that machine:** the room renders its header and pulse (machine data needs no Hermes) with the bot shelf replaced by the editorial setup card driven by the existing `HermesSetupWizardController` state machine (`GatewayReachabilityState`) for local bodies, or a "Hermes isn't reachable on Mini — last heartbeat 2h ago" card with a remote-nudge CTA for Wire bodies.
- **Face C, pre-first-snapshot:** typed "preparing" state (the fleet plane returns `-32603 … not ready`); the board never paints an empty table as if it were a quiet one. Zero running with a healthy snapshot = full roster shown idle — a **healthy empty board**, visually calm, roster present.
- **Any face, Wire down:** remote regions get a single unmissable banner ("Wire to Mini Hermes is down — showing last snapshot, 4 m old") and every remote row's freshness label switches to stale. Local data never dims because remote data died.

---

## 4. The Wire — Pro and Ultra, encrypted, fail-closed

### 4.1 Definition and law

The Wire is the machine-to-machine lane of BurnBar Cloud: the encrypted connection over which bodies exchange presence, telemetry, room relays, fleet snapshots, and bot handoffs. Alberto's constraints, verbatim into law:

1. **Tier:** BurnBar Cloud **Pro and Ultra only.** Not Free, not Cloud. (Fleet caps: Pro pairs **2 bodies**, Ultra **8** — **Decision #1, §14**. The gate itself was never open.)
2. **Encrypted:** end-to-end between enrolled machines. The relay in the middle forwards ciphertext or nothing — the Horcrux promise (`NAMES.md`, burnbar.ai `/trust`) extended to Mac⇄Mac.
3. **Fail-closed:** when entitlement, pairing, or encryption cannot be verified, the Wire **does not fall back to anything weaker**. It goes dark and the UI says so (§3.6, §9). There is no plaintext mode, no third-party bridge, no Discord, no Nous cloud.

### 4.2 What already exists (the Wire is 70% built, like Computer Use was)

| Piece | State | Citation |
|---|---|---|
| iroh QUIC endpoint per Mac, ALPN `openburnbar/1`, length-prefixed `HermesRealtimeRelayFrame` JSON | Shipping (phone↔Mac) | `crates/openburnbar-iroh/`, `packages/hermes-wire-protocol/protocol.json`, `docs/HERMES_IROH_TRANSPORT.md` |
| Ed25519-signed pairing records with 3-minute freshness, published to Firestore | Shipping | `users/{uid}/iroh_pairing/{connectionId}` (`IrohPairingRecordDoc`), callables under `functions/src/callables/iroh*` |
| HPKE v3 payload sealing (Auth mode, DHKEM P-256, AES-256-GCM), `relayKeyVersion: 3` | Shipping | `plans/2026-06-04-burnbar-hpke-v3-migration.md`, `RelaySenderKeyDoc` (`functions/src/types/legacy/connections.ts`) |
| Sealed Firestore store-and-forward fallback when P2P is unavailable | Shipping | `docs/HERMES_REALTIME_RELAY.md`, `docs/CLI_AGENT_CHAT_MIRROR.md` |
| Trusted-device enrollment (escrow devices) that `firestore.rules` already trusts for mission claims | Shipping | `users/{uid}/escrow_devices/{deviceId}` |
| Hosted WSS relay | **Retired 2026-05-28** — do not plan against it | `docs/HERMES_IROH_RETIREMENT.md`, `services/hermes-realtime-relay/` (archaeology) |
| Signal Double Ratchet lane | Contracts staged, **not the production default** (`packages/libsignal-protocol` is flag-off) | `packages/signal-envelope-contracts/src/index.ts`, `docs/signalification/` |

### 4.3 What is new: the Mac⇄Mac lane

Three seams, all extensions of the shipped design rather than new machinery:

1. **Multi-host pairing directory.** Today the pairing key registry is a singleton (`iroh_pairing_keys/host`). New: per-device host keys at `users/{uid}/iroh_pairing_keys/{deviceId}` with `host` kept as a legacy alias for the primary Mac. Every enrolled Mac both publishes a signed NodeAddr (which `iroh_pairing/{connectionId}` + `publishedByDeviceId` already supports) and *dials* peers — the dialer role phones already implement, now compiled into the Mac host client (`HermesIrohRelayHostClient` grows an outbound session table alongside its inbound accept loop).
2. **The `war.*` frame family** on the existing envelope (add cases to `HermesRealtimeRelayFrameType` + `protocol.json`, per the wiki's own modification guide): `war.body.hello` (capability + entitlement proof), `war.body.heartbeat` (presence + pulse summary), `war.fleet.snapshot` (the machine's `BurnBarFleetSnapshot`, §3.3 — the fleet plane stays local; its *snapshot* is relayed), `war.room.relay` (Face B chat/session/profile/jobs ops against a remote body — same `HermesRelayOperation` vocabulary phones use today), `war.handoff` (cross-machine bot handoff envelope), `war.flame.telemetry` (distill-time resource pulls; adaptive cadence per Decision #4, §14). All payloads HPKE-sealed; iroh QUIC provides transport encryption; signatures provide the audit identity, matching the shipped two-layer story.
3. **Wire grants.** A body pair is connected only after an explicit, revocable **wire grant**: on Mac A the user approves "Let MacBook Hermes and Mini Hermes talk," recorded per pair, surfaced in Devices & Sync next to escrow devices, revocable from **either** machine (revocation is honored fail-closed — an unverifiable revocation state reads as revoked). Grant issuance requires both machines to be escrow-enrolled and the account to hold the Wire tier.

**Dispatch does not ride the Wire.** Cross-machine work dispatch stays on the sealed Firestore mission queue (§5.5) — durable across sleep and offline gaps, already approval-gated, already rules-enforced. The Wire is the *nervous system* (presence, telemetry, rooms, handoffs); Firestore remains the *order ledger*. This split is what lets a Mini finish a mission through a 90-second Wire drop (§8) without inventing a second dispatch path.

### 4.4 Entitlement gating and lapse behavior

- **Gate check:** both ends verify tier at `war.body.hello` (entitlement docs under `users/{uid}/entitlements/*` — `burnbar_pro_max` / `burnbar_ultra` families per `EntitlementArbitration.swift`) and re-verify on a slow cadence and on every reconnect. Server-side, Firestore rules on `hermes_bodies` and wire-grant docs mirror the check, the same defense-in-depth pattern as `wandFanOutCap(userId)` in `firestore.rules`.
- **Lapse:** Pro/Ultra expires → wire sessions close (fail-closed), bodies remain visible but dimmed with "Wire requires Cloud Pro," swap control renders the locked state via the existing `FeatureUnlockSheet`, Face C shows local rows only, the Flame's fountains lose the remote branches and its `DistillRecord` says so (§7.2 `dryFountains`). Nothing is deleted; the room goes quiet, not blank.
- **Placement in the ladder:** the Wire sits with its Pro siblings — Floo (Pro), Agent Control (Pro), Hosted MCP (Pro) in `GatedFeatureID` — as a new `GatedFeatureID.wire`-class entry requiring `.pro`. Ultra buys *more wire*: a body cap of **8** against Pro's **2**, enforced as a `warBodyCap(userId)` rule in `firestore.rules` beside `wandFanOutCap`, plus recurring standing orders (**Decisions #1 and #5, §14**). Wand parallelism stays per-executing-machine on the shipped SSOT — no separate cross-machine concurrency knob, because per-machine caps already bound the total and every extra knob is an un-explainable support state (§13.6).

### 4.5 What crosses the Wire (schema-level, exhaustive)

| Crosses (sealed) | Never crosses |
|---|---|
| Body hello/heartbeat: display name, presence, capability flags, entitlement proof | Provider credentials, OAuth tokens, API keys (Keychain-bound today; stays that way — cloud sync already uploads only non-secret account metadata) |
| Pulse + fleet snapshot: `BurnBarMachineStatus` numbers, roster rows with status/confidence, machine cost strip aggregates | Computer Use screenshots and audit-chain bodies (local-only by shipped design; only chain *headers* mirror to Firestore) |
| Face B relay ops: session lists, session detail, profiles, jobs, chat turns for the remote room | Raw provider transcripts / JSONL session files (stay on their machine; Face C shows metadata, deep inspection happens on the owning machine) |
| `war.handoff` envelopes between two bodies' Hermes | Pensieve plaintext (hosted memory stays E2EE via the shipped MCP path; the Flame queries it locally, §6) |
| Flame telemetry pulls at distill time | Anything when entitlement/pairing/revocation state is unverifiable — fail-closed means *nothing* crosses |

---

## 5. The Flame — BurnBar's orchestrator

### 5.1 Router, not persona

The Flame is BurnBar's own CLI-class citizen on the chat page, wearing the BurnBar logo. Its law:

> The Flame **routes**. It does not chat for chatting's sake, it has no personality settings, no memory of its own beyond its decision ledger, no avatar picker, and no ambition to answer your question itself. Its input is a goal; its output is a **decision** — model, harness, machine, time, agent count — with the evidence attached. If you ask it something that isn't work to place, its honest answer is a redirect to an agent that chats.

This is the deliberate inversion of Bot Mode: Nous multiplied personas; the Flame is the *absence* of persona — the room's dispatcher. It renders in flame identity (`FlameSigilView`, `primaryGradient` ember→amber) and never in mercury, so no one ever mistakes the router for Hermes.

### 5.2 Where it lives

- **Brain: in the daemon**, as a new service beside its ancestors — `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/` alongside `OpenBurnBarProviderRouter.swift`, `MissionControl/`, and the fleet plane. The daemon is where every fountain already terminates (quota polling, usage ledger, mission control, fleet probes, inbox ticks) and where the JSONL journaling pattern lives. New RPC family: `daemon.flame.plan` / `daemon.flame.decision.get|list` / `daemon.flame.dispatch` (registered in `BurnBarRPCMethod` with coverage in `BurnBarDaemonSocketRPCCoverageTests`).
- **Face: on the Desk**, as a deck sigil (§3.1). Selecting the Flame opens the **router console** in the conversation pane: a composer whose placeholder is "What needs to happen?" and a feed of decision cards — not chat bubbles. Decision cards render verdict, plan rows (machine/harness/model/agents/schedule), cost + quota-draw estimates with confidence labels, the grant checklist, and Approve / Adjust / Decline. Approve dispatches (§5.5); Adjust reopens placement controls; everything lands in the ledger either way.
- **Hand: in the CLI.** `openburnbar-cli flame plan "<goal>"` (print the decision as JSON + human table), `flame decisions`, `flame dispatch <decisionId>`, `flame why <decisionId>` (render the DistillRecord evidence) — added to `BurnBarCLIRunner` beside `missions` / `mission-approve`, so the router is scriptable from the first phase.

### 5.3 The loop

```
prompt/goal ──▶ COLLECT ──▶ DISTILL ──▶ DECIDE ──▶ [approval] ──▶ DISPATCH ──▶ ATTRIBUTE ──▶ LEARN
                 │             │           │                          │             │           │
                 8 fountains   DistillRecord  RoutingDecision         existing      originator   decision outcome
                 (§6)          (§7.2)         (§7.1)                  mission/wand/ on every     recorded against
                                                                      run paths     board row    the ledger
```

- **Collect** hits every fountain with a per-fountain freshness budget; a fountain that can't answer in budget is recorded **dry**, never guessed (§9).
- **Distill** normalizes the three quota-confidence vocabularies into one floor (`exact | estimated | unavailable` — the Mac-parity alias set from `ProviderQuotaMacParity.swift`), joins bodies to hardware to live pulse, and writes the immutable `DistillRecord`: *what the Flame saw*.
- **Decide** scores placements. The scoring frame extends the daemon router's shipped five dimensions (capability / cost / latency / trust / policy-fit, `OpenBurnBarProviderRouter.swift`) with the war dimensions: **quota headroom** (from snapshots + reset clocks), **machine load** (pulse), **machine capability** (hardware + installed harnesses from the fleet roster), **placement policy** (user prefs like "keep Claude for afternoons"), and **agent count** under Wand caps. Output: verdict `dispatch | advise | hold | decline` + ranked plan with fallbacks.
- **Approval** is the only ground truth — inherited verbatim from Computer Use Decision 1. No silent autopilot. (Recurring schedules run under a scoped, revocable **standing order** — a standing approval, §7.6 — and do not re-prompt per emission; every emission is still journaled, attributed, and BudgetGate-checked. **Decision #5, §14**.)
- **Dispatch** never invents a path (§5.5). **Attribute** stamps the originator (§7.4). **Learn** records the outcome (mission result, actual cost, actual quota draw) against the decision so `flame why` can show predicted-vs-actual — the feedback ledger for tuning weights later; no self-modifying behavior in v1.

### 5.4 Ancestors (the Flame is a promotion, not an invention)

| Ancestor | What it proves | What the Flame adds |
|---|---|---|
| `BurnBarProviderRouter` (daemon) | Five-dimension scoring, JSONL decision audit (`provider-routing-decisions.jsonl`), fail-closed exact-model mode | The machine axis, quota-reset clocks, agent count, schedule; decisions as first-class user-visible artifacts |
| `WandModelRouter` (Headmaster/Pareto) + ministry selector (`tools/openburnbar-mcp/select_wand_models.py`) | Fan-out model choice per worker; tier caps | Live quota telemetry (the Wand router scores heuristics today — a named gap), machine placement, and one decision record covering all workers |
| `BudgetGate` → `BudgetGateDecision` | allow / softWarning / hardBlocked / paused as a typed gate | The spend grant: every RoutingDecision embeds the gate result; hardBlocked forces verdict `decline` with the shipped `BudgetBlockedCard` rendering |
| Mission Control (`missionDispatchPacket` gating: approved? terminal? policy? readiness?) + `BurnBarParallelDAGScheduler` | Decision ≠ dispatch already enforced in the tree | The Flame *feeds* this gate rather than bypassing it |
| Router Rundown (`functions/src/routerRundown*.ts`) + `catalog.json` pricing + benchmark-aware Insights | Model quality/price boards | Advisory inputs to Decide, labeled as advisory — benchmarks inform, never override quotas |

Also inherited as a warning: `intelligent_model_router` is a **dead alias** (decodes to same-model failover, excluded from `allCases` — `ProviderRouterMode`). The Flame gets its own mode namespace; nothing reuses that string.

### 5.5 Decision ≠ dispatch

The Flame **emits**; it never **executes**. Dispatch rides the rails that already exist, chosen per plan row:

| Plan row shape | Rail | What's new on the rail |
|---|---|---|
| N parallel workers on machine M | Wand fan-out → mission group (`mission_groups` + N `cli_agent_mission_requests`) | **Machine targeting**: today the queue is account-scoped and "whichever Mac claims wins" — a named gap. New optional `targetDeviceID` on the request doc honored by `CLIAgentMissionRequestListener` claim logic + `firestore.rules`. (One-shot scheduling lands as `notBefore` on the mission doc; recurrence is held by the Flame scheduler and emits fresh missions — **Decision #5, §14**) |
| Single session on machine M | Single mission, same targeting | Same |
| Local daemon-managed run | `run.create` (RunService, approval-gated) | Originator stamp only |
| Advise-only (Free tier — **Decision #2, §14** — or verdict `advise`) | No rail — the decision card is the product | — |

Caps enforced at dispatch, never at decide: Wand parallelism per tier (1/3/8/16 — enforced in all four shipped places), Computer Use budgets if a plan row needs Agent Control, BudgetGate for spend. The Flame showing you a 12-agent plan on a Cloud tier is a bug by definition — Decide reads the caps from the same SSOT (`WandFanOut.maxParallel`) so infeasible plans are never rendered.

### 5.6 Grants — the four keys

The Flame holds no standing authority. Each decision lists which keys it needs and which are present; a missing key renders the affected plan rows locked-with-reason, and approval cannot cover a missing key ("approve" ≠ "grant").

| Grant | Meaning | Existing substrate |
|---|---|---|
| **Wire** | May see and place work on remote bodies | §4.3 wire grants; without it the Flame is a single-machine router (which is still a product: Free ships it advise-only, Cloud dispatches locally — **Decision #2 and ladder B1, §14**) |
| **Agent Control** | Plan rows that drive browser/system tools | The entire shipped grant apparatus: Pro gate, `controlAgentGrantRequest` frames, `agent_capability_grant_requests` queue, trust modes, scope rules, audit chain. The Flame may *request*, never self-grant — "entitlement alone is not auto-pilot" (`docs/FEATURE_GATING_SPEC.md`) stays true with the Flame in the room |
| **Wand > 1** | Parallel worker counts | Tier caps (SSOT above); the grant is the tier itself, surfaced per-decision |
| **Spend** | Estimated cost clearance | `BudgetGate.evaluate(credential:projectName:estimatedCost:)` — the estimate comes from `catalog.json` pricing and is labeled an estimate |

### 5.7 What the Flame reads but never holds

Credentials (Keychain-bound; the Flame sees quota *snapshots* and account *metadata*, the same boundary cloud sync already enforces), Pensieve plaintext (queried via the local/hosted MCP tools with their E2EE intact), Hermes bot memories (Hermes's own; visible only as session metadata via relay ops). The Flame's entire worldview is reconstructible from its DistillRecords — that is the point of them.

---

## 6. The fountain inventory

Alberto named eight fountains. Every one is mapped to what actually exists, how fresh it runs, and where it is dry. **Rule inherited from the fleet plane: a dry fountain is reported dry, never simulated.**

| # | Fountain | What it yields | Real substrate (cited) | Freshness | Honest gaps |
|---|---|---|---|---|---|
| 1 | **Quotas** | Per-provider, per-account buckets with reset clocks and confidence | `ProviderQuotaSnapshot` / `QuotaSnapshotDoc` (`OpenBurnBarCore/.../ProviderQuotaTypes.swift`, `functions/src/types/legacy/quota-usage.ts`); 17 live adapters in `ProviderQuotaAdapterRegistry.standard` (Claude, Codex, Cursor, xAI/Grok, Factory, MiniMax, ZAI, Warp, Kimi, …); local cache `provider_quota_snapshots`; Firestore `users/{uid}/quota_snapshots/*` | Adapter polling + CLI-stream signals (`CLIBridgeQuotaSignalRecorder`) | **Three confidence vocabularies** (canonical `high/medium/low/stale`, Mac aliases `exact/estimated/unavailable`, FFI enum) — Distill must normalize; `planTier` typed on the doc but the Mac sync doesn't write it; some providers have parsers but no adapter (Hermes itself) |
| 2 | **Account subs** | Which subscription each provider account carries, and BurnBar's own tier | `ProviderAccountDoc` (`functions/src/types/generated/provider-account.ts`); plan inference scattered: Claude OAuth `subscriptionType`/`rateLimitTier` (`ClaudeCredentialsReader.swift`), switcher `subscriptionTierID`, Codex `planType`, `provider_quota_snapshots.planName`; BurnBar tier via `EntitlementArbitration.effectiveTier` | On account refresh / OAuth read | **No first-class plan field** on the account doc (except Mimo's `tokenPlanTier`) — Distill records plan with a `source` tag (`oauth / switcher / statusText`) instead of pretending it's canonical |
| 3 | **Session logs** | Every session's tokens, cost, model, machine, billing kind | SQLite `token_usage` (`docs/SCHEMA_SQLITE.sql` — note: schema doc has known drift, treat migrations as truth); parsers registered in `ParserRegistry.swift`; daemon journals `run-journal.jsonl`, `usage-events.jsonl`; sealed cloud manifests `users/{uid}/session_logs/*`; rollups `usage_rollups/{today,7d,30d,90d,all_time}` | Parser ingest (near-real-time on file change) | **No `sessions` table** — sessions are `sessionId` join keys; **no originator** (§7.4 fixes); provider transcripts stay in CLI-owned paths |
| 4 | **MCP memories** | Session memory + Pensieve knowledge the user approved | Hosted MCP tools (`services/hosted-mcp/src/toolRegistry.ts`): `burnbar_search_knowledge`, `burnbar_search_conversations`, `burnbar_recent_usage`, `burnbar_list_resumable_conversations`, …; local `agent_memories` / `memory_*` tables; review UI `MemoryReviewInboxView.swift` | Sync-driven (hosted) / extraction-gated (local) | E2EE by design — the Flame queries through the same tools agents use; **mem0 (`droid-wiki` mirror) is developer knowledge, not a product fountain** — excluded |
| 5 | **AI Inbox** | Ranked, evidence-bearing suggestions (CI waste, cost anomaly, stuck PR, …) with actions | `BurnBarAIInboxContracts.swift` (kinds, P1–P4, evidence, actions, memory candidates); daemon generator `OpenBurnBarDaemon/.../AIInbox/`; SQLite `ai_inbox_items`; sealed mirror + FCM on P1 (`functions/src/aiInboxNotifications.ts`) | 300 s tick, change-gated | **Off by default; egress `.off` by default** (detector-only) — Distill records `inbox: dry(disabled)` when off; the Flame never nags it on |
| 6 | **Hermes bodies + computers** | Which machines exist, which run Hermes, bot rosters, session/jobs state | §2 registry (new) joining `hermes_connections` + `devices` + `iroh_pairing` + gateway `hermes_gateway_clients`; roster/session/jobs via `HermesRelayOperation.{sessions,sessionDetail,profiles,jobs}`; liveness via fleet `hermes` probe (120 s window) | Heartbeats 120 s; relay ops on demand | **The registry is the new part** (§2.3); Bot Mode roster shape depends on upstream Hermes Desktop surface — pin a contract version at Face B build time (§13.3) |
| 7 | **Hardware** | What each machine *is* (chip, cores, RAM size, GPU) | `devices.hardwareModel` (`hw.model` string via `DeviceHardwareIcon.swift`) — icon-grade only | On device registration | **Real inventory does not exist**: no chip/core/RAM-size/GPU registry anywhere (confirmed absence). §7.3 adds `hardware` to `HermesBody` (sysctl-sourced: `machdep.cpu.brand_string`, `hw.memsize`, `hw.perflevel*`); until populated, Distill lists `hardware: dry` and Decide falls back to load-only placement |
| 8 | **Live resources** | What each machine is *doing right now* (CPU, RAM, load, disk) | `BurnBarFleetMachineStatusProbe` (`host_statistics` CPU, `HOST_VM_INFO64` memory, `getloadavg`, `statfs`) in `BurnBarFleetSnapshot`, 15 s cadence, local-only by contract | 15 s local; remote = adaptive over the Wire (**Decision #4, §14**) | **Thermal/power explicitly `.unavailable`**; **no GPU utilization**; per-agent CPU/RAM usually PID-only (UI already falls back to the labeled token-burn **Proxy**) — the board keeps that exact labeling |

Reading the table bottom-up is the build order hiding in plain sight: fountains 1–5 flow today and need only normalization; fountain 6 needs the registry; 7 needs a small probe; 8 needs the Wire to travel.

---

## 7. Schemas

All new shapes land in `tools/schema-sync/` TypeSpec first (repo law — `./tools/schema-sync/check-drift.sh` before changing shared models), emit TS/Swift/Kotlin, and version with `schemaVersion` from day one. SQLite changes update `docs/SCHEMA_SQLITE.sql` alongside the GRDB migration, per `AGENTS.md`.

### 7.1 `RoutingDecision`

The Flame's output. Immutable once verdict-stamped; dispatch progress lives in `dispatch.*` updates appended by the dispatcher, not by editing the decision.

```jsonc
{
  "decisionId": "d-a3f2c9…",                  // uuid
  "schemaVersion": 1,
  "createdAt": "2026-08-17T09:14:07Z",
  "requestedBy": { /* Originator, §7.4 — who asked the Flame */ },
  "goal": {
    "sha256": "…",                            // hash of the prompt text
    "sealedRef": "vault://flame/goals/…",     // CloudVault-sealed body; plaintext never in the ledger
    "surface": "desk_console | face_b_composer | cli | phone"
  },
  "distillId": "s-77b1…",                     // the evidence this decision was made on (§7.2)

  "verdict": "dispatch | advise | hold | decline",
  "verdictReason": "…",                        // required for hold/decline (e.g. "BudgetGate: hardBlocked (daily)")

  "plan": [{
    "taskId": "t-01",
    "summary": "Migrate parser fixtures to schema v3",
    "body": { "bodyId": "relay-host-9C41…", "displayName": "Mini Hermes" },
    "harness": "droid",                        // ChatBackendID rawValue — the shipped vocabulary
    "modelID": "minimax/m2.7",                 // canonical id, resolvable in catalog.json
    "agentCount": 3,                           // ≤ WandFanOut.maxParallel(tier), by construction
    "schedule": { "kind": "now | window", "notBefore": null, "expiresAt": null },   // recurrence never lives here — it lives on a StandingOrder (§7.6), Decision #5 (§14)
    "estimate": {
      "costUsd": 0.87, "costConfidence": "estimated",          // catalog.json list-price math, labeled
      "quotaDraw": [{ "providerID": "minimax", "accountID": "acc_…", "bucketId": "weekly", "fraction": 0.03, "confidence": "exact" }],
      "durationMinutes": 22
    },
    "fallbacks": [{ "body": "…", "harness": "codex", "modelID": "…", "reason": "if Mini offline > 10m" }]
  }],

  "caps": {
    "tier": "pro",
    "wandMaxParallel": 8,                      // read from WandFanOut SSOT at decide time
    "budgetGate": "allow | softWarning | hardBlocked | paused"   // BudgetGateDecision, verbatim
  },
  "grants": {
    "required":  ["wire", "wand_parallel"],    // "agent_control" / "spend" when applicable
    "satisfied": ["wire", "wand_parallel"],
    "missing":   []                            // non-empty ⇒ affected rows render locked; approval cannot substitute
  },

  "rationale": [                               // ranked, evidence-linked — this is what `flame why` renders
    { "factor": "quota_headroom", "detail": "Claude 5h bucket at 38%, resets 09:55 — held in reserve per user policy", "fountain": "quotas" },
    { "factor": "machine_load",   "detail": "MacBook CPU 74% (7 agents) vs Mini 6%",                                  "fountain": "resources" },
    { "factor": "memory",         "detail": "Pensieve hit: fixture-migration notes 2026-08-11",                       "fountain": "mcp_memories" }
  ],

  "dispatch": {
    "mode": "wand | mission | run | none",
    "missionGroupID": null, "missionIDs": [], "runIDs": [],
    "dispatchedAt": null,
    "approval": { "approvedBy": null, "approvedAt": null, "surface": null }
  },

  "outcome": {                                 // appended by Learn; null until terminal
    "state": null,                             // "completed | failed | cancelled | expired"
    "actualCostUsd": null, "actualQuotaDraw": null,
    "predictedVsActualNote": null
  },

  "parentDecisionId": null,                    // re-plans chain
  "auditParentSha256": "…"                     // hash-chain over canonical JSON, same discipline as the CU audit chain (SHA-256 today, BLAKE3-swappable)
}
```

### 7.2 `DistillRecord`

What the Flame saw — immutable, hash-addressed, referenced by every decision. One record per Decide; cheap because fountains are snapshots, not scans.

```jsonc
{
  "distillId": "s-77b1…",
  "schemaVersion": 1,
  "collectedAt": "2026-08-17T09:14:05Z",
  "collectBudgetMs": 1500,                      // per-fountain deadline; misses go dry, not late

  "fountains": {
    "quotas":    { "state": "fresh", "snapshots": [{ "providerID": "anthropic", "accountID": "acc_…", "bucketId": "5h",
                    "remainingFraction": 0.38, "resetAt": "2026-08-17T09:55:00Z",
                    "confidence": "exact",     // normalized floor: exact | estimated | unavailable (ProviderQuotaMacParity aliases)
                    "fetchedAt": "…" }] },
    "accounts":  { "state": "fresh", "plans": [{ "providerID": "anthropic", "planLabel": "Max", "source": "oauth" },
                                               { "providerID": "openai",    "planLabel": "Pro", "source": "switcher" }] },
    "sessions":  { "state": "fresh", "activeCount": 8, "cost24hUsd": 14.20, "topModels": ["sonnet-4.6", "minimax/m2.7"] },
    "memories":  { "state": "fresh", "hits": [{ "tool": "burnbar_search_knowledge", "ref": "kn_…", "label": "fixture migration notes" }] },
    "inbox":     { "state": "dry",   "dryReason": "disabled" },            // honest, not zero
    "bodies":    { "state": "fresh", "machines": [{ "bodyId": "…MacBook", "presence": "online",  "hermes": { "reachable": true,  "botCount": 4 } },
                                                  { "bodyId": "…Mini",    "presence": "online",  "hermes": { "reachable": true,  "botCount": 2 } }] },
    "hardware":  { "state": "partial", "perBody": [{ "bodyId": "…Mini", "hardwareModel": "Mac16,11", "chipBrand": null, "memBytes": null }],
                   "dryFields": ["chipBrand", "memBytes"] },
    "resources": { "state": "fresh", "perBody": [{ "bodyId": "…MacBook", "cpuPercent": 74, "memUsedBytes": 51e9, "memTotalBytes": 64e9, "loadAvg1": 9.8, "diskFreeBytes": 210e9, "sampledAt": "…", "transport": "local" },
                                                 { "bodyId": "…Mini",    "cpuPercent": 6,  "memUsedBytes": 9e9,  "memTotalBytes": 64e9, "loadAvg1": 0.4, "diskFreeBytes": 1.4e12, "sampledAt": "…", "transport": "wire" }] }
  },

  "dryFountains": ["inbox", "hardware.chipBrand", "hardware.memBytes"],   // surfaced verbatim on the decision card
  "confidenceFloor": "estimated",               // the weakest link across consulted quota evidence
  "sha256": "…"
}
```

### 7.3 `HermesBody`

```jsonc
// users/{uid}/hermes_bodies/{bodyId}   — bodyId == relay-host-<installationUUID>
{
  "bodyId": "relay-host-9C41…",
  "schemaVersion": 1,
  "deviceId": "…",                             // → users/{uid}/devices/{deviceId}
  "displayName": "Mini Hermes",                // user-editable; defaults to deviceName
  "machineName": "Alberto's Mac mini",         // Host.current().localizedName at publish
  "platform": "macos",
  "hardware": { "model": "Mac16,11", "chipBrand": "Apple M4 Pro", "coresPerf": 10, "coresEff": 4,
                "memBytes": 68719476736, "gpu": null },          // sysctl-sourced; null = unknown, rendered "—"
  "hermes": { "installed": true, "gatewayReachable": true, "version": "…",
              "gatewayClientId": "hgc_…",      // when device-code-paired via the Gateway Platform
              "botCount": 2, "botsUpdatedAt": "…" },
  "endpoints": { "irohNodeId": "…64-hex…", "pairingConnectionId": "relay-host-9C41…" },
  "presence": { "state": "online | idle | offline", "lastHeartbeatAt": "…", "wireReachable": true },
  "capabilities": ["hermes_chat", "bots", "cron", "wand", "agent_control", "fleet_probe"],
  "createdAt": "…", "updatedAt": "…"
}
```

Written only by the owning Mac (rules-enforced, same posture as escrow docs). The swap control, Face B header, and the Flame's `bodies` fountain all read exactly this.

### 7.4 `Originator` — the STARTED BY column

One typed shape stamped everywhere work begins, so Face C never guesses:

```jsonc
{
  "kind": "user_local | user_remote | flame | wand | mission | hermes_bot | hermes_cron | external | unknown",
  "label": "Flame · d-a3f2",                   // render-ready
  "bodyId": "relay-host-…",                    // where the order originated
  "decisionId": "d-a3f2…",                     // when kind == flame
  "missionID": "…", "missionGroupID": "…",     // when dispatched via missions/wand
  "botName": "Mr Tester",                      // when kind == hermes_bot / hermes_cron
  "confidence": "exact | inferred | unknown"   // fleet-style honesty; external rows are usually "inferred"
}
```

Landing sites (each is a small, additive change): `CLIAgentMissionRequestDoc` (formalizing the existing `source`/`sourceSurface` strings), `BurnBarRunJournal` `run_created` events, new nullable columns on `token_usage` (`originatorKind`, `originatorRef`, extending the shipped `executionSource*` family), and fleet agent rows when the daemon can derive it (it knows its own spawns exactly; everything else is `external/inferred`).

### 7.5 Storage and sync

| Artifact | Home | Pattern it follows |
|---|---|---|
| `flame-decisions.jsonl`, `flame-distills.jsonl` | Daemon support dir (`~/Library/Application Support/OpenBurnBar/`) | Sibling to `provider-routing-decisions.jsonl`, `run-journal.jsonl`, `controller-events.jsonl` — the shipped JSONL journal discipline, hash-chained like the CU audit log |
| `flame_decisions`, `flame_distill_records` tables | GRDB SQLite | For console/board queries; `docs/SCHEMA_SQLITE.sql` updated with the migration |
| Sealed mirror `users/{uid}/flame_decisions/{id}` | Firestore, CloudVault-sealed body + plaintext routing header (verdict, createdAt, bodyIds) | Identical posture to the AI Inbox mirror — phones render decision cards without the cloud reading goals |
| `hermes_bodies`, wire grants | Firestore + rules | Escrow-device posture |

### 7.6 `StandingOrder` — recurring approval, scoped and revocable *(Decision #5)*

A standing order is how "approval is the only ground truth" survives recurrence without becoming a nag or an autopilot. It is a **standing approval with hard edges**, modeled on the Computer Use trusted-scope precedent (expiring scopes, revocable, fail-closed):

```jsonc
// daemon-held, event-sourced on the Mission Control JSONL pattern; sealed mirror like flame_decisions
{
  "orderId": "so_…",
  "schemaVersion": 1,
  "decisionId": "fd_…",                        // the RoutingDecision the user approved as recurring
  "originator": { "kind": "flame", "…": "…" }, // every emission stamps this
  "recurrence": { "cron": "0 7 * * 1-5", "timezone": "America/New_York" },
  "scope": {
    "expiresAt": "…",                          // hard ceiling: ≤ 30 days from grant; renewal is a fresh approval
    "maxRuns": 20,                             // hard ceiling on emissions
    "perRunBudgetUsd": 2.00,                   // BudgetGate-checked per emission, not once
    "targetBodyIds": ["relay-host-…"]          // placement may not silently widen beyond the approved bodies
  },
  "state": "active | paused | revoked | expired | exhausted",
  "runsEmitted": 3, "lastEmittedAt": "…",
  "createdAt": "…", "approvedAt": "…", "revokedAt": null
}
```

Laws: emissions **never re-prompt** while the order is valid, but each one is journaled, attributed (`originator.kind == "flame"`, order id in the chain), and BudgetGate-checked; an unverifiable order state reads as revoked (fail-closed, same posture as wire grants §4.3); revocation works from Mac **or** phone and halts before the next emission; when the scheduler sees a Hermes cronjob targeting the same body and window (fountain 6's `jobs` op), it defers and says so — two schedulers may coexist on one machine, but they never stack blind, and the board shows both chains via originators. Standing orders are **Ultra-gated** (ladder B1, §14); Pro gets one-shot windows (`notBefore`).

---

## 8. A day in the life

*Two computers, one prompt, a handoff, a board row — the four beats Alberto asked to see. Machine names are the defaults a real user would have; numbers are shaped like real fountain output.*

**09:12.** Alberto opens BurnBar on the MacBook. The Desk is busy: seven sessions on the board glyph, Claude's 5h bucket showing 38% in the popover. In the deck: Claude, Codex, Hermes (two presence dots — both Macs online), and the flame.

**09:14 — one prompt.** He clicks the flame and types: *"Migrate the parser fixtures to schema v3 and get the Android suite green. Don't torch my Claude quota — I need it this afternoon."*

The Flame collects (1.5 s budget). Distill `s-77b1` records: Claude 5h at 38%, **exact**, resets 09:55; Codex weekly 82% exact; MiniMax weekly 97% exact. Plans: Claude **Max** (oauth), Codex **Pro** (switcher). MacBook pulse: CPU 74%, load 9.8, 7 agents. **Mini pulse over the Wire: CPU 6%, 55 GB free RAM, disk 1.4 TB.** Fleet roster says Mini has `factory-droid` and `claude-code` installed and idle. Pensieve hit: his own fixture-migration notes from last Tuesday. Inbox: dry (disabled) — recorded, not zeroed.

Decision card `d-a3f2`, verdict **dispatch**:

> **Mini Hermes** · droid ×3 · MiniMax M2.7 — fixture migration, est. $0.87 (estimated), 3% MiniMax weekly
> **Mini Hermes** · claude-code ×1 · Sonnet 4.6 — final review pass only, est. 4% Claude 5h *(after 09:55 reset — scheduled)*
> **MacBook** — untouched. *Rationale: Claude reserved per your goal; MacBook at 74% CPU; Mini idle with both harnesses installed.*
> Grants: wire ✓ · wand 4/8 ✓ · spend allow ✓ · agent control — not needed.

**09:15 — approve.** One click. The Flame writes the decision, dispatches a mission group targeted at Mini's `deviceId`, stamps `originator: flame · d-a3f2`. Mini's listener claims it — no other Mac can, the target is on the doc.

**09:19 — the room.** He clicks the Hermes sigil. The Desk *becomes* MacBook Hermes's room — sigil gliding into the header, regions cascading in, one shimmer along the border. He taps the swap capsule: **Mini Hermes** slides in from the right. The pulse strip is climbing (CPU 41% and rising — his workers). On the bot shelf, Mini's own crew: "Hermes" and "Mr Tester" (cron glyph, 07:00).

**09:31 — the handoff.** Mr Tester's cron already ran the Android suite this morning and knows the flaky test. Mini's Hermes hands off: a chip appears in the room — **⇄ Handoff: mr-tester → hermes** · *"waiting for reply…"* then *"[Message from agent 'hermes']: two fixtures reference retired schema fields; flagged for the migration workers."* Same Bot Mode mechanics Nous demoed — rendered in BurnBar chrome, ember-stroked, on the Wire, readable from the other machine.

**09:33 — the board.** Third control: the room flips — perspective 0.6, 520 ms — into the Command Board:

```
MINI HERMES                                                    $0.31 today
◉ droid        worker 1/3 · fixtures     MiniMax M2.7   ⚑ Flame · d-a3f2     running 18m   $0.11
◉ droid        worker 2/3 · fixtures     MiniMax M2.7   ⚑ Flame · d-a3f2     running 18m   $0.09
◉ droid        worker 3/3 · fixtures     MiniMax M2.7   ⚑ Flame · d-a3f2     running 18m   $0.11
◉ hermes       mr-tester · suite triage  —              ☿ Hermes cron 07:00  running 2m    —
○ claude-code  review pass               Sonnet 4.6     ⚑ Flame · d-a3f2     queued 09:55  —

MACBOOK HERMES                                                 $1.87 today
◉ claude-code  api refactor              Sonnet 4.6     ● you (this Mac)     running 31m   $1.87
◉ codex        —                         —              ◌ external            running 9m    Proxy 41k tok
```

Every row answers *who started which session* — him, the Flame (deep-link to `d-a3f2`), Hermes's own cron, and one honest `external` he started from a bare terminal.

**09:41 — the wire blinks.** The Mini drops off the network for 90 seconds. The banner appears — *"Wire to Mini Hermes is down — showing last snapshot, 1m old"* — Mini's rows relabel stale. The workers **don't stop**: the mission is on the Firestore ledger and executing locally on Mini. Wire returns; rows re-freshen; nothing was pretended in between.

**09:55.** Claude's bucket resets on schedule; the queued review row starts; `flame why d-a3f2` will later show predicted $0.87 / 4% vs actual $0.91 / 3.6%. His afternoon Claude is intact — which was the actual prompt.

---

## 9. Empty, offline, and dry-fountain states

House bar (from the shipped fleet contract): **typed not-ready over fabricated emptiness; `—` over fake zeros; text labels with color secondary; degraded states named, never collapsed into success.**

| Surface | Condition | Rendering |
|---|---|---|
| Swap control | One body (most users, day one) | Static machine label, no chevron — the control never advertises a fleet the user doesn't have |
| Swap control | Second body exists, tier below Pro | Locked row + `FeatureUnlockSheet` (shipped component); copy names the Wire and the tier, no dark patterns |
| Face B | Body online, Hermes not installed/running | Header + pulse render (machine truth needs no Hermes); shelf area carries the editorial setup card — local bodies drive the shipped `HermesSetupWizardController` states (`cliMissing / apiServerDisabled / dashboardOnly / unreachable → "Make Gateway Reachable"`), remote bodies get last-heartbeat + a nudge CTA |
| Face B | Body offline | Room in last-known state, dimmed, presence "offline · last seen 2h ago"; composer disabled with reason; nothing pretends to be live |
| Face B | Bot shelf empty (Hermes reachable, zero bots) | "No bots on Mini Hermes yet — create them in Hermes on that machine" + jump-out. **No BurnBar bot-builder** (§13.1) |
| Face C | Pre-first-snapshot | Typed "Preparing the board…" from the fleet plane's `-32603 not ready`; never an empty table |
| Face C | Healthy zero | Full roster rendered idle — the shipped "healthy empty board" — plus remote roster sections per body |
| Face C | Remote body's snapshot stale | Section banner + per-row stale labels; local sections unaffected |
| Face C | Attribution underivable | `external` + confidence `inferred` — never a guessed owner |
| Flame | Fountain misses collect budget | Listed in `dryFountains`; decision card renders "Decided without: inbox (disabled), hardware.chip (unknown)" in `monoTiny` |
| Flame | All quota evidence `unavailable` for a provider | That provider's placements demote to fallbacks; if the goal *requires* it, verdict `hold` with reason — the Flame does not route on fiction |
| Flame | `BudgetGate` `hardBlocked` / `paused` | Verdict `decline` / `hold`; card embeds the shipped `BudgetBlockedCard` |
| Flame | Wire grant missing, remote plan optimal | Verdict `advise`: shows the better remote plan locked-with-reason + the best local plan dispatchable — sells the Wire by being honest, not by nagging |
| Wire | Entitlement lapse mid-session | Sessions close (fail-closed); bodies dim; Face C drops to local; DistillRecords mark remote fountains dry with `dryReason: entitlement` |
| Wire | Pairing/revocation state unverifiable | Treated as revoked. Dark, stated, no downgrade path |
| Any | Kill switch (`war_room_kill_switch`, Remote Config) | Faces B/C collapse to Face A with a named notice; Flame goes advise-only; same posture as `computer_use_kill_switch` |

---

## 10. Privacy and security

1. **The Wire inherits the strongest shipped posture, not a new one.** iroh QUIC E2E between Ed25519-paired endpoints; HPKE v3 sealing on relayed payloads; sealed Firestore fallback; relays forward ciphertext only (Horcrux). New `war.*` frames ride the same envelope and keystores — no new crypto is invented for this feature. Signalification, when it lands repo-wide, upgrades the Wire for free.
2. **Fail-closed is a security property here, not just UX.** Unverifiable entitlement, pairing, or revocation ⇒ no traffic. The Wire never negotiates down.
3. **New data class: cross-device telemetry.** Pulse numbers (CPU/RAM/load/disk) leaving a machine is new. Mitigations: telemetry crosses only under an active wire grant (per body pair, revocable from either end); samples are ephemeral on the receiver (rendered, folded into DistillRecords, not accumulated server-side); Firestore never stores raw pulse — only sealed DistillRecords embed point-in-time readings.
4. **The Flame's ledger is sealed like the Inbox.** Goals are CloudVault-sealed (`goal.sealedRef`); the Firestore mirror carries plaintext routing headers only (verdict, timestamps, bodyIds) — the same split `ai_inbox_items` ships today. `flame-decisions.jsonl` is local, hash-chained, and `openburnbar-cli audit-verify` learns to walk it (the CU chain verifier pattern).
5. **Credentials never move.** Quota snapshots and account metadata travel; keys stay in Keychain / server-private scopes — the boundary cloud sync already enforces, restated as a Wire invariant (§4.5).
6. **Computer Use invariants are inherited unchanged** wherever a Flame plan row touches Agent Control: approval ground truth, per-session trust modes, phone downgrade-only, scope rules, tamper-evident audit, three panic paths + Remote Config kill. The Flame adds a fourth kill of its own (`war_room_kill_switch`) and dispatch-side enforcement of all existing caps.
7. **Hermes bots' privacy belongs to Hermes.** BurnBar relays and renders bot threads under the user's own account and grant; it does not extract, index, or memorize bot conversations into Pensieve without the user's explicit action (the same consent posture as chat-thread cloud sync: metadata syncs, bodies are opt-in).
8. **MAS posture.** The Wire (network telemetry between own devices) is MAS-safe; Face B/C are UI. Any plan row that requires Path C-class system control stays behind the direct-download build exactly as shipped (`#if DISTRIBUTION_MAS` compiles it out). Nothing in this plan moves that line.

---

## 11. What BurnBar already has vs what is new

| Capability | Exists today | New in this plan |
|---|---|---|
| Machine identity | `deviceId`, `devices/{deviceId}`, `relay-host-<installationUUID>`, iroh pairing, escrow enrollment | **`HermesBody` join registry**; per-device host keys (multi-host directory) |
| Hermes chat | Backend picker, local `:8642`, phone→Mac relay ops (`sessions/sessionDetail/profiles/jobs`), gateway platform for external `hermes-agent` | **Face B room** per machine; bot shelf/cron/handoff rendering; Mac⇄Mac room relay |
| Machine↔machine transport | iroh + HPKE v3 + sealed Firestore fallback — **phone↔Mac only** | **The Wire**: Mac⇄Mac lane, `war.*` frames, wire grants, Pro/Ultra fail-closed gate |
| Agent liveness | Live Agent Fleet: 10-agent roster, 15 s cadence, machine pulse, orchestrator designation, directive channel — **local-only** | **Face C Command Board**: fleet snapshots relayed over the Wire, cross-machine rows, machine grouping |
| Session attribution | `executionSource*` runtime class; mission `source`/`sourceSurface` strings | **`Originator`** — typed STARTED BY on missions, runs, usage rows, board rows, with confidence |
| Routing | Provider router (5-dim, JSONL audit), Wand model router (heuristic), ministry selector, router rundown, pricing catalog | **The Flame**: unified Collect→Distill→Decide over all fountains + machines; `RoutingDecision` / `DistillRecord` ledgers; router console + CLI verbs |
| Dispatch | Mission claim queue (approval-gated, sealed), Wand fan-out (tier caps 1/3/8/16), RunService | **`targetDeviceID` machine targeting**; Flame→mission emission; originator stamping |
| Spend control | BudgetGate (allow/soft/hard/paused), CU budgets, kill switches | Spend grant embedded per decision; `war_room_kill_switch` |
| Quotas / accounts / usage / memories / inbox / insights | All shipping (§6) | Confidence normalization at Distill; plan-source tagging; **no new collectors** for fountains 1–5 |
| Hardware / resources | `hw.model` string; fleet pulse local-only; no GPU/thermal | `HermesBody.hardware` probe (sysctl); pulse over the Wire (adaptive cadence — Decision #4) |
| Design system | Tokens, liquid glass, grain (poster-scoped), mercury identity, cascade/flip/matched-geometry precedents, reduce-motion discipline | **Face morph choreography**; `FlameSigilView` (living flame at rest); grain graduated to room texture |

The pattern the tree keeps proving: Mercury built the pipe, Computer Use built the trust — the War Room is the first feature that mostly **joins** what exists instead of building substrate.

---

## 12. Phasing

Flags follow the shipped convention (Remote Config + local override). No calendar estimates — each phase names its invasiveness and exit criteria. Every phase lands with tests in the active suites (`AgentLensTests/Active/`, `OpenBurnBarDaemonTests`) and schema-sync drift checks green.

| Phase | Ships | Touches | Exit criteria |
|---|---|---|---|
| **W0 — Names on doors** | `HermesBody` registry + `Originator` type + TypeSpec emitters + `hardware` probe; bodies listed in Devices & Sync | `tools/schema-sync/`, `OpenBurnBarCore` shared models, `HermesRelayHostService` publish path, one GRDB migration + `docs/SCHEMA_SQLITE.sql` | Both Macs publish joined bodies; new usage/mission/run writes carry originators; zero UI beyond settings; drift check green |
| **W1 — The Wire** (`war_room_wire`) | Multi-host pairing directory, Mac⇄Mac iroh sessions, `war.body.*` + `war.fleet.snapshot` frames, wire grants UX, entitlement fail-closed both ends + rules | `crates/openburnbar-iroh` consumers, `HermesIrohRelayHostClient` (outbound table), `HermesRealtimeRelayTypes` + `protocol.json`, `firestore.rules`, Devices & Sync | Two enrolled Macs exchange presence + fleet snapshots E2E-sealed; lapse test proves dark-not-degraded; revocation from either end; kill switch verified |
| **W2 — Face B + swap** (`war_room_face_b`) | Hermes Room (local body first, then remote over `war.room.relay`), computer-swap control, A⇄B and B⇄B choreography, room empty states | `DashboardChatWorkspaceView` + new `AgentLens/Views/WarRoom/`, `ChatSessionController` body scoping, relay op plumbing | Both rooms render with live shelf/cron from relay ops; swap ≤ 400 ms perceived; reduce-motion parity; Hermes-missing and offline states match §9; renders **native** per Decision #3 — no embed path is scaffolded, even "temporarily" |
| **W3 — Face C** (`war_room_face_c`) | Command Board, B⇄C flip, originator column end-to-end, machine grouping + cost strips | New board views reusing `Fleet*` component lineage; run-journal/mission/Hermes-session joins | Board shows both machines' rows with STARTED BY; external rows honest (`inferred`); pre-snapshot/healthy-zero/stale states match the fleet contract; a Wand cast from the phone attributes correctly |
| **W4 — Flame, advisor** (`flame_advisor`) | Daemon Flame service: Collect/Distill/Decide, advise-only (dispatch disabled); deck sigil + router console; `flame plan/decisions/why` CLI; ledgers + sealed mirror | `OpenBurnBarDaemon` new service + RPC family, `BurnBarCLIRunner`, console UI, JSONL + SQLite + mirror | Decisions render with rationale + dry-fountain honesty; confidence normalization property-tested across all three vocabularies; infeasible plans (over-cap) unrepresentable by construction; `audit-verify` walks the decision chain |
| **W5 — Flame, dispatch** (`flame_dispatch`) | Verdict `dispatch` live: decision→mission-group emission, `targetDeviceID` honored by listener + rules, grant checklist enforcement, outcome Learn loop | Mission contracts (+1 field), `CLIAgentMissionRequestListener` claim logic, `firestore.rules`, BudgetGate call-site | §8 runs end-to-end on two real Macs: one prompt → targeted cross-machine dispatch → attributed board rows → outcome recorded; missing-grant paths render locked; caps enforced at dispatch in tests |
| **W6 — Rhythm** (`flame_rhythm`) | Adaptive telemetry (Decision #4) + the Flame scheduler with standing orders (Decision #5): `notBefore` one-shots, recurring emissions, cron-collision deferral, predicted-vs-actual surfacing | Daemon scheduler on the Mission Control JSONL/event-sourcing pattern; `war.flame.telemetry` cadence logic both ends; standing-order approval/revocation UX (Mac + phone card); `firestore.rules` for `notBefore` claims | A standing order emits N attributed missions across real sleep/wake cycles, each BudgetGate-checked, none re-prompting; revocation from either device halts before the next emission (fail-closed); cadence verified continuous with a face open or decision pending, heartbeat-only otherwise; board shows Flame and Hermes-cron chains side by side without blind stacking |

Dependencies: W1 needs W0. W2/W3 need W1 for remote content but ship local-body value alone if the Wire slips. W4 needs only W0 (a single-machine advisor is real product — and per Decision #2 it is the Free tier's product). W5 needs W1+W4. W6 needs W5 (standing orders emit through the dispatch rail; W1 ships pull-with-cache telemetry semantics behind its flag, W6 completes the adaptive cadence). This order front-loads the two things everything else leans on — identity and the Wire — and holds the highest-blast-radius steps (dispatch, then recurrence) for last, each behind its own flag.

---

## 13. Risks

### 13.1 The second-chat-app trap *(the one that kills the product)*

**Risk:** Face B quietly becomes "BurnBar's chat app that happens to show Hermes" — we start owning threads, building bot editors, growing a parallel memory system. Then we are competing with Hermes Desktop with a worse Hermes, and the war room dies of feature envy. Alberto rejected a page for less.

**Structural defenses (already encoded above, restated as review law):**
- Face B renders and relays; **Hermes owns bots, memory, skills, and history** (§3.2's refusals — no bot creation, no history ownership, no persona settings).
- The composer's power move is the **flame accessory** — the differentiated action is routing, not chatting.
- The Flame is persona-free by law (§5.1); pressure to make it "friendly" is pressure toward the trap.
- **North-star metric is decisions dispatched and honest board-minutes viewed — never messages sent.** A PR that adds message-count telemetry as a success metric for the War Room should be rejected on this line.

### 13.2 Upstream drift (Nous moves fast)

Bot Mode is a day-old surface; rosters/cron/handoff shapes will move. Mitigations: Face B consumes only the already-abstracted `HermesRelayOperation` vocabulary + gateway platform APIs (our own adapter layer, `tools/hermes-platform-burnbar/`); pin a contract version in `HermesBody.hermes.version`; contract tests against recorded fixtures; per-capability flags so a drifted surface (e.g. jobs) degrades to its empty state instead of breaking the room. Provenance duty: upstream is MIT (`LICENSES/Nous-hermes-agent-MIT.txt`, `docs/security/AGENT_RUNTIME_PROVENANCE.md`) — keep attribution current if we vendor more of it.

### 13.3 Quota confidence laundering

The Flame's credibility dies the first time it routes on an estimate presented as fact. Defenses: normalization floor recorded per DistillRecord; decision cards label every number (`estimated` costs, `exact` quota, `Proxy` burn); `unavailable` quotas demote placements or force `hold` (§9). The fleet plane's honesty rules are the review bar for every Flame surface.

### 13.4 Wire operability

New failure surface: sleep/wake flapping, NAT changes, two-Mac clock skew, battery cost of telemetry. Defenses: heartbeat hysteresis before presence flips; stale-labeled last snapshots instead of blanking; dispatch on the durable Firestore ledger so Wire flaps never orphan work (§8's 90-second drop is the acceptance test); telemetry cadence is adaptive (Decision #4) with battery as a first-class input — heartbeat-only when no face is open and no decision is pending, so a sleeping laptop pays near-zero.

### 13.5 Dispatch races and targeting

Adding `targetDeviceID` to a claim queue invites races (target offline forever) and stale claims. Defenses: target + TTL (`expiresAt` already exists on the docs); fallback rows in the decision (§7.1) let the user re-approve re-placement; rules reject claims by non-target devices; `macOffline` is already a rendered mission phase on mobile — reuse it.

### 13.6 Entitlement complexity

Wire (Pro+), Agent Control (Pro), Wand caps (per-tier), Ultra deltas (body cap 8 + standing orders — Decisions #1/#5) can compound into un-explainable states. Defense: the grant checklist on every decision card is the single explanation surface — four named keys with present/missing states (§5.6), reusing `FeatureUnlockSheet` for the upsell path. If support can't explain a locked row from its card alone, the card failed review.

### 13.7 Scope collision with shipped names

"Fleet" (local plane), "Agent Watch" (phone mirror), "Hermes Square" (mobile personas) all sound adjacent. §2.4/§3.3 draw the lines; `NAMES.md` gains War Room / Wire / Flame / Command Board / HermesBody entries in W0 so reviewers and copy never blur them. Public naming is closed in §14 B2: **War Room** and **Flame** go public through the `website/src/data/capabilities.ts` SSOT like Floo/Horcrux; **the Wire stays internal**.

---

## 14. Decisions — **all closed** *(2026-08-17)*

Alberto's directive: close every call, business calls included, choosing the most profitable and defensible option. Each decision below names the choice, the rejected options, and the rationale on those two axes. The style follows the Computer Use master plan's locked-decisions precedent: decided means decided — a future change is a new decision with a new rationale, not drift.

### Decision #1 — Fleet caps: Pro pairs **2 bodies**, Ultra **8**. Wand caps unchanged. — **CLOSED: option (b)**

The laptop-plus-desktop pair is the dominant real Pro topology — it is the demo, the day-in-the-life, and the shape of Alberto's own setup. Pro at 2 bodies sells that story completely. Ultra becomes **the fleet tier**: up to 8 bodies, which gives Ultra its first *structural* differentiator beyond 10× memory and wand 16 — one that scales with hardware owned. That is the most defensible pricing axis available: a person with three or more Macs running agents is the highest-willingness-to-pay segment in the market, and a competitor cannot discount away the fact that BurnBar is the only thing that can see all of their machines' quotas, sessions, and pulses at once.

Enforcement is one new knob: `warBodyCap(userId)` in `firestore.rules` beside `wandFanOutCap`, mirrored in `GatedFeature` — Pro 2, Ultra 8. Eight, not unlimited, because caps must be testable and enforceable, 8 is generous past every real topology, and whoever exceeds it is an enterprise conversation, not a rules change.

**Rejected:** (a) wand-only differentiation — leaves Ultra structurally empty, the current weakness; (c) a separate cross-machine concurrency knob — per-machine Wand caps already bound the total, and every extra knob is an un-explainable support state (§13.6); (d) telemetry richness by tier — **honesty is not a SKU**; degrading data quality for lower tiers poisons the Flame's credibility (§13.3) for a weak revenue lever.

### Decision #2 — Free ships the **advise-only** single-machine Flame. — **CLOSED: option (b)**

The Flame's Collect/Distill/Decide is all-local: COGS ≈ 0. Giving Free the advisor is the cheapest possible demonstration of the moat — the fountains — and every decision card is a native upsell surface, because the card *is* the pitch: "here is the plan built from your quotas, your sessions, your machines." The ladder it creates (see B1) is clean at every rung: Free **sees** the decision, Cloud **dispatches** it locally, Pro dispatches it **across machines**, Ultra makes it **recur**. The nag-risk guardrail is already law (§9): locked remote rows render only when genuinely better, with honest reasons — never as bait.

**Rejected:** (a) Cloud+ only — throws away a zero-cost top-of-funnel demo of the hardest-to-copy asset; (c) Pro-only — same, worse; the Free dispatch-to-one-agent middle option — dispatch is the Cloud tier's rung (`theWand` is Cloud-gated today; the ladder stays aligned with shipped gates).

### Decision #3 — Face B renders **native**. Embed and hybrid are explicit non-goals. — **CLOSED: option (a)**

Alberto's directive — "we have our own design language and token, we use those" — is a requirement, not a preference, and only native satisfies it. The evidence was already decisive: the relay proxies `sessions/sessionDetail/profiles/jobs` — the exact data native needs; native keeps MAS review clean and the audit story coherent; and an embedded Hermes surface would put Nous chrome inside BurnBar, which is both brand dilution and the front door of the second-chat-app trap (§13.1). Defensibility: a native room rendered over our own relay is a surface only BurnBar can build; an embed is a surface anyone can build. Upstream drift — the real cost of native — is already mitigated by the contract-version pin, recorded-fixture tests, and per-capability degradation flags (§13.2).

**Rejected:** (b) embed — velocity now, brand and trap later; (c) hybrid — pays both maintenance bills for neither benefit.

### Decision #4 — Remote telemetry is **adaptive**, same for every tier. — **CLOSED: option (c)**

Continuous 15 s pulse over the Wire while any face is open or a decision is in flight; coarse 60 s summary embedded in existing heartbeats otherwise; Distill pulls on demand with a 60 s cache when idle. Placement quality is the paid product's core promise — a stale pulse mis-places work and erodes the exact trust the Flame monetizes — and battery discipline on laptops is non-negotiable, so neither always-on (a) nor always-lazy (b) survives contact with real usage. Adaptive is more code on both ends, but every component exists (15 s fleet cadence local, heartbeats shipping, iroh datagrams trivially cheap at these sizes). W1 ships pull-with-cache semantics behind its flag as the ramp; W6 completes the adaptive state machine (§12).

**Rejected:** (a) continuous push — battery cost with no eyes on it; (b) pull-only — stale at exactly the decision moments that matter. Telemetry-by-tier was rejected under Decision #1.

### Decision #5 — Missions stay the only dispatch rail; a daemon-side **Flame scheduler** holds time; recurrence runs under **standing orders**. — **CLOSED: option (c), sharpened**

"Now" and windowed one-shots ride the mission doc (`targetDeviceID` + `notBefore` — the durable Firestore ledger survives sleep, flaps, and crashes; §13.4's defense depends on it). Recurrence is held daemon-side by a Flame scheduler built on the Mission Control JSONL/event-sourcing pattern, emitting **fresh missions per run** — never a second dispatch path. The approval law gets its explicit answer in the `StandingOrder` (§7.6): a scoped standing approval — expiry ≤ 30 days, max-runs ceiling, per-emission BudgetGate, placement pinned to approved bodies, revocable from either device, fail-closed when unverifiable — under which emissions do not re-prompt but are always journaled and attributed. Cron collision with Hermes's own jobs is handled by advisory deferral plus board visibility of both chains.

Profitability: "standing orders" is the sellable automation story — the word for what fleet owners actually want — and it is Ultra's second structural differentiator (B1). Defensibility: it reuses the shipped ledger, the shipped journal pattern, and the CU trusted-scope expiry precedent, so the safety posture is inherited, not invented.

**Rejected:** (a) missions-only — recurrence on a claim-queue doc makes the ledger a scheduler, which it is not; (b) scheduler-only — holding "now" work in a daemon queue adds a fragile hop to the 95% case.

### Business decisions

**B1 — Packaging: no new SKU. The ladder sells the upgrades.**

| Tier | War Room capability |
|---|---|
| **Free** | Faces A/B/C for the local machine; Flame **advisor** (advise-only) |
| **Cloud** | + Flame **dispatch** on this machine ("now" plans; Wand cap 3) |
| **Pro** | + **the Wire**: 2 bodies, multi-machine faces, cross-machine dispatch, windowed one-shots (`notBefore`); Wand 8; sits beside its Pro siblings Floo and Agent Control |
| **Ultra** | + **the fleet**: 8 bodies, **standing orders** (recurring automation); Wand 16 and 10× memory as today |

Prices unchanged; no separate War Room SKU. The Computer Use precedent (a bolt-on SKU later folded into bundles) bought entitlement complexity that §13.6 is still defending against — not repeating it. The War Room's business job is to make Pro irresistible and give Ultra the structural story it lacks. The upgrade moments are **physical events, not banners**: pairing a second body is the Pro moment; the third body or the first recurring plan is the Ultra moment. Both moments render through the shipped `FeatureUnlockSheet`, with honest copy, exactly where the user already is. This is the most defensible packaging available because the value scales with hardware owned and data accumulated — neither of which a competitor can discount.

**B2 — Naming.** Internal codenames enter `NAMES.md` in W0: **War Room** (the program and the three-face surface), **Wire**, **Flame**, **Command Board**, **HermesBody**. Public names, through the `website/src/data/capabilities.ts` SSOT like Floo/Horcrux: **War Room** (the multi-machine command experience) and **Flame** (the router — brand-native to the logo, ownable, adjacent to no competitor's mark). **The Wire stays internal**: public copy folds it into War Room ("your encrypted BurnBar connection"), per the standing policy that marketing never exposes transport jargon.

**B3 — Metrics.** North star: **weekly dispatched decisions per active account**. Guardrails: decision→approval rate (sustained < 60% means the Flame is guessing — fix Decide before growing anything), median predicted-vs-actual cost error ≤ 25% (§7.1's Learn loop measures it), % of board rows attributed `exact`, wire session uptime. Revenue events: second-body pairing → Pro conversion; standing-order creation → Ultra conversion. The forbidden metric stands (§13.1): **messages sent is never a success metric for this feature.**

**B4 — Rollout.** Ring rollout via `scripts/rollout.mjs` on the §12 flags, `war_room_kill_switch` live from ring 0. Direct download first, MAS follows — nothing in the War Room gates on MAS review (the Wire is MAS-safe; Path C exclusions are unchanged). The launch artifact is §8 executed unscripted on two physical Macs — the demo *is* the marketing, in the exact shape Nous demonstrated Bot Mode.

---

## 15. Acceptance — Alberto's test

This plan passes when Alberto reads §1 and §8 and says **"that's my idea."** Concretely, the vision's every named element has a home: machine-bound Hermes identity (§2), the elegant transform into a Grok-Bot-class room in our skin (§3.2, §3.4), back to agents and CLIs (§3.4 back semantics), the computer toggle that never toggles bots (§3.5, §2.4), the CLI dashboard with who-started-it on every row (§3.3, §7.4), the Pro/Ultra encrypted fail-closed wire (§4), and the flame-logo router that drinks the fountains, distills, and decides model/harness/machine/time/agent-count without ever becoming a persona or bypassing a grant (§5–§7).

Per-phase acceptance is in §12's exit criteria. The product-level bar is §8 executed on two physical Macs, unscripted, with the board attributing every row correctly — including the honest `external` one.

Every decision this plan raised is closed in §14 — the five product calls and the business calls — so nothing between here and W0 waits on a meeting. The build order in §12 is executable as written.

---

## Appendix A — citation index (primary)

- **Identity / devices:** `AgentLens/Services/AccountManager.swift` · `AgentLens/Services/CloudSync/UsageSyncService.swift` · `AgentLens/Services/CloudSync/HermesRelayHostService.swift` · `functions/src/types/legacy/connections.ts` · `OpenBurnBarCore/.../IrohHostKeyPinStore.swift` · `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryPeer.swift`
- **Transport / crypto:** `crates/openburnbar-iroh/` · `packages/hermes-wire-protocol/protocol.json` · `docs/HERMES_IROH_TRANSPORT.md` · `docs/HERMES_IROH_RETIREMENT.md` · `plans/2026-06-04-burnbar-hpke-v3-migration.md` · `packages/signal-envelope-contracts/src/index.ts` · `NAMES.md` (Horcrux)
- **Fleet:** `docs/fleet/BURNBAR_FLEET_API.md` · `docs/fleet/BURNBAR_FLEET_SIGNALS.md` · `OpenBurnBarCore/.../Contracts/BurnBarFleetContracts.swift` · `AgentLens/Views/Dashboard/Fleet/`
- **Missions / Wand:** `functions/src/types/legacy/media.ts` · `OpenBurnBarCore/.../MissionGroupContracts.swift` · `packages/entitlements/src/wandFanOut.ts` · `firestore.rules` · `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener*.swift` · `AgentLens/Services/CloudSync/MacWandMissionDispatcher.swift` · `docs/ELDER_AND_PARETO_WAND_CONTRACTS.md`
- **Routing / budget:** `OpenBurnBarDaemon/.../OpenBurnBarProviderRouter.swift` · `OpenBurnBarCore/.../WandModelRouter.swift` · `tools/openburnbar-mcp/select_wand_models.py` · `OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json` · `AgentLens/Services/DataStore/BudgetGate.swift` · `functions/src/routerRundown*.ts`
- **Quotas / accounts / usage:** `OpenBurnBarCore/.../ProviderQuotaTypes.swift` · `OpenBurnBarCore/.../ProviderQuota/ProviderQuotaAdapterRegistry.swift` · `functions/src/types/legacy/quota-usage.ts` · `functions/src/types/generated/provider-account.ts` · `docs/SCHEMA_SQLITE.sql` · `functions/src/rollups.ts`
- **Memories / inbox / insights:** `services/hosted-mcp/src/toolRegistry.ts` · `OpenBurnBarCore/Sources/OpenBurnBarInboxModels/BurnBarAIInboxContracts.swift` · `OpenBurnBarDaemon/.../AIInbox/` · `OpenBurnBarCore/Sources/OpenBurnBarInsights/`
- **Hermes surfaces:** `AgentLens/Views/Dashboard/DashboardChatWorkspaceView.swift` · `AgentLens/Views/Chat/` · `AgentLens/Models/ChatBackendID.swift` · `docs/HERMES_GATEWAY_PLATFORM.md` · `docs/HERMES_REALTIME_RELAY.md` · `droid-wiki/features/hermes-chat.md`
- **Computer Use / trust:** `plans/2026-05-16-computer-use-master-plan.md` · `docs/HERMES_COMPUTER_USE.md` · `docs/FEATURE_GATING_SPEC.md` · `functions/src/computerUseBudget.ts`
- **Design:** `AgentLens/Theme/DesignSystem.swift` · `AgentLens/Theme/LiquidGlass.swift` · `AgentLens/Views/Settings/DataControlCenterFlip.swift` · `OpenBurnBarCore/.../BurnBarLogoFormationView.swift` · `packages/design-tokens/` · `DESIGN.md`
- **Tiers:** `OpenBurnBarCore/Sources/OpenBurnBarKernel/Membership/GatedFeature.swift` · `OpenBurnBarCore/Sources/OpenBurnBarKernel/Entitlements/EntitlementArbitration.swift`

*End of master plan. No product code accompanies this document.*





