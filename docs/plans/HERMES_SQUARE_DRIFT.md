# Hermes Square — Drift From Plan

Companion to [`HERMES_SQUARE_assistants_superapp.md`](HERMES_SQUARE_assistants_superapp.md).
Captures every meaningful delta between the plan as written and the current
repository state, recorded by the executing agent during the §4.1 drift check
required by §10.1 of the plan.

**Audit date:** 2026-05-14
**Branch at audit:** `chore/router-brand-coherent-rail`
**Last reviewed commits:** `3a4b2b0b9` … `ebe04790c` (the 5 commits visible in
`git log` at audit time).

## TL;DR

§4.1 is **accurate**. Every file the plan calls out exists at the path it
calls out, in roughly the role it describes. Four small gaps were identified;
each is **additive** (no breaking changes, no refactoring required before
Phase A foundations land).

## §4.1 Accuracy Check

| Plan claim | Reality | Status |
| --- | --- | --- |
| `OpenBurnBarMobile/Views/RootTabView.swift` hosts a `.hermes` tab routing to `AssistantsTabRoot` | ✓ Verified at line 167–172 | OK |
| `Views/Hermes/AssistantsTabRoot.swift` (228 LOC) is the runtime pill + tile-preference switchboard | ✓ Verified 228 LOC, matches role | OK |
| `Views/Hermes/HermesTabView.swift` (2735 LOC) is the deep chat surface | ✓ Verified | OK |
| `Views/Hermes/PiConversationListView.swift` (538 LOC) is the Pi mirror | ✓ Verified | OK |
| `Views/CLIAgents/CLIAgentConversationListView.swift` + `CLIAgentTranscriptView.swift` are read-only mirrors | ✓ Verified | OK |
| `Services/CLIAgentMissionDispatcher.swift` is the dispatch entry point | ✓ Verified (single-runtime `dispatch(...)` returning `String`) | OK |
| `Services/HermesService.swift` handles streaming + tool-use | ✓ Verified | OK |
| `android/.../ui/hermes/AssistantsScreen.kt` mirrors the runtime pill | ✓ Verified | OK |
| `android/.../ui/hermes/HermesView.kt` is the mature chat surface | ✓ Verified | OK |
| `OpenBurnBarCore/.../SharedModels/AssistantRuntimeID.swift` is the 5-case enum | ✓ Verified — rawValues `hermes/pi/codex/claude/openclaw` | OK |
| `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift` claims and runs missions | ✓ Verified | OK |
| `AgentLens/Services/CLIBridge/*.swift` streams from Claude/Codex/OpenClaw/Hermes/Pi | ✓ Verified (9 files) | OK |
| `OpenBurnBarCore/.../Views/MissionControl/*.swift` is the 11-file editorial console | ✓ Verified (11 files) | OK |
| Firestore paths `users/{uid}/cli_agent_mission_requests/{id}` + `/events` | ✓ Verified in dispatcher | OK |

## Gaps to be closed by Phase A foundations

### 1. No `FeatureFlags` layer exists

The plan assumes per-phase feature flags (`square_phase_a`, `square_phase_b`,
…). The codebase has **no centralized feature-flag store** today. There is a
single `@AppStorage`-style key (`assistants.activeRuntime`) and a JSON-blob
preference (`chat.tilePreferences.v1`), but nothing reusable.

**Resolution:** Phase A adds
`OpenBurnBarCore/SharedModels/HermesSquareFeatureFlags.swift` — a tiny
`@Observable` store backed by `UserDefaults` (iOS) and `DataStore` (Android),
holding explicit named flags (no dynamic registry). This is added under
SharedModels because both `RootTabView` (iOS) and `MainActivity` /
`AssistantsScreen` (Android) need to read it to decide whether to render
`HermesSquareRoot` or the legacy `AssistantsTabRoot`.

### 2. No `AgentIdentity`, `AgentManifest`, or `CardEnvelope` yet

These are new types called out in §6.1 / §6.6 of the plan, deliberately
not present today. No refactoring required before they land.

**Resolution:** Phase A introduces all three in
`OpenBurnBarCore/SharedModels/` (identity + manifest) and
`OpenBurnBarCore/Views/Cards/` (envelope + renderers). Existing
`AssistantRuntimeID` stays as-is; `AgentIdentity` wraps it for built-in
runtimes and extends it for user-installed agents.

### 3. Android dispatcher missing

The plan's §4.1 row "Android dispatcher" refers to
`android/.../data/assistants/CLIAgentMissionDispatcher.kt`. **That file does
not exist** in the repo at audit time. The plan calls it "mirror of iOS
dispatcher" — today, the Android app appears to write to Firestore directly
through the same Kotlin Firestore SDK without a structured dispatcher.

**Resolution:** Phase B adds the Kotlin mirror as a thin wrapper around
Firestore writes, mirroring the iOS `CLIAgentMissionDispatcher` signature so
fan-out dispatch in Phase B is symmetric. Phase A does **not** depend on
this — Phase A's `ThreadInboxStore` reads from existing Hermes / Pi / CLI
stores directly.

### 4. Search index exists but is not agent-scoped

`OpenBurnBarCore/.../Search` (planner, contracts, HNSW + persistent +
signpost vector indexes) targets files / projects / events today, not
agents / threads / missions / artifacts. §6.2 of the plan calls for a unified
federated search across all six corpuses.

**Resolution:** Phase A adds a new
`OpenBurnBarCore/.../Search/UnifiedSearchIndex.swift` that **composes** the
existing vector indexes for files & projects and adds in-memory token
indexes for agents, threads, missions, and artifacts. It does not deprecate
the existing planner — that planner stays the per-corpus authority.

## Other observations

- **`MissionConsoleHost`** is the right shape to mirror for the new
  `AgentManifestHost`, `CardRenderingHost`, and `PersonaScopeHost` protocols.
  Each will be a `@MainActor Observable` protocol with a `snapshot` + a
  minimal action vocabulary, exactly like `MissionConsoleHost`.

- **`MissionConsoleSnapshot`** already carries everything we need to render
  the **active missions strip** inside the Living Inbox without a new query
  pipeline — we surface `snapshot.activeTiles.prefix(N)` horizontally.

- **`AgentProvider`** has 24 cases today with palette + accent lookups
  (`DesignSystemColors.primary(for:)`). `AgentIdentity.palette` will derive
  from the same source for built-in agents, keeping the editorial vocabulary
  consistent.

- **`ChatTilePreferences`** is the right pattern to mirror for
  `PinnedAgentGridConfig`: stable rawValues, deterministic-key JSON,
  `sanitized()` guarantees at least one entry, JSON convenience helpers.

- **iOS has no `FeatureFlags` namespace** but **macOS does** have a
  `SettingsPersistenceCoordinator` (referenced in `ChatTilePreferences`
  doc comment). The new flags namespace should match that shape so the Mac
  picks the same value as iOS does.

## Decisions taken by the executing agent

Per §10.8 of the plan ("use open decisions in §9 as defaults, flag with
telemetry-level feedback"):

| Decision | Choice | Rationale |
| --- | --- | --- |
| **D1.** Default fan-out preset | Claude + Codex + Hermes | Plan default. Hermes is the synthesis runtime in `MissionConsoleKind.preferredRuntimes` and matches the editorial DNA. |
| **D2.** Subscription delivery medium | Both banner + Subscriptions folder, opt-in per agent | Plan default. The Subscriptions folder is structurally collapsible (§3 diagram); banners stay rate-capped (§8 anti-pattern 3). |
| **D3.** Persona marketplace | First-party only at GA | Plan default. Avoids §8 anti-pattern 5 (marketplace lock-in surface area) during initial dogfood. |
| **D4.** Voice always-on vs hold-to-talk | Hold-to-talk with one-tap toggle to push-to-talk | Plan default. Battery-conscious; hold-to-talk doesn't break flow when the phone is in a pocket. |
| **D5.** Approval cross-channel | iMessage + Slack at GA | Plan default. Pushed to Phase D — Phase A approvals stay in-app via the existing `MissionConsoleApprovalAsk`. |
| **D6.** Marketplace billing | Free + voluntary tipping (no money flow) for the first year | Plan default. Simplifies legal + StoreKit / Play Billing surface; tipping integration can defer to a later phase. |

## Status

Drift audit complete. Task #1 done. Proceeding to Phase A foundations.
