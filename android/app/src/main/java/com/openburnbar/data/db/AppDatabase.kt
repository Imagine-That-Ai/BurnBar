package com.openburnbar.data.db

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.openburnbar.data.models.BudgetEvent
import com.openburnbar.data.models.BudgetRule
import com.openburnbar.data.models.TokenUsage

@Entity(
    tableName = "budget_rules",
    indices = [
        Index(value = ["scope", "isEnabled"]),
        Index(value = ["providerID", "accountID", "isEnabled"]),
        Index(value = ["projectName", "isEnabled"]),
        Index(value = ["syncedAt"]),
    ],
)
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
    val isEnabled: Boolean = true,
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
        isEnabled = isEnabled,
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
    isEnabled = isEnabled,
)

@Entity(
    tableName = "budget_events",
    indices = [
        Index(value = ["ruleID", "occurredAt"]),
        Index(value = ["kind", "occurredAt"]),
        Index(value = ["syncedAt"]),
    ],
)
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
    val sourceDeviceID: String? = null,
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
        sourceDeviceID = sourceDeviceID,
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
    sourceDeviceID = sourceDeviceID,
)

@Entity(
    tableName = "token_usage",
    indices = [
        Index(value = ["startTime"]),
        Index(value = ["endTime"]),
        Index(value = ["providerId", "providerAccountId"]),
        Index(value = ["projectName"]),
    ],
)
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
    val schemaVersion: Int,
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
    schemaVersion = schemaVersion,
)

@Entity(
    tableName = "text_expansion_snippets",
    indices = [
        Index(value = ["trigger"]),
        Index(value = ["isEnabled", "deletedAtMillis"]),
        Index(value = ["syncedAtMillis"]),
    ],
)
data class TextExpansionSnippetEntity(
    @PrimaryKey val id: String,
    val title: String,
    val trigger: String,
    val body: String,
    val mode: String,
    val isEnabled: Boolean = true,
    val scopeJson: String = "{}",
    val revision: Int = 1,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val deletedAtMillis: Long? = null,
    val syncedAtMillis: Long? = null,
    val sourceDeviceID: String? = null,
)

@Dao
interface TextExpansionDao {
    @Query("SELECT * FROM text_expansion_snippets WHERE deletedAtMillis IS NULL ORDER BY updatedAtMillis DESC, title ASC")
    fun getAllActive(): List<TextExpansionSnippetEntity>

    @Query("SELECT * FROM text_expansion_snippets ORDER BY updatedAtMillis DESC")
    fun getAllIncludingDeleted(): List<TextExpansionSnippetEntity>

    @Query("SELECT * FROM text_expansion_snippets WHERE isEnabled = 1 AND deletedAtMillis IS NULL ORDER BY title ASC")
    fun getEnabled(): List<TextExpansionSnippetEntity>

    @Query("SELECT * FROM text_expansion_snippets WHERE syncedAtMillis IS NULL OR syncedAtMillis < updatedAtMillis ORDER BY updatedAtMillis DESC LIMIT :limit")
    fun getUnsynced(limit: Int = 200): List<TextExpansionSnippetEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(snippet: TextExpansionSnippetEntity)

    @Query("UPDATE text_expansion_snippets SET syncedAtMillis = :syncedAt WHERE id IN (:ids)")
    fun markSynced(ids: List<String>, syncedAt: Long = System.currentTimeMillis())

    @Query(
        "UPDATE text_expansion_snippets SET deletedAtMillis = :deletedAtMillis, updatedAtMillis = :deletedAtMillis, syncedAtMillis = NULL, isEnabled = 0, revision = revision + 1 WHERE id = :id",
    )
    fun softDelete(id: String, deletedAtMillis: Long = System.currentTimeMillis())
}

@Database(
    entities = [
        BudgetRuleEntity::class,
        BudgetEventEntity::class,
        TokenUsageEntity::class,
        TextExpansionSnippetEntity::class,
    ],
    version = 3,
    exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun budgetRuleDao(): BudgetRuleDao

    abstract fun budgetEventDao(): BudgetEventDao

    abstract fun budgetSpendDao(): BudgetSpendDao

    abstract fun budgetOrgRollupDao(): BudgetOrgRollupDao

    abstract fun tokenUsageWriteDao(): TokenUsageWriteDao

    fun budgetDatabaseAccess(): BudgetDatabaseAccess =
        BudgetDatabaseAccess(
            ruleDao = budgetRuleDao(),
            eventDao = budgetEventDao(),
            spendDao = budgetSpendDao(),
            orgRollupDao = budgetOrgRollupDao(),
            tokenUsageWriteDao = tokenUsageWriteDao(),
        )

    abstract fun textExpansionDao(): TextExpansionDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance =
                    Room.databaseBuilder(
                        context.applicationContext,
                        AppDatabase::class.java,
                        "burnbar_database",
                    )
                        .addMigrations(MIGRATION_1_2, MIGRATION_2_3)
                        .fallbackToDestructiveMigration()
                        .build()
                INSTANCE = instance
                instance
            }
        }

        private val MIGRATION_1_2 =
            object : Migration(1, 2) {
                override fun migrate(db: SupportSQLiteDatabase) {
                    db.execSQL(
                        """
                        CREATE TABLE IF NOT EXISTS text_expansion_snippets (
                            id TEXT NOT NULL PRIMARY KEY,
                            title TEXT NOT NULL,
                            trigger TEXT NOT NULL,
                            body TEXT NOT NULL,
                            mode TEXT NOT NULL,
                            isEnabled INTEGER NOT NULL DEFAULT 1,
                            scopeJson TEXT NOT NULL DEFAULT '{}',
                            revision INTEGER NOT NULL DEFAULT 1,
                            createdAtMillis INTEGER NOT NULL,
                            updatedAtMillis INTEGER NOT NULL,
                            deletedAtMillis INTEGER,
                            syncedAtMillis INTEGER,
                            sourceDeviceID TEXT
                        )
                        """.trimIndent(),
                    )
                    db.execSQL("CREATE INDEX IF NOT EXISTS index_text_expansion_snippets_trigger ON text_expansion_snippets(trigger)")
                    db.execSQL(
                        "CREATE INDEX IF NOT EXISTS index_text_expansion_snippets_isEnabled_deletedAtMillis ON text_expansion_snippets(isEnabled, deletedAtMillis)",
                    )
                    db.execSQL("CREATE INDEX IF NOT EXISTS index_text_expansion_snippets_syncedAtMillis ON text_expansion_snippets(syncedAtMillis)")
                }
            }

        private val MIGRATION_2_3 =
            object : Migration(2, 3) {
                override fun migrate(db: SupportSQLiteDatabase) {
                    db.execSQL("DROP INDEX IF EXISTS index_text_expansion_snippets_trigger")
                    db.execSQL("CREATE INDEX IF NOT EXISTS index_text_expansion_snippets_trigger ON text_expansion_snippets(trigger)")
                }
            }
    }
}
