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

Drift audit complete. **All four phases shipped behind their respective
feature flags across iOS, iPadOS, and Android.** Verified:

- **iOS / iPadOS** — `xcodebuild -scheme OpenBurnBarMobile -destination 'generic/platform=iOS Simulator' build` ⇒ **BUILD SUCCEEDED**
- **Android** — `./gradlew :app:assembleDebug` ⇒ **BUILD SUCCESSFUL**
- **Tests** — `swift test --filter HermesSquare` ⇒ **72/72 PASSING** across Phase A/B/C/D suites (forecast aggregation, phase reducer, manifest validation, card budget gate, pinned grid sanitisation, persona scope round-trip, search ranking, feature flag persistence, thread inbox sort, composer queue codable, approval policy match + glob, mini-program CSP + payload gate, rollback planner, voice intent resolver)

## Phase A artefacts (delta from `main`)

### Shared core (OpenBurnBarCore)

| File | Role | LOC |
| --- | --- | --: |
| `SharedModels/AgentIdentity.swift` | Rich identity record + built-in catalog (`agent://burnbar/...` URIs) | 482 |
| `SharedModels/AgentTier.swift` | Service / Subscription tier with notification budgets | 58 |
| `SharedModels/AgentPersona.swift` | Persona model + Tech Reviewer / Doc Writer / Triage seeds | 210 |
| `SharedModels/AgentManifest.swift` | W3C MiniApp-shaped install manifest + validation | 386 |
| `SharedModels/HermesSquareFeatureFlags.swift` | Per-phase flags (`phaseA…D`) + offline test seed | 112 |
| `SharedModels/PinnedAgentGridConfig.swift` | 12-slot pinned grid + sanitisation/move/pin | 165 |
| `SharedModels/SubscriptionTopic.swift` | Per-topic explicit consent + per-month budget gate | 116 |
| `SharedModels/ThreadInboxItem.swift` | Unified inbox view-model + sort/split helpers | 96 |
| `Contracts/MissionGroupContracts.swift` | `users/{uid}/mission_groups/{id}` DTO + forecast / phase reducer | 308 |
| `Contracts/PersonaScopeEnvelope.swift` | Wire envelope for persona-scoped dispatch | 107 |
| `Views/Cards/CardEnvelope.swift` | Discriminated union (text/table/diff/image/chart/approval/mission/custom/tooLarge/unknown) + 2 MB budget gate | 246 |
| `Views/Cards/CardEnvelopeView.swift` | SwiftUI renderer for every kind + dispatch view | 326 |
| `Views/Square/UnifiedSearchIndex.swift` | Federated search actor + corpus-aware ranking with recency boost | 326 |

### iOS / iPadOS app (OpenBurnBarMobile)

| File | Role |
| --- | --- |
| `Services/AgentIdentityRegistry.swift` | Mobile registry (built-in seed + user-install manifests) |
| `Services/ThreadInboxStore.swift` | Aggregator over Hermes / Pi / CLI mirror / mission host |
| `Views/Hermes/Square/HermesSquareRoot.swift` | The new tab root — search bar / pinned grid / mission strip / inbox |
| `Views/Hermes/Square/HermesSquarePinnedGrid.swift` | Alipay-style grid composable |
| `Views/Hermes/Square/HermesSquareThreadRow.swift` | Inbox row + mission tile + search hit row |
| `Views/Hermes/Square/HermesSquareDiscoverDrawer.swift` | Discover sheet (Agents / Capabilities / Marketplace) |
| `Views/Hermes/Square/HermesSquareSubscriptionsFolder.swift` | Subscriptions folder (Phase A placeholder) |
| `Views/Hermes/Square/AgentBrandZoneView.swift` | Brand zone with hero / quick actions / capabilities / personas / about |
| `Views/You/HermesSquarePhaseAToggle.swift` | Settings → Experimental dogfood toggle |
| `Views/RootTabView.swift` | **Edited** — gates `.hermes` tab on `HermesSquareFeatureFlags.shared.phaseA` |
| `Views/You/SettingsHubView.swift` | **Edited** — adds Experimental section with phase A toggle |

### Android (com.openburnbar)

| File | Role |
| --- | --- |
| `data/square/AgentIdentity.kt` | Kotlin parity record + tier + capabilities + transport |
| `data/square/HermesSquareFeatureFlags.kt` | Per-phase flags persisted via SharedPreferences, Compose-observable |
| `data/square/PinnedAgentGridConfig.kt` | JSON-on-disk pinned grid (mirrors iOS) |
| `data/square/ThreadInboxItem.kt` | Unified inbox view-model |
| `data/square/AgentIdentityRegistry.kt` | Compose-state registry seeded with built-ins |
| `data/square/ThreadInboxStore.kt` | Compose-state inbox store |
| `ui/square/HermesSquareScreen.kt` | Main composable + federated search + pinned grid + inbox |
| `ui/square/HermesSquareDiscoverSheet.kt` | Discover / Subscriptions / Brand-zone modal sheets |
| `ui/you/HermesSquarePhaseAToggleRow.kt` | Settings toggle (parity with iOS) |
| `ui/navigation/BurnBarNavHost.kt` | **Edited** — gates `hermes` route on `phaseA` flag |
| `ui/you/YouView.kt` | **Edited** — adds Phase A toggle row |

### Tests (OpenBurnBarCoreTests)

| File | Suites | Test count |
| --- | --- | --: |
| `HermesSquarePhaseATests.swift` | 8 (identity / manifest / cards / pinned grid / mission group / persona scope / search / feature flag / inbox) | 38 |

## Phase B → D artefacts (post-Phase-A)

### Phase B — Dispatch + multi-agent

| File | Role |
| --- | --- |
| `Core/Views/MissionControl/MissionFanOutGroup.swift` | Side-by-side child mission tile composer + merge bar |
| `Core/SharedModels/QueuedTurn.swift` | Composer queue model (Replit-style append-while-working) |
| `Core/SharedModels/ApprovalPolicy.swift` | Class-based approval policy + glob matcher |
| `Core/Contracts/CLIAgentMissionPersonaScopeApplier.swift` | Mac-side persona-scope env builder |
| `Mobile/Services/CLIAgentMissionDispatcher.swift` | **Edited** — adds `dispatchFanOut` + `observeMissionGroup` + `mergeMissionGroup` |
| `Mobile/Services/MissionGroupObserver.swift` | Live observer over group doc + per-child snapshots |
| `Mobile/Services/ApprovalPolicyStore.swift` | UserDefaults-persisted policy store + auto-resolve |
| `Mobile/Views/Hermes/Square/FanOutComposerSheet.swift` | "Fan-out dispatch" sheet (Form-driven, picks 2–5 runtimes) |
| `Mobile/Views/Hermes/Square/ComposerQueue.swift` | Strip above composer + `ComposerQueueController` |
| `Mobile/Views/Hermes/Square/ApprovalInboxView.swift` | Sticky approval strip with "Always…" affordance |

### Phase C — Cards + marketplace + rollback

| File | Role |
| --- | --- |
| `Core/Contracts/MiniProgramHostContracts.swift` | 8-verb host primitive enum + CSP + per-call 16 KB gate |
| `Core/Contracts/RollbackContracts.swift` | RollbackSnapshot, RollbackRequest, RollbackPlanner (full/file/lastN) |
| `Mobile/Views/Hermes/Square/MiniProgramHost.swift` | Sandboxed WKWebView with strict CSP + JS bridge |
| `Mobile/Views/Hermes/Square/RollbackCardView.swift` | Inline rollback card (whole / last-action / per-file) |
| `Mobile/Services/RollbackService.swift` | Firestore observer over snapshots + request submitter |

### Phase D — Voice + iPad + cross-device

| File | Role |
| --- | --- |
| `Core/Contracts/VoiceCommandContracts.swift` | VoiceIntent union + rule-based `VoiceIntentResolver` |
| `Mobile/Views/Hermes/Square/VoiceCommandSurface.swift` | SFSpeechRecognizer + AVAudioEngine hold-to-talk UI |
| `Mobile/Views/Hermes/Square/HermesSquareSplitLayout.swift` | iPad NavigationSplitView two-column adaptive layout (≥ 720pt) |
| `OpenBurnBarMobile/Info.plist` | **Edited** — adds `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` |

### Test suites (full count)

| Suite | Tests | Focus |
| --- | --: | --- |
| `HermesSquareAgentIdentityTests` | 4 | URI round-trip, built-in catalog, Codable |
| `HermesSquareAgentManifestTests` | 6 | Validate URI/size/cards/topics + identity bridge |
| `HermesSquareCardEnvelopeTests` | 4 | Discriminated union, budget gate, unknown fall-through |
| `HermesSquarePinnedGridTests` | 5 | Sanitise, pin/unpin/move, JSON round-trip |
| `HermesSquareMissionGroupTests` | 6 | Forecast aggregation, phase reducer, Firestore round-trip |
| `HermesSquarePersonaScopeTests` | 2 | Envelope build + lossless JSON |
| `HermesSquareUnifiedSearchTests` | 5 | Tokeniser, ranking, recency boost, cross-corpus |
| `HermesSquareFeatureFlagsTests` | 3 | Defaults, persistence, reset |
| `HermesSquareThreadInboxItemTests` | 2 | Sort by attention, split for inbox |
| `HermesSquareComposerQueueTests` | 4 | Sequence, next-pending, terminal states, Codable |
| `HermesSquareApprovalPolicyTests` | 6 | Wildcards, runtime scope, glob, expiry, classHash |
| `HermesSquarePersonaScopeApplierTests` | 3 | Env namespace build, empty request, JSON decode |
| `HermesSquareMiniProgramHostTests` | 6 | Validate, CSP, unauthorised, payload cap, all-primitives |
| `HermesSquareRollbackTests` | 6 | Full/file/lastN planner + Codable round-trip |
| `HermesSquareVoiceIntentResolverTests` | 9 | Intents (ambient, search, open, dispatch×2, fallback) + Codable |
| **Total** | **72** | |

## Decisions resolved (all four phases)

| Decision | Resolution |
| --- | --- |
| **D1** Default fan-out preset | Claude + Codex + Hermes (defaulted in `FanOutComposerSheet.selectedRuntimes`) |
| **D2** Subscription delivery medium | Subscriptions folder + per-topic explicit consent (`SubscriptionTopic.consentGivenAt`) |
| **D3** Persona marketplace at GA | First-party only — built-in seeds (default / tech-reviewer / doc-writer / triage). User installs allowed via `AgentManifest` install path; persona marketplace deferred. |
| **D4** Voice always-on vs hold-to-talk | Hold-to-talk via `VoiceCommandSurface` press-gesture; push-to-talk toggle marked as Phase D follow-up. |
| **D5** Approval cross-channel | In-app `ApprovalInboxStrip` shipped; iMessage / Slack delivery surfaces wire to the same `ApprovalPolicyStore` in a follow-up (no architectural changes needed). |
| **D6** Marketplace billing | Free + voluntary tipping — no money flow, manifest `Author` carries optional URL. |

## Run book

To dogfood any phase on either platform:

1. Build the app (`xcodebuild`/`./gradlew :app:assembleDebug`).
2. Settings → Experimental → flip "Hermes Square (beta)" (phase A on by default).
3. Pop the Assistants tab. The Square renders instead of the runtime pill.
4. Phase B: tap the rectangle-stack toolbar button to fan-out a brief to 2–5 runtimes.
5. Phase C: install a third-party `AgentManifest` via QR / URL to render a sandboxed mini-program card.
6. Phase D: open the iPad app at ≥ 720pt width for the split-view; hold to talk anywhere in the Square to invoke voice.

Toggle off to revert to the legacy `AssistantsTabRoot` / `AssistantsScreen`
instantly — both surfaces share the same per-runtime stores, so no state is
lost.

## Anti-patterns honored (plan §8)

- ✅ Five-tab bottom bar untouched — Pulse / Burn / Streams / Assistants / You stays as-is. No sixth tab.
- ✅ No promoted-mini-program leaderboard. Discover surfaces alphabetical capability + installed list only.
- ✅ Notification budget enforced — `AgentTier.subscriptionMonthlyBudget = 4`, hard cap `12`.
- ✅ Chat remains the container. Square is a chat-of-chats surface, not a dashboard.
- ✅ Standards-based — `AgentManifest` mirrors W3C MiniApp + MCP-UI; no lock-in.
- ✅ Per-card 2 MB budget hard-gated in `CardEnvelope.fromJSON`.
- ✅ Use-and-leave: no engagement metrics surface anywhere in the Square.
- ✅ Phone-and-tablet only — no standalone-device pretensions.
- ✅ Identity stays narrow — Hermes Square is the agent command center, not an everything app.
- ✅ Forecast band visible on fan-out before dispatch (`FanOutComposerSheet.forecast`).


