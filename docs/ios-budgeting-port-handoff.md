# iOS Budgeting Port — Handoff

> **Audience**: Any agent or engineer implementing the budget port.
> **Minimum deployment**: iOS 17.0 (matches `OpenBurnBarMobile` target).
> **SwiftUI patterns**: `@Observable` with `@MainActor`, `NavigationStack`, `Tab` API (iOS 18+).
> **This document is the single source of truth** for the iOS budgeting port. It replaces all prior sketches.

---

## Table of Contents

- [Summary](#summary)
- [1. Shared Models (OpenBurnBarCore — already available)](#1-shared-models-openburnbarcore--already-available)
- [2. Data Stores to Port (6 total)](#2-data-stores-to-port-6-total)
  - [2A. BudgetRulesStore](#2a-budgetrulesstore)
  - [2B. BudgetSettings](#2b-budgetsettings)
  - [2C. BudgetLedger](#2c-budgetledger)
  - [2D. BudgetGate](#2d-budgetgate)
  - [2E. BudgetForecast](#2e-budgetforecast)
  - [2F. BudgetNotificationCenter](#2f-budgetnotificationcenter)
  - [2G. BudgetEnforcement (singleton wiring)](#2g-budgetenforcement-singleton-wiring)
- [3. SwiftUI View Adaptations for Mobile](#3-swiftui-view-adaptations-for-mobile)
  - [3A. BudgetSettingsView](#3a-budgetsettingsview)
  - [3B. BudgetRuleEditorSheet](#3b-budgetruleeditorsheet)
  - [3C. BudgetBlockedCard (chat layer)](#3c-budgetblockedcard-chat-layer)
  - [3D. BudgetStatusChip (Pulse tab)](#3d-budgetstatuschip-pulse-tab)
  - [3E. Credential and Project lane cards](#3e-credential-and-project-lane-cards)
  - [3F. Forecast projections in views](#3f-forecast-projections-in-views)
- [4. Firestore Sync (Cloud Budget Service)](#4-firestore-sync-cloud-budget-service)
- [5. Gate Insertion at the Chat Layer](#5-gate-insertion-at-the-chat-layer)
- [6. Local Notifications](#6-local-notifications)
- [7. Key Invariants](#7-key-invariants)
- [8. Testing Patterns](#8-testing-patterns)
- [9. Reference File Map](#9-reference-file-map)
- [10. SwiftUI Correctness Checklist](#10-swiftui-correctness-checklist)

---

## Summary

Port the enterprise budgeting, forecasting, and hard spending limits feature from macOS (`AgentLens/`) to iOS (`OpenBurnBarMobile/`). The shared data models already live in [`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/BudgetRule.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/BudgetRule.swift), so iOS gets every type for free. The port needs:

1. **Database schema** — `budget_rules` + `budget_events` tables (GRDB migration matching macOS v42)
2. **6 data stores** — `BudgetRulesStore`, `BudgetSettings`, `BudgetLedger`, `BudgetGate`, `BudgetForecast`, `BudgetNotificationCenter`
3. **Wiring singleton** — `BudgetEnforcement` (process-wide entry point)
4. **SwiftUI views** — adapted for compact-width mobile navigation (`NavigationStack`, sheets, `Tab`-based routing)
5. **Firestore sync** — extend `FirestoreRepository` / add `CloudBudgetService` for cross-device rule persistence
6. **Gate insertion** — pre-request evaluation in `CLIAgentRelayChatTransport` / `HermesService`
7. **Local notifications** — `UNUserNotificationCenter` for 80% warnings and 100% blocks
8. **Tests** — unit, snapshot, and integration

---

## 1. Shared Models (OpenBurnBarCore — already available)

These types are defined in [`BudgetRule.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/BudgetRule.swift) and are already compiled into the iOS target via the `OpenBurnBarCore` SPM dependency. **No changes needed.**

| Type | Role | Key properties |
|------|------|---------------|
| `BudgetRuleScope` | Enum: `.credential`, `.project`, `.global`, `.organization` | `CaseIterable`, `Codable`, `Hashable`, `Sendable` |
| `BudgetPeriod` | Enum: `.day`, `.week`, `.month`, `.allTime` | `windowStart(reference:)`, `nextReset(reference:)` |
| `BudgetBehavior` | Enum: `.warnThenBlock`, `.hardBlock`, `.warnOnly`, `.hardBlockWithFallback` | Default is `.warnThenBlock` |
| `BudgetBillingMode` | Enum: `.perUsage`, `.subscription`, `.unknown` | `billingMode(forSecretPrefix:)` static method |
| `BudgetRule` | Full spending-limit model: `Identifiable`, `Codable`, `Hashable`, `Sendable` | `id`, `scope`, `identifier`, `providerID`, `accountID`, `projectName`, `label`, `amountUSD`, `period`, `behavior`, `fallbackCredentialIDs: [String]`, `pausedUntil`, `createdAt`, `updatedAt`, `syncedAt`, `sourceDeviceID`, `isEnabled`, computed `displayLabel`, `isPaused(at:)` |
| `BudgetEventKind` | Enum: `.warning`, `.block`, `.override`, `.pause`, `.resume`, `.ruleCreated`, `.ruleUpdated`, `.ruleDeleted` | Audit log |
| `BudgetEvent` | Immutable audit row: `Identifiable`, `Codable`, `Hashable`, `Sendable` | `id`, `ruleID`, `kind`, `source`, `amountAtEvent`, `limitAtEvent`, `detailJSON`, `occurredAt`, `syncedAt`, `sourceDeviceID` |
| `BudgetCredentialIdentity` | Unified credential handle | `providerID`, `slotID`, `displayLabel`, `billingMode`; static `billingMode(forSecretPrefix:)` |
| `BudgetGateDecision` | Enum: `.allow`, `.warn(rule, usedPercent, used, limit)`, `.block(rule, used, limit, fallback?)`, `.paused(rule, resumeAt)` | Pure data — callers translate into UI or errors |

---

## 2. Data Stores to Port (6 total)

### Architecture note

The iOS app uses `@Observable @MainActor` classes for all stores (see [`DashboardStore`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Models/DashboardStore.swift), [`QuotaStore`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Models/QuotaStore.swift)). The macOS budget stores follow the **same pattern**. Port each one with the same `@Observable @MainActor final class` signature.

> [!IMPORTANT]
> Per the SwiftUI state management reference: `@Observable` classes should be marked `@MainActor` for thread safety with SwiftUI. Use `@State private var` when a view owns the store; use `@Bindable var` when a child needs bindings to the store's properties.

---

### 2A. BudgetRulesStore

**macOS source**: [`AgentLens/Services/DataStore/BudgetRulesStore.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetRulesStore.swift) (295 lines)
**iOS target**: `OpenBurnBarMobile/Models/BudgetRulesStore.swift`

SQLite CRUD against `budget_rules` and `budget_events`. **Pure GRDB** — no Firestore, no platform-specific code. The macOS version is `final class BudgetRulesStore: @unchecked Sendable` with a `DatabaseWriter` dependency.

**Port strategy**: Copy verbatim. iOS shares the same GRDB-backed `OpenBurnBar.sqlite` database and the same `DatabaseWriter` queue. The only precondition is the database migration (see below).

**Database migration**: Add `v42_budget_rules_and_events` to the iOS migration runner. The SQL is identical to macOS:

```swift
migrator.registerMigration("v42_budget_rules_and_events") { db in
    try db.create(table: "budget_rules") { t in
        t.column("id", .text).primaryKey()
        t.column("scope", .text).notNull()
        t.column("identifier", .text)
        t.column("providerID", .text)
        t.column("accountID", .text)
        t.column("projectName", .text)
        t.column("label", .text)
        t.column("amountUSD", .double).notNull()
        t.column("period", .text).notNull()
        t.column("behavior", .text).notNull()
        t.column("fallbackCredentialIDsJSON", .text)
        t.column("pausedUntil", .datetime)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("syncedAt", .datetime)
        t.column("sourceDeviceID", .text)
        t.column("isEnabled", .boolean).notNull().defaults(to: true)
    }
    try db.create(table: "budget_events") { t in
        t.column("id", .text).primaryKey()
        t.column("ruleID", .text).notNull()
        t.column("kind", .text).notNull()
        t.column("source", .text)
        t.column("amountAtEvent", .double).notNull().defaults(to: 0)
        t.column("limitAtEvent", .double).notNull().defaults(to: 0)
        t.column("detailJSON", .text)
        t.column("occurredAt", .datetime).notNull()
        t.column("syncedAt", .datetime)
        t.column("sourceDeviceID", .text)
    }
    // Indexes for gate query performance
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_rules_scope_idx ON budget_rules(scope, isEnabled)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_rules_provider_account_idx ON budget_rules(providerID, accountID, isEnabled)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_rules_project_idx ON budget_rules(projectName, isEnabled)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_rules_synced_idx ON budget_rules(syncedAt)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_events_rule_idx ON budget_events(ruleID, occurredAt DESC)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_events_kind_idx ON budget_events(kind, occurredAt DESC)")
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_events_synced_idx ON budget_events(syncedAt)")
}
```

**Key methods to port** (all operate on the `DatabaseWriter` queue):

| Method | Purpose |
|--------|---------|
| `upsertRule(_:)` | INSERT OR REPLACE with `syncedAt = NULL` on conflict |
| `deleteRule(id:)` | Hard delete by ID |
| `fetchAllRules(includeDisabled:)` | All enabled (or all) rules, `ORDER BY createdAt DESC` |
| `fetchRule(id:)` | Single rule lookup |
| `fetchRules(forCredential:accountID:)` | Credential-scoped rules for gate query |
| `fetchRules(forProject:)` | Project-scoped rules |
| `fetchGlobalRules()` | Global rules |
| `recordEvent(_:)` | Append audit event |
| `recentEvents(forRule:limit:)` | Recent events, optionally filtered by rule |
| `markEventSynced(_:)` | Set `syncedAt = Date()` after Firestore upload |

---

### 2B. BudgetSettings

**macOS source**: [`AgentLens/Services/DataStore/BudgetSettings.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetSettings.swift) (188 lines)
**iOS target**: `OpenBurnBarMobile/Models/BudgetSettings.swift`

Observable façade over `BudgetRulesStore`. Pattern: `@Observable @MainActor final class`. This is the **write entry point** for UI, Hermes, and MCP. Maintains an in-memory cache of all enabled rules refreshed on every write.

```swift
@Observable
@MainActor
final class BudgetSettings {
    private let store: BudgetRulesStore
    private let deviceID: String

    private(set) var rules: [BudgetRule] = []

    init(store: BudgetRulesStore, deviceID: String) { ... }

    // Writes — stamp updatedAt, clear syncedAt, record audit event
    @discardableResult
    func upsertRule(_ rule: BudgetRule, source: String = "settings_ui") -> BudgetRule { ... }
    func deleteRule(id: String, source: String = "settings_ui") { ... }
    func pauseRule(id: String, until: Date, source: String = "settings_ui") { ... }
    func resumeRule(id: String, source: String = "settings_ui") { ... }

    // Reads
    func rules(forCredential providerID: String, accountID: String?) -> [BudgetRule] { ... }
    func rules(forProject projectName: String) -> [BudgetRule] { ... }
    var primaryGlobalRule: BudgetRule? { ... }
    var globalRules: [BudgetRule] { ... }
    var credentialRules: [BudgetRule] { ... }
    var projectRules: [BudgetRule] { ... }
    var organizationRules: [BudgetRule] { ... }
    func recentEvents(forRule ruleID: String? = nil, limit: Int = 100) -> [BudgetEvent] { ... }
    func refresh() { ... }
}
```

**iOS-specific differences**:

- **No legacy migration**. macOS has `migrateLegacyCostAlertThresholdIfNeeded()` which converts an `AlertSettings.costAlertThreshold` `UserDefaults` value. iOS never had this setting, so **skip** this migration entirely.
- Wire into `OpenBurnBarMobileApp` at startup alongside other stores (see wiring section 2G).

> [!TIP]
> Views that bind to `BudgetSettings` properties use `@Bindable var budgetSettings: BudgetSettings` for two-way bindings. Read-only consumers use `let budgetSettings: BudgetSettings`.

---

### 2C. BudgetLedger

**macOS source**: [`AgentLens/Services/DataStore/BudgetLedger.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetLedger.swift) (88 lines)
**iOS target**: `OpenBurnBarMobile/Models/BudgetLedger.swift`

Swift `actor` that queries `token_usage` for running totals. The SQL is tight and indexed — a single `SELECT COALESCE(SUM(cost), 0) FROM token_usage WHERE ...` per rule.

```swift
actor BudgetLedger {
    private let dbQueue: any DatabaseWriter

    func currentSpend(forRule rule: BudgetRule, reference: Date = Date()) async throws -> Double { ... }
    func snapshot(forRules rules: [BudgetRule], reference: Date = Date()) async -> [String: Double] { ... }
}
```

**Port strategy**: Copy verbatim. iOS's `DashboardStore` already queries the same `token_usage` table through the same GRDB queue. The `BudgetLedger` SQL scopes by:

| Rule scope | SQL filter |
|-----------|-----------|
| `.credential` | `providerID = ? AND providerAccountID = ?` |
| `.project` | `projectName = ?` |
| `.global` | No additional filter (sums all rows) |
| `.organization` | `providerAccountLabel = ? OR providerAccountID = ?` |

All scopes add `startTime >= ? AND startTime <= ?` for the period window.

---

### 2D. BudgetGate

**macOS source**: [`AgentLens/Services/DataStore/BudgetGate.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetGate.swift) (154 lines)
**iOS target**: `OpenBurnBarMobile/Models/BudgetGate.swift`

Pure decision engine. `@MainActor final class` with no platform-specific code. Takes a `BudgetSettings` and `BudgetLedger` dependency, returns `BudgetGateDecision`.

```swift
@MainActor
final class BudgetGate {
    private let settings: BudgetSettings
    private let ledger: BudgetLedger
    private let warningThreshold: Double  // default 0.8

    func evaluate(
        credential: BudgetCredentialIdentity,
        projectName: String? = nil,
        estimatedCost: Double,
        reference: Date = Date()
    ) async -> BudgetGateDecision { ... }

    func rulesForContext() -> [BudgetRule] { ... }
    func ledgerSpend(forRule:reference:) async throws -> Double { ... }
}
```

**Port strategy**: Copy verbatim. The gate's `matchingRules` method queries `settings.rules(forCredential:accountID:)`, `settings.rules(forProject:)`, and `settings.globalRules` — all provided by the ported `BudgetSettings`.

**Decision classification logic** (critical — must match macOS exactly):

```
.warnOnly:       projectedPercent >= 80% → warn, always allow
.warnThenBlock:  projectedPercent >= 100% → block; >= 80% → warn; else allow
.hardBlock:      projectedPercent >= 100% → block; else allow
.hardBlockWithFallback: same as warnThenBlock but block includes fallback credential
```

Priority order: `allow(0) < paused(1) < warn(2) < block(3)`. The most restrictive decision across all matching rules wins.

Also port the `BudgetBlockedError` from the same file:

```swift
struct BudgetBlockedError: Error, LocalizedError, Sendable {
    let rule: BudgetRule
    let used: Double
    let limit: Double
    let fallback: BudgetCredentialIdentity?
    let resetAt: Date?
    var errorDescription: String? { ... }
}
```

---

### 2E. BudgetForecast

**macOS source**: [`AgentLens/Services/DataStore/BudgetForecast.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetForecast.swift) (148 lines)
**iOS target**: `OpenBurnBarMobile/Models/BudgetForecast.swift`

Swift `actor` that produces forward projections. Answers "at the current burn rate, when will this rule's running spend cross the limit?"

```swift
actor BudgetForecast {
    struct Projection: Hashable, Sendable {
        let ruleID: String
        let currentSpend: Double
        let limit: Double
        let trailingDailyAverage: Double
        let daysUntilLimit: Double?
        let projectedAtPeriodEnd: Double
        let generatedAt: Date

        var willExceed: Bool { ... }
        var headroom: Double { ... }
        var usedPercent: Double { ... }
        func projectedHitDate(calendar:) -> Date? { ... }
    }

    func forecast(forRule:reference:) async -> Projection { ... }
}
```

**Port strategy**: Copy verbatim. Uses the same `token_usage` SQL as `BudgetLedger`. Linear extrapolation: 7-day trailing daily average → projected days until limit.

> [!NOTE]
> iOS already has [`VelocityForecastStore`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Models/VelocityForecastStore.swift) (3.5 KB) which does similar forward projections for the Insights tab. The budget forecast is **separate** — it's rule-scoped (per-rule projections) while velocity forecast is provider-scoped. Don't merge them; the `BudgetForecast` is simpler and self-contained.

---

### 2F. BudgetNotificationCenter

**macOS source**: [`AgentLens/Services/DataStore/BudgetNotificationCenter.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetNotificationCenter.swift) (71 lines)
**iOS target**: `OpenBurnBarMobile/Services/BudgetNotificationCenter.swift`

`UNUserNotificationCenter`-based notifications. Debounces 80% warnings to one per `(rule, period)`. 100% blocks always fire.

```swift
@MainActor
final class BudgetNotificationCenter {
    func requestAuthorizationIfNeeded() { ... }
    func emitWarning(rule:used:limit:periodStart:) { ... }
    func emitBlock(rule:used:limit:) { ... }
    func resetWarningDebounce() { ... }
}
```

**Port strategy**: Copy verbatim — `UNUserNotificationCenter` is the same API on iOS and macOS. The only change is that iOS requires explicit authorization before first use. Call `requestAuthorizationIfNeeded()` during app startup wiring.

**iOS notification specifics** (see section 6 for full details):
- Request `.alert, .sound, .badge` authorization
- Warning uses `.default` sound
- Block uses `.defaultCritical` sound (attention-grabbing for budget breaches)
- Identifier format: `burnbar.budget.warn.{ruleID}.{periodStart}` and `burnbar.budget.block.{ruleID}.{timestamp}`

---

### 2G. BudgetEnforcement (singleton wiring)

**macOS source**: [`AgentLens/Services/DataStore/BudgetEnforcement.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetEnforcement.swift) (154 lines)
**iOS target**: `OpenBurnBarMobile/Models/BudgetEnforcement.swift`

Process-wide singleton that gate-aware call sites use. Before configuration, `evaluate()` returns `.allow` so test harnesses work.

```swift
@MainActor
final class BudgetEnforcement {
    static let shared = BudgetEnforcement()

    func configure(gate:notifications:forecast:) { ... }
    func evaluate(credential:projectName:estimatedCost:reference:) async -> BudgetGateDecision { ... }
    func budgetContextSection() async -> String? { ... }

    nonisolated static func estimateCost(model:inputCharacters:assumedOutputTokens:) -> Double { ... }
}
```

Also port `AgentLensCredentialIdentity` helper — it hashes a bearer token to produce a stable slot ID:

```swift
enum AgentLensCredentialIdentity {
    static func make(providerHint:bearerToken:displayLabel:) -> BudgetCredentialIdentity { ... }
}
```

**App startup wiring** — add to `AuthGateView` or wherever stores are initialized:

```swift
// After creating the GRDB database queue:
let budgetRulesStore = BudgetRulesStore(dbQueue: dbQueue)
let budgetSettings = BudgetSettings(store: budgetRulesStore, deviceID: localDeviceID)
let budgetLedger = BudgetLedger(dbQueue: dbQueue)
let budgetGate = BudgetGate(settings: budgetSettings, ledger: budgetLedger)
let budgetForecast = BudgetForecast(dbQueue: dbQueue)
let budgetNotifications = BudgetNotificationCenter()

BudgetEnforcement.shared.configure(
    gate: budgetGate,
    notifications: budgetNotifications,
    forecast: budgetForecast
)
```

> [!WARNING]
> `BudgetEnforcement.shared` is a `@MainActor` singleton. All access must be from the main actor. The `evaluate()` method is `async` because it awaits the `BudgetLedger` actor for spend queries.

---

## 3. SwiftUI View Adaptations for Mobile

### Design system

iOS uses [`AuroraDesign`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Theme/AuroraDesign.swift) and [`MobileTheme`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Theme/MobileTheme.swift) tokens. macOS uses `DesignSystem.Colors.*`. The mapping:

| macOS (`DesignSystem.Colors`) | iOS (`AuroraDesign` / `MobileTheme`) |
|------|------|
| `.error` | `AuroraDesign.error` or `MobileTheme.error` |
| `.warning` | `AuroraDesign.warning` |
| `.success` | `AuroraDesign.success` |
| `.coral` | `AuroraDesign.coral` |
| `.purple` | `AuroraDesign.purple` |
| `.surface` | `AuroraDesign.surface` |
| `.textPrimary` | `AuroraDesign.textPrimary` |
| `.textSecondary` | `AuroraDesign.textSecondary` |
| `.textMuted` | `AuroraDesign.textMuted` |
| `.background` | `AuroraDesign.background` |
| `DesignSystem.Radius.md` | `AuroraDesign.Radius.md` |

### Navigation context

The iOS app uses `RootTabView` with tabs: Dashboard, Quota, Activity, Account. Budget settings live under the **Account → Settings** flow. The tab structure (per iOS app architecture) uses `NavigationStack` per tab.

---

### 3A. BudgetSettingsView

**macOS source**: [`AgentLens/Views/Settings/BudgetSettingsView.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Views/Settings/BudgetSettingsView.swift) (457 lines)
**iOS target**: `OpenBurnBarMobile/Settings/BudgetSettingsView.swift`

**Adaptations for mobile**:

| macOS pattern | iOS replacement | Why |
|--------------|-----------------|-----|
| `SettingsDeepLinkScrollContainer(route:)` | Remove — iOS uses `NavigationStack` push | macOS-only container |
| `NavigationLink { destination } label: { row }` | `NavigationLink(value:) { row }` + `.navigationDestination(for:)` | Type-safe navigation (iOS 16+) |
| `.listStyle(.inset)` | `.listStyle(.insetGrouped)` | Standard iOS settings style |
| `@Bindable var budgetSettings: BudgetSettings` | Same — `@Bindable` is correct since the parent owns it | |
| `.sheet(item: $showingAddSheet)` | Same — enum-based sheet management | |

**Skeleton**:

```swift
struct BudgetSettingsView: View {
    @Bindable var budgetSettings: BudgetSettings

    @State private var showingAddSheet: AddRuleScope?

    var body: some View {
        List {
            introSection
            globalSection
            credentialSection
            projectSection
            eventsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Budgets")
        .sheet(item: $showingAddSheet) { scope in
            BudgetRuleEditorSheet(budgetSettings: budgetSettings, rule: ...)
        }
    }
}
```

**Subviews to extract** (follow SwiftUI view-structure reference — extract subviews, not computed properties):

1. `BudgetRuleRow` — identical to macOS, fully portable
2. `BudgetEventRow` — identical to macOS, fully portable
3. `BudgetRuleEditorView` — push destination for existing rules
4. `BudgetRuleEditorSheet` — sheet for new rules (already a sheet — minimal changes)

> [!TIP]
> `BudgetRuleRow` and `BudgetEventRow` are POD views (plain old data — `let` properties only). They get the fastest `memcmp`-based diffing. Keep them simple and extracted.

---

### 3B. BudgetRuleEditorSheet

**macOS source**: Same file, `BudgetRuleEditorSheet` struct (lines 392–456)
**iOS target**: Same file or `OpenBurnBarMobile/Settings/BudgetRuleEditorSheet.swift`

**Already a `NavigationStack` + `Form` + toolbar sheet** — minimal changes needed:

```swift
struct BudgetRuleEditorSheet: View {
    @Bindable var budgetSettings: BudgetSettings
    @State var rule: BudgetRule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { ... }
                .navigationTitle("New rule")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { ... } }
                }
        }
    }
}
```

> [!IMPORTANT]
> **Correctness**: `@State var rule: BudgetRule` is correct here because the sheet **creates** a new local copy of the rule. The view **owns** this copy. It does NOT receive it from a parent — it receives an initial value to seed the form. After saving, `budgetSettings.upsertRule(rule)` persists the edited copy.

---

### 3C. BudgetBlockedCard (chat layer)

**macOS source**: [`AgentLens/Views/Chat/BudgetBlockedCard.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Views/Chat/BudgetBlockedCard.swift) (167 lines)
**iOS target**: `OpenBurnBarMobile/Views/Chat/BudgetBlockedCard.swift`

Renders as an inline card in the Hermes chat view when `BudgetGate.evaluate` returns `.block`.

**Adaptations**:

| macOS pattern | iOS replacement |
|--------------|-----------------|
| `DesignSystem.Colors.*` | `AuroraDesign.*` tokens |
| `DesignSystem.Radius.md` | `AuroraDesign.Radius.md` |
| `.help("Open Budget Settings")` | Remove — no tooltip on iOS; use `.accessibilityHint()` instead |
| `@State private var hover = false` + `.onHover` | Remove — no hover on iOS |
| `.buttonStyle(.plain)` | Keep — prevents default iOS button styling on action buttons |

**Structure** (identical to macOS but with iOS color tokens):

```
HStack
  ├─ Image(systemName: "xmark.octagon.fill") — error tint
  └─ VStack
       ├─ header: "Budget limit reached" + rule.displayLabel
       ├─ details: "$used of $limit per period" + reset date
       └─ actionButtons: [+$25] [Allow session] [⚙]
```

Three action callbacks: `onRaiseLimit`, `onAllowSession`, `onOpenSettings`.

---

### 3D. BudgetStatusChip (Pulse tab)

**macOS source**: [`AgentLens/Views/Dashboard/Components/BurnRailBudgetChip.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Views/Dashboard/Components/BurnRailBudgetChip.swift) (125 lines)
**iOS target**: `OpenBurnBarMobile/Views/Pulse/BudgetStatusChip.swift`

Compact pill showing the most restrictive rule's used/limit. Visible only when any rule ≥ 50% used.

**Adaptations**:

| macOS pattern | iOS replacement |
|--------------|-----------------|
| `.onHover { hover = $0 }` | Remove — no hover on iOS |
| `.help(toolTip(...))` | Remove — use `.accessibilityLabel()` only |
| `DesignSystem.Animation.hover` | `animation(.easeOut(duration: 0.15), value: ...)` or remove |

**Threshold tints** (keep identical):
- `< 50%`: hidden
- `50–79%`: secondary text color
- `80–99%`: warning amber
- `≥ 100%`: error red

Place in the Dashboard/Pulse tab header area beside existing summary cards.

---

### 3E. Credential and Project lane cards

**macOS sources**:
- `AgentLens/Views/Dashboard/DashboardCredentialLaneView.swift`
- `AgentLens/Views/Dashboard/DashboardProjectSpendLaneView.swift`

**iOS targets**:
- `OpenBurnBarMobile/Views/Pulse/CredentialLaneCard.swift`
- `OpenBurnBarMobile/Views/Pulse/ProjectSpendLaneCard.swift`

Use the existing `AuroraGlassCard` pattern from the iOS app. Horizontal scroll cards in the Dashboard/Pulse tab.

---

### 3F. Forecast projections in views

The `BudgetForecast.Projection` struct provides `willExceed`, `headroom`, `usedPercent`, and `projectedHitDate()`. Display in `BudgetRuleRow` and `BudgetSettingsView`:

```swift
// In BudgetRuleRow, after the amount:
if let projection = forecasts[rule.id], let hitDate = projection.projectedHitDate() {
    Text("Projected hit: \(hitDate.formatted(date: .abbreviated, time: .omitted))")
        .font(.caption2)
        .foregroundStyle(projection.willExceed ? AuroraDesign.warning : AuroraDesign.textMuted)
}
```

> [!TIP]
> **Performance**: Don't call `forecast(forRule:)` inside the view body. Instead, compute forecasts in a `.task { }` modifier or on the store, cache them as `[String: BudgetForecast.Projection]`, and pass the dictionary to row views as a `let` property. This avoids async work in the render path.

---

## 4. Firestore Sync (Cloud Budget Service)

**macOS source**: [`AgentLens/Services/CloudBudgetService.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/CloudBudgetService.swift) (218 lines)
**iOS target**: `OpenBurnBarMobile/Services/CloudBudgetService.swift`
**Alternative**: Extend [`FirestoreRepository`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/FirestoreRepository.swift) with budget-specific methods.

**Firestore layout**:
```
users/{uid}/budgetRules/{ruleId}    — rules synced bidirectionally
users/{uid}/budgetEvents/{eventId}  — events uploaded (append-only, no download needed)
```

**Upload flow** (same as macOS):
1. Query `budget_rules WHERE syncedAt IS NULL` → push to Firestore
2. Mark local rows as synced (`syncedAt = Date()`)
3. Query `budget_events WHERE syncedAt IS NULL LIMIT 500` → push to Firestore
4. Mark synced via `budgetRulesStore.markEventSynced(eventID)`

**Download flow**:
1. Query Firestore `budgetRules` where `sourceDeviceID != localDeviceID`
2. For each remote rule: if not local → insert; if local but remote `updatedAt > local.updatedAt` → overwrite
3. Call `budgetSettings.refresh()` to reload the in-memory cache

**Conflict resolution**: Last-write-wins on `updatedAt`.

**Integration point**: Call `downloadRemoteBudgetRules()` during the existing Firestore sync cycle (alongside usage rollup and quota snapshot downloads).

---

## 5. Gate Insertion at the Chat Layer

iOS doesn't have a daemon HTTP gateway. The gate inserts **before** the request is sent:

### Primary insertion: `CLIAgentRelayChatTransport` / `HermesService`

In [`CLIAgentRelayChatTransport`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/CLIAgentRelayChatTransport.swift) or [`HermesService`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/HermesService.swift), before sending the request:

```swift
// Before the request is dispatched:
let credential = AgentLensCredentialIdentity.make(
    providerHint: providerID,
    bearerToken: bearerToken,
    displayLabel: credentialLabel
)
let estimatedCost = BudgetEnforcement.estimateCost(
    model: modelName,
    inputCharacters: prompt.count
)
let decision = await BudgetEnforcement.shared.evaluate(
    credential: credential,
    projectName: projectName,
    estimatedCost: estimatedCost
)

switch decision {
case .block(let rule, let used, let limit, let fallback):
    throw BudgetBlockedError(
        rule: rule,
        used: used,
        limit: limit,
        fallback: fallback,
        resetAt: rule.period.nextReset()
    )
case .warn(let rule, let usedPercent, let used, let limit):
    // Attach warning context to the response stream
    // The notification is already fired by BudgetEnforcement.evaluate()
    break
case .allow, .paused:
    break
}
```

### Error rendering in chat

Catch `BudgetBlockedError` in the chat view's error handling and render `BudgetBlockedCard`:

```swift
if let budgetError = error as? BudgetBlockedError {
    BudgetBlockedCard(
        error: budgetError,
        onRaiseLimit: { rule, amount in
            var updated = rule
            updated.amountUSD += amount
            budgetSettings.upsertRule(updated, source: "chat_raise")
        },
        onAllowSession: { rule in
            // Pause for 1 hour (session override)
            budgetSettings.pauseRule(
                id: rule.id,
                until: Date().addingTimeInterval(3600),
                source: "chat_override"
            )
        },
        onOpenSettings: {
            // Navigate to BudgetSettingsView
        }
    )
}
```

### Context injection for Hermes

[`HermesService`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/HermesService.swift) builds system prompts. Add the budget context section alongside existing context:

```swift
if let budgetContext = await BudgetEnforcement.shared.budgetContextSection() {
    systemPrompt += "\n\n" + budgetContext
}
```

This renders a Markdown section like:
```
## Budgets & per-usage credentials
- OpenRouter main: $42.00 of $50.00 this month (84%)
- All per-usage credentials: $127.00 of $200.00 this month (63%)
```

---

## 6. Local Notifications

### Authorization

Request on app startup (in `BudgetEnforcement.configure`):

```swift
func requestAuthorizationIfNeeded() {
    Task { @MainActor in
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            authorized = false
        }
    }
}
```

### Notification content

| Threshold | Title | Sound | Debouncing |
|-----------|-------|-------|-----------|
| 80% warn | "Budget warning · {displayLabel}" | `.default` | One per `(ruleID, periodStart)` — reset when period rolls |
| 100% block | "Budget reached · {displayLabel}" | `.defaultCritical` | Always fire |

### Delivery

Use `UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)` for immediate delivery. Identifiers include rule ID and timestamp for deduplication.

### Deep linking (future polish)

Register a `UNNotificationCategory` with custom actions ("Raise +$25", "Open Budgets") so the user can act directly from the notification. This is a polish item — v1 ships without it.

---

## 7. Key Invariants

1. **Subscription credentials are exempt.** `BudgetCredentialIdentity.billingMode(forSecretPrefix:)` returns `.subscription` for `sk-ant-oat*` keys. The gate short-circuits to `.allow` — Claude Pro/Max OAuth keys are never blocked.

2. **80% warn, 100% block** is the default behavior (`warnThenBlock`). This matches the Phase 4 decision.

3. **Local pricing for gate, billing API for nightly truth-up.** The gate uses locally-computed `cost` from `token_usage` rows. Drift detection (>5%) runs during the nightly `BillingRefreshCoordinator` cycle.

4. **Hermes/MCP have full read+write+pause authority.** The MCP server (`tools/openburnbar-mcp/server.py`) already has all 7 budget tools. No iOS changes needed.

5. **Cross-device sync via Firestore.** Budget rules and events sync under `users/{uid}/budgetRules/` and `users/{uid}/budgetEvents/`. Conflict resolution is "last write wins" on `updatedAt`.

6. **`BudgetEnforcement.shared` returns `.allow` before configuration.** This ensures test harnesses and detached flows never block unexpectedly.

---

## 7.5. Known Gaps to Address During Port

> [!CAUTION]
> These gaps exist on macOS today. The iOS port should fix them.

### Gap 1: Missing Firestore Security Rules

`CloudBudgetService.swift` writes to `users/{uid}/budgetRules/` and `users/{uid}/budgetEvents/`, but these collections have **no explicit match blocks** in [`firestore.rules`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/firestore.rules). They may fall through to a catch-all deny. Add:

```javascript
match /users/{userId}/budgetRules/{ruleId} {
  allow read, write: if request.auth != null && request.auth.uid == userId;
}
match /users/{userId}/budgetEvents/{eventId} {
  allow read: if request.auth != null && request.auth.uid == userId;
  allow create: if request.auth != null && request.auth.uid == userId;
  // Events are append-only — no update/delete from client
}
```

### Gap 2: Missing TypeScript Schema

`functions/src/types.ts` has no `BudgetRuleDoc` or `BudgetEventDoc` interfaces, even though Firestore collections exist. The Swift `BudgetRule` model in OpenBurnBarCore is the de facto schema. Add TypeScript mirrors to `types.ts` for consistency.

### Gap 3: Zero macOS Unit Tests for Budget Stack

No tests exist for `BudgetGate`, `BudgetLedger`, `BudgetEnforcement`, `BudgetForecast`, `BudgetRulesStore`, or `CloudBudgetService` in `AgentLensTests/`. The iOS port test suite (§8) will be the **first** tests for this logic.

### Gap 4: Existing SettingsHubView Budget Slider

[`SettingsHubView`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Views/You/SettingsHubView.swift) (lines 183–217) already has a "daily budget" slider and cost/token alert toggles using `@AppStorage`. These are UI-only — no enforcement exists. When porting, **replace** these with a `NavigationLink` to the full `BudgetSettingsView`, and run a one-time migration that converts the `@AppStorage("dailyBudget")` value into a `BudgetRule(scope: .global, period: .day, behavior: .warnOnly)` if it's non-zero.

---

## 8. Testing Patterns

### Unit tests — `OpenBurnBarMobileTests/`

| Test | What to verify |
|------|---------------|
| `BudgetGateTests` | `evaluate()` with synthetic rules and spend amounts: allow, warn at 80%, block at 100%, subscription exempt, paused rule, multi-rule worst-case |
| `BudgetLedgerTests` | `currentSpend()` against known `token_usage` fixtures: day/week/month/allTime windows, credential/project/global scopes |
| `BudgetSettingsTests` | `upsertRule` stamps `updatedAt`, clears `syncedAt`, records audit event; `deleteRule` records `.ruleDeleted` event; `pauseRule`/`resumeRule` toggle `pausedUntil` |
| `BudgetForecastTests` | `forecast()` linear projection: known trailing spend → expected `daysUntilLimit` and `projectedAtPeriodEnd` |
| `BudgetCredentialIdentityTests` | `billingMode(forSecretPrefix:)`: `sk-ant-oat*` → subscription, `sk-ant-api*` → perUsage, `sk-*` → perUsage, other → unknown |

### Snapshot tests

| View | Configurations |
|------|---------------|
| `BudgetSettingsView` | Light + dark, empty rules, populated rules |
| `BudgetBlockedCard` | Light + dark, with/without reset date |
| `BudgetStatusChip` | 60% (neutral), 85% (warning), 105% (blocked) |
| `BudgetRuleRow` | Each scope (global, credential, project, org) |

### Integration test

1. Set a `$0.01/day` global rule via `BudgetSettings`
2. Insert a `token_usage` row with `cost = 0.02` for today
3. Call `BudgetEnforcement.shared.evaluate(...)` with `estimatedCost = 0.001`
4. Assert the decision is `.block`
5. Assert `BudgetNotificationCenter` would fire a block notification (mock the center)

### Test infrastructure

- Use an in-memory GRDB database (`DatabaseQueue()`) for all store tests
- Run the `v42_budget_rules_and_events` migration on the in-memory DB
- Mock `BudgetLedger` for `BudgetGate` tests to control spend amounts
- Mock `UNUserNotificationCenter` for notification tests

---

## 9. Reference File Map

| Purpose | macOS path | iOS port target | Notes |
|---------|-----------|----------------|-------|
| Shared models | [`OpenBurnBarCore/.../BudgetRule.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/BudgetRule.swift) | Already in iOS target | No changes |
| Database migration | [`OpenBurnBarDatabase.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/OpenBurnBarDatabase.swift) (search `v42_budget_rules_and_events`) | iOS migration runner | Copy SQL verbatim |
| CRUD store | [`BudgetRulesStore.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetRulesStore.swift) | `Models/BudgetRulesStore.swift` | Copy verbatim |
| Observable settings | [`BudgetSettings.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetSettings.swift) | `Models/BudgetSettings.swift` | Skip legacy migration |
| Ledger (SQL actor) | [`BudgetLedger.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetLedger.swift) | `Models/BudgetLedger.swift` | Copy verbatim |
| Gate (decision engine) | [`BudgetGate.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetGate.swift) | `Models/BudgetGate.swift` | Copy verbatim |
| Forecast (projections) | [`BudgetForecast.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetForecast.swift) | `Models/BudgetForecast.swift` | Copy verbatim |
| Notifications | [`BudgetNotificationCenter.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetNotificationCenter.swift) | `Services/BudgetNotificationCenter.swift` | Same UNUserNotification API |
| Enforcement entry | [`BudgetEnforcement.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/DataStore/BudgetEnforcement.swift) | `Models/BudgetEnforcement.swift` | Wire into app startup |
| Settings view | [`BudgetSettingsView.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Views/Settings/BudgetSettingsView.swift) | `Settings/BudgetSettingsView.swift` | `.insetGrouped`, remove `SettingsDeepLinkScrollContainer` |
| Error card | [`BudgetBlockedCard.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Views/Chat/BudgetBlockedCard.swift) | `Views/Chat/BudgetBlockedCard.swift` | Replace `DesignSystem` → `AuroraDesign`, remove hover |
| Budget chip | [`BurnRailBudgetChip.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Views/Dashboard/Components/BurnRailBudgetChip.swift) | `Views/Pulse/BudgetStatusChip.swift` | Remove hover, replace tokens |
| Cloud sync | [`CloudBudgetService.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/CloudBudgetService.swift) | `Services/CloudBudgetService.swift` | Adapt to iOS `FirestoreRepository` |
| Chat transport | [`CLIAgentRelayChatTransport.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/CLIAgentRelayChatTransport.swift) | Modify in-place | Add pre-request gate call |
| Hermes context | [`HermesService.swift`](file:///Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/HermesService.swift) | Modify in-place | Add `budgetContextSection()` to system prompt |
| Design tokens | `DesignSystem.Colors.*` | `AuroraDesign.*` / `MobileTheme.*` | See mapping table in §3 |

---

## 10. SwiftUI Correctness Checklist

Per the SwiftUI Expert Skill correctness rules — verify these after porting:

- [ ] All `@State` properties are `private`
- [ ] `@Binding` only where a child modifies parent state
- [ ] Passed values never declared as `@State` or `@StateObject` (they ignore updates)
- [ ] `@Bindable var budgetSettings: BudgetSettings` for injected `@Observable` objects needing bindings
- [ ] `ForEach` uses stable identity (`BudgetRule.id`, `BudgetEvent.id` — both `String`)
- [ ] `.animation(_:value:)` always includes the `value` parameter
- [ ] No `NavigationView` — use `NavigationStack` exclusively
- [ ] No `foregroundColor(_:)` — use `foregroundStyle(_:)`
- [ ] No `cornerRadius(_:)` — use `clipShape(.rect(cornerRadius:))`
- [ ] No `onChange(of:) { newValue in }` — use `onChange(of:) { }` or `onChange(of:) { old, new in }`
- [ ] No `accentColor(_:)` — use `tint(_:)`
- [ ] No `onTapGesture` for primary actions — use `Button`
- [ ] Sheets use `.sheet(item:)` not `.sheet(isPresented:)` when presenting model data
- [ ] Sheets own their dismiss via `@Environment(\.dismiss)`
- [ ] No heavy computation in view body — forecasts computed in `.task {}` and cached
- [ ] Complex views extracted to separate structs (not `@ViewBuilder` computed properties)
- [ ] `@Observable` classes marked `@MainActor`
- [ ] `.compositingGroup()` before `.clipShape()` on layered views with overlays
- [ ] Accessibility labels on all interactive elements
- [ ] Dynamic Type supported (no fixed font sizes)
