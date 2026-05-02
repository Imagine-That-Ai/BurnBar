# SettingsManager God-Object Remediation

## Objective

Decompose the 1,179-line `SettingsManager` (`AgentLens/Services/SettingsManager.swift`) into domain-specific `@Observable` stores, replace the atomic 60-key `save()` with dirty-tracking coalesced persistence, extract business logic into dedicated services, and decompose the monolithic protocol. Eliminate the performance issue, maintenance burden, and single point of failure while keeping the app functional throughout the migration.

---

## Current State Analysis

**Source of information:** `AgentLens/Services/SettingsManager.swift:1-1179`, `AgentLens/Services/Protocols/SettingsManagerProtocol.swift:1-257`, `AgentLensTests/Active/SettingsManagerTests.swift:1-1204`, `AgentLensTests/Active/SettingsManagerSecretStorageTests.swift:1-376`, and cross-references with ~35 view files in `AgentLens/Views/`.

**Key metrics:**
- 77 stored properties with `didSet { save() }`
- 24 computed properties / methods
- ~300-line `init()` with default resolution, clamping, and legacy migration
- ~120-line `save()` that writes ~60 `UserDefaults` keys + 4 keychain secrets unconditionally on every property mutation
- Consumed by ~35 view files via `@Bindable`, `let`, or `@Environment(SettingsManager.self)`
- Tests span 1,580 lines across two monolithic test files

**Prioritized risks:**
1. **Performance** — Every property mutation triggers 60+ disk writes. Rapid UI changes (e.g., sliders, steppers) create write storms.
2. **God object** — All app configuration lives in one file. Adding any feature requires touching this file, creating merge conflicts and review bottlenecks.
3. **Testability** — `SettingsManagerProtocol` has 40+ requirements. Mocks must reproduce the entire surface area.
4. **Separation of concerns** — Business logic (provider path resolution, Hermes model mapping, CSV encoding, usage formatting) is entangled with persistence.
5. **Observation overhead** — `@Observable` means any mutation invalidates every view holding a `SettingsManager` reference, even if that view only reads unrelated properties.

---

## Target Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  SwiftUI Views (receive focused stores, not monolith)       │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ @Observable  │    │ @Observable  │    │ @Observable  │
│ Appearance   │    │ Controller   │    │ Gateway      │
│ Settings     │    │ Settings     │    │ Settings     │
└──────┬───────┘    └──────┬───────┘    └──────┬───────┘
       │                   │                   │
       └───────────────────┼───────────────────┘
                           ▼
              ┌────────────────────────┐
              │ SettingsPersistence    │
              │ Coordinator            │
              │ (dirty-tracking,       │
              │  debounced flush)      │
              └───────────┬────────────┘
                          ▼
                   ┌──────────────┐
                   │ UserDefaults │
                   │  + Keychain  │
                   └──────────────┘
```

`SettingsManager` becomes a thin container that exposes domain stores as `let` properties. It remains `@Observable` so SwiftUI can traverse into sub-stores. Once all call sites migrate, the old stored properties are removed and `SettingsManager` becomes purely a composition root.

---

## Implementation Plan

### Phase 1: Foundation — Coalesced Persistence Layer

- [ ] **Task 1.1. Create `AgentLens/Services/Settings/SettingsPersistenceCoordinator.swift`.** Build a `@MainActor` class that owns a `UserDefaults` instance, maintains a `Set<String>` of dirty keys, and provides `load<T>(forKey:defaultValue:)` / `set<T>(_ value:T, forKey:)` / `removeObject(forKey:)`. The `set` method marks the key dirty and schedules a debounced flush (e.g., 0.1s via `Task.sleep`). The `flush()` method writes only dirty keys to `UserDefaults`, then clears the set. This eliminates the 60-key atomic write on every property mutation.
  - *Rationale:* Fixes the performance issue at the source. All domain stores will delegate to this coordinator, ensuring writes are coalesced across store boundaries.

- [ ] **Task 1.2. Extract `SettingsSecretPersistence` to `AgentLens/Services/Settings/SettingsSecretPersistence.swift`.** Move the existing struct (`SettingsManager.swift:38-80`) and its `SettingsSecretDefaultsKey` enum (`SettingsManager.swift:31-36`) into a standalone file. No behavior changes.
  - *Rationale:* Removes the first chunk of non-settings logic from `SettingsManager.swift` and makes secret persistence independently testable.

- [ ] **Task 1.3. Move standalone enums to dedicated files.** Extract `AppearanceMode` (`SettingsManager.swift:17-29`), `SummaryProviderID` (`SettingsManager.swift:4-10`), `IndexEmbeddingProviderID` (`SettingsManager.swift:12-15`), and `TimeRange` (`SettingsManager.swift:1142-1179`) into `AgentLens/Models/Settings/` (or `OpenBurnBarCore` if already imported there). Update imports in all referencing files.
  - *Rationale:* These types are pure model definitions. They do not belong in a service file. Moving them reduces `SettingsManager.swift` by ~50 lines and prevents the file from growing when new enum cases are added.

- [ ] **Task 1.4. Create shared test infrastructure `AgentLensTests/Support/SettingsTestSupport.swift`.** Extract `makeIsolatedDefaults()`, `makeTemporaryDirectory()`, and the five test keychain backends (`SettingsManagerTestKeychainBackend`, `InteractionLockedWriteTestKeychainBackend`, `AlwaysInteractionLockedTestKeychainBackend`, `FailingWriteKeychainBackend`, `VerificationMismatchKeychainBackend`) from the two existing test files. Eliminate the duplicate `SettingsManagerTestKeychainBackend` definitions.
  - *Rationale:* Prevents duplication and gives every new domain store test a consistent isolation pattern.

### Phase 2: Extract Domain Stores (Incremental, One Domain at a Time)

For each domain below, perform the same sub-tasks. Domains are ordered by risk surface (smallest / least coupled first):

#### Domain 2A: Appearance

- [ ] **Task 2A.1. Create `AgentLens/Services/Settings/Stores/AppearanceSettings.swift`.** Build an `@Observable @MainActor` class with stored properties `appearanceMode: AppearanceMode` and `showInMenuBar: Bool`. Use `SettingsPersistenceCoordinator` for load/save. Add a computed `preferredSwiftUIColorScheme: ColorScheme?`.
  - *Rationale:* Appearance is the smallest domain (2 stored properties, ~5 consuming views). It is a safe proving ground for the store pattern.

- [ ] **Task 2A.2. Add `let appearance: AppearanceSettings` to `SettingsManager`.** Initialize it in `SettingsManager.init`. Keep the old `appearanceMode` and `showInMenuBar` stored properties temporarily for backward compatibility.
  - *Rationale:* Allows existing code to continue working while new code and migrated views use the sub-store.

- [ ] **Task 2A.3. Create `AgentLensTests/Active/Settings/AppearanceSettingsTests.swift`.** Migrate relevant tests from `SettingsManagerTests.swift` (appearance mode default/resolution, `preferredSwiftUIColorScheme` derivation).
  - *Rationale:* Establishes the per-domain test pattern before scaling to larger domains.

- [ ] **Task 2A.4. Migrate views: `AppearanceCorkboardSection`, `OnboardingWizardView`, `HermesSetupWizardView`, `SwitcherOnboardingWizardView`.** Change `$settingsManager.appearanceMode` to `$settingsManager.appearance.appearanceMode` in `AppearanceCorkboardSection`. Change `settingsManager.preferredSwiftUIColorScheme` to `settingsManager.appearance.preferredSwiftUIColorScheme` in onboarding views.
  - *Rationale:* Completes the end-to-end validation of the pattern. Once verified, the old `appearanceMode` stored property can be removed from `SettingsManager`.

- [ ] **Task 2A.5. Remove old `appearanceMode` and `showInMenuBar` stored properties from `SettingsManager`.** Update `SettingsManagerProtocol` to remove the appearance requirements or redirect them to the sub-store protocol.
  - *Rationale:* Completes the extraction. `SettingsManager.swift` shrinks.

#### Domain 2B: Behavior

- [ ] **Task 2B.1. Create `AgentLens/Services/Settings/Stores/BehaviorSettings.swift`.** Include `refreshInterval: TimeInterval`, `defaultTimeRange: TimeRange`, `launchAtLogin: Bool`, and computed `refreshIntervalMinutes: Double`. Use the persistence coordinator.
  - *Rationale:* These four properties are tightly coupled (all relate to app-level behavior/timing) and are consumed by `GeneralSettingsView` and `DashboardToolbarContent`.

- [ ] **Task 2B.2. Add `let behavior: BehaviorSettings` to `SettingsManager` and migrate views.** Update `GeneralSettingsView` bindings: `$settingsManager.behavior.refreshInterval`, `$settingsManager.behavior.defaultTimeRange`, `$settingsManager.behavior.launchAtLogin`.
  - *Rationale:* Mechanical migration. The `refreshIntervalMinutes` computed property moves to the store.

- [ ] **Task 2B.3. Create `AgentLensTests/Active/Settings/BehaviorSettingsTests.swift`.** Migrate refresh interval and time range tests from `SettingsManagerTests.swift`.
  - *Rationale:* Follows the established test pattern.

#### Domain 2C: Alerts & Notifications

- [ ] **Task 2C.1. Create `AgentLens/Services/Settings/Stores/AlertSettings.swift`.** Include `costAlertThreshold: Double?`, `dailyDigestEnabled: Bool`, `dailyDigestHour: Int`.
  - *Rationale:* Small domain (3 properties) consumed by `GeneralSettingsView` and `AlertsSettingsView`.

- [ ] **Task 2C.2. Migrate `GeneralSettingsView` and `AlertsSettingsView` bindings.** Update to `$settingsManager.alerts.costAlertThreshold`, etc.
  - *Rationale:* Completes the alerts domain extraction.

#### Domain 2D: Controller Runtime

- [ ] **Task 2D.1. Create `AgentLens/Services/Settings/Stores/ControllerSettings.swift`.** Include all 10 controller properties (`controllerRuntimeEnabled`, `controllerRuntimeRefreshMinutes`, `controllerLocalNotificationsEnabled`, `controllerTelegramEnabled`, `controllerTelegramBotToken`, `controllerTelegramChatID`, `controllerCalendarIntegrationEnabled`, `controllerCalendarDefaultMinutes`, `controllerDefaultSnoozeMinutes`, `controllerSimulatorToolsEnabled`). Use `SettingsSecretPersistence` for the bot token.
  - *Rationale:* Controller settings are a cohesive domain with clear boundaries. The bot token uses keychain storage, which `SettingsSecretPersistence` already handles.

- [ ] **Task 2D.2. Migrate views: `DaemonSettingsView`, `AlertsAndNotificationsViews`, `PrivacyIndexingSettingsView`, `OpenBurnBarControllerWorkbenchPanel`, `OpenBurnBarControllerRuntimeGuideCard`.** Update bindings to use `$settingsManager.controller.*`.
  - *Rationale:* These views only touch controller properties. Migration is mechanical and safe.

#### Domain 2E: Gateway

- [ ] **Task 2E.1. Create `AgentLens/Services/Settings/Stores/GatewaySettings.swift`.** Include `gatewayEnabled: Bool`, `gatewayHost: String`, `gatewayPort: Int`, `gatewayAuthToken: String` (keychain-backed). Include computed `gatewayConfigurationDict: [String: Any]`.
  - *Rationale:* Gateway settings are logically distinct and only consumed by `ChatGatewaySettingsView` and the daemon launch path.

- [ ] **Task 2E.2. Migrate `ChatGatewaySettingsView` bindings.** Update to `$settingsManager.gateway.gatewayEnabled`, etc.
  - *Rationale:* Single view owns all gateway bindings.

#### Domain 2F: Chat Backend & Onboarding

- [ ] **Task 2F.1. Create `AgentLens/Services/Settings/Stores/ChatBackendSettings.swift`.** Include `chatBackendOnboardingCompleted`, `switcherOnboardingCompleted`, `selectedOnboardingProvidersCSV`, `enabledChatBackendIDsCSV`, `openClawGatewayBaseURL`, `openClawBearerToken` (keychain), `hermesBearerToken` (keychain), `hermesChatModelOverride`. Include computed `enabledChatBackends`, `selectedOnboardingProviders`, and methods `setEnabledChatBackends(_:)`, `setChatBackendEnabled(_:enabled:)`. Include static + instance `resolvedHermesChatModel(gatewayAdvertisedModel:)`.
  - *Rationale:* This is the highest-impact domain (~15 views read `enabledChatBackends`). Keeping it in one store prevents fragmentation.

- [ ] **Task 2F.2. Migrate chat-related views.** Update `ChatGatewaySettingsView`, `OnboardingWizardView`, `OnboardingConnectView`, `HermesSetupWizardView`, `SwitcherOnboardingWizardView`, `MenuBarPopoverView`, `DashboardQuickSwitchView`, `PopoverQuickSwitchView`, `ChatEngineBackendStrip`, `ChatEngineModelMenu`, `ChatContentView`, `ChatSidebarView`, `ChatPanelView` to access `settingsManager.chatBackend.enabledChatBackends`, etc.
  - *Rationale:* Many views are affected, but the changes are uniform (replace `settingsManager.enabledChatBackends` with `settingsManager.chatBackend.enabledChatBackends`).

#### Domain 2G: Indexing & Privacy

- [ ] **Task 2G.1. Create `AgentLens/Services/Settings/Stores/IndexSettings.swift`.** Include `conversationIndexingEnabled`, `conversationIndexingConsentShown`, `restrictedLogAccess`, `databaseEncryptionEnabled`, `preferredIndexEmbeddingVersionID`, `indexEmbeddingProvider`, `indexOpenAIModel`. Include computed `preferredIndexEmbeddingVersionIDValue`.
  - *Rationale:* These properties all relate to local indexing, search, and privacy controls.

- [ ] **Task 2G.2. Create `AgentLens/Services/Settings/Stores/CrossEncoderSettings.swift`.** Include all 6 cross-encoder properties.
  - *Rationale:* Cross-encoder is a sub-domain of indexing but large enough to deserve its own store.

- [ ] **Task 2G.3. Migrate `PrivacyIndexingSettingsView` and `SessionLogsView`.** Update bindings to `$settingsManager.indexing.*` and `$settingsManager.crossEncoder.*`.
  - *Rationale:* `PrivacyIndexingSettingsView` binds the most properties of any single view (~10). Migrating it validates the sub-store binding pattern at scale.

#### Domain 2H: Cloud Sync

- [ ] **Task 2H.1. Create `AgentLens/Services/Settings/Stores/CloudSyncSettings.swift`.** Include `conversationCloudBackupEnabled`, `iCloudSessionMetadataMirrorEnabled`, `sessionLogCloudBackupEnabled`, `sessionLogCloudBackupConsentShown`.
  - *Rationale:* Small, cohesive domain consumed by `AccountSwitcherSettingsView` and `SessionLogCloudConsentSheet`.

#### Domain 2I: CLI Assistant

- [ ] **Task 2I.1. Create `AgentLens/Services/Settings/Stores/CLIAssistantSettings.swift`.** Include `cliAssistantAllowed`, `cliAssistantConsentShown`. Preserve the didSet behavior where setting `cliAssistantAllowed = true` auto-sets `cliAssistantConsentShown = true`.
  - *Rationale:* Tiny domain. The cross-property didSet logic belongs inside the store, not in a monolithic manager.

#### Domain 2J: Summaries

- [ ] **Task 2J.1. Create `AgentLens/Services/Settings/Stores/SummarySettings.swift`.** Include all 20 summary stored properties and computed `summaryProviderOrder` with `setSummaryProviderOrder(_:)`.
  - *Rationale:* This is the largest domain (22 total items) but is consumed almost exclusively by `DashboardSummarizingComponents`. A dedicated store eliminates the biggest chunk of properties from `SettingsManager`.

- [ ] **Task 2J.2. Migrate `DashboardSummarizingComponents` bindings.** Update all `$settingsManager.summary*` bindings.
  - *Rationale:* Single view, many bindings. One focused migration commit.

#### Domain 2K: Quotas

- [ ] **Task 2K.1. Create `AgentLens/Services/Settings/Stores/QuotaSettings.swift`.** Include `miniMaxQuotaMode`, `factoryQuotaPlanTier`, `tokenizerAssistedFallbackEnabled`.
  - *Rationale:* Consumed by quota UI. Small domain.

#### Domain 2L: Provider Paths

- [ ] **Task 2L.1. Create `AgentLens/Services/Settings/Stores/ProviderPathSettings.swift`.** Include `logPaths: [AgentProvider: String]`. Keep the store focused on persistence only.
  - *Rationale:* Separates the raw `logPaths` storage from the filesystem business logic.

### Phase 3: Extract Business Logic Services

- [ ] **Task 3.1. Create `AgentLens/Services/ProviderPathService.swift`.** Extract `detectAvailableProviders()`, `pathExists(for:)`, `restrictedLogDirectory(for:)`, `resolvedPath(for:)`, `resetPathsToDefaults()`, and `candidatePaths(for:configuredPath:)` from `SettingsManager`. The service takes `ProviderPathSettings` and `IndexSettings` (for `restrictedLogAccess`) as dependencies.
  - *Rationale:* These methods perform live filesystem I/O (`FileManager.default.fileExists`) and contain provider-specific hardcoded path heuristics. A dedicated service allows mocking filesystem state in tests and removes I/O from the settings store.

- [ ] **Task 3.2. Create `AgentLens/Services/ChatBackendConfigurationService.swift`.** Extract `enabledChatBackends`, `setEnabledChatBackends(_:)`, `setChatBackendEnabled(_:enabled:)`, and `resolvedHermesChatModel(gatewayAdvertisedModel:)` from `SettingsManager`. The service takes `ChatBackendSettings` as a dependency.
  - *Rationale:* Pure business logic (Codex/MiniMax gateway model mapping, CSV encoding/decoding) that has nothing to do with persistence.

- [ ] **Task 3.3. Create `AgentLens/Services/UsageFormattingService.swift`.** Extract `formatUsageMetric(cost:tokens:)` from `SettingsManager`. The service takes `BehaviorSettings` (for `usageDisplayMode`) as a dependency.
  - *Rationale:* Pure presentation logic consumed by 5+ dashboard views. It does not belong in a persistence layer.

- [ ] **Task 3.4. Create `AgentLens/Services/ArtifactDiscoverySettingsService.swift`.** Extract `artifactDiscoveryRegisteredRoots`, `artifactDiscoveryAdditionalKnownPatterns`, `decodeJSONStringArray(_:)`, and `encodeJSONStringArray(_:)` from `SettingsManager`. Use proper `Codable` structs instead of raw JSON strings.
  - *Rationale:* JSON serialization utilities that bridge raw string storage to typed arrays. Using `Codable` structs is cleaner than manual JSON string manipulation.

- [ ] **Task 3.5. Update all call sites to use the new services.** Replace `settingsManager.detectAvailableProviders()` with `ProviderPathService(settings: providerPathSettings, indexSettings: indexSettings).detectAvailableProviders()`, etc. Where services are widely used, inject them via `@Environment` or constructor injection.
  - *Rationale:* Completes the separation of concerns. Views and other services no longer depend on `SettingsManager` for business logic.

### Phase 4: Refactor SettingsManager Facade and Protocol

- [ ] **Task 4.1. Remove all old stored properties from `SettingsManager`.** After all view migrations are complete, delete the 77 stored properties and their `didSet { save() }` blocks. `SettingsManager` now contains only `let` references to domain stores and any remaining cross-domain computed properties.
  - *Rationale:* This is the payoff. `SettingsManager.swift` shrinks from 1,179 lines to a thin composition root (~100-150 lines).

- [ ] **Task 4.2. Decompose `SettingsManagerProtocol`.** Create focused protocols in `AgentLens/Services/Protocols/Settings/`:
  - `AppearanceSettingsProtocol`
  - `BehaviorSettingsProtocol`
  - `AlertSettingsProtocol`
  - `ControllerSettingsProtocol`
  - `GatewaySettingsProtocol`
  - `IndexSettingsProtocol`
  - `CloudSyncSettingsProtocol`
  - `ChatBackendSettingsProtocol`
  - `SummarySettingsProtocol`
  - `CrossEncoderSettingsProtocol`
  - `QuotaSettingsProtocol`
  - `ProviderPathSettingsProtocol`
  - `DiscoverySettingsProtocol`
  - `CLIAssistantSettingsProtocol`

  Retain `SettingsManagerProtocol` as a composition of all focused protocols for backward compatibility during the transition, then deprecate it once consumers migrate.
  - *Rationale:* Allows tests to mock only the domain they need. Views can eventually declare `@Bindable var appearance: any AppearanceSettingsProtocol` instead of depending on the full monolith.

- [ ] **Task 4.3. Update `SettingsManager.init()`.** Replace the ~300-line inline init with delegation to each domain store's init. Each store handles its own default resolution and legacy migration. `OpenBurnBarMigration.migrateUserDefaults(defaults:)` is called once by the `SettingsPersistenceCoordinator`.
  - *Rationale:* Eliminates the 300-line init method. Default resolution lives next to the properties it initializes.

- [ ] **Task 4.4. Delete the monolithic `save()` method.** With all persistence delegated to domain stores via `SettingsPersistenceCoordinator`, the 120-line `save()` method is no longer needed.
  - *Rationale:* The final cleanup. `SettingsManager` no longer contains any direct `UserDefaults` or keychain write logic.

### Phase 5: Test Reorganization

- [ ] **Task 5.1. Create per-domain test files under `AgentLensTests/Active/Settings/`.** For each extracted domain store, create a dedicated test file using the shared `SettingsTestSupport` infrastructure. Migrate tests from the monolithic `SettingsManagerTests.swift`.
  - *Rationale:* Matches the source decomposition. Tests become faster to run, easier to locate, and independently maintainable.

- [ ] **Task 5.2. Create `AgentLensTests/Active/Settings/SettingsManagerIntegrationTests.swift`.** Retain only cross-domain integration tests:
  - Initialization and delegation wiring
  - Cross-domain computed properties (`gatewayConfigurationDict`, `resolvedHermesChatModel`)
  - End-to-end persistence routing (general defaults, keychain secrets)
  - Legacy migration coordination
  - Save coordination
  - Provider detection and path resolution (filesystem integration)
  - *Rationale:* The monolithic test file shrinks to ~100-150 lines of integration tests. Unit tests live next to their domains.

- [ ] **Task 5.3. Split secret storage tests.** Move `SettingsSecretPersistence` tests to `AgentLensTests/Active/Settings/SettingsSecretPersistenceTests.swift`. Move `KeychainStore` behavior tests to `AgentLensTests/Active/Keychain/KeychainStoreTests.swift`. Move `ProviderAPIKeyStore` tests to `AgentLensTests/Active/Keychain/ProviderAPIKeyStoreTests.swift`.
  - *Rationale:* `SettingsManagerSecretStorageTests.swift` currently mixes three unrelated concerns. Splitting them aligns tests with the types they validate.

- [ ] **Task 5.4. Add property-wrapper or coordinator-level stress tests.** Verify that 100 rapid mutations to different properties result in exactly one (or a small number of) `UserDefaults` flush operations, not 100.
  - *Rationale:* Validates the core performance fix and prevents regression.

### Phase 6: Final Cleanup and Verification

- [ ] **Task 6.1. Audit remaining `SettingsManager.shared` direct property access in non-view code.** Search for service classes that read `SettingsManager.shared.someProperty` and update them to receive the specific domain store or service via injection.
  - *Rationale:* Services like `ICloudSessionMirrorService`, `ArtifactDiscoveryService`, and `RefreshOrchestrator` likely read settings. They should depend on focused stores, not the monolith.

- [ ] **Task 6.2. Update previews and environment injection.** Replace `.environment(SettingsManager())` in previews with `.environment(SettingsManager.shared)` or a test fixture that injects isolated domain stores.
  - *Rationale:* Previews should not create orphaned `SettingsManager` instances that bypass the coordinator.

- [ ] **Task 6.3. Verify build and run the full test suite.** Ensure zero regressions across `AgentLensTests` and `OpenBurnBarDaemon` test targets.
  - *Rationale:* Final validation before considering the remediation complete.

---

## Verification Criteria

- [ ] `SettingsManager.swift` is under 200 lines (down from 1,179).
- [ ] No property mutation triggers an unconditional write of 60+ `UserDefaults` keys.
- [ ] The `save()` method is deleted; persistence is handled by `SettingsPersistenceCoordinator` and domain stores.
- [ ] Each domain store is independently unit-testable with isolated `UserDefaults`.
- [ ] All existing SwiftUI views compile and function without behavioral regression.
- [ ] Business logic methods (`detectAvailableProviders`, `formatUsageMetric`, `resolvedHermesChatModel`) are no longer in `SettingsManager`.
- [ ] `SettingsManagerProtocol` is decomposed into focused protocols; mocks only implement the surface they need.
- [ ] The full test suite passes with zero failures.

---

## Potential Risks and Mitigations

1. **SwiftUI `@Bindable` breakage during migration.**
   - *Risk:* Changing `$settingsManager.appearanceMode` to `$settingsManager.appearance.appearanceMode` could break observation if the facade or sub-store `@Observable` configuration is incorrect.
   - *Mitigation:* Migrate one domain at a time. Validate each domain with the affected views before proceeding. Use `ViewInspector` tests (already in use for `ContextPackSessionDetailSurfaceTests`) to verify bindings update correctly.

2. **UserDefaults key collisions or lost defaults during transition.**
   - *Risk:* If domain stores use different keys or default resolution logic, existing user settings could be lost or reset.
   - *Mitigation:* Keep `UserDefaults` keys identical to the current ones. The `SettingsPersistenceCoordinator` reads/writes the same keys. Add integration tests that seed legacy `UserDefaults` values and verify they resolve correctly through the new domain stores.

3. **Keychain secret migration regressions.**
   - *Risk:* `SettingsSecretPersistence` handles migration from legacy `UserDefaults` tokens to keychain. Moving this logic into domain stores could re-trigger migration or lose secrets.
   - *Mitigation:* Do not change `SettingsSecretPersistence` logic in Phase 1 (pure file move). Only change which store calls it. Retain all existing secret storage tests and run them unchanged.

4. **Cross-domain computed properties break during decomposition.**
   - *Risk:* Properties like `gatewayConfigurationDict` and `restrictedLogDirectory(for:)` span multiple domains. Extracting them too early could create circular dependencies.
   - *Mitigation:* Keep cross-domain computed properties on `SettingsManager` as the final facade layer until all underlying stores are stable. Then extract them to dedicated services (Phase 3) that receive the required stores as parameters.

5. **Merge conflicts during long-running refactoring.**
   - *Risk:* `SettingsManager.swift` is a high-churn file. A multi-phase refactoring could conflict with feature work.
   - *Mitigation:* Extract domains in order of least contention (appearance, behavior, alerts) before tackling high-churn domains (summaries, chat backend). Each domain extraction is a self-contained PR that can merge independently.

---

## Alternative Approaches

1. **Property Wrapper Approach (`@PersistedUserDefault`).**
   - *Description:* Create a custom property wrapper that stores the value locally and syncs to `UserDefaults`, keeping all properties on `SettingsManager` as stored properties. This would require zero view changes.
   - *Trade-offs:* Custom property wrappers interacting with `@Observable` have known edge cases in Swift 5.10. The macro expansion order and observation instrumentation are not guaranteed to work correctly. Even if they do, `SettingsManager` would still be a 300-line god object with 80+ properties — the maintenance burden and SPOF would remain. This approach only fixes the performance issue, not the structural problem.

2. **Single Settings Struct with Codable Persistence.**
   - *Description:* Define a single `Settings` struct conforming to `Codable` with nested domain structs. Persist the entire struct as one JSON blob in `UserDefaults`.
   - *Trade-offs:* Simplifies the persistence layer to a single key, but loses granular dirty tracking (any change rewrites the entire blob). It also makes keychain secrets awkward to mix into a JSON blob. SwiftUI observation would require the entire struct to be `@Observable` or wrapped in `@State`, which is not practical for a singleton.

3. **Keep `SettingsManager` as the sole `@Observable`, extract only persistence and logic.**
   - *Description:* Keep all 80+ stored properties on `SettingsManager`, but extract `save()` into a coordinator and extract business methods into services. Use a `@ObservationIgnored` persistence coordinator.
   - *Trade-offs:* Fixes performance and reduces file size somewhat, but `SettingsManager` still has 80+ properties and remains a maintenance bottleneck. Adding a feature still means editing this file. This is a half-measure that does not address the god-object anti-pattern.

---

## Assumptions

- Swift 5.10 `@Observable` macro supports observing sub-stores through `let` properties on a parent `@Observable` class (verified pattern in SwiftUI).
- The project will accept incremental PRs, one domain per PR, rather than requiring a single big-bang rewrite.
- `UserDefaults` keys remain stable; no user data migration is needed beyond what `OpenBurnBarMigration` already handles.
- Views that only read settings (do not bind via `$`) can continue using `SettingsManager` during the transition, or receive read-only value types later.
