# Hermes Square — Mobile Command Center for the AI Agent Fleet

> A super-app reinvention of the Assistants section.
> Codename **Hermes Square** — a town square where every agent in your fleet has a presence, where dispatch is one tap, where missions live as first-class shareable objects, where the phone, iPad, and Android are equal-class command surfaces with the Mac.

This document is **both a vision and a prompt**. The prose is written to be handed verbatim to an autonomous coding agent or to a human engineering team: ambitious enough to inspire, concrete enough to execute, sourced enough to defend.

---

## §0. The thesis in one paragraph

The Assistants section of OpenBurnBar is today a slim chat surface for two runtimes (Hermes, Pi) plus a read-only mirror for three more (Claude, Codex, OpenClaw). It is competent and bears the editorial DNA of the rest of the app — but it is **one tap deep**. The thesis of Hermes Square is that AI agents are not a chat feature. They are a fleet, and the phone is the bridge. We rebuild Assistants as a **WeChat-class super-app surface** where every agent is an addressable contact in a shared messaging fabric; every capability is a **mini-card** with a strict size budget and host-mediated permissions; every long-running task lives in a **goals → tasks → sub-tasks** board you can swipe through from a coffee shop; voice + vision + push are first-class invocation primitives; and a **search bar at the top** federates across people, agents, missions, threads, artifacts, and web. This is shippable in 2026 because the technical pieces — phone-as-remote-window (Anthropic Claude Code Remote Control v2.1.110, Apr 2026; OpenAI Codex mobile, May 2026), declarative agent UI (W3C MiniApps + MCP-UI / A2UI v0.9), agent-inbox patterns (Devin / Replit Queue / Cursor Background Agents), and infrastructure-level RBAC for personas (Cequence Agent Personas, Apr 2026) — are all newly available. Nobody has stitched them into one elegantly-designed surface. We will.

---

## §1. Why this is achievable *now* (and not 12 months ago)

The 2026 frontier finally enables the four primitives the super-app pattern requires:

1. **Remote control of local agents over a phone-class channel.** Anthropic shipped [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) in Feb 2026, and OpenAI shipped [Codex in ChatGPT mobile](https://openai.com/index/work-with-codex-from-anywhere/) in May 2026 — both pair a phone to a local CLI via QR / secure relay, both stream live diffs and approvals, both push notifications to the phone when the agent needs you. The phone-as-bridge pattern is **mainstream and validated**.

2. **Declarative agent UI surfaces with a permission model.** Google's [A2UI v0.9](https://developers.googleblog.com/a2ui-v0-9-generative-ui/) (Dec 2025) and [MCP Apps / MCP-UI](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/) (Jan 2026) define declarative widget schemas that hosts can render — exactly the same shape as WeChat Mini Programs ([Weixin runtime](https://developers.weixin.qq.com/miniprogram/en/dev/framework/runtime/env.html)) and the W3C [MiniApp Packaging](https://www.w3.org/TR/miniapp-packaging/) spec. Agents can now ship UI cards that we render in our chrome.

3. **Goals-and-tasks UX patterns for long-running agentic work.** [Smashing Mag's agentic UX guide](https://www.smashingmagazine.com/2026/02/designing-agentic-ai-practical-ux-patterns/) and [UX Magazine](https://uxmag.com/articles/secrets-of-agentic-ux-emerging-design-patterns-for-human-interaction-with-ai-agents) converged in 2026 on the right model: **chat is a poor fit for async multi-hour agent work**. The right surface is a *kanban-style board* with goals → tasks → sub-tasks, status, SLA, and owner. We have BurnBar's existing mission contract (`BurnBarMissionSnapshot` in `OpenBurnBarMissionControlMissionsContracts.swift`) to feed this board.

4. **Persona-scoped agent invocation with RBAC.** [Cequence's Agent Personas](https://www.cequence.ai/blog/ai/agent-personas-missing-agentic-security-layer/) (Apr 2026) shipped the infrastructure-level pattern: a plain-English job description compiles into a scoped virtual MCP endpoint per agent role. The consumer mobile picker for this *does not yet exist*. We can ship it.

We also have the **wisdom of failure** to lean on: ([Humane Pin](https://www.techradar.com/computing/artificial-intelligence/with-the-humane-ai-pin-now-dead-what-does-the-rabbit-r1-need-to-do-to-survive) bricked Feb 2025, sold for $116M; [Rabbit R1](https://www.everydayaitech.com/en/articles/ai-gadgets-flop-2025) sold 100K and stalled). The lesson: a standalone AI surface must answer *"what does this do that a phone with the same model can't do better, faster, more conveniently?"* Hermes Square's answer is unambiguous: it is the **phone-and-tablet command surface for a Mac-bound fleet** — not a replacement for the Mac, not a standalone agent — the *bridge* that lets you stay productive in motion.

---

## §2. Vision pillars (the four anchors)

Hermes Square rests on **four pillars**, each a direct steal from a proven super-app pattern, each translated to AI agents.

### Pillar 1 — **The Living Inbox** (chat-as-container, WeChat school)
Every interaction with every agent lives in **threads** in a unified inbox. Agents are addressable like people. Outputs from agents — artifacts, mission cards, action proposals — are **forwardable as first-class objects** (the hongbao pattern: an artifact is a thing you can send to another person, drop into a group, pin to a mission, save to a folder). Source: [WeChat integrated UX](https://www.nngroup.com/articles/wechat-integrated-ux/) + [Hongbao social mechanics](https://www.technologyreview.com/2019/07/10/134255/wechat-is-running-a-natural-experiment-in-human-generosity/).

### Pillar 2 — **The Constellation** (agents as identities, WeChat Official Accounts school)
Every agent — Hermes, Pi, OpenClaw, Claude, Codex, plus a long tail of user-installed personas — has an **account page** with a brand zone (icon, color, capabilities, status, last 7 days of activity, your conversation history), and lives in one of two tiers borrowed straight from [WeChat Official Accounts](https://appinchina.co/blog/what-are-wechat-official-accounts-the-complete-guide-to-creating-and-using-wechat-official-accounts/):
- **Service-tier** agents (interactive, in the main inbox, full action API) — Claude, Codex, Hermes, Pi, OpenClaw, anything the user invokes transactionally.
- **Subscription-tier** agents (broadcast publications, folded into a single "Subscriptions" folder) — research scouts, monitoring agents, scheduled summarisers. They write to you on a cadence; the platform caps their notification budget.

This solves the "500 agents pinging me" failure mode by **structural design**, not pleading with users to mute.

### Pillar 3 — **The Cards** (capabilities as mini-programs, WeChat Mini-Program school)
Agent capabilities surface as **typed UI cards** — small, declarative, sandboxed render targets that the host (OpenBurnBar) draws in its own chrome but with the agent's data, color, and copy. Same dual-thread isolation pattern as [WeChat](https://developers.weixin.qq.com/miniprogram/en/dev/framework/runtime/env.html) and [W3C MiniApps](https://www.w3.org/TR/miniapp-packaging/). On the wire, we adopt **MCP-UI** ([MCP Apps spec](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/)) so any MCP-shipping agent slots in. We enforce **hard size budgets**: ≤2MB per card manifest, ≤20MB per agent total — same as WeChat, same reason: forces "use-it-and-leave" cards instead of bloated mini-dashboards.

### Pillar 4 — **The Brain Stem** (host services, Alipay AI Pay school)
A small, sharp set of host primitives every card / agent / thread can call:
- **Dispatch** — send a mission to one or N agents (parallel fan-out from §6.4)
- **Approve** — sign off on a proposed action (with "Yes always for this class" learning, [Claude Code-style](https://code.claude.com/docs/en/permission-modes))
- **Fork** — clone an agent's context to a new thread
- **Forward** — send mission / artifact / thread to another conversation (hongbao primitive)
- **Delegate** — grant a scoped credential to an agent for a defined window ([Alipay AI Pay's agent-payment model](https://technode.global/2026/04/22/alipay-introduces-ai-payment-service-for-autonomous-agents/), translated to non-financial credentials)
- **Pin** — promote a card / agent / mission to a fixed home-grid slot (~12 slots, Alipay-style)
- **Subscribe** — opt into a topic from a Subscription-tier agent with explicit per-topic consent ([WeChat Subscription Notifications](https://developers.weixin.qq.com/doc/service/en/guide/product/subscription_messages/intro.html))
- **Rollback** — undo an agent's action via session snapshot ([Rubrik Agent Rewind](https://www.rubrik.com/insights/ai-issues-take-control-with-rubrik-agent-rewind) / [DiffBack](https://github.com/A386official/diffback) pattern)

These eight verbs are the entire host API. Every card, every agent, every long-running mission composes them.

---

## §3. The architecture in one diagram (read top-down)

```
┌──────────────────────────────────────────────────────────────────────┐
│  Hermes Square — root scene                                         │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  [搜一搜-style federated search bar]                         │    │
│  │  agents · threads · missions · artifacts · cards · web      │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  ┌───────────── PINNED GRID (12 slots, Alipay-style) ─────────┐   │
│  │  [Hermes] [Claude] [Codex] [Pi] [Open] [+]  [+] [+]  ...    │   │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌──────── THE LIVING INBOX (threads + missions) ────────────────┐ │
│  │  ↳ Active missions sorted by need-attention                   │ │
│  │     • "Approve file edit" — Codex • 14s ago         [≥]       │ │
│  │     • Refactor router rails — Claude • in flight    [▤]       │ │
│  │     • Weekly cost summary — (subscription) Hermes   [✦]       │ │
│  │  ↳ Conversations                                              │ │
│  │     • Hermes · 3 unread                                       │ │
│  │     • Pi · last reply 2h ago                                  │ │
│  │  ↳ Subscriptions folder (collapsed by default)                │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌──────── DISCOVER (swipe down from inbox, WeChat-style) ────────┐│
│  │  • Recent: agents you used this week                          ││
│  │  • Capabilities: cards available right now                    ││
│  │  • Marketplace: 3rd-party & community agents                  ││
│  │  • Brand zones: per-agent canonical pages                     ││
│  └──────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
       │
       └──> Bottom bar:  [Inbox] [Compose] [Missions] [Voice] [Me]
                                  ↑
                            (the only big button — it's the dispatch primitive)
```

The **bottom bar is five anchors, no more, no fifth, no rearranging** — Allen Zhang school ([4 philosophies behind WeChat Mini-Programs](https://zarazhang.com/2017/08/27/4-philosophies-underlying-the-wechat-mini-program-lessons-from-the-father-of-wechat/)). Resist the urge to add a sixth.

---

## §4. Codebase grounding (what we touch, what we keep)

These are the actual files this plan will read, modify, and add. Everything is anchored to real paths in the repository.

### 4.1 What exists today (do not rebuild — extend)

| Concern | File | Role |
| --- | --- | --- |
| iOS root scene | `OpenBurnBarMobile/Views/RootTabView.swift` | The 5-tab Aurora nav. Today there's a `.hermes` tab hosting `AssistantsTabRoot`. |
| iOS Assistants root | `OpenBurnBarMobile/Views/Hermes/AssistantsTabRoot.swift` (228 LOC) | The runtime pill + tile-preference switchboard. |
| iOS Hermes chat | `OpenBurnBarMobile/Views/Hermes/HermesTabView.swift` (2735 LOC) | The deep chat UI we'll reuse for thread rendering. |
| iOS Pi chat | `OpenBurnBarMobile/Views/Hermes/PiConversationListView.swift` (538 LOC) | Mirror pattern; merges into the unified inbox. |
| iOS CLI mirror | `OpenBurnBarMobile/Views/CLIAgents/CLIAgentConversationListView.swift` + `CLIAgentTranscriptView.swift` | Today: read-only mirror of Mac sessions. We make these **two-way**. |
| iOS dispatcher | `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift` | Already the right shape; we extend with parallel fan-out + persona-scoped dispatch. |
| iOS Hermes service | `OpenBurnBarMobile/Services/HermesService.swift` | Streaming + tool-use already wired. |
| Android root | `android/app/src/main/java/com/openburnbar/MainActivity.kt` | Hosts `AssistantsScreen`. |
| Android Assistants root | `android/app/src/main/java/com/openburnbar/ui/hermes/AssistantsScreen.kt` | Same runtime pill as iOS. |
| Android Hermes | `android/app/src/main/java/com/openburnbar/ui/hermes/HermesView.kt` | Mature chat surface — feature parity with iOS. |
| Android dispatcher | `android/app/src/main/java/com/openburnbar/data/assistants/CLIAgentMissionDispatcher.kt` | Mirror of iOS dispatcher. |
| Shared runtime enum | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AssistantRuntimeID.swift` | The 5-case enum. We **expand** this into a richer `AgentIdentity` model. |
| Mac listener | `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift` | Already claims missions, runs them on Mac. We add per-mission persona scoping. |
| Mac CLI bridge | `AgentLens/Services/CLIBridge/*.swift` | Streams from Claude / Codex / OpenClaw / Hermes / Pi. We expand to emit MCP-UI cards. |
| Mission console (just shipped) | `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/MissionControl/*.swift` | The 11-file editorial console from the previous session — **reuse as the "Missions" tab** of Hermes Square. |
| Firestore paths | `users/{uid}/cli_agent_mission_requests/{id}` + `/events` + `users/{uid}/cli_sessions/{id}` | Already work; we add `users/{uid}/agent_identities/{id}` + `users/{uid}/subscription_topics/{topic}`. |

### 4.2 What's missing today (10-line gap from the assistants audit)

1. **No unified inbox.** Sessions are siloed per-runtime. Switching the pill forgets the previous draft.
2. **No multi-agent fan-out.** One prompt → one runtime by structural assumption.
3. **No async task lifecycle UI.** Mission dispatched, no surface tracks it.
4. **No mini-program / card framework.** Every per-runtime UI is hardcoded.
5. **No agent discovery.** User enters URLs by hand or uses Remote Relay; no LAN, no catalog.
6. **No conversation forwarding.** Transcripts are private; no share / forward / pin.
7. **No per-agent personas.** Single user identity across all agents.
8. **No cross-runtime draft state.** Switching pills loses context.
9. **No iPad-adaptive layouts.** iPad mirrors iPhone single-pane.
10. **No federated search.** Each surface has its own search affordance.

Hermes Square closes **all ten** in the architecture in §6.

---

## §5. The user journeys (the proof of feel)

Twelve scenes that *must* feel inevitable. Each is a north-star user story; collectively they are the regression suite for "did we ship the right thing."

### S1 — *I'm on the subway and Codex needs me*
The phone vibrates. Banner: "Codex wants to run `pnpm test --ci` in BurnBar — approve once / always / deny." Tap "always for tests in this project" once and Codex resumes; the banner records the new auto-policy. Source pattern: [Claude Code permission modes](https://code.claude.com/docs/en/permission-modes) + [Claude Code v2.1.110 push notifications](https://medium.com/@joe.njenga/how-im-using-new-claude-code-mobile-push-notifications-for-hands-off-coding-79fa924709ae).

### S2 — *I have a hard problem; I want all five agents to take a swing*
In Compose, I type the problem brief. Below the input I tap **Fan-out** and pick Claude + Codex + Hermes. The host opens **three parallel thread tiles** stacked horizontally — each runtime streams its own answer. When all three finish I get a **side-by-side diff merge** card; I swipe to keep the winning approach. Source pattern: [parallel-code](https://github.com/johannesjo/parallel-code) on desktop, never elegantly on mobile.

### S3 — *I want to send today's brief to Claude AND save it for Tuesday*
I tap a brief I wrote in chat, choose **Forward**, and pick Claude + a scheduled drop on Tuesday 9am. The brief is now a hongbao — a first-class object. Source pattern: [WeChat hongbao + Subscription Notifications](https://www.technologyreview.com/2019/07/10/134255/wechat-is-running-a-natural-experiment-in-human-generosity/).

### S4 — *I want a research agent that writes me weekly*
Discover → Capabilities → "Weekly Recap" agent (Subscription tier). Tap subscribe. Agent now writes me Saturday 8am with a 200-word summary. Per-template explicit consent (not "all notifications from agent"). Source pattern: [WeChat Subscription Notifications](https://developers.weixin.qq.com/doc/service/en/guide/product/subscription_messages/intro.html).

### S5 — *I want to scope Claude as a tech reviewer, not a code writer*
On Claude's brand-zone page, tap "Personas" → "Tech Reviewer (read-only)". Future dispatches in that persona can read files + run grep but not edit. Source pattern: [Cequence Agent Personas + SoulSpec](https://soulspec.org/).

### S6 — *I dropped my phone and want to keep working from the iPad*
Open iPad → same threads, same missions, same drafts, mid-typing intact via shared @Observable store. iPad uses split-view: thread list left, active thread + situation room right. Source pattern: [Claude Cowork](https://claude.com/product/cowork) cross-surface continuity.

### S7 — *I want voice + screen-glance, not typing*
Hold the Voice tab → speak: "Show me what Codex did last night." Speech routes to a Hermes-side intent resolver; result is a card showing last night's PRs + diffs. Source pattern: [Gemini Live](https://venturebeat.com/ai/googles-ai-surprise-gemini-live-speaks-like-a-human-taking-on-chatgpt-advanced-voice-mode) + agent-tool routing.

### S8 — *The agent did something I regret; I want to undo*
Mission tile → "Rollback this session" — host walks back the changes via DiffBack-style per-file snapshot. Source pattern: [DiffBack](https://github.com/A386official/diffback) + [Rubrik Agent Rewind](https://www.rubrik.com/insights/ai-issues-take-control-with-rubrik-agent-rewind).

### S9 — *I want a teammate to inherit this thread*
Tap thread → Share → pick another OpenBurnBar user. The thread + its missions + its draft state replicate to their inbox (read-only by default; they can fork to write). Source pattern: WeChat forward-conversation.

### S10 — *I want to add the new agent that just dropped*
Discover → Marketplace → an agent ships an [MCP Apps manifest](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/). One-tap install (pinned to home grid if I want), permissions reviewed (host-mediated scope), and now it's in the Constellation. Source pattern: [GPT Store](https://openai.com/index/introducing-the-gpt-store/) + WeChat scope authorization.

### S11 — *I'm typing fast and want a queue of follow-ups*
Above the chat composer, a **Queue strip** lets me append follow-ups while the agent is still working on turn 1. Source pattern: [Replit Queue](https://blog.replit.com/introducing-queue-a-smarter-way-to-work-with-agent).

### S12 — *I see "today's burn $4.27" and want to know which agent caused it*
Tap the burn meter (already in the just-shipped Mission Console) → drill into per-agent breakdown → pin a per-agent budget cap. Source pattern: existing `MissionConsoleSnapshot.health.burnTodayUSD` + new per-runtime aggregation.

---

## §6. The architecture in detail

### 6.1 Shared core: `AgentIdentity`, `AgentManifest`, `CardEnvelope`

In `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/`:

- **`AgentIdentity`** — replaces the thin `AssistantRuntimeID` enum. A record carrying:
  - `id` (stable URI: `agent://burnbar/claude`, `agent://burnbar/codex`, `agent://third-party/community/foo`)
  - `displayName`, `glyph`, `palette` (provider-color anchor)
  - `tier: .service | .subscription`
  - `availability: .online | .offline | .unknown` plus a freshness timestamp
  - `personas: [PersonaSlot]` — the scoped variants of the same underlying runtime
  - `capabilities: AgentCapabilities` — declared schema of what tools, models, vision, audio, agent loops, etc.
  - `dispatchTransport` — local CLI, Firestore relay, HTTP gateway, native MCP server, etc.
  - `installSource` — built-in / user-installed / shared-by-teammate / marketplace
  - `lastSevenDays` — pre-aggregated stats for the brand zone

- **`AgentManifest`** — the install manifest for third-party agents, modeled after [W3C MiniApp Manifest](https://www.w3.org/TR/miniapp-packaging/). JSON. Declares identity, capabilities, required scopes, card surfaces, push topics, size budgets. Validated on install; permissions presented in a single dialog (one scope = one row, one explanation).

- **`CardEnvelope`** — the typed UI card payload, [MCP-UI](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/) shape. Discriminated union of:
  - `text(markdown:)` — inline rich text
  - `table(headers:rows:)` — tabular data
  - `diff(file:before:after:)` — code diff (the Codex / Claude tool result)
  - `image(url:alt:)`
  - `chart(spec:)` — Vega-Lite spec
  - `approval(prompt:options:)` — a tap-once action gate
  - `mission(snapshot:)` — embedded mission tile (reuses the Mission Console primitives just shipped)
  - `custom(schema:url:)` — sandboxed mini-program with a manifest URL

Cards are *rendered by the host*, not by the agent. The agent emits the envelope; the host draws it in our chrome with our typography. This is the WeChat dual-thread isolation: the agent never directly touches our view tree.

### 6.2 The Living Inbox (replaces `AssistantsTabRoot`)

In `OpenBurnBarMobile/Views/Hermes/HermesSquareRoot.swift` (new) and the Android equivalent `android/.../ui/square/HermesSquareScreen.kt`:

- **Top federated search bar** — single search across agents, threads, missions, artifacts, cards, web. Tabbed result page (WeChat 搜一搜 model). Algolia-style locally on-device for the user's own data; gated cloud search for the marketplace. Files: new `OpenBurnBarCore/.../Search/UnifiedSearchIndex.swift`.

- **Pinned grid (12 slots)** — Alipay-style top grid the user customises. Pin Hermes / Claude / Codex / Pi / OpenClaw / favourite personas. Long-press to rearrange. Files: new `OpenBurnBarCore/.../SquareModels/PinnedAgentGrid.swift`.

- **Active missions strip** — the just-shipped Mission Console becomes the **Missions tab** at the bottom but also surfaces a horizontally-scrolling **strip** of top active missions inside the Living Inbox. Reuses `MissionConsoleActiveTile` directly. Files: shared, no new code.

- **Thread list** — the unified merge of Hermes + Pi + CLI mirror sessions, sorted by last activity, with badges for unread and "needs attention" (e.g. awaiting approval). Files: new `OpenBurnBarCore/.../Square/ThreadInboxStore.swift` that aggregates from existing per-runtime stores.

- **Subscriptions folder** — collapsed by default. Subscription-tier agent broadcasts (weekly recaps, monitoring alerts) live here, capped at platform-enforced cadence. Files: new `OpenBurnBarCore/.../Square/SubscriptionInbox.swift`.

- **Discover drawer** — swipe down from inbox (WeChat school) to reveal: Recent agents, Capability cards available right now, Marketplace, Brand zones. Files: new `OpenBurnBarMobile/Views/Hermes/DiscoverDrawer.swift`.

### 6.3 The Constellation — Agent brand zones

Per-agent canonical page (`AgentBrandZoneView.swift`):
- Hero strip — glyph, name, tier, online status, palette
- Quick actions: New thread / Dispatch mission / Forward / Subscribe / Personas
- Capabilities pills (tool use / vision / audio / agent loops / file edits / shell)
- Last 7 days strip — pre-aggregated count of threads, missions, burn, success rate
- Persona slots — list with descriptions and "active" indicator
- Threads with this agent (search-filtered list of inbox threads)
- About / source / version / required scopes / install date

This is the "WeChat Brand Zone" applied to agents. It is *the* page you arrive at when search resolves to an agent. It is shareable: copying the URL produces a `agent://...` deeplink that opens to this page on any device.

### 6.4 Multi-agent fan-out (the killer move)

A new dispatch flow inside the composer:
- Default: one runtime selected (current behaviour)
- **Fan-out mode**: toggle in the composer footer. Pick 2–5 runtimes. Hit Dispatch.
- Backend: `CLIAgentMissionDispatcher.dispatchFanOut(...)` writes **one mission group** (`users/{uid}/mission_groups/{groupID}`) with N child missions (`users/{uid}/cli_agent_mission_requests/{id}`).
- Mac listeners claim each child mission independently (one per runtime). Results stream back as independent missions but linked by `groupID`.
- iOS surface: a **fan-out card** that renders the group as three (or N) parallel mission tiles in a horizontally scrollable stack. When all complete (or after a timeout), a **merge card** appears: diff-style side-by-side, "swipe to keep this one, or take both" controls.
- Source pattern: [Anthropic's multi-agent research blueprint](https://www.anthropic.com/engineering/multi-agent-research-system) for the orchestrator/sub-agent pattern, [parallel-code](https://github.com/johannesjo/parallel-code) for the worktree-isolation idea, [Composio Agent Orchestrator](https://github.com/ComposioHQ/agent-orchestrator) for the merge UI.

Files:
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/MissionGroupContracts.swift` (new)
- `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift` (extend with `dispatchFanOut`)
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/MissionControl/MissionFanOutGroup.swift` (new — composes three `MissionActiveTile`s side-by-side)
- `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift` (extend to claim per-runtime, respect group hints)

### 6.5 Personas — SoulSpec-flavoured scoped invocation

Personas extend an agent's identity with **role + scope**:
- Each persona = a JSON record with `name`, `description`, `permittedTools`, `permittedScopes` (file globs, shell command prefixes, MCP endpoints), `systemPromptAdditions`, `temperature override`, `preferred model`.
- Default personas seed at install: e.g. for Claude Code — "Default", "Tech Reviewer (read-only)", "Doc Writer", "Triage".
- User can add personas inline from the brand-zone page.
- At dispatch, the persona becomes a *scope* on the resulting Mac-side session: the listener (`CLIAgentMissionRequestListener`) reads `request.personaScopeJSON` and applies it to the spawned subprocess via the existing tool-allow / file-allow infrastructure.

This is the [Cequence Agent Personas](https://www.cequence.ai/blog/ai/agent-personas-missing-agentic-security-layer/) pattern, but **consumer-mobile**.

Files:
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AgentPersona.swift` (new)
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/PersonaScopeEnvelope.swift` (new)
- `AgentLens/Services/CloudSync/CLIAgentMissionRuntimePlanner.swift` (extend to consume persona scope)
- iOS + Android brand-zone view extensions

### 6.6 The Card runtime — MCP-UI host

Hermes Square hosts agent-emitted cards. The pipeline:

1. **Agent emits `CardEnvelope` JSON** (over Hermes / Pi / CLI stream) — discriminated union with strict schema.
2. **Host validates** against MCP-UI / W3C MiniApp Manifest constraints — size, scope, allowed elements.
3. **Host renders** in its own SwiftUI / Compose chrome — typography from `UnifiedDesignSystem`, colours from agent's palette, layout from card kind.
4. **User actions** on the card (tap, approve, expand) are emitted as **intent events** back to the agent (the WeChat dual-thread bus model).
5. **For `custom` cards** that need a real mini-program, the host launches a sandboxed WKWebView (iOS) / WebView (Android) with a strict CSP, a tiny JS bridge that exposes only the eight host primitives from §2 Pillar 4, and a 2MB / 20MB size cap enforced by manifest.

Files:
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Cards/CardEnvelope.swift` (new — the discriminated union)
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Cards/Card*View.swift` (new — one per kind)
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AgentManifest.swift` (new)
- `OpenBurnBarMobile/Views/MiniProgram/MiniProgramHost.swift` (new — the sandboxed WKWebView host)
- `android/app/src/main/java/com/openburnbar/miniprogram/MiniProgramHost.kt` (Android equivalent)

### 6.7 Voice + vision as invocation primitives

A fifth bottom-bar slot (**Voice**) hosts the always-on speech surface:
- Hold-to-talk → speech-to-text → routed into the active thread OR resolved as an intent (open agent, dispatch mission, search).
- Tap → camera + speech: speak while the camera streams a frame ([Gemini Live](https://venturebeat.com/ai/googles-ai-surprise-gemini-live-speaks-like-a-human-taking-on-chatgpt-advanced-voice-mode) / [ChatGPT Voice](https://toolchase.com/blog/chatgpt-voice-mode-guide/) parity).
- Background voice answering — when a Subscription-tier agent has new content, an in-call announcement (opt-in) reads it.

iOS uses `SFSpeechRecognizer` + `AVFoundation`; Android uses Google's on-device speech model. Both routed through `HermesService.sendMessage(text:, attachments:[voiceFrame])` so the existing Hermes pipeline handles it.

Files:
- `OpenBurnBarMobile/Views/Square/VoiceCommandSurface.swift` (new)
- `android/.../ui/square/VoiceCommandSurface.kt` (new)

### 6.8 The Queue — append-while-working

In the chat composer, above the text input, a horizontal strip shows queued follow-ups. While the agent works on turn 1, the user appends turns 2, 3, 4. Each queued turn shows status, optional reorder handle, attachment chips. Source pattern: [Replit Queue](https://blog.replit.com/introducing-queue-a-smarter-way-to-work-with-agent).

Files:
- `OpenBurnBarMobile/Views/Square/ComposerQueue.swift` (new)
- `android/.../ui/square/ComposerQueue.kt` (new)
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/QueuedTurn.swift` (new)

### 6.9 Approvals — Yes-always + multi-channel inbox

Approvals are first-class objects (`ApprovalAsk`, already in the just-shipped Mission Console). Hermes Square extends them with:

- **Class-based learning** — when the user picks "Always for X", the host writes a policy record (`users/{uid}/approval_policies/{class}`) that auto-resolves matching future asks.
- **Rich card delivery** — approvals can ship to iMessage / WhatsApp / Slack via [NanoClaw / HumanLayer-style](https://github.com/humanlayer/humanlayer) deep-link cards.
- **Approval inbox** — a sticky strip at the top of the Living Inbox when N approvals are pending, with batch-approve-by-class affordance.

### 6.10 Rollback — DiffBack-style undo

Every agent action that touches files writes a pre-flight snapshot to a per-session ephemeral workspace (Mac-side, alongside the existing CLIAgentSessionMirror). A mission tile in any state can be rolled back from the phone:
- Full session rollback (all files revert)
- Per-file rollback (swipe-to-revert)
- Single-action rollback (the most recent commit only)

Source pattern: [DiffBack](https://github.com/A386official/diffback) on disk, [Rubrik Agent Rewind](https://www.rubrik.com/insights/ai-issues-take-control-with-rubrik-agent-rewind) for the conceptual model. Implementation: Mac-side `git stash`-style snapshots in a `.burnbar/sessions/{id}/` shadow tree, with a Firestore index for the phone to browse.

Files:
- `AgentLens/Services/CloudSync/CLIAgentSessionRollback.swift` (new)
- `OpenBurnBarMobile/Services/RollbackService.swift` (new)
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Cards/RollbackCardView.swift` (new — embeds in mission tile)

### 6.11 iPad adaptive layout — split-view

The current iPad surface mirrors iPhone. We change to a **two-column adaptive layout** at width ≥ 720pt:
- Left column (260–320pt): thread list + pinned grid above
- Right column (flex): active thread OR active mission situation room
- Toolbar on right column toggles between Thread / Mission / Brand Zone views

Files:
- `OpenBurnBarMobile/Views/Square/HermesSquareSplitLayout.swift` (new — iPad-specific)
- Reuse the just-shipped `MissionControlConsoleView` regular-layout code

### 6.12 Android — parity, not port

Android gets the same architecture, using Compose. The existing `HermesView.kt` becomes `HermesSquareScreen.kt`; the same store / mission types are mirrored as Kotlin data classes. Material 3 Expressive lookalikes for `auroraGlass` (we already have an Android equivalent in `android/.../theme/`).

Files (new):
- `android/app/src/main/java/com/openburnbar/ui/square/HermesSquareScreen.kt`
- `android/app/src/main/java/com/openburnbar/ui/square/AgentBrandZoneScreen.kt`
- `android/app/src/main/java/com/openburnbar/ui/square/ComposerQueue.kt`
- `android/app/src/main/java/com/openburnbar/ui/square/VoiceCommandSurface.kt`
- `android/app/src/main/java/com/openburnbar/ui/square/MissionFanOutCard.kt`
- `android/app/src/main/java/com/openburnbar/data/square/MissionGroupRepository.kt`
- `android/app/src/main/java/com/openburnbar/data/square/AgentManifestRegistry.kt`
- `android/app/src/main/java/com/openburnbar/ui/cards/CardRenderer.kt`

---

## §7. Phased rollout (four phases, ~10 weeks each)

### Phase A — Foundations (~10 weeks)
Build the shared core: `AgentIdentity`, `AgentManifest`, `CardEnvelope`, `MissionGroup` contracts; the `ThreadInboxStore` aggregator; the federated search index; the new `HermesSquareRoot` view (iOS + Android) without yet replacing the existing assistants tab. Ship behind a feature flag, dogfood internally.

**Done when**: The new Inbox renders all existing Hermes + Pi + CLI sessions unified, pinned grid works, mission strip surfaces, federated search returns results across all corpuses. No new dispatch flows yet.

### Phase B — Dispatch + multi-agent (~10 weeks)
Compose with Queue, Fan-out dispatch, MissionFanOutGroup card, Discover drawer, Brand Zones for the five built-in agents, Personas (built-in only, no marketplace yet), Approval inbox + "yes always" policy learning.

**Done when**: User can fan-out a prompt to 3+ agents, see live parallel streams, swipe to merge a winner. Approvals from the phone are 1-tap. Personas scope a dispatch correctly on the Mac side.

### Phase C — Cards + marketplace (~10 weeks)
MCP-UI / W3C MiniApp Manifest support: load a third-party agent from manifest URL, render its cards in our chrome, scope its permissions through host primitives. Internal marketplace of OpenBurnBar-shipped first-party agents (research scout, weekly recap, monitoring) — Subscription-tier. Rollback service shipped.

**Done when**: A third-party agent author can publish a manifest, a BurnBar user can install it from a URL or a QR code, and its cards render correctly with no host code changes. Rollback works end-to-end from the phone.

### Phase D — Ambient + voice + iPad + cross-device (~10 weeks)
Voice command surface (hold-to-talk + tap-with-camera). iPad split-view. Cross-device thread share + handoff (start on iPhone, continue on iPad, Mac sees both). Watch-app deep links (no full Watch app — just complications + actionable notifications). Ambient briefing card (the Subscription-tier "what's important" agent that reads your Gmail / Calendar / GitHub with explicit scope, [Claude Cowork-style](https://claude.com/product/cowork)).

**Done when**: A user can pick up the phone, hold to talk, say "what's important?", and get a 30-second answer with action affordances. iPad split-view feels native. Approvals delivered via iMessage extension are 1-tap.

---

## §8. Anti-patterns we will refuse

Lessons from the failure column:

1. **No fifth-tab feature creep.** Five tabs, no more. ([Allen Zhang philosophy](https://zarazhang.com/2017/08/27/4-philosophies-underlying-the-wechat-mini-program-lessons-from-the-father-of-wechat/))
2. **No promoted-mini-program leaderboard.** No "Top agents this week" surface ever. Discovery via search + brand-zone + user-installed only.
3. **No unbounded notifications.** Subscription-tier agents get a platform-capped budget (4/month default). Per-template explicit consent. ([WeChat Subscription Notifications](https://developers.weixin.qq.com/doc/service/en/guide/product/subscription_messages/intro.html))
4. **No "agent dashboard" replacing chat.** Chat is the container. ([NN/G WeChat](https://www.nngroup.com/articles/wechat-integrated-ux/))
5. **No marketplace lock-in.** Use [MCP-UI](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/) and [W3C MiniApp](https://www.w3.org/TR/miniapp-packaging/) standards. Anyone can publish; we never become Apple-of-AI.
6. **No bloated cards.** Hard size budgets, no exceptions. ([WeChat performance docs](https://developers.weixin.qq.com/miniprogram/en/dev/framework/performance/tips/start_optimizeA.html))
7. **No engagement metrics.** We don't measure time-in-app; we measure missions-completed-per-minute-of-attention. Use-and-leave (用完即走).
8. **No standalone "AI device" ambitions.** ([Humane Pin lesson](https://www.techradar.com/computing/artificial-intelligence/with-the-humane-ai-pin-now-dead-what-does-the-rabbit-r1-need-to-do-to-survive)) Phone-and-tablet are the surfaces. The Mac stays the workshop.
9. **No "everything app" identity crisis.** This is *the* command center for agents — not a chat app, not a productivity app, not a social network. ([Stratechery on super-app skepticism](https://stratechery.com/2024/united-states-v-apple/))
10. **No surprise costs.** Every dispatch shows forecast; daily / weekly budgets are user-settable; over-budget warnings before submit. The just-shipped Mission Console burn forecast extends to fan-out forecast (worst-case = sum of N runtimes' forecasts).

---

## §9. Open decisions for the executing agent

These are intentional gaps to clarify with the user (or to choose well and explain why):

- **D1.** Default fan-out preset — which 3 runtimes? Default proposal: Claude + Codex + Hermes (Hermes for orchestration synthesis).
- **D2.** Subscription-tier delivery medium — banner notification only? Or auto-summarised as the first card in the Subscriptions folder? Default: both, opt-in per agent.
- **D3.** Persona-marketplace launch — first-party only at GA, then user-publishable in a follow-up release? Or open from day 1? Default: first-party only.
- **D4.** Voice always-on vs hold-to-talk — battery vs ergonomics. Default: hold-to-talk with one-tap toggle to push-to-talk.
- **D5.** Approval cross-channel — which channels first? Default: iMessage + Slack at GA; WhatsApp + Discord + Email in a follow-up.
- **D6.** Marketplace billing — purely free until we have signal? Or set up payments to publishers from day 1? Default: free + voluntary tipping (no money flow) for the first year.

---

## §10. The prompt for the executing agent

> You are an autonomous engineering agent assigned to implement **Hermes Square** in the OpenBurnBar repository at `/Users/albertonunez/Documents/Windsurf/BurnBar`. The codebase is a SwiftUI macOS + iOS + iPadOS app (targets `OpenBurnBar` and `OpenBurnBarMobile` plus the shared `OpenBurnBarCore` Swift package), with a parallel Compose Android app under `android/app/src/main/java/com/openburnbar/`.
>
> Read this document end-to-end before you start. Then:
>
> 1. **Map the gap.** Re-read the files in §4.1 to confirm the current state hasn't drifted from this document; note any drift in a `DRIFT.md` next to this plan.
> 2. **Plan in four phases.** Use the phasing in §7 unless you find a concrete reason to merge phases. Each phase ships behind a feature flag (`square_phase_a`, `square_phase_b`, etc.) and is independently dogfoodable.
> 3. **Anchor in evidence.** Every architectural choice traces back either to a citation in §§1–6 of this document or to a file path in §4.1. If you invent a new pattern, cite *why*.
> 4. **Keep the editorial vocabulary.** Hermes Square inherits the editorial-observatory typography, ember+amber on slate palette, mercury+aureate Hermes glass, and the just-shipped Mission Console primitives. Do not invent new tokens; do not pick new fonts. Bend the existing vocabulary further; do not break it.
> 5. **Test relentlessly at the seams.** Federated search, fan-out dispatch, persona scope enforcement, card rendering, rollback. Unit-test the pure logic, integration-test the dispatchers, snapshot-test every new screen at compact + regular widths and both color schemes.
> 6. **Ship across all three OS targets in lockstep.** If a feature lands on iPhone but not iPad or Android, it isn't done.
> 7. **Refuse the anti-patterns in §8 even when pressed.** They're load-bearing.
> 8. **Use the open decisions in §9 as defaults, but flag any you're about to ship to the user with one line of telemetry-level feedback.**
> 9. **The completion bar (from `CLAUDE.md`) applies.** "Boil the ocean. Do the whole thing."

You may deploy sub-agents for parallel research, parallel implementation across iOS/Android/Mac, and parallel test authorship. You may use the existing `MissionConsoleHost` protocol as the template for `AgentManifestHost`, `CardRenderingHost`, and `PersonaScopeHost`. You may extend the just-shipped Mission Console — do not deprecate it; integrate it as the Missions tab and the in-line strip on the Living Inbox.

When done, the experience is: a friend looks over my shoulder while I drive my agent fleet from an iPhone in a coffee shop, watches me dispatch three agents to three problems in parallel, watches me approve a shell command without losing my place in a third thread, watches a card slide in carrying a generated chart I forward to another teammate, and says: *"I want this."*

---

## §11. Sources

**Codebase audits** (internal, this session):
- iOS / iPadOS / Android Assistants surface map (sub-agent report 1)
- Agent runtime inventory (sub-agent report 2)

**WeChat / Alipay / super-app architecture** (sub-agent report 3):
- [Weixin runtime / dual-thread](https://developers.weixin.qq.com/miniprogram/en/dev/framework/runtime/env.html), [subpackages 2MB/20MB](https://developers.weixin.qq.com/miniprogram/en/dev/framework/subpackages.html), [scope authorize](https://developers.weixin.qq.com/miniprogram/en/dev/framework/open-ability/authorize.html), [subscription notifications](https://developers.weixin.qq.com/doc/service/en/guide/product/subscription_messages/intro.html), [WeChat OAuth](https://developers.weixin.qq.com/doc/oplatform/en/Mobile_App/WeChat_Login/Development_Guide.html)
- [W3C MiniApp Packaging](https://www.w3.org/TR/miniapp-packaging/), [MiniApp White Paper v2](https://www.w3.org/TR/mini-app-white-paper/), [MiniApps WG publications](https://www.w3.org/groups/wg/miniapps/publications/)
- [NN/G WeChat integrated UX](https://www.nngroup.com/articles/wechat-integrated-ux/), [NN/G Mini Programs UX lessons](https://www.nngroup.com/articles/wechat-mini-programs/)
- [Allen Zhang's "use-and-leave" philosophy](https://zarazhang.com/2017/08/27/4-philosophies-underlying-the-wechat-mini-program-lessons-from-the-father-of-wechat/), [a16z on the same](https://a16z.com/four-key-product-principles-from-wechats-creator/)
- [WeChat Official Accounts](https://appinchina.co/blog/what-are-wechat-official-accounts-the-complete-guide-to-creating-and-using-wechat-official-accounts/), [Service vs Subscription](https://blog.sinorbis.com/types-of-wechat-official-accounts)
- [WeChat hongbao](https://en.wikipedia.org/wiki/WeChat_red_envelope), [MIT Tech Review on hongbao at scale](https://www.technologyreview.com/2019/07/10/134255/wechat-is-running-a-natural-experiment-in-human-generosity/)
- [Alipay AXML](https://miniprogram.alipay.com/docs-alipayconnect/miniprogram_alipayconnect/mpdev/framework_axml-reference_axml-introduction), [Service Center UX docs](https://miniprogram.alipay.com/docs/miniprogram/design/service-center)
- [WeChat 搜一搜](https://it-consultis.com/insights/wechat-search/), [Sekkei on WeChat search](https://sekkeidigitalgroup.com/wechat-seo/)
- [Alipay AI Pay 120M weekly](https://www.businesswire.com/news/home/20260213770962/en/Alipay-AI-Payment-Exceeds-120-Million-Transactions-in-One-Week-as-Agentic-Commerce-Accelerates-in-China), [AI agent payment service](https://technode.global/2026/04/22/alipay-introduces-ai-payment-service-for-autonomous-agents/)
- [Stratechery super-app skepticism](https://stratechery.com/2024/united-states-v-apple/)
- [Storyly app fatigue](https://www.storyly.io/post/too-many-apps-for-that-app-fatigue), [CleverTap app fatigue](https://clevertap.com/blog/app-fatigue/)
- [Google A2UI](https://developers.googleblog.com/introducing-a2ui-an-open-project-for-agent-driven-interfaces/), [A2UI v0.9](https://developers.googleblog.com/a2ui-v0-9-generative-ui/)
- [MCP Apps blog](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/), [Shopify MCP-UI](https://shopify.engineering/mcp-ui-breaking-the-text-wall), [WorkOS MCP-UI deep-dive](https://workos.com/blog/mcp-ui-a-technical-deep-dive-into-interactive-agent-interfaces)

**2026 mobile AI agent UX state of the art** (sub-agent report 4):
- [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control), [push notifications v2.1.110](https://medium.com/@joe.njenga/how-im-using-new-claude-code-mobile-push-notifications-for-hands-off-coding-79fa924709ae), [VentureBeat coverage](https://venturebeat.com/orchestration/anthropic-just-released-a-mobile-version-of-claude-code-called-remote), [Claude Code permission modes](https://code.claude.com/docs/en/permission-modes), [Claude Code channels](https://code.claude.com/docs/en/channels)
- [OpenAI Codex in ChatGPT mobile](https://openai.com/index/work-with-codex-from-anywhere/), [9to5Mac](https://9to5mac.com/2026/05/14/openai-brings-codex-control-to-chatgpt-for-iphone-and-android/), [TechCrunch](https://techcrunch.com/2026/05/14/openai-says-codex-is-coming-to-your-phone/)
- [Claude Cowork](https://claude.com/product/cowork), [Cowork get started](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork), [Claude Orbit](https://claudeorbit.com/)
- [Cursor web/mobile](https://cursor.com/blog/agent-web), [Cursor Background Agents](https://stevekinney.com/courses/ai-development/cursor-background-agents)
- [Devin 2.0](https://cognition.ai/blog/devin-2), [Devin docs 2026](https://docs.devin.ai/release-notes/2026)
- [Replit mobile + Queue](https://blog.replit.com/introducing-queue-a-smarter-way-to-work-with-agent)
- [v0 by Vercel 2026 guide](https://www.nxcode.io/resources/news/v0-by-vercel-complete-guide-2026)
- [GitHub Spark](https://docs.github.com/en/copilot/concepts/spark)
- [Manus AI mobile](https://apps.apple.com/us/app/manus-ai-agent-automation/id6740909540)
- [Perplexity Comet mobile](https://www.perplexity.ai/comet)
- [Lindy](https://rimo.app/@blogs/lindy-ai-review_en-US)
- [HumanLayer SDK](https://github.com/humanlayer/humanlayer), [NanoClaw + Vercel approval cards](https://venturebeat.com/orchestration/should-my-enterprise-ai-agent-do-that-nanoclaw-and-vercel-launch-easier-agentic-policy-setting-and-approval-dialogs-across-15-messaging-apps), [LangChain HITL](https://docs.langchain.com/oss/python/langchain/human-in-the-loop), [Microsoft Agent Framework](https://learn.microsoft.com/en-us/agent-framework/integrations/ag-ui/human-in-the-loop)
- [Smashing Magazine agentic UX](https://www.smashingmagazine.com/2026/02/designing-agentic-ai-practical-ux-patterns/), [UX Magazine](https://uxmag.com/articles/secrets-of-agentic-ux-emerging-design-patterns-for-human-interaction-with-ai-agents), [Sitepoint 2026 patterns](https://www.sitepoint.com/the-definitive-guide-to-agentic-design-patterns-in-2026/)
- [Anthropic multi-agent research](https://www.anthropic.com/engineering/multi-agent-research-system), [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/), [parallel-code](https://github.com/johannesjo/parallel-code), [Composio orchestrator](https://github.com/ComposioHQ/agent-orchestrator)
- [Cequence Agent Personas](https://www.cequence.ai/blog/ai/agent-personas-missing-agentic-security-layer/), [SoulSpec](https://soulspec.org/)
- [GPT Store](https://openai.com/index/introducing-the-gpt-store/)
- [DiffBack](https://github.com/A386official/diffback), [Rubrik Agent Rewind](https://www.rubrik.com/insights/ai-issues-take-control-with-rubrik-agent-rewind), [InfoWorld coverage](https://www.infoworld.com/article/4038528/rubrik-unveils-undo-button-for-ai-agent-mistakes)
- [Humane / Rabbit post-mortem](https://www.digitalapplied.com/blog/ai-product-failures-2026-sora-humane-rabbit-lessons)

---

*This document is the prompt. Read it. Build it. Boil the ocean.*
