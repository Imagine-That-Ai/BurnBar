# Break Up UsageAggregator -- Extract Parser Registry, Billing, and Summary Engine

## Objective

Decompose `AgentLens/Services/UsageAggregator.swift` (1,250 lines) from a monolithic "god service" into focused, single-responsibility modules. The file currently conflates four distinct concerns:

1. **Parser registry and refresh orchestration** (lines 8-99, 101-278, 280-358, 360-422)
2. **Billing / API reconciliation** (lines 204-264)
3. **Auto-summary engine** (lines 646-803, 841-1250 -- summarization orchestration, LLM provider dispatch, Ollama/OpenAI-compatible calls, payload parsing, cost estimation, API key resolution)
4. **Projection and backfill scheduling** (lines 510-839)

After extraction, `UsageAggregator` should remain as a thin orchestration facade that coordinates the extracted services, preserving the same public API surface so consumers (`DashboardView`, `OnboardingScanView`, `OpenBurnBarOperatingLayer`, `AgentLensApp`) require zero or minimal changes.

---

## Current State Analysis

### File Profile
- **Path:** `AgentLens/Services/UsageAggregator.swift:1-1250`
- **Size:** 1,250 lines
- **Class:** `@Observable @MainActor final class UsageAggregator`
- **Dependencies injected:** `DataStore`, `CloudSyncService`, `ICloudSessionMirrorService`, `SettingsManager`, `ProviderAPIKeyStore`, `ProviderUsageAPIService`, `ProviderQuotaService`, `ArtifactDiscoveryService`, `ProjectionPipelineService`
- **State properties:** 20+ `private(set)` properties driving UI observation

### Consumers (25 references across 15 files)
- **Views** read observed properties: `isRefreshing`, `isSummarizing`, `summaryProgressDone/Total`, `summaryCurrentTitle`, `summaryQueue`, `summaryTimeRemaining`, `parserHealth`, `errors`
- **Operating Layer** holds an optional reference for snapshot cache keying
- **App entry point** creates and wires into dependency graph
- **Tests** (parked): `AgentLensTests/Parked/UsageAggregatorTests.swift` (1,636 lines)

### Existing Decomposition (already extracted)
- `AgentLens/Services/UsageAggregation/BillingUsageReconciliation.swift` -- pure static reconciliation logic
- `AgentLens/Services/UsageAggregation/ParserHealth.swift` -- enum
- `AgentLens/Services/UsageAggregation/SummaryQueueItem.swift` -- struct
- `AgentLens/Services/UsageAggregation/UsageAggregationPolicies.swift` -- policy constants
- `AgentLens/Services/UsageAggregatorParsers.swift` -- concrete parser implementations (1,346 lines, separate file)

### Responsibility Decomposition

| Concern | Lines | % of file | Proposed Destination |
|---|---|---|---|
| Parser registry + `defaultParsers()` | ~55 | 4% | `ParserRegistry` |
| Refresh orchestration (`refreshAll`, `refresh(provider:)`, `recountAll`) | ~220 | 18% | Stays in `UsageAggregator` (thin) |
| Persistence helpers (`persistAndReloadUsageRows`, etc.) | ~30 | 2% | Stays in `UsageAggregator` |
| Parser health reporting (`upsertParserImportHealth`) | ~70 | 6% | `ParserHealthReporter` (or stays) |
| Billing API fetch + reconciliation orchestration | ~60 | 5% | `BillingRefreshCoordinator` |
| Backfill scheduling | ~40 | 3% | Stays (small) |
| Artifact discovery + projection sweep launch | ~130 | 10% | Stays (delegates to existing services) |
| Auto-summary orchestration + sweep | ~160 | 13% | `AutoSummaryEngine` |
| LLM provider dispatch (`summarizeConversation`) | ~100 | 8% | `AutoSummaryEngine` |
| Ollama/OpenAI HTTP calls | ~120 | 10% | `SummaryLLMClient` |
| Payload parsing + sanitization | ~50 | 4% | `SummaryLLMClient` |
| Cost estimation + API key resolution + daily cap | ~80 | 6% | `SummaryCostEstimator` + `SummaryAPIKeyResolver` |
| Test helpers | ~20 | 2% | Move to respective extracted types |

---

## Implementation Plan

### Phase 1: Extract Parser Registry

**Rationale:** The static `defaultParsers()` mapping and the concept of a parser registry is a standalone, testable concern. Extracting it makes the parser list discoverable and extensible without touching the aggregator.

- [ ] 1.1. Create `AgentLens/Services/UsageAggregation/ParserRegistry.swift` containing a `ParserRegistry` struct or enum with a static method `defaultParsers() -> [AgentProvider: any LogParser]` -- move the dictionary from `UsageAggregator.swift:45-73`
- [ ] 1.2. Update `UsageAggregator.init` (line 98) to call `ParserRegistry.defaultParsers()` instead of `Self.defaultParsers()`
- [ ] 1.3. Remove the `defaultParsers()` static method from `UsageAggregator`
- [ ] 1.4. Verify all 17 provider entries are preserved exactly in the new registry
- [ ] 1.5. Add a unit test in `AgentLensTests/Active/` confirming `ParserRegistry.defaultParsers()` returns all expected provider keys

### Phase 2: Extract Summary LLM Client

**Rationale:** The HTTP networking layer for Ollama and OpenAI-compatible endpoints (lines 960-1138) is pure I/O with no dependency on `UsageAggregator` state beyond settings values. Extracting it isolates network concerns, enables independent testing with mock URLSession, and removes ~280 lines from UsageAggregator.

- [ ] 2.1. Create `AgentLens/Services/UsageAggregation/SummaryLLMClient.swift` containing a `SummaryLLMClient` actor or struct
- [ ] 2.2. Move `callOpenAICompatibleCompletion(...)` (lines 1082-1138) into `SummaryLLMClient`
- [ ] 2.3. Move `summarizeWithOllama(prompt:)` (lines 1027-1080) into `SummaryLLMClient`, parameterizing the settings values it reads (`summaryLocalBaseURL`, `summaryLocalModel`, `summaryRequestTimeoutSeconds`, output tokens) as method parameters instead of reading from `settingsManager`
- [ ] 2.4. Move `parseSummaryPayload(from:)` (lines 1140-1156) into `SummaryLLMClient`
- [ ] 2.5. Move `sanitizeSummaryPayload(_:fallbackTitle:)` (lines 1158-1172) into `SummaryLLMClient`
- [ ] 2.6. Move the private `SessionSummaryPayload` struct (lines 425-428) into `SummaryLLMClient` file, making it `internal` for testability
- [ ] 2.7. Update all call sites in `UsageAggregator` to delegate to a `SummaryLLMClient` instance
- [ ] 2.8. Add unit tests for `parseSummaryPayload` and `sanitizeSummaryPayload` in `AgentLensTests/Active/SummaryLLMClientTests.swift` (these are currently implicitly tested through integration; explicit unit tests improve coverage)

### Phase 3: Extract Summary Cost Estimator and API Key Resolver

**Rationale:** Cost estimation (lines 1212-1249) and API key resolution (lines 1174-1204) are pure functions with no aggregator state dependency. They're independently testable and reusable.

- [ ] 3.1. Create `AgentLens/Services/UsageAggregation/SummaryCostEstimator.swift` with a `SummaryCostEstimator` enum or struct
- [ ] 3.2. Move `estimateCostUSD(provider:model:inputTokens:outputTokens:)` (lines 1212-1249) into `SummaryCostEstimator`
- [ ] 3.3. Move `exceedsCloudDailyCap(adding:)` (lines 1206-1210) into `SummaryCostEstimator`, parameterizing `settingsManager.summaryDailyCapUSD` and `dataStore.summarySpendToday()` as parameters
- [ ] 3.4. Create `AgentLens/Services/UsageAggregation/SummaryAPIKeyResolver.swift` with a `SummaryAPIKeyResolver` struct
- [ ] 3.5. Move `resolveAPIKey(for:)` (lines 1174-1204) into `SummaryAPIKeyResolver`, injecting `ProviderAPIKeyStore` and optionally `ProcessInfo.processInfo.environment` for testability
- [ ] 3.6. Update `UsageAggregator` (and any code extracted in Phase 4) to use the new types
- [ ] 3.7. Add unit tests for `SummaryCostEstimator.estimateCostUSD` covering each provider/model branch
- [ ] 3.8. Add unit tests for `SummaryAPIKeyResolver.resolveAPIKey` covering keychain, env-var, and empty fallback paths

### Phase 4: Extract Auto-Summary Engine

**Rationale:** The auto-summary orchestration is the single largest concern in the file (~300 lines including sweep control, concurrency management, provider fallback chains, and progress tracking). It has its own state machine (`isSummarizing`, progress tracking, queue) that is only loosely coupled to the refresh lifecycle. Extracting it yields the biggest maintainability win.

- [ ] 4.1. Create `AgentLens/Services/UsageAggregation/AutoSummaryEngine.swift` containing `@Observable @MainActor final class AutoSummaryEngine`
- [ ] 4.2. Move summary-related observed state into `AutoSummaryEngine`: `isSummarizing`, `summaryProgressDone`, `summaryProgressTotal`, `summaryCurrentTitle`, `summaryQueue`, `summaryTimeRemaining`, `localSummaryEndpointCooldownUntil`, `mlxSummaryEndpointCooldownUntil`, `hasCompletedInitialSummarySweep`
- [ ] 4.3. Move `runAutoSummarySweep(indexedAfter:)` (lines 694-803) into `AutoSummaryEngine`
- [ ] 4.4. Move `launchAutoSummarySweep(indexedAfter:)` (lines 646-653) into `AutoSummaryEngine`
- [ ] 4.5. Move `summarizeConversation(_:)` (lines 863-958) into `AutoSummaryEngine`, which internally uses `SummaryLLMClient`, `SummaryCostEstimator`, and `SummaryAPIKeyResolver` from phases 2-3
- [ ] 4.6. Move `summarizeWithOpenAICompatibleProvider(...)` (lines 960-1025) into `AutoSummaryEngine`
- [ ] 4.7. Move `recordParallelSummaryResult(...)` and `markSummaryItemProcessing(...)` (lines 656-692) into `AutoSummaryEngine`
- [ ] 4.8. Move `effectiveAutoSummaryBatchLimit`, `effectiveAutoSummaryMaxConcurrency`, `effectiveAutoSummaryPromptChars`, `effectiveAutoSummaryOutputTokens` (lines 841-861) into `AutoSummaryEngine`
- [ ] 4.9. Move `AutoSummaryResult` private struct (lines 430-436) into `AutoSummaryEngine` file
- [ ] 4.10. Inject `AutoSummaryEngine` into `UsageAggregator.init`, create it there by default, and store as a property
- [ ] 4.11. Expose `AutoSummaryEngine` as a public property on `UsageAggregator` (or forward observed properties) so that `DashboardView` (`DashboardView.swift:342-353`) and `DashboardSummarizingComponents` (`DashboardSummarizingComponents.swift:262-405`) can bind to it
- [ ] 4.12. Update `DashboardView` and `DashboardSummarizingComponents` to read summary state from `aggregator.summaryEngine` instead of directly from `aggregator`
- [ ] 4.13. Update `UsageAggregator.refreshAll()` to call `summaryEngine.launchAutoSummarySweep(indexedAfter:)` at line 198
- [ ] 4.14. Wire the `requestProjectionSweep()` callback -- `AutoSummaryEngine` needs a closure or delegate to notify the aggregator to trigger a projection sweep after summary completion (line 802)

### Phase 5: Extract Billing Refresh Coordinator

**Rationale:** The billing API fetch + reconciliation orchestration (lines 204-264 of `refreshAll`) is a self-contained pipeline that could be tested independently from the parser refresh flow.

- [ ] 5.1. Create `AgentLens/Services/UsageAggregation/BillingRefreshCoordinator.swift` with a struct or class that encapsulates the billing API fetch-reconcile-persist cycle
- [ ] 5.2. Move the billing section of `refreshAll()` (lines 204-251) into a `BillingRefreshCoordinator.reconcile(...)` method that takes `dataStore`, `usageAPIService`, and baseline usages as parameters
- [ ] 5.3. Have it return the supplemental usages and any error messages so `UsageAggregator` can set `parserImportError` and `apiUsages`
- [ ] 5.4. Update `UsageAggregator.refreshAll()` to call `BillingRefreshCoordinator.reconcile(...)` in place of the inline billing logic
- [ ] 5.5. Add unit tests covering the orchestration flow (mock `ProviderUsageAPIService` returning canned records, verify supplemental rows are computed correctly)

### Phase 6: Slim Down UsageAggregator Facade

**Rationale:** After phases 1-5, `UsageAggregator` should be ~300-350 lines -- a thin facade that wires together `ParserRegistry`, `AutoSummaryEngine`, `BillingRefreshCoordinator`, and existing services. This phase verifies the decomposition is complete and clean.

- [ ] 6.1. Verify `UsageAggregator.swift` is under 400 lines
- [ ] 6.2. Verify all `@Observable` properties that views bind to are still accessible (either directly on `UsageAggregator` or via a public sub-object like `summaryEngine`)
- [ ] 6.3. Verify `UsageAggregatorTests` (parked) still compiles if unparked -- update test references to match new type locations
- [ ] 6.4. Verify that `BackfillSchedulerTests` and `MultiSourceReconciliationTests` (active) still pass
- [ ] 6.5. Run full `AgentLensTests` target and confirm zero regressions
- [ ] 6.6. Update `project.yml` if new files need explicit inclusion (XcodeGen auto-globs from directory, so likely no change needed, but verify)

---

## Verification Criteria

- `UsageAggregator.swift` reduced from 1,250 to ~300-350 lines
- All 17 parser providers still registered and functional
- No change to the public API surface consumed by views (`isRefreshing`, `isSummarizing`, `summaryProgressDone/Total`, `summaryCurrentTitle`, `summaryQueue`, `summaryTimeRemaining`, `parserHealth`, `errors`, `apiUsages`, `lastRefresh`, `refreshAll()`, `recountAll()`, `refresh(provider:)`)
- New files created in `AgentLens/Services/UsageAggregation/`:
  - `ParserRegistry.swift` (~30 lines)
  - `SummaryLLMClient.swift` (~200 lines)
  - `SummaryCostEstimator.swift` (~60 lines)
  - `SummaryAPIKeyResolver.swift` (~40 lines)
  - `AutoSummaryEngine.swift` (~350 lines)
  - `BillingRefreshCoordinator.swift` (~80 lines)
- Each extracted type has at least one dedicated test file in `AgentLensTests/Active/`
- Existing active tests pass without modification
- Build succeeds with `SWIFT_STRICT_CONCURRENCY: complete`

---

## Potential Risks and Mitigations

1. **`@Observable` observation breaks when summary state moves to a sub-object**
   Mitigation: SwiftUI `@Observable` supports nested observation -- `aggregator.summaryEngine.isSummarizing` will trigger view updates. Alternatively, `UsageAggregator` can forward computed properties that delegate to `summaryEngine`, keeping the existing observation contract identical. The forwarding approach is safer for the initial extraction.

2. **Thread-safety of extracted `SummaryLLMClient` when called from TaskGroup**
   Mitigation: `SummaryLLMClient` should be `Sendable` (struct with no mutable state, or actor). All mutable cooldown state stays in `AutoSummaryEngine` (which is `@MainActor`). The LLM client receives parameters and returns results -- pure request/response.

3. **Circular dependency between `AutoSummaryEngine` and `UsageAggregator` (projection sweep callback)**
   Mitigation: Use a closure `onRequestProjectionSweep: () -> Void` injected at init time rather than a direct reference back to the aggregator. This keeps the dependency unidirectional.

4. **Parked tests (1,636 lines) reference `UsageAggregator` internals that move**
   Mitigation: Phase 6.3 explicitly addresses this. Since tests are parked (not compiled in CI), breakage is cosmetic until they're activated. Update references to point to new type locations.

5. **`internal` access for test helpers (`computeSupplementalUsages`, `costDeltaExceedsEpsilon`) may need relocation**
   Mitigation: `computeSupplementalUsages` already delegates to `BillingUsageReconciliation.supplementalUsages` -- test should call that directly. `costDeltaExceedsEpsilon` can move to `SummaryCostEstimator` or `BillingUsageReconciliation`.

---

## Alternative Approaches

1. **Protocol-based extraction**: Define protocols (`SummaryEngine`, `BillingReconciler`) and have `UsageAggregator` depend on protocols. More testable but adds indirection. Recommended only if multiple implementations are foreseeable (e.g., a mock summary engine for previews). Not recommended as the initial move -- extract concrete types first, abstract later if needed.

2. **Extension-file-only split**: Keep everything in `UsageAggregator` but split into `UsageAggregator+Summary.swift`, `UsageAggregator+Billing.swift`, etc. Lower risk (no API change) but doesn't improve testability or reduce coupling -- it's cosmetic. Not recommended as the primary approach, though it could serve as an intermediate step.

3. **Full actor extraction**: Make `AutoSummaryEngine` a standalone actor (not `@MainActor`) to properly isolate summary work from the main thread. Better architecture long-term (aligns with tech debt Theme B: `@MainActor as default`) but higher risk for this PR. Recommended as a follow-up after the initial extraction stabilizes.

---

## Execution Order Recommendation

Phases are ordered by dependency and risk:

1. **Phase 1** (Parser Registry) -- zero-risk, no API change, immediate clarity win
2. **Phase 2** (Summary LLM Client) -- pure extraction of I/O code, no state migration
3. **Phase 3** (Cost Estimator + Key Resolver) -- pure functions, trivially testable
4. **Phase 4** (Auto-Summary Engine) -- biggest win, highest risk, depends on 2 and 3
5. **Phase 5** (Billing Refresh Coordinator) -- independent of 2-4, can be parallelized
6. **Phase 6** (Verification) -- final pass after all extractions

Phases 1-3 can be shipped as separate PRs with zero consumer changes. Phase 4 is the only one that touches view code. Phase 5 is independent and can be done in parallel with Phase 4.
