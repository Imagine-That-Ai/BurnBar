# Droid mission prompt — BurnBar Live Agent Fleet layer

Copy everything below the line into Droid / Factory to create the mission.

---

Create a Factory mission (do not start implementation yet) that plans and scaffolds a new **Live Agent Fleet** layer inside BurnBar.

## Working tree
- Local checkout: `/Users/albertonunez/Developer/AgentLens`
- Product name: **BurnBar** (Xcode project `BurnBar.xcodeproj`, app target `AgentLens`, shared core `BurnBarCore`, local daemon `BurnBarDaemon`, Cursor/VS Code extension under `extensions/burnbar`)
- Remote: `https://github.com/Ajnunezg/BurnBar.git` (also tracked under Imagine-That-Ai org workflows elsewhere; treat this checkout as source of truth)
- Read first, in order:
  1. `docs/MISSION.md`
  2. `docs/DIRECTION.md`
  3. `docs/ROADMAP.md` (especially “Not On The Roadmap”: no vanity dashboards)
  4. `DESIGN.md`
  5. `docs/BURNBAR_CURSOR_AGENT_SPEC.md` (daemon = local control plane; app must not become a second control plane)
  6. `docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md`
  7. `CONTRIBUTING.md`
  8. `TODOS.md` → “Add Multi-Agent Orchestration After Single-Agent Matures” (P3) — this mission is **observability + orchestration surface**, not the full daemon-native multi-agent execution graph yet

## Product intent (user goal)
Build a BurnBar layer where the user’s coding agents can **see each other live** on a shared operational board:

Target agent identities to support as first-class fleet participants:
- Grok Bot (Cursor Grok Bot / sand agents — local signals under `~/.grokbot`)
- Grok CLI (local Grok tooling under `~/.grok` if present)
- Hermes (`AgentProvider.hermes`, logs `~/.hermes/sessions`, parser `HermesParser.swift`)
- Droid / Factory (`AgentProvider.factory`, logs `~/.factory/sessions`, parser `FactoryDroidParser.swift`; also `~/.factory/background-processes.json`)
- Claude Code (`AgentProvider.claudeCode`, `~/.claude/projects`, `ClaudeCodeParser.swift`)
- Pi (`~/.pi` — **not yet in `AgentProvider`**; must be added)
- Codex (`AgentProvider.codex`, `~/.codex`, existing Codex paths/caches in `BurnBarIdentity.swift`)

The live board must show, at minimum:
1. **What each agent is doing right now** (status, current task/summary, repo/project, model if known, last activity timestamp)
2. **Per-repo agent map** (which agents are touching which repos / `projectName`s)
3. **Total running agents** count + breakdown by provider
4. **Machine status** (macOS host health: CPU, memory, load, thermal/power if cheap; disk pressure if available)
5. **System resource consumers** attributable to agent work where possible (process-level when detectable; otherwise session/token burn as proxy — be honest about confidence)
6. **Orchestrator designation**: user can mark one agent (or a BurnBar-managed orchestrator role) as **Orchestrator**
7. **Orchestrator channel**: a chat/command surface that talks **only to the orchestrator**, which then manages the rest of the fleet (assign, pause, summarize, redirect). Reuse/extend the existing in-app chat panel (`AgentLens/Views/Chat/`, `ChatSessionController.swift`) rather than inventing a parallel chat stack.

This is the **Observe + light control** slice of BurnBar’s direction (“memory and control plane for AI-assisted software work”), not a vanity analytics wall.

## Architecture constraints (non-negotiable)
- **Local-first.** GRDB/SQLite remains interactive authority. Do not make Firestore/cloud the live fleet serving path.
- **Daemon is the control plane.** Live fleet state, heartbeats, process probes, and orchestrator routing should live primarily in `BurnBarDaemon` + `BurnBarCore` contracts, with the macOS app as a client/UI. Mirror the rule from `docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md`: “The app is a client of the daemon, not a second control plane.”
- Reuse existing seams:
  - `AgentLens/Models/AgentProvider.swift` — extend for missing identities (Grok Bot, Grok CLI, Pi) with real `logDirectory` / `filePattern` / `supportLevel`
  - `AgentLens/Services/LogParser/*` + `UsageAggregator.swift` — session/history ingestion
  - `BurnBarCore/Sources/BurnBarCore/BurnBarContracts.swift` — add typed fleet/orchestrator DTOs here
  - `BurnBarDaemon` run journal / workspace bridge patterns (`BurnBarRunService`, `BurnBarRunJournal`, `BurnBarDaemonServer`)
  - Dashboard shell: `AgentLens/Views/Dashboard/` (`DashboardView`, `Alternate3Dashboard`, `ProjectsView`, `ProviderDashboardView`, `DatabaseWorkspaceView`)
  - Design tokens in `DESIGN.md` (industrial/utilitarian, SF Pro Rounded, existing provider accent colors)
- Discover agent signals from **registered roots + known patterns only** (same rule as skills/agent-doc discovery). No arbitrary filesystem crawling.
- Prefer **heartbeat / active-session / process snapshot** tables that are rebuildable, with typed health/degraded states (no silent `try?` on critical paths).
- Multi-client safe: multiple UI clients (app popover, dashboard window, later extension) can read the same fleet snapshot.

## Existing primitives to ground the design
- Providers already modeled: Factory, Claude Code, Copilot, Aider, Cursor, Codex, Zai, MiniMax, Kimi, Cline, Kilo Code, Roo Code, Forge, Augment, Hermes, Gemini CLI, Goose
- Gaps vs this mission: **Grok Bot, Grok CLI, Pi** need provider cases + parsers/probes
- Session rows already carry `provider`, `sessionId`, `projectName`, `model`, token/cost, time range (`TokenUsage` in `AgentProvider.swift`; GRDB schema in `DataStore.swift`)
- Factory already exposes `~/.factory/background-processes.json` (currently often empty) — treat as a candidate live signal, not the only one
- Codex has `active_sessions.json` under `~/.codex` — candidate live signal
- Grok Bot has local exec daemon files under `~/.grokbot` — candidate live signal
- Chat panel already exists for in-app Q&A over usage/retrieval — extend for **Orchestrator mode** (scoped system prompt + tools that read fleet state / send orchestrator directives), don’t fork a second messenger

## Mission deliverables (what the mission plan must produce)
Write a Factory mission with clear milestones. Suggested milestone split (adjust only if investigation proves a better cut):

### M0 — Discovery & contract
- Inventory live signals per target agent (paths, freshness, how to detect “running” vs “idle historical session”)
- Propose `BurnBarFleetSnapshot` / `BurnBarFleetAgent` / `BurnBarOrchestratorState` contracts in `BurnBarCore`
- Define confidence levels (exact process, active session file, last log heartbeat, estimated)
- Explicitly list out-of-scope items (full multi-agent execution graph from `TODOS.md` P3, cloud relay, killing arbitrary user processes without consent)

### M1 — Fleet projection (daemon)
- Daemon service that builds a local fleet snapshot on a short cadence
- Persist latest snapshot + short history in SQLite (daemon or shared DB module — justify choice)
- Expose snapshot via existing daemon protocol (extend contracts; keep versioning/protocol mismatch story consistent with Cursor onboarding docs)

### M2 — Provider coverage for missing agents
- Add `AgentProvider` cases + parsers/probes for Pi, Grok Bot, Grok CLI
- Map Droid→Factory, Claude→claudeCode, Codex→codex, Hermes→hermes
- Document supportLevel/dataConfidence honestly

### M3 — Live Fleet dashboard surface
- New dashboard section/tab in the existing dashboard IA (not a random floating window)
- Show: running count, per-agent cards/rows, per-repo grouping, machine status, resource consumers with confidence badges
- Follow `DESIGN.md` (dense, precise, warm charcoal / botanical cream; provider accents)

### M4 — Orchestrator designation + channel
- User can set/clear the orchestrator (persist locally)
- Orchestrator chat surface: messages go only to orchestrator role
- Orchestrator can read fleet snapshot and propose/manage directives (start with: summarize fleet, focus repo, ask agent X status, suggest who should take a task). Real cross-agent command execution can be gated behind explicit approvals.
- Keep human-in-the-loop for destructive or high-blast-radius actions

### M5 — Agent-readable fleet API
- Local, authenticated-to-machine way for agents (including Droid/Claude/Codex/Hermes/Grok/Pi) to **read** the same fleet board (e.g. daemon endpoint, CLI, or well-known local file/socket documented in-repo)
- Goal: “agents can refer to the board at all times,” not only humans in the BurnBar UI

### M6 — Hardening
- Tests: contract decode, snapshot builder fakes, provider probe unit tests, UI snapshot or view-model tests where cheap
- Degraded modes when a probe fails
- Performance: snapshot build must stay cheap enough for menu-bar / dashboard refresh (define a budget, e.g. <100ms typical on Alberto’s machine class)

## Mission output format
Create the mission under Factory’s normal mission flow with:
- Clear milestone IDs and seal criteria
- File-level touch list (expected paths)
- Explicit reuse list vs new modules
- Test plan per milestone
- Risks / open questions (especially: how Grok Bot / Pi expose live activity today)
- A short “why this is on-mission for BurnBar” note tying to `docs/MISSION.md` Observe pillar and `docs/DIRECTION.md` control-plane thesis
- Call out that this does **not** prematurely implement the XL P3 “multi-agent orchestration” execution engine in `TODOS.md`; it builds the **shared live board + orchestrator surface** that engine would later use

## Definition of done for mission creation
- Mission markdown + milestones saved in Factory
- Alberto can open the mission and see scope, boundaries, and first implementation milestone ready to run
- No code changes required in M0 beyond optional contract sketches if you include them as mission artifacts

## Voice / quality bar
Be concrete. Cite real paths. Prefer the smallest architecture that makes the fleet board real and agent-readable. If a target agent has no reliable live signal yet, still include it with `unsupported`/`partial` and a probe plan — do not fake liveness.
