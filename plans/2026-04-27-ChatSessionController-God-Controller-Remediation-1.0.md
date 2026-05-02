# ChatSessionController God-Controller Remediation

## Objective

Decompose `ChatSessionController` (`AgentLens/Views/Chat/ChatSessionController.swift`, 1,493 lines) from a monolithic `@MainActor` god-class into a thin observable coordinator backed by focused, single-responsibility sub-controllers and a non-`@MainActor` send engine. After refactoring, `ChatSessionController` should be under ~250 lines (facade only), and no sub-component should exceed ~350 lines of domain logic.

This remediation directly addresses:
- **Tech Debt Strategy P1-2** (`@MainActor` on I/O-heavy services)
- **Tech Debt Strategy P2-1** (giant files create merge conflicts)
- **Tech Debt Strategy P4-2** (flaky tests with `Task.sleep` timing)

---

## Initial Assessment

### Source of Information & Implications

| Finding | Source | Implication |
|---|---|---|
| `ChatSessionController` is 1,493 lines with 30+ mutable properties and 40+ methods. | `AgentLens/Views/Chat/ChatSessionController.swift:1-1493` | Any chat feature change requires reasoning about streaming, search, thread persistence, backend switching, and panel geometry simultaneously. |
| Entire class is `@MainActor @Observable`. | `AgentLens/Views/Chat/ChatSessionController.swift:12-14` | Database queries (`dataStore.fetchChatMessages`), network calls (`probeHermesAvailability`), file I/O (`ensureChatWorkspaceDirectoryExists`), and embedding retrieval (`runBurnBarQuery`) all block the main thread. |
| `send()` is ~375 lines (631-1007) containing backend validation, retrieval planning, evidence formatting, prompt building, streaming orchestration, and usage tracking. | `AgentLens/Views/Chat/ChatSessionController.swift:631-1007` | The method is untestable as a unit. It mixes synchronous UI state mutation with async I/O and complex conditional branching. |
| `buildLocalIndexOracleResponse()` is ~150 lines (1188-1339) with 6 distinct response strategies (provider ranking, credential scan, aggregate count, exact match, retrieval results, fallback). | `AgentLens/Views/Chat/ChatSessionController.swift:1188-1339` | Oracle logic is buried inside a view controller. It should be a standalone testable service. |
| `ChatSessionControllerSearchStateTests` uses `Task.sleep` for timing-dependent assertions. | `AgentLensTests/Active/ChatSessionControllerSearchStateTests.swift:29,37,78` | Tests are flaky and depend on real time instead of deterministic test doubles. |
| `ChatPanel` and 8+ other views bind directly to `ChatSessionController` properties. | `AgentLens/Views/Chat/ChatPanel.swift:6`, `AgentLens/App/AgentLensApp.swift:86`, etc. | The public API surface is large. Extraction must preserve existing bindings or provide transparent forwarding. |
| `IndexedQueryResponseStrategy` is a static decision function with no side effects. | `AgentLens/Views/Chat/ChatSessionController.swift:1160-1186` | This is pure logic that can be extracted into a value type or enum with methods. |
| `streamTask` is a `Task<Void, Never>?` created inside `send()`. Cancellation is manual and scattered. | `AgentLens/Views/Chat/ChatSessionController.swift:98,889,1009-1014` | Streaming lifecycle should be managed by a dedicated engine with structured cancellation. |

### Prioritized Risks

1. **SwiftUI Binding Breakage** — `ChatPanel`, `DashboardView`, `AgentLensApp`, and `MenuBarPopoverView` all bind to `ChatSessionController` via `@Bindable`. Sub-controllers must either be `@Observable` themselves or proxied through the facade.
2. **Main-Actor Serialization Changes** — Moving `send()` and retrieval off `@MainActor` changes when UI updates occur. The existing code already uses `await MainActor.run { ... }` inside `streamTask`, so the pattern exists but must be systematized.
3. **Test Regression** — `ChatSessionControllerSearchStateTests` exercises end-to-end `send()` behavior with a real `SearchService`. Extraction requires moving these tests to the new `ChatSendEngine` or `LocalIndexOracle`.
4. **Incremental Refactor vs. Big-Bang** — A partial extraction leaves the codebase in a worse state. The plan uses file-private shims and deprecation wrappers to keep every commit compiling.

---

## Implementation Plan

### Phase 1: Extract Pure Logic and Self-Contained Sub-Controllers (Low Risk)

These extractions have no async streaming dependencies and can be done safely first.

- [ ] **Task 1.1.** Create `AgentLens/Views/Chat/Subcontrollers/ChatPanelGeometryController.swift` (`@MainActor @Observable`).
  - Move: `panelWidth`, `panelHeight`, `panelFloatOffset`, `isMinimized`.
  - Move: `clampedPanelOffset(_:container:padding:)`, `applyClampedPanelDrag(start:translation:container:padding:)`, `reclampPanelOffset(container:padding:)`, `persistPanelGeometry()`.
  - Move UserDefaults keys: `udPanelW`, `udPanelH`, `udOffsetX`, `udOffsetY`.
  - *Rationale:* Panel geometry is entirely self-contained with no external dependencies. It is the safest extraction and immediately removes ~35 lines from the god class.
  - *Verification:* `ChatPanel` drag/resize gestures still work; geometry persists across app launches.

- [ ] **Task 1.2.** Create `AgentLens/Views/Chat/Subcontrollers/ChatModelStore.swift` (`@MainActor @Observable`).
  - Move: `chatModelCodex`, `chatModelClaude`, `chatModelHermes`, `chatModelOpenClaw` with their `didSet` UserDefaults persistence.
  - Move: `chatModelSelection(for:)`, `setChatModelSelection(_:for:)`, `effectiveChatModel(for:)`, `chatModelMenuTitle()`, `abbreviateChatModelName(_:)`.
  - Move UserDefaults keys: `udChatModelCodex`, `udChatModelClaude`, `udChatModelHermes`, `udChatModelOpenClaw`.
  - *Rationale:* Model selection is a cross-cutting concern used by both the chat header (`ChatEngineModelMenu`) and the send engine. Isolating it removes ~65 lines and makes model rules testable.
  - *Verification:* Model picker shows correct defaults per backend; selection persists across restarts.

- [ ] **Task 1.3.** Create `AgentLens/Views/Chat/Subcontrollers/ChatThreadCoordinator.swift` (`@MainActor @Observable`).
  - Move: `activeThreadID`, `messages`, `historyThreads`, `historyQuery`, `firstAssistantBadgeShown`.
  - Move: `loadPersistedMessages()`, `clearChat()`, `startNewChatThread()`, `refreshHistory()`, `openHistoryThread(_:)`, `persistActiveThreadSlot()`, `migrateCodexThreadFromLegacyIfNeeded()`, `resolveThreadID(for:createIfMissing:)`.
  - Move: `chatWorkspaceURL`, `hermesChatWorkspaceURL`, `ensureChatWorkspaceDirectoryExists()`, `revealChatWorkspaceInFinder()`.
  - Move static migration helpers: `migrateLegacyChatModeIfNeeded()`, `migrateThreadIDSlotsIfNeeded()`.
  - Move UserDefaults keys: `udActiveThreadID`, `udThreadIDLocalIndex`, `udThreadIDHermes`, `threadStorageKey(for:)`.
  - *Rationale:* Thread lifecycle (CRUD, migration, workspace setup) is a distinct domain from streaming or search. This removes ~140 lines.
  - *Verification:* Thread history loads; new threads create workspace directories; backend switches preserve correct thread slot.

- [ ] **Task 1.4.** Create `AgentLens/Views/Chat/Subcontrollers/ChatSearchController.swift` (`@MainActor @Observable`).
  - Move: `searchQuery`, `searchResults`, `isSearching`.
  - Move: `performSearch()`, `selectSearchResult(_:)`, `handleSearchQueryChange(previousValue:)`, `cancelCurrentSearch(clearResults:)`, `nextSearchRequestID()`, `normalizedSearchQuery()`.
  - Move state: `searchTask`, `searchQueryRevision`, `activeSearchRequestID`, `activeSearchQuery`.
  - Keep dependency: `searchService` (injected via `ChatSessionSearchProviding` protocol).
  - *Rationale:* Search has its own concurrency model (request IDs, revision counters, task cancellation). Isolating it removes ~100 lines and makes race-condition tests deterministic.
  - *Verification:* Existing `ChatSessionControllerSearchStateTests` search-state tests pass (moved to test `ChatSearchController` directly).

- [ ] **Task 1.5.** Create `AgentLens/Services/Chat/ChatBackendProber.swift` (actor, not `@MainActor`).
  - Move: `probeHermesAvailability()`, `probeOpenClawAvailability()`.
  - Move state: `hermesAvailable`, `openClawAvailable` (published via `AsyncStream` or observed through the facade).
  - Inject `CLIBridge`, `SettingsManager`.
  - *Rationale:* Probing involves network/CLI I/O and should never block the main thread. This removes ~30 lines.
  - *Verification:* Backend pills in `ChatEngineBackendStrip` disable correctly when gateway is down.

- [ ] **Task 1.6.** Refactor `ChatSessionController` to own the sub-controllers from Tasks 1.1-1.5 and expose transparent forwarding properties.
  - Keep `ChatSessionController` as `@MainActor @Observable`.
  - Add stored properties for each sub-controller.
  - Add computed property forwards (e.g., `var panelWidth: CGFloat { get { geometry.panelWidth } set { geometry.panelWidth = newValue } }`).
  - *Rationale:* SwiftUI views bind to the facade; the facade delegates to sub-controllers. This preserves the existing API surface while enabling incremental extraction.
  - *Verification:* All SwiftUI previews compile; no view changes are required in Phase 1.

---

### Phase 2: Extract Local Index Oracle (Pure Logic, Testable)

- [ ] **Task 2.1.** Create `AgentLens/Services/Chat/LocalIndexOracle.swift` (struct, no actor isolation).
  - Move: `buildLocalIndexOracleResponse(queryText:queryRun:retrievalResults:jumpTargets:desiredCount:)`.
  - Move: `exactJumpPatterns(queryText:queryRun:)`, `desiredJumpTargetCount(for:)`, `exactMatchScanLimit(for:)`, `sanitizedLocalOracleContext(_:)`, `appendJumpTargetSummary(_:into:)`.
  - Move: `looksLikeConversationMemoryQuestion(_:plan:)`, `requiresLLMSynthesis(_:)`, `looksLikeCredentialExposureQuestion(_:)`.
  - Move: `indexOracleNoiseWords`.
  - Move: `IndexedQueryResponseStrategy` enum and its `indexedQueryResponseStrategy(queryText:plan:hasJumpTargets:retrievalResultCount:)` static method (make it an instance method on `LocalIndexOracle`).
  - Inject `DataStore` (for database queries inside oracle logic).
  - *Rationale:* The oracle is ~220 lines of conditional response building with no streaming or UI concerns. Making it a struct with injected `DataStore` enables unit testing without a full `ChatSessionController`.
  - *Verification:* Existing oracle tests in `ChatSessionControllerSearchStateTests` are moved to `LocalIndexOracleTests` and still pass.

- [ ] **Task 2.2.** Create `AgentLensTests/Active/LocalIndexOracleTests.swift`.
  - Migrate oracle-specific tests from `ChatSessionControllerSearchStateTests`.
  - Replace `Task.sleep` with deterministic test doubles (inject a `Date` provider if needed, but oracle logic is synchronous).
  - *Rationale:* Oracle tests should not depend on async timing.
  - *Verification:* All 5 oracle test cases pass without `Task.sleep`.

---

### Phase 3: Extract Chat Send Engine (High Impact, Off Main Thread)

- [ ] **Task 3.1.** Create `AgentLens/Services/Chat/ChatSendEngine.swift` (actor, **not** `@MainActor`).
  - Define an actor that encapsulates everything currently in `send()` and its helpers.
  - Inject: `DataStore`, `CLIBridge`, `SettingsManager`, `searchService: SearchService`, `LocalIndexOracle`, `ChatUsageTracker`.
  - Define an `AsyncStream<ChatSendEvent>` output for streaming progress. Events:
    - `.started(assistantId:)`
    - `.textUpdated(assistantId:content:pieces:)`
    - `.completed(assistantId:finalMessage:)`
    - `.failed(assistantId:errorDescription:)`
    - `.usageRecorded(assistantId:)`
  - *Rationale:* The engine performs heavy work (retrieval queries, database writes, CLI streaming, usage persistence) and must not block the main thread. Using an actor with an output stream preserves structured concurrency and makes the streaming lifecycle explicit.

- [ ] **Task 3.2.** Move `send()` body into `ChatSendEngine.execute(request:)`.
  - Preserve all existing logic:
    1. Backend availability validation (Hermes/OpenClaw/Codex/Claude checks).
    2. Retrieval query building (`retrievalQueryText`, `BurnBarSearchPlan.plan`).
    3. Search service call (`runBurnBarQuery`).
    4. Jump target building (`buildConversationJumpTargets`).
    5. Strategy selection (`IndexedQueryResponseStrategy`).
    6. Oracle execution (`LocalIndexOracle.buildLocalIndexOracleResponse`).
    7. Evidence formatting (`OpenBurnBarChatEvidenceFormatting`).
    8. Prompt assembly (`ContextBuilder.buildDatabaseAnalystSystemPrompt`, workspace section, focus section).
    9. Stream creation (per-backend `cliBridge.chat*Stream` calls).
    10. Stream consumption (text chunks, tool use, usage snapshots).
    11. Final persistence (`dataStore.saveChatMessage`, `ChatUsageTracker.saveUsageIfNeeded`).
  - Replace inline `await MainActor.run { ... }` blocks with stream event emission.
  - *Rationale:* Decomposing the 375-line method into a structured actor with typed events removes the god-method and enables testing each phase independently.

- [ ] **Task 3.3.** Move `buildConversationJumpTargets` helper into `ChatSendEngine` or `LocalIndexOracle`.
  - This method depends on `DataStore` and retrieval results. Keep it inside the engine since it is part of the pre-stream preparation phase.
  - *Rationale:* Jump targets are computed once per send, before streaming begins.

- [ ] **Task 3.4.** Move `saveUsageIfNeeded` into `AgentLens/Services/Chat/ChatUsageTracker.swift` (actor, not `@MainActor`).
  - Move: `saveUsageIfNeeded(_:backend:requestModel:responseMessageID:startedAt:endedAt:)`.
  - Move the provider/model/cost mapping logic currently inside the closure at lines 1040-1057.
  - *Rationale:* Usage tracking is a side effect that writes to `DataStore`. Isolating it removes ~70 lines and makes it testable.
  - *Verification:* Token usage records appear in database after a completed stream.

- [ ] **Task 3.5.** Refactor `ChatSessionController.send()` to delegate to `ChatSendEngine` and consume the event stream.
  - `send()` becomes:
    1. Prepare user message and append to `messages` (MainActor).
    2. Call `await sendEngine.execute(request: ...)` and iterate the `AsyncStream`.
    3. On each event, update `messages`, `isStreaming`, `streamError`, `conversationJumpTargets`, etc. (MainActor).
    4. On completion/cancellation, clean up `streamTask`.
  - `fireAndForgetSend()` stays on `ChatSessionController` but simply calls the new `send()`.
  - `cancelGeneration()` cancels the stream task and the engine's CLI bridge.
  - *Rationale:* The controller stays `@MainActor` and `@Observable` but is now a thin event consumer rather than a heavy orchestrator.

- [ ] **Task 3.6.** Move `retrievalQueryText(for:messages:)` and `isShortAffirmation(_:)` into `ChatSendEngine` (private static methods).
  - These are send-specific helpers with no UI dependency.
  - *Rationale:* Keep send-phase utilities with the engine.

- [ ] **Task 3.7.** Move `burnBarWorkspacePromptSection(path:)` into `ChatSendEngine` or a shared `ChatPromptComposer` if prompt assembly grows further.
  - *Rationale:* Prompt sections are part of the send phase, not the controller.

- [ ] **Task 3.8.** Move `appendStreamingText(_:to:)` into `ChatSendEngine` or `ChatTranscriptPiece` extension.
  - *Rationale:* This is a pure array-manipulation helper used only during streaming.

---

### Phase 4: Refactor ChatSessionController Facade

- [ ] **Task 4.1.** Strip all implementation from `ChatSessionController`, keeping only:
  - Sub-controller references (`geometry`, `modelStore`, `threadCoordinator`, `searchController`, `backendProber`, `sendEngine`).
  - UI state that cannot live elsewhere: `isStreaming`, `streamError`, `activeStreamMessageId`, `selectedContext`, `conversationJumpTargets`, `lastRetrievalHadNoEvidence`.
  - Facade forwarding properties for SwiftUI bindings.
  - `send()`, `fireAndForgetSend()`, `cancelGeneration()` as thin delegators.
  - `setChatBackend(_:)` — orchestrates thread switch + backend prober + workspace setup via sub-controllers.
  - `syncChatBackendWithEnabledBackends()`.
  - `buildInsightBriefSnapshot(refreshRollups:)`.
  - `refreshRetrievalHealth(sharedFeaturesAvailable:)` (delegates to `RetrievalHealthService`).
  - `reconfigureSearchService()`.
  - Initializer wiring.
  - *Rationale:* The facade is the SwiftUI observation point. It should contain no logic beyond delegation and event routing.
  - *Target size:* < 250 lines.

- [ ] **Task 4.2.** Update `ChatPanel`, `DashboardView`, `AgentLensApp`, and other views to bind directly to sub-controllers where appropriate.
  - For example, `ChatEngineModelMenu` can take `ChatModelStore` directly instead of the full `ChatSessionController`.
  - `ChatEngineBackendStrip` can take `ChatBackendProber` + `ChatModelStore`.
  - Do this incrementally; the facade forwards remain for compatibility.
  - *Rationale:* Fine-grained observation reduces unnecessary SwiftUI view updates.

---

### Phase 5: Test Migration and Hardening

- [ ] **Task 5.1.** Create `AgentLensTests/Active/ChatSendEngineTests.swift`.
  - Test each phase of `execute(request:)` with injected doubles:
    - `DataStore` with in-memory `DatabaseQueue`.
    - `ControlledCLIBridge` that yields predefined `CLIChatStreamEvent` sequences.
    - `ControlledSearchService` that returns fixed `OpenBurnBarQueryRunResult` values.
    - `LocalIndexOracle` with a mock `DataStore`.
  - Test cancellation: ensure `cancelGeneration()` stops the stream and does not save partial assistant messages.
  - Test backend validation: Hermes unavailable, OpenClaw unavailable, Codex not installed, Claude not installed, CLI disabled.
  - *Rationale:* The engine is the most complex new component and requires the most test coverage.

- [ ] **Task 5.2.** Create `AgentLensTests/Active/ChatThreadCoordinatorTests.swift`.
  - Test thread creation, migration, history loading, and workspace directory creation.
  - *Rationale:* Thread logic involves UserDefaults and filesystem side effects that are easy to regress.

- [ ] **Task 5.3.** Update `ChatSessionControllerSearchStateTests` to target `ChatSearchController` directly.
  - Replace `Task.sleep` with `ControlledChatSessionSearchProvider` that uses `Continuation` or deterministically ordered async events.
  - *Rationale:* Eliminates flakiness identified in Tech Debt Strategy P4-2.
  - *Verification:* Tests pass reliably under `-test-iterations 100`.

- [ ] **Task 5.4.** Create `AgentLensTests/Active/ChatPanelGeometryControllerTests.swift`.
  - Test clamping math with various container/proposed offset combinations.
  - Test UserDefaults round-trip.
  - *Rationale:* Geometry math is easy to unit-test and prevents layout regressions.

- [ ] **Task 5.5.** Run full `AgentLensTests` target and verify zero regressions.
  - *Rationale:* Final gate before considering the work complete.

---

## Verification Criteria

- `ChatSessionController.swift` is under 250 lines (facade only) and contains no `send()` implementation details.
- `ChatSendEngine.swift` is under 350 lines and is **not** `@MainActor`.
- `LocalIndexOracle.swift` is under 250 lines and has no streaming or UI dependencies.
- All existing SwiftUI previews compile without modification (facade forwards remain).
- `ChatSessionControllerSearchStateTests` no longer uses `Task.sleep`; passes 100 iterations reliably.
- New tests exist for `ChatSendEngine`, `LocalIndexOracle`, `ChatThreadCoordinator`, `ChatSearchController`, and `ChatPanelGeometryController`.
- No `@MainActor` annotation on `ChatSendEngine`, `LocalIndexOracle`, or `ChatBackendProber`.
- `make test` (or Xcode test action) passes for `AgentLensTests`.

---

## Potential Risks and Mitigations

1. **SwiftUI Observation Chain Breakage**
   - *Risk:* Sub-controllers are `@Observable`, but views may not re-render if the facade does not trigger `objectWillChange` when sub-controller state changes.
   - *Mitigation:* In Phase 4, the facade uses computed properties with `get/set` that read/write sub-controllers directly. Since sub-controllers are also `@Observable`, SwiftUI's macro-generated observation tracks them. For aggregated state (e.g., `isStreaming`), the facade updates its own stored property when the send engine emits events.

2. **Actor Re-Entrancy in ChatSendEngine**
   - *Risk:* `ChatSendEngine` is an actor. Calling `cliBridge.chatCodexStream` inside the actor may create re-entrancy issues if `CLIBridge` methods are also actors.
   - *Mitigation:* `CLIBridge` is a class (not an actor). The engine calls it directly. All UI-mutating state updates are emitted through `AsyncStream` and applied by the `@MainActor` facade, preserving serializability of UI state.

3. **Stream Cancellation Race**
   - *Risk:* `cancelGeneration()` cancels `streamTask`, but the engine may still emit a final `.completed` event after cancellation.
   - *Mitigation:* Use `withTaskCancellationHandler` in the engine. On cancellation, set an internal `isCancelled` flag and suppress final persistence. The facade ignores late events if `activeStreamMessageId` no longer matches.

4. **Test Mock Explosion**
   - *Risk:* Extracting 5+ sub-controllers requires many test doubles.
   - *Mitigation:* Reuse existing patterns (`ControlledChatSessionSearchProvider`, `OpenBurnBarSearchIntegrationHarness`). For `ChatSendEngine`, define a `ChatSendEngineDependencies` struct-of-closures rather than protocols, matching the `OpenBurnBarDaemonDependencies` pattern.

5. **Partial Refactoring Leaving Dangling Types**
   - *Risk:* Stopping midway leaves `ChatSessionController` in a half-extracted state.
   - *Mitigation:* Complete Phase 1 entirely before starting Phase 3. Phase 1 keeps the facade compiling and functional at all times. Do not interleave sub-controller extraction with send-engine extraction.

---

## Alternative Approaches

1. **Pure MVVM with ViewModel per View**
   - Instead of a single `ChatSessionController`, create separate view models for `ChatPanel`, `ChatEngineBackendStrip`, `ChatEngineModelMenu`, etc.
   - *Trade-off:* More types and more wiring, but the cleanest separation. Requires touching every view file. Recommended only if the team is willing to update all 9 call sites that reference `ChatSessionController`.

2. **Keep `@MainActor` on Everything, Extract Files Only**
   - Split code into separate files but keep `@MainActor` on all sub-controllers.
   - *Trade-off:* Fastest to execute and avoids actor complexity, but does not solve the main-thread blocking issue. Not recommended because the Tech Debt Strategy explicitly calls out `@MainActor` on I/O as critical debt.

3. **Replace `AsyncStream` with `@Observable` + `ObservationRegistrar`**
   - Instead of an event stream, make `ChatSendEngine` `@Observable` and have the view observe it directly.
   - *Trade-off:* Simpler view wiring, but requires `ChatSendEngine` to be `@MainActor` (or use `nonisolated` observation hacks), defeating the purpose. The `AsyncStream` approach is explicit and testable.

---

## Clarity Assessment / Assumptions

- **Assumption:** The user wants the `ChatSessionController` decomposed into smaller, domain-cohesive units while keeping SwiftUI bindings stable.
- **Assumption:** "Remediate" means structural decomposition + main-thread relief + test hardening, not a full architectural rewrite (e.g., no TCA or Combine adoption).
- **Assumption:** The existing `SearchService` and `CLIBridge` APIs remain unchanged; only their consumers are reorganized.
- **Assumption:** Tests in `AgentLensTests/Active/` must continue to compile and pass; moving tests to `Parked/` is not acceptable.
- **Assumption:** The `@Observable` macro (SwiftUI) is the preferred observation mechanism and should be preserved for all UI-facing controllers.
