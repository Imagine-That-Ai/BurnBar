package com.openburnbar.data.db

import android.content.Context
import androidx.room.*
import com.openburnbar.data.models.*

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
) {
    fun toModel(): BudgetRule = BudgetRule(
        id = id,
        scope = scope,
        identifier = identifier,
        providerID = providerID,
        accountID = accountID,
        projectName = projectName,
        label = label,
        amountUSD = amountUSD,
        period = period,
        behavior = behavior,
        fallbackCredentialIDsJSON = fallbackCredentialIDsJSON,
        pausedUntil = pausedUntil?.let { java.util.Date(it) },
        createdAt = java.util.Date(createdAt),
        updatedAt = java.util.Date(updatedAt),
        syncedAt = syncedAt?.let { java.util.Date(it) },
        sourceDeviceID = sourceDeviceID,
        isEnabled = isEnabled
    )
}

fun BudgetRule.toEntity(): BudgetRuleEntity = BudgetRuleEntity(
    id = id,
    scope = scope,
    identifier = identifier,
    providerID = providerID,
    accountID = accountID,
    projectName = projectName,
    label = label,
    amountUSD = amountUSD,
    period = period,
    behavior = behavior,
    fallbackCredentialIDsJSON = fallbackCredentialIDsJSON,
    pausedUntil = pausedUntil?.time,
    createdAt = createdAt?.time ?: System.currentTimeMillis(),
    updatedAt = updatedAt?.time ?: System.currentTimeMillis(),
    syncedAt = syncedAt?.time,
    sourceDeviceID = sourceDeviceID,
    isEnabled = isEnabled
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
) {
    fun toModel(): BudgetEvent = BudgetEvent(
        id = id,
        ruleID = ruleID,
        kind = kind,
        source = source,
        amountAtEvent = amountAtEvent,
        limitAtEvent = limitAtEvent,
        detailJSON = detailJSON,
        occurredAt = java.util.Date(occurredAt),
        syncedAt = syncedAt?.let { java.util.Date(it) },
        sourceDeviceID = sourceDeviceID
    )
}

fun BudgetEvent.toEntity(): BudgetEventEntity = BudgetEventEntity(
    id = id,
    ruleID = ruleID,
    kind = kind,
    source = source,
    amountAtEvent = amountAtEvent,
    limitAtEvent = limitAtEvent,
    detailJSON = detailJSON,
    occurredAt = occurredAt?.time ?: System.currentTimeMillis(),
    syncedAt = syncedAt?.time,
    sourceDeviceID = sourceDeviceID
)

@Entity(tableName = "token_usage", indices = [
    Index(value = ["startTime"]),
    Index(value = ["endTime"]),
    Index(value = ["providerId", "providerAccountId"]),
    Index(value = ["projectName"])
])
data class TokenUsageEntity(
    @PrimaryKey val id: String,
    val provider: String,
    val providerId: String?,
    val providerAccountId: String?,
    val providerAccountLabel: String?,
    val providerAccountSource: String?,
    val model: String?,
    val sessionId: String?,
    val deviceId: String?,
    val sourceDeviceId: String?,
    val sourceDeviceName: String? = null,
    val inputTokens: Int,
    val outputTokens: Int,
    val cacheCreationTokens: Int,
    val cacheReadTokens: Int,
    val reasoningTokens: Int,
    val totalTokens: Int,
    val costUsd: Double,
    val cost: Double,
    val provenanceConfidence: String?,
    val provenanceMethod: String?,
    val userDisplayId: String?,
    val projectName: String?,
    val timestamp: Long,
    val startTime: Long,
    val endTime: Long,
    val createdAt: Long,
    val updatedAt: Long,
    val schemaVersion: Int
)

fun TokenUsage.toEntity(sourceDeviceName: String? = null): TokenUsageEntity = TokenUsageEntity(
    id = id,
    provider = provider,
    providerId = providerId,
    providerAccountId = providerAccountId,
    providerAccountLabel = providerAccountLabel,
    providerAccountSource = providerAccountSource,
    model = model,
    sessionId = sessionId,
    deviceId = deviceId,
    sourceDeviceId = sourceDeviceId,
    sourceDeviceName = sourceDeviceName ?: providerAccountLabel,
    inputTokens = inputTokens,
    outputTokens = outputTokens,
    cacheCreationTokens = cacheCreationTokens,
    cacheReadTokens = cacheReadTokens,
    reasoningTokens = reasoningTokens,
    totalTokens = totalTokens,
    costUsd = costUsd,
    cost = cost,
    provenanceConfidence = provenanceConfidence,
    provenanceMethod = provenanceMethod,
    userDisplayId = userDisplayId,
    projectName = projectName,
    timestamp = timestamp,
    startTime = startTime,
    endTime = endTime,
    createdAt = createdAt,
    updatedAt = updatedAt,
    schemaVersion = schemaVersion
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

    // ── Spend Ledger Queries ──

    @Query("SELECT COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) FROM token_usage WHERE startTime >= :windowStart AND startTime <= :reference")
    fun getGlobalSpend(windowStart: Long, reference: Long): Double

    @Query("SELECT COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) FROM token_usage WHERE startTime >= :windowStart AND startTime <= :reference AND providerId = :providerID AND (providerAccountId IS NULL OR providerAccountId = '' OR providerAccountId = :accountID)")
    fun getCredentialSpend(windowStart: Long, reference: Long, providerID: String, accountID: String): Double

    @Query("SELECT COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) FROM token_usage WHERE startTime >= :windowStart AND startTime <= :reference AND projectName = :projectName")
    fun getProjectSpend(windowStart: Long, reference: Long, projectName: String): Double

    @Query("SELECT COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) FROM token_usage WHERE startTime >= :windowStart AND startTime <= :reference AND (providerAccountLabel = :identifier OR providerAccountId = :identifier)")
    fun getOrganizationSpend(windowStart: Long, reference: Long, identifier: String): Double

    // ── Org Rollup Queries ──

    @Query("""
        SELECT COALESCE(sourceDeviceName, sourceDeviceId, 'local') AS label,
               COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) AS totalCost,
               COALESCE(SUM(totalTokens), 0) AS totalTokens,
               COUNT(DISTINCT sessionId) AS sessionCount,
               COUNT(DISTINCT COALESCE(sourceDeviceId, 'local')) AS deviceCount
        FROM token_usage
        WHERE startTime >= :windowStart
        GROUP BY label
        ORDER BY totalCost DESC
        LIMIT :limit
    """)
    fun orgRollupByUser(windowStart: Long, limit: Int): List<OrgRollupRow>

    @Query("""
        SELECT COALESCE(projectName, 'Unassigned') AS label,
               COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) AS totalCost,
               COALESCE(SUM(totalTokens), 0) AS totalTokens,
               COUNT(DISTINCT sessionId) AS sessionCount,
               COUNT(DISTINCT COALESCE(sourceDeviceId, 'local')) AS deviceCount
        FROM token_usage
        WHERE startTime >= :windowStart
        GROUP BY label
        ORDER BY totalCost DESC
        LIMIT :limit
    """)
    fun orgRollupByProject(windowStart: Long, limit: Int): List<OrgRollupRow>

    @Query("""
        SELECT COALESCE(providerAccountLabel, providerAccountId, 'Default') AS label,
               COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) AS totalCost,
               COALESCE(SUM(totalTokens), 0) AS totalTokens,
               COUNT(DISTINCT sessionId) AS sessionCount,
               COUNT(DISTINCT COALESCE(sourceDeviceId, 'local')) AS deviceCount
        FROM token_usage
        WHERE startTime >= :windowStart
        GROUP BY label
        ORDER BY totalCost DESC
        LIMIT :limit
    """)
    fun orgRollupByCredential(windowStart: Long, limit: Int): List<OrgRollupRow>

    @Query("""
        SELECT COALESCE(provider, 'Unknown') AS label,
               COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) AS totalCost,
               COALESCE(SUM(totalTokens), 0) AS totalTokens,
               COUNT(DISTINCT sessionId) AS sessionCount,
               COUNT(DISTINCT COALESCE(sourceDeviceId, 'local')) AS deviceCount
        FROM token_usage
        WHERE startTime >= :windowStart
        GROUP BY label
        ORDER BY totalCost DESC
        LIMIT :limit
    """)
    fun orgRollupByProvider(windowStart: Long, limit: Int): List<OrgRollupRow>

    // ── Token Usage Sync Queries ──
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertTokenUsage(usage: TokenUsageEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertTokenUsages(usages: List<TokenUsageEntity>)
}

@Database(
    entities = [
        BudgetRuleEntity::class,
        BudgetEventEntity::class,
        TokenUsageEntity::class
    ],
    version = 1,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun budgetDao(): BudgetDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "burnbar_database"
                )
                .fallbackToDestructiveMigration()
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
