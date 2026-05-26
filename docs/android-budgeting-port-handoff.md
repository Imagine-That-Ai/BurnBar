# Android Budgeting Port — Handoff

## Summary

Port the enterprise budgeting, forecasting, and hard spending limits feature to the Android app (`android/app/src/main/java/com/openburnbar/`). The canonical schema lives in `functions/src/types.ts` and the canonical models in `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/BudgetRule.swift`. Android needs Kotlin data classes mirroring those types, a Room DAO for `budget_rules`/`budget_events`, a settings UI in Compose, and Firestore sync for cross-device rule persistence.

## What Already Exists (Cross-Platform)

| Component | Location | Android status |
|---|---|---|
| Firestore schema for `usage`, `usage_rollups`, `quota_snapshots` | `functions/src/types.ts` | Android already reads these via `FirestoreRepository` |
| `TokenUsage` model | `android/.../data/models/TokenUsage.kt` | Fully implemented with `@IgnoreExtraProperties` + `@PropertyName` |
| `DashboardStore` | `android/.../data/stores/DashboardStore.kt` | Reads Firestore `UsageRollups` |
| `VelocityForecastStore` (mobile) | `OpenBurnBarMobile/Models/VelocityForecastStore.swift` | iOS-only; Android has no equivalent yet |
| MCP budget tools | `tools/openburnbar-mcp/server.py` | Platform-agnostic; reads SQLite directly. No Android port needed. |
| Firestore `sourceDeviceID` + `sourceDeviceName` on usage rows | Already synced | Android writes these; macOS reads them for org rollup |

## What Needs Building

### 1. Kotlin Data Classes

Create `android/app/src/main/java/com/openburnbar/data/models/BudgetModels.kt`:

```kotlin
@IgnoreExtraProperties
data class BudgetRule(
    val id: String = "",
    val scope: String = "",          // credential, project, global, organization
    val identifier: String? = null,
    val providerID: String? = null,
    val accountID: String? = null,
    val projectName: String? = null,
    val label: String? = null,
    val amountUSD: Double = 0.0,
    val period: String = "",          // day, week, month, allTime
    val behavior: String = "",        // warnThenBlock, hardBlock, warnOnly, hardBlockWithFallback
    val fallbackCredentialIDsJSON: String? = null,
    val pausedUntil: Date? = null,
    val createdAt: Date? = null,
    val updatedAt: Date? = null,
    val syncedAt: Date? = null,
    val sourceDeviceID: String? = null,
    val isEnabled: Boolean = true
) {
    val displayLabel: String
        get() = when {
            !label.isNullOrBlank() -> label
            scope == "credential" -> "${providerID ?: "credential"} · ${accountID?.takeLast(6) ?: "default"}"
            scope == "project" -> projectName ?: "Unnamed project"
            scope == "global" -> "All per-usage credentials"
            scope == "organization" -> identifier ?: "Organization"
            else -> id
        }

    fun isPausedAt(reference: Date = Date()): Boolean =
        pausedUntil != null && pausedUntil!!.after(reference)
}

enum class BudgetRuleScope(val value: String) {
    CREDENTIAL("credential"),
    PROJECT("project"),
    GLOBAL("global"),
    ORGANIZATION("organization")
}

enum class BudgetPeriod(val value: String) {
    DAY("day"),
    WEEK("week"),
    MONTH("month"),
    ALL_TIME("allTime")
}

enum class BudgetBehavior(val value: String) {
    WARN_THEN_BLOCK("warnThenBlock"),
    HARD_BLOCK("hardBlock"),
    WARN_ONLY("warnOnly"),
    HARD_BLOCK_WITH_FALLBACK("hardBlockWithFallback")
}

enum class BudgetBillingMode(val value: String) {
    PER_USAGE("perUsage"),
    SUBSCRIPTION("subscription"),
    UNKNOWN("unknown");

    companion object {
        fun forSecretPrefix(prefix: String): BudgetBillingMode {
            val lower = prefix.lowercase()
            return when {
                lower.startsWith("sk-ant-oat") -> SUBSCRIPTION
                lower.startsWith("sk-ant-api") -> PER_USAGE
                lower.startsWith("sk-") -> PER_USAGE
                else -> UNKNOWN
            }
        }
    }
}

@IgnoreExtraProperties
data class BudgetEvent(
    val id: String = "",
    val ruleID: String = "",
    val kind: String = "",       // warning, block, override, pause, resume, ruleCreated, ruleUpdated, ruleDeleted
    val source: String? = null,
    val amountAtEvent: Double = 0.0,
    val limitAtEvent: Double = 0.0,
    val detailJSON: String? = null,
    val occurredAt: Date? = null,
    val syncedAt: Date? = null,
    val sourceDeviceID: String? = null
)

data class BudgetGateDecision(
    val kind: Kind,
    val rule: BudgetRule? = null,
    val usedPercent: Double = 0.0,
    val used: Double = 0.0,
    val limit: Double = 0.0,
    val fallback: BudgetCredentialIdentity? = null,
    val resumeAt: Date? = null
) {
    enum class Kind { ALLOW, WARN, BLOCK, PAUSED }
}

data class BudgetCredentialIdentity(
    val providerID: String,
    val slotID: String,
    val displayLabel: String,
    val billingMode: BudgetBillingMode
)
```

### 2. Room DAO + Database Migration

Add two new tables to the existing Room database. In the `AppDatabase` class (or wherever the Room database is defined), add:

```kotlin
@Entity(tableName = "budget_rules", indices = [
    Index(value = ["scope", "isEnabled"]),
    Index(value = ["providerID", "accountID", "isEnabled"]),
    Index(value = ["projectName", "isEnabled"]),
    Index(value = ["syncedAt"])
])
data class BudgetRuleEntity(
    @PrimaryKey val id: String,
    val scope: String,
    val identifier: String? = null,
    val providerID: String? = null,
    val accountID: String? = null,
    val projectName: String? = null,
    val label: String? = null,
    val amountUSD: Double,
    val period: String,
    val behavior: String,
    val fallbackCredentialIDsJSON: String? = null,
    val pausedUntil: Long? = null, // epoch millis
    val createdAt: Long,
    val updatedAt: Long,
    val syncedAt: Long? = null,
    val sourceDeviceID: String? = null,
    val isEnabled: Boolean = true
)

@Entity(tableName = "budget_events", indices = [
    Index(value = ["ruleID", "occurredAt"]),
    Index(value = ["kind", "occurredAt"]),
    Index(value = ["syncedAt"])
])
data class BudgetEventEntity(
    @PrimaryKey val id: String,
    val ruleID: String,
    val kind: String,
    val source: String? = null,
    val amountAtEvent: Double = 0.0,
    val limitAtEvent: Double = 0.0,
    val detailJSON: String? = null,
    val occurredAt: Long,
    val syncedAt: Long? = null,
    val sourceDeviceID: String? = null
)

@Dao
interface BudgetDao {
    @Query("SELECT * FROM budget_rules WHERE isEnabled = 1 ORDER BY createdAt DESC")
    fun getAllEnabledRules(): List<BudgetRuleEntity>

    @Query("SELECT * FROM budget_rules WHERE scope = 'credential' AND providerID = :providerID AND (accountID IS NULL OR accountID = '' OR accountID = :accountID) AND isEnabled = 1")
    fun getCredentialRules(providerID: String, accountID: String?): List<BudgetRuleEntity>

    @Query("SELECT * FROM budget_rules WHERE scope = 'project' AND projectName = :projectName AND isEnabled = 1")
    fun getProjectRules(projectName: String): List<BudgetRuleEntity>

    @Query("SELECT * FROM budget_rules WHERE scope = 'global' AND isEnabled = 1")
    fun getGlobalRules(): List<BudgetRuleEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertRule(rule: BudgetRuleEntity)

    @Query("DELETE FROM budget_rules WHERE id = :id")
    fun deleteRule(id: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertEvent(event: BudgetEventEntity)

    @Query("SELECT * FROM budget_events WHERE ruleID = :ruleID ORDER BY occurredAt DESC LIMIT :limit")
    fun getEventsForRule(ruleID: String, limit: Int = 100): List<BudgetEventEntity>

    @Query("SELECT * FROM budget_events ORDER BY occurredAt DESC LIMIT :limit")
    fun getRecentEvents(limit: Int = 100): List<BudgetEventEntity>
}
```

### 3. BudgetGate (Pure Logic)

```kotlin
// android/.../data/budget/BudgetGate.kt
class BudgetGate(
    private val dao: BudgetDao,
    private val warningThreshold: Double = 0.8
) {
    data class EvaluateResult(
        val decision: BudgetGateDecision.Kind,
        val rule: BudgetRuleEntity? = null,
        val used: Double = 0.0,
        val limit: Double = 0.0,
        val usedPercent: Double = 0.0,
        val fallback: BudgetCredentialIdentity? = null,
        val resumeAt: Date? = null
    )

    suspend fun evaluate(
        credential: BudgetCredentialIdentity,
        projectName: String? = null,
        estimatedCost: Double,
        reference: Date = Date()
    ): EvaluateResult {
        if (credential.billingMode == BudgetBillingMode.SUBSCRIPTION) {
            return EvaluateResult(BudgetGateDecision.Kind.ALLOW)
        }
        val candidates = mutableListOf<BudgetRuleEntity>()
        candidates.addAll(dao.getCredentialRules(credential.providerID, credential.slotID))
        if (!projectName.isNullOrBlank()) {
            candidates.addAll(dao.getProjectRules(projectName))
        }
        candidates.addAll(dao.getGlobalRules())
        val activeRules = candidates.filter { it.isEnabled && it.amountUSD > 0 }
        if (activeRules.isEmpty()) return EvaluateResult(BudgetGateDecision.Kind.ALLOW)

        var worst = EvaluateResult(BudgetGateDecision.Kind.ALLOW)
        for (rule in activeRules) {
            if (rule.isPausedAt(reference)) {
                val paused = EvaluateResult(BudgetGateDecision.Kind.PAUSED, rule = rule, resumeAt = rule.pausedUntil)
                worst = if (priority(paused.decision) > priority(worst.decision)) paused else worst
                continue
            }
            val used = currentSpendForRule(rule, reference)
            val projected = used + max(0.0, estimatedCost)
            val decision = classify(rule, used, projected)
            worst = if (priority(decision.decision) > priority(worst.decision)) decision else worst
        }
        return worst
    }

    // currentSpendForRule queries token_usage via DAO
    // classify mirrors the Swift BudgetGate.classify logic
    // priority(ALLOW=0, PAUSED=1, WARN=2, BLOCK=3)
}
```

### 4. Compose UI — Settings

Create `android/.../ui/settings/BudgetSettingsScreen.kt`:

- Top section: intro text ("Per-usage credentials get hard blocks when a rule is exceeded. Subscription credentials are exempt.")
- Global section: list of global rules with NavigationLink to editor
- Credential section: list of credential-scoped rules
- Project section: list of project-scoped rules
- Events footer: recent audit log

Use the existing `AuroraDesign` tokens for colors. Follow the pattern in `SettingsManifest.kt` for navigation.

### 5. Compose UI — Budget Blocked Card

When `BudgetGate.evaluate` returns `BLOCK`, render an inline card in the chat view (inside `HermesRichBubble.kt` or equivalent):

```kotlin
@Composable
fun BudgetBlockedCard(
    rule: BudgetRuleEntity,
    used: Double,
    limit: Double,
    onRaiseLimit: (BudgetRuleEntity, Double) -> Unit,
    onAllowSession: (BudgetRuleEntity) -> Unit,
    onOpenSettings: () -> Unit
) {
    // AuroraDesign.Card surface + error-tinted border
    // Icon: xmark.octagon.fill, designSystem color error
    // Title: "Budget limit reached"
    // Subtitle: rule.displayLabel
    // Detail: "$used of $limit per month"
    // Three buttons: +$25 (coral), Allow session (purple), Settings (textMuted)
}
```

### 6. Budget Status Chip (Pulse Tab)

Compact pill in the `PulseView` header area, mirroring the macOS `BurnRailBudgetChip`:

```kotlin
@Composable
fun BudgetStatusChip(rules: List<BudgetRuleEntity>, spendByRule: Map<String, Double>) {
    // Show only when any rule >= 50% used
    // 80%+: warning amber tint
    // 100%+: error red tint
    // Format: "$42/$50" monospaced
}
```

### 7. Org Rollup View

`android/.../ui/insights/OrgRollupView.kt` — mirrors `IntelligenceBriefScreen.kt`'s editorial pattern:

- Segmented control: User / Project / Credential / Provider
- Period picker: Day / Week / Month / All Time
- LazyColumn of rollup rows with cost, tokens, sessions, device count
- Gated behind `Settings.Global.enterpriseOrgViewEnabled` (default off)

The SQL query is already implemented in the MCP server (`burnbar_org_spend`). Port the same query to Room:

```kotlin
@Query("""
    SELECT COALESCE(sourceDeviceName, sourceDeviceID, 'local') AS label,
           COALESCE(SUM(cost), 0) AS totalCost,
           COALESCE(SUM(totalTokens), 0) AS totalTokens,
           COUNT(DISTINCT sessionId) AS sessionCount,
           COUNT(DISTINCT COALESCE(sourceDeviceID, 'local')) AS deviceCount
    FROM token_usage
    WHERE startTime >= :windowStart
    GROUP BY label
    ORDER BY totalCost DESC
    LIMIT :limit
""")
fun orgRollupByUser(windowStart: Long, limit: Int): List<OrgRollupRow>
```

### 8. Notifications

Android uses `NotificationCompat` from AndroidX. Mirror `BudgetNotificationCenter`:

```kotlin
class BudgetNotificationCenter(private val context: Context) {
    fun emitWarning(rule: BudgetRuleEntity, used: Double, limit: Double) {
        // 80% warning notification — debounce one per (rule, period)
    }
    fun emitBlock(rule: BudgetRuleEntity, used: Double, limit: Double) {
        // 100% block notification — always fire
    }
}
```

Register a notification channel `burnbar_budget` at app startup alongside existing channels.

### 9. Firestore Sync

Extend the existing `CloudSyncService` (or `FirestoreRepository`) pattern:

```kotlin
// Upload: budget_rules WHERE syncedAt IS NULL
// Download: budget_rules WHERE sourceDeviceID != localDeviceId AND updatedAt > lastSync
// Upload: budget_events WHERE syncedAt IS NULL (last 500 per sync)
// Download: budget_events not needed (append-only, local is source of truth)
```

### 10. Reference Files

| Purpose | macOS path | Android port notes |
|---|---|---|
| Shared models | `OpenBurnBarCore/.../BudgetRule.swift` | Port to Kotlin data classes with `@IgnoreExtraProperties` |
| Database schema | `OpenBurnBarDatabase.swift` (search `v42_budget_rules`) | Room entities + DAO + migration |
| Gate logic | `AgentLens/.../BudgetGate.swift` | Port `evaluate()` as suspend function over DAO |
| Ledger | `AgentLens/.../BudgetLedger.swift` | Room query on `token_usage` table |
| Forecast | `AgentLens/.../BudgetForecast.swift` | Port linear extrapolation; reference `VelocityForecastStore` |
| Settings UI | `AgentLens/.../BudgetSettingsView.swift` | Compose `BudgetSettingsScreen` |
| Error card | `AgentLens/.../BudgetBlockedCard.swift` | Compose card in chat view |
| Credential lane | `AgentLens/.../DashboardCredentialLaneView.swift` | Horizontal scroll in Pulse tab |
| Project lane | `AgentLens/.../DashboardProjectSpendLaneView.swift` | Same pattern |
| Budget chip | `AgentLens/.../BurnRailBudgetChip.swift` | Compact pill in Pulse header |
| Cloud sync | `AgentLens/.../CloudBudgetService.swift` | Extend `FirestoreRepository` |
| Notifications | `AgentLens/.../BudgetNotificationCenter.swift` | Android `NotificationCompat` |
| Enforcement entry | `AgentLens/.../BudgetEnforcement.swift` | Singleton wired into app startup |
| Context builder | `AgentLens/.../ContextBuilder.swift` (lines ~200, ~331) | Add budget section to Hermes system prompt |
| MCP tools | `tools/openburnbar-mcp/server.py` | No port needed — reads SQLite directly |
| Org rollup | `AgentLens/.../OrgRollupView.swift` | Compose `OrgRollupView` |
| Design system | `DESIGN.md` | Use `AuroraDesign` tokens; follow `IntelligenceBriefScreen.kt` editorial patterns |

### 11. AGENTS.md Schema Sync

Per `android/app/AGENTS.md`, after porting, run:

```bash
cd android && ./gradlew :app:testDebugUnitTest --no-daemon
```

And update `tools/schema-sync/` if the Room schema drifts from `functions/src/types.ts`.

### 12. Key Invariants (Same as macOS/iOS)

1. **Subscription credentials are exempt.** `BudgetBillingMode.forSecretPrefix("sk-ant-oat")` returns `SUBSCRIPTION`. The gate short-circuits to `ALLOW`.
2. **80% warn, 100% block** is the default behavior (`warnThenBlock`).
3. **Local pricing for gate, billing API for nightly truth-up.** The Android app uses `ProviderUsageAPIService` (already wired for Anthropic/OpenAI/OpenRouter) for reconciliation.
4. **Hermes/MCP have full authority.** The MCP server reads the same SQLite database; no Android-specific MCP changes needed.
5. **Cross-device sync via Firestore.** `budget_rules` and `budget_events` sync under `users/{uid}/budgetRules/` and `users/{uid}/budgetEvents/`. Last-write-wins on `updatedAt`.
