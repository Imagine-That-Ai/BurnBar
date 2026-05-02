# Break Up God-Modules: OpenBurnBarDaemonManager, BurnBarRunService, Contracts

## Objective

Decompose three god-modules that have accumulated unrelated responsibilities, improving testability, compile times, and domain clarity:

1. **`OpenBurnBarDaemonManager`** (`AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager.swift`, 1783 lines) — macOS app-side daemon coordinator.
2. **`BurnBarRunService`** (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarRunService.swift`, 1427 lines) — daemon-side run orchestration actor.
3. **`OpenBurnBarContracts`** (`OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarContracts.swift`, 1385 lines) — monolithic cross-domain contract file.

After refactoring, no file should exceed ~400 lines of domain logic, and each module should have a single, well-defined reason to change.

---

## Initial Assessment

### Source of Information & Implications

| Finding | Source | Implication |
|---|---|---|
| `OpenBurnBarDaemonManager` mixes daemon lifecycle, provider config, usage sync, controller projects, connector/browser proxying, notification relay, and process helpers. | `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager.swift:1-1783` | Any change to provider settings or controller features requires recompiling the entire daemon manager. Testing requires mocking all 10+ dependencies. |
| `BurnBarRunService` holds 13 direct dependencies and contains run CRUD, state machine transitions, agent loop orchestration, tool dispatch, approval flow, provider-only execution with failover, context selection, and journal/checkpoint management. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarRunService.swift:53-106` | The actor serializes everything through a single queue, creating contention between unrelated concerns like approval polling and agent loop decisions. |
| `OpenBurnBarContracts.swift` contains RPC envelopes, run state, tool definitions, approvals, client attach/detach, usage events, provider configuration, connector plane, and browser tooling in one file. | `OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarContracts.swift:1-1385` | Every target that imports `OpenBurnBarCore` recompiles when any contract changes. The file has no logical boundary. |
| `BurnBarAgentLoopService`, `BurnBarPlannerService`, `BurnBarRecoveryEngine`, `BurnBarPolicyEngine`, `BurnBarContextSelector`, `BurnBarWorkspaceBridgeBroker`, and `BurnBarRunJournal` already exist as separate components. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/*.swift` | The refactoring is primarily about *orchestration* extraction, not greenfield implementation. |
| `MissionControl` already has a directory-based module split (`MissionControl/*.swift`). | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/MissionControl/` | This pattern should be emulated for the run-service and daemon-manager splits. |
| `AgentLensTests/Parked/OpenBurnBarDaemonManagerTests.swift` exists but is parked. | `AgentLensTests/Parked/` | Tests will need to be moved out of "parked" and updated for the new module boundaries. |

### Prioritized Risks

1. **Actor Isolation Breakage** — `BurnBarRunService` is an actor. Extracting sub-services into separate actors changes serialization guarantees. The plan preserves actor boundaries carefully.
2. **Circular Dependencies** — The extracted modules may need to reference each other (e.g., ApprovalFlow needs RunLifecycle). The plan introduces protocols to break cycles.
3. **Test Regression** — `OpenBurnBarRunServiceTests.swift` and `OpenBurnBarDaemonServerTests.swift` depend on current types. Tests must be updated incrementally.
4. **Cross-Target Import Churn** — Splitting contracts changes import graphs for `AgentLens`, `OpenBurnBarDaemon`, and `OpenBurnBarDaemonTests`. The plan uses typealiases during transition.

---

## Implementation Plan

### Phase 1: Contract Decomposition (OpenBurnBarCore)

Extract domain-specific contract files from `OpenBurnBarContracts.swift`. Keep the original file temporarily with `@_exported import` or typealiases to avoid breaking consumers, then delete once all targets compile.

- [ ] **Task 1.1.** Create `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift` containing `BurnBarProtocolVersion`, `BurnBarRPCMethod`, `BurnBarRPCRequestEnvelope`, `BurnBarRPCRequestEnvelopeWithParams`, `BurnBarRPCError`, `BurnBarRPCResponseEnvelope`, `BurnBarAuthBootstrapRequest/Response`, `BurnBarProtocolHandshakeRequest/Response`, and `BurnBarEmptyResult`.
  - *Rationale:* RPC plumbing is infrastructure, not domain logic. Separating it allows other contract files to import only what they need.
- [ ] **Task 1.2.** Create `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRunContracts.swift` containing `BurnBarRunPhase`, `BurnBarRunStateSnapshot`, `BurnBarRunStateMachine`, `BurnBarRunStateMachineError`, `BurnBarRunCreateRequest/Response`, `BurnBarRunListRequest/Response`, `BurnBarRunGetRequest`, `BurnBarRunDetailResponse`, `BurnBarRunSubscribeRequest`, `BurnBarRunPollRequest`, `BurnBarRunEventBatch`, `BurnBarRunCancelRequest`, `BurnBarRunRetryRequest`, `BurnBarToolExecutionRequest/Response`, `BurnBarToolResultSubmissionRequest`, `BurnBarApprovalRespondRequest`, and `BurnBarRunServiceError`.
  - *Rationale:* Run lifecycle is the most frequently changed domain. Isolating it minimizes recompilation.
- [ ] **Task 1.3.** Create `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarToolContracts.swift` containing `BurnBarToolKind`, `BurnBarToolDefinition`, `BurnBarToolInvocation`, `BurnBarToolResult`, `BurnBarToolExecutionErrorCode`, `BurnBarToolExecutionError`, `BurnBarToolCallStatus`, `BurnBarToolCallSnapshot`, `BurnBarWorkspaceCapability`, and `BurnBarApprovalPolicy`.
  - *Rationale:* Tooling contracts are shared by the run service, workspace bridge, and extension. A standalone file prevents run-changes from triggering extension recompilation.
- [ ] **Task 1.4.** Create `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarApprovalContracts.swift` containing `BurnBarApprovalRequest`, `BurnBarApprovalDecision`, `BurnBarApprovalResponse`, `BurnBarExecutionReadinessCode`, and `BurnBarExecutionReadiness`.
  - *Rationale:* Approval flow is a cross-cutting concern used by both run service and mission control.
- [ ] **Task 1.5.** Create `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarProviderContracts.swift` containing `BurnBarProviderCredentialSlotStatus`, `BurnBarProviderCredentialSlot`, `BurnBarProviderSettings`, `BurnBarProviderConfigurationSnapshot`, `BurnBarConfigGetRequest`, `BurnBarConfigUpdateRequest`, `BurnBarConfigResponse`, `BurnBarRecentUsageRequest/Response`, `BurnBarUsageEvent`, `BurnBarHealthRequest/Response`, `BurnBarCatalogRequest/Response`.
  - *Rationale:* Provider configuration is independent from run state and changes on a different cadence (user settings vs runtime events).
- [ ] **Task 1.6.** Create `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarConnectorContracts.swift` containing all connector- and browser-related types: `BurnBarConnectorKind`, `BurnBarConnectorAuthKind`, `BurnBarConnectorHealthStatus`, `BurnBarConnectorActionKind`, `BurnBarConnectorConfigMutation`, `BurnBarConnectorConfigSnapshot`, `BurnBarConnectorPlaneSnapshot/Response`, `BurnBarConnectorConfigUpdateRequest`, `BurnBarConnectorActionRequest/Response`, `BurnBarBrowserEngineKind`, `BurnBarBrowserToolStatus`, `BurnBarBrowserActionKind`, `BurnBarBrowserEnginePreference`, `BurnBarBrowserEngineSnapshot`, `BurnBarBrowserToolingSnapshot/Response`, `BurnBarBrowserToolingUpdateRequest`, `BurnBarBrowserActionRequest/Response`.
  - *Rationale:* Connector and browser tooling are external integration surfaces. Keeping them together simplifies adding new connectors later.
- [ ] **Task 1.7.** Create `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarClientContracts.swift` containing `BurnBarClientAttachRequest/Response`, `BurnBarClientClaimControlRequest`, `BurnBarClientDetachRequest`, and `BurnBarClientArbitrationSnapshot`.
  - *Rationale:* Client session management is a distinct boundary between the daemon and its peers.
- [ ] **Task 1.8.** Update `OpenBurnBarContracts.swift` to re-export all moved symbols via `public typealias` or `@_exported import` (if using a sub-module). Verify that `OpenBurnBarCore`, `OpenBurnBarDaemon`, `AgentLens`, and tests compile without modification.
  - *Rationale:* Zero-downtime refactoring avoids breaking parallel work.
- [ ] **Task 1.9.** Remove the shim re-exports from `OpenBurnBarContracts.swift` and delete the file once all downstream targets have migrated their imports. Update `Package.swift` if a new target was introduced (not required if keeping files in the same target).
  - *Rationale:* Clean up the temporary compatibility layer.
- [ ] **Task 1.10.** Update or add tests in `OpenBurnBarCoreTests` to reference the new file locations. Verify no regressions.
  - *Rationale:* Preserve behavior verification after file moves.

### Phase 2: BurnBarRunService Decomposition (Daemon)

Extract cohesive sub-actors/services from `BurnBarRunService`. The existing `BurnBarRunService` facade remains to preserve the RPC surface, but it delegates to extracted actors.

- [ ] **Task 2.1.** Create `BurnBarRunLifecycleService.swift` (actor) responsible for run CRUD, in-memory store (`runs`, `runOrder`), state transitions (`transition`), checkpoint restore (`restorePersistedRunsIfNeeded`), and persistence (`writeCheckpoint`).
  - *Rationale:* Run storage and state machine are the core model. Isolating them prevents agent-loop bugs from corrupting the run registry.
- [ ] **Task 2.2.** Create `BurnBarToolDispatchService.swift` (actor) responsible for `executeTool`, `submitToolResult`, `dispatchCompanionToolCall`, `enqueueCompanionToolCall`, `applySuccessfulToolResult`, and `handleToolFailure`.
  - *Rationale:* Tool dispatch interacts with `BurnBarWorkspaceBridgeBroker`. Separating it means tool execution latency does not block run-list queries.
- [ ] **Task 2.3.** Create `BurnBarApprovalFlowService.swift` (actor) responsible for `respondToApproval` and `requestMandatoryToolApprovalIfNeeded`.
  - *Rationale:* Approval flow has its own state (pending approvals) and UI coupling. An isolated actor simplifies testing approval edge cases.
- [ ] **Task 2.4.** Create `BurnBarProviderExecutionService.swift` (actor or struct) responsible for `executeProviderOnlyRun` and `shouldFailOverProviderError`.
  - *Rationale:* Provider execution is I/O-heavy (HTTP). Isolating it prevents slow provider calls from blocking the run service event loop.
- [ ] **Task 2.5.** Create `BurnBarRunExecutionEngine.swift` (actor) that orchestrates `continueExecution`, `continueIntentExecution`, `deterministicContextAction`, `runAgentLoop`, and `completeRunAndRecordUsage`. This engine coordinates the lifecycle, tool dispatch, approval, and provider services without holding their implementation details.
  - *Rationale:* This is the "glue" that replaces the procedural orchestration inside `BurnBarRunService`. It is still a coordinator, but it coordinates *services*, not *logic*.
- [ ] **Task 2.6.** Refactor `BurnBarRunService` into a thin facade that owns the sub-actors and exposes the existing public API. Remove all private implementation methods, keeping only delegation and constructor wiring.
  - *Rationale:* The RPC layer (`BurnBarDaemonServer`) calls `BurnBarRunService`. A stable facade avoids changing the server wiring.
- [ ] **Task 2.7.** Move connector-plane and browser-tooling proxy methods (`connectorPlaneSnapshot`, `updateConnectorPlane`, `performConnectorAction`, `browserToolingSnapshot`, `updateBrowserTooling`, `performBrowserAction`) out of `BurnBarRunService` and into `BurnBarDaemonServer` directly, or into a new `BurnBarToolingProxyService`. They were always passthroughs.
  - *Rationale:* These methods have nothing to do with run lifecycle. Their presence in `BurnBarRunService` was a convenience leak.
- [ ] **Task 2.8.** Update `BurnBarDaemonServer` to wire the new sub-actors. Ensure `BurnBarRunService` facade is initialized with the sub-actors rather than creating them internally.
  - *Rationale:* Dependency injection at the server level allows tests to substitute individual sub-actors.
- [ ] **Task 2.9.** Update `OpenBurnBarRunServiceTests.swift` to test sub-actors individually. Add tests for `BurnBarRunLifecycleService`, `BurnBarToolDispatchService`, `BurnBarApprovalFlowService`, and `BurnBarProviderExecutionService`.
  - *Rationale:* Smaller units enable more focused tests and faster failure diagnosis.
- [ ] **Task 2.10.** Run the full daemon test suite (`OpenBurnBarDaemonTests`) and verify no regressions in run lifecycle, tool dispatch, approval, and provider failover paths.
  - *Rationale:* Integration tests catch actor-reordering and serialization issues.

### Phase 3: OpenBurnBarDaemonManager Decomposition (App)

Extract cohesive managers from `OpenBurnBarDaemonManager`. The existing class remains as a facade for SwiftUI observation.

- [ ] **Task 3.1.** Create `OpenBurnBarDaemonLifecycleManager.swift` (`@MainActor`) responsible for `installAndStart`, `repair`, `uninstall`, `refreshHealth`, `awaitHealthy`, `bootoutIfNeeded`, `runLaunchctl`, `installFilesIfNeeded`, `writeLaunchAgentPlist`, and binary resolution helpers (`OpenBurnBarDaemonBinaryResolver`, `OpenBurnBarDaemonProcessRunner`).
  - *Rationale:* Daemon lifecycle is infra-heavy (file system, launchctl). Separating it allows UI tests to mock the lifecycle without touching provider config.
- [ ] **Task 3.2.** Create `OpenBurnBarProviderConfigurationManager.swift` (`@MainActor`) responsible for `updateProviderConfiguration`, `addProviderCredentialSlot`, `updateProviderCredentialSlot`, `removeProviderCredentialSlot`, `setPreferredProviderCredentialSlot`, `refreshProviderCredentialSlotQuotas`, `mutateProviderSettingsSnapshot`, and `quotaCapableProvider`.
  - *Rationale:* Provider settings change frequently in the UI. A dedicated manager reduces recompilation of lifecycle code.
- [ ] **Task 3.3.** Create `OpenBurnBarControllerRuntimeManager.swift` (`@MainActor`) responsible for `fetchControllerRuntimeSnapshot`, `answerControllerQuestion`, `completeControllerFollowup`, `snoozeControllerFollowup`, `scheduleControllerFollowupCalendar`, `refreshControllerProjects`, `saveControllerProject`, `createMission`, `launchControllerReview`, and `syncControllerNotificationConfiguration`.
  - *Rationale:* Controller features (questions, followups, missions, review runs) form a distinct product surface.
- [ ] **Task 3.4.** Create `OpenBurnBarConnectorPlaneManager.swift` (`@MainActor`) responsible for `refreshOperationalToolPlane`, `updateConnectorConfig`, `performConnectorAction`, `updateBrowserTooling`, and `performBrowserAction`.
  - *Rationale:* Connector/browser tooling is an operational plane separate from both provider settings and controller runtime.
- [ ] **Task 3.5.** Create `OpenBurnBarUsageSyncManager.swift` (`@MainActor`) responsible for `refreshRuntimeSnapshot`, `loadRecentDaemonEvents`, and `daemonLogTailForDiagnostics`. Move `OpenBurnBarDaemonUsageSyncService` into this file or keep it as a nested helper.
  - *Rationale:* Usage sync bridges the daemon's JSONL ledger into the app's `DataStore`. It's a data-layer concern.
- [ ] **Task 3.6.** Create `OpenBurnBarDaemonNotificationRelay.swift` and move `OpenBurnBarDaemonLocalNotificationRelay` there. Also move `exportControllerActivitySnapshot` and `makeControllerActivitySnapshot` into `OpenBurnBarControllerRuntimeManager` or a dedicated `OpenBurnBarActivitySnapshotExporter`.
  - *Rationale:* Notification relay is a side-effecting singleton observer. It should not live in the main manager.
- [ ] **Task 3.7.** Refactor `OpenBurnBarDaemonManager` into a thin `@Observable @MainActor` facade that owns the extracted managers and exposes `@Published`-equivalent properties (`status`, `providerConfigurations`, `recentUsage`, etc.) for SwiftUI. Remove all private logic, keeping only property forwarding and `attach(dataStore:)`.
  - *Rationale:* SwiftUI needs a single observable object. The facade pattern satisfies this without turning the facade into a god class.
- [ ] **Task 3.8.** Update `AgentLens` views that reference `OpenBurnBarDaemonManager.shared` directly for granular operations to reference the sub-managers (e.g., settings views use `ProviderConfigurationManager`). Keep the facade for dashboard views that need aggregated state.
  - *Rationale:* Fine-grained observation reduces unnecessary SwiftUI view updates.
- [ ] **Task 3.9.** Move `OpenBurnBarDaemonManagerTests.swift` out of `AgentLensTests/Parked/` and update it to test the extracted managers. Add unit tests for `DaemonLifecycleManager`, `ProviderConfigurationManager`, and `ControllerRuntimeManager` using the existing dependency-injection patterns (`OpenBurnBarDaemonDependencies`).
  - *Rationale:* Un-parking tests and making them pass validates the decomposition.
- [ ] **Task 3.10.** Run the full `AgentLens` test suite and verify SwiftUI previews compile.
  - *Rationale:* `@Observable` and `@MainActor` changes can break SwiftUI previews in subtle ways.

### Phase 4: Integration & Cleanup

- [ ] **Task 4.1.** Audit for dead code. After extraction, some private helpers in the original god-modules may be unused. Remove them.
  - *Rationale:* Prevents drift and reduces maintenance surface.
- [ ] **Task 4.2.** Update `CHANGELOG.md` with the architectural refactoring notes, highlighting new module boundaries for future contributors.
  - *Rationale:* Onboarding docs should reflect the new structure.
- [ ] **Task 4.3.** Update `docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md` (or equivalent) with a module map showing which file belongs to which domain.
  - *Rationale:* Future AI agents and human contributors need a clear map.
- [ ] **Task 4.4.** Verify that `make test` (or the Xcode test action) passes for all three targets: `OpenBurnBarCoreTests`, `OpenBurnBarDaemonTests`, and `AgentLensTests`.
  - *Rationale:* Final gate before considering the work complete.

---

## Verification Criteria

- `OpenBurnBarContracts.swift` no longer exists; all types compile from their new domain files.
- `BurnBarRunService.swift` is under 200 lines (facade only) and delegates to sub-actors.
- `OpenBurnBarDaemonManager.swift` is under 150 lines (facade only) and delegates to sub-managers.
- No `@_exported import` or typealias shims remain in the contract layer.
- All existing tests pass; new unit tests exist for each extracted sub-actor/sub-manager.
- `AgentLensTests/Parked/OpenBurnBarDaemonManagerTests.swift` is moved to the active test target and compiles.
- The daemon's RPC surface (`BurnBarDaemonServer`) requires zero changes to its method-switch body (only wiring changes).

---

## Potential Risks and Mitigations

1. **Actor Re-Entrancy & Serialization Changes**
   - *Risk:* Splitting `BurnBarRunService` into multiple actors changes the serialization order of run mutations and tool results.
   - *Mitigation:* Keep `BurnBarRunLifecycleService` as the single source of truth for run state. Other actors return decisions/values to the lifecycle actor, which applies state changes. This preserves run-state serialization while allowing concurrent I/O in provider and tool dispatch actors.

2. **SwiftUI Observation Chain Breakage**
   - *Risk:* Sub-managers are not `@Observable`, so SwiftUI views observing the facade may miss updates if the facade does not properly forward changes.
   - *Mitigation:* The facade remains `@Observable` and updates its own stored properties whenever sub-managers complete async work. Do not expose sub-manager properties directly to SwiftUI; always proxy through the facade.

3. **Cross-Target Import Cycle**
   - *Risk:* Extracted contract files may reference each other in ways that create subtle ordering issues.
   - *Mitigation:* Use a directed acyclic graph: `RPCContracts` → `ToolContracts` → `RunContracts` → `ProviderContracts`. `ConnectorContracts` and `ClientContracts` are leaves. No contract file imports another contract file with a higher rank.

4. **Test Mock Explosion**
   - *Risk:* More modules means more protocols and mocks.
   - *Mitigation:* Use the existing `OpenBurnBarDaemonDependencies` pattern (struct-of-closures) rather than protocols where possible. It is lightweight and does not require mock classes.

5. **Partial Refactoring Leaving Dangling Types**
   - *Risk:* Stopping midway leaves the codebase in a worse state.
   - *Mitigation:* Complete one phase entirely before starting the next. Do not interleave contract moves with run-service extraction. The shim layer in Phase 1 allows safe incremental commits.

---

## Alternative Approaches

1. **Pure Protocol-Oriented Decomposition**
   - Instead of concrete actors, define protocols for each subdomain (`BurnBarRunLifecycleServing`, `BurnBarToolDispatching`, etc.) and inject them.
   - *Trade-off:* More boilerplate, but enables aggressive mocking and alternative implementations. Recommended if the team plans to add a second run backend (e.g., cloud-hosted).

2. **Single-Target Directory Reorganization Only**
   - Keep all code in the same Swift target but split into folders (`Run/Lifecycle.swift`, `Run/ToolDispatch.swift`, etc.).
   - *Trade-off:* Faster to execute and avoids import cycles, but does not improve compile times or enforce boundaries. Not recommended because the core issue is coupling, not just file size.

3. **Swift Package Sub-Modules**
   - Create separate SPM targets inside `OpenBurnBarCore` and `OpenBurnBarDaemon` (e.g., `OpenBurnBarCoreContracts`, `OpenBurnBarDaemonRun`).
   - *Trade-off:* Strongest boundary enforcement, but more `Package.swift` churn and potential cyclical dependency headaches. Recommended only if the team is willing to maintain a more granular package graph.

---

## Clarity Assessment / Assumptions

- **Assumption:** The user wants the god-modules broken up into smaller, domain-cohesive units while keeping the public API surface stable for RPC and SwiftUI consumers.
- **Assumption:** "Contracts split by domain" refers specifically to `OpenBurnBarContracts.swift` (the 1385-line monolith), not the already-partially-split `AgentContracts` and `MissionControlContracts`.
- **Assumption:** Tests in `AgentLensTests/Parked/` are parked due to compilation issues with the god-module, and un-parking them is desirable.
- **Assumption:** The refactoring should be done incrementally with zero breaking changes at each commit (using shim re-exports), rather than one atomic mega-commit.
- **Assumption:** The `BurnBarRunService` public API must remain stable because `BurnBarDaemonServer` references it directly in 20+ switch cases.
