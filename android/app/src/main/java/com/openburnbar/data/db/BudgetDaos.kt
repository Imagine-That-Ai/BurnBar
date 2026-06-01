package com.openburnbar.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.openburnbar.data.models.OrgRollupRow

@Dao
interface BudgetRuleDao {
    @Query("SELECT * FROM budget_rules WHERE isEnabled = 1 ORDER BY createdAt DESC")
    fun getAllEnabledRules(): List<BudgetRuleEntity>

    @Query(
        "SELECT * FROM budget_rules WHERE scope = 'credential' AND providerID = :providerID AND (accountID IS NULL OR accountID = '' OR accountID = :accountID) AND isEnabled = 1",
    )
    fun getCredentialRules(providerID: String, accountID: String?): List<BudgetRuleEntity>

    @Query("SELECT * FROM budget_rules WHERE scope = 'project' AND projectName = :projectName AND isEnabled = 1")
    fun getProjectRules(projectName: String): List<BudgetRuleEntity>

    @Query("SELECT * FROM budget_rules WHERE scope = 'global' AND isEnabled = 1")
    fun getGlobalRules(): List<BudgetRuleEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertRule(rule: BudgetRuleEntity)

    @Query("DELETE FROM budget_rules WHERE id = :id")
    fun deleteRule(id: String)
}

@Dao
interface BudgetEventDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertEvent(event: BudgetEventEntity)

    @Query("SELECT * FROM budget_events WHERE ruleID = :ruleID ORDER BY occurredAt DESC LIMIT :limit")
    fun getEventsForRule(ruleID: String, limit: Int = 100): List<BudgetEventEntity>

    @Query("SELECT * FROM budget_events ORDER BY occurredAt DESC LIMIT :limit")
    fun getRecentEvents(limit: Int = 100): List<BudgetEventEntity>
}

@Dao
interface BudgetSpendDao {
    @Query(
        "SELECT COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) FROM token_usage WHERE startTime >= :windowStart AND startTime <= :reference",
    )
    fun getGlobalSpend(windowStart: Long, reference: Long): Double

    @Query(
        """
        SELECT COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0)
        FROM token_usage
        WHERE startTime >= :windowStart AND startTime <= :reference
          AND providerId = :providerID
          AND (providerAccountId IS NULL OR providerAccountId = '' OR providerAccountId = :accountID)
        """,
    )
    fun getCredentialSpend(windowStart: Long, reference: Long, providerID: String, accountID: String): Double

    @Query(
        "SELECT COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0) FROM token_usage WHERE startTime >= :windowStart AND startTime <= :reference AND projectName = :projectName",
    )
    fun getProjectSpend(windowStart: Long, reference: Long, projectName: String): Double

    @Query(
        """
        SELECT COALESCE(SUM(CASE WHEN costUsd > 0.0 THEN costUsd ELSE cost END), 0.0)
        FROM token_usage
        WHERE startTime >= :windowStart AND startTime <= :reference
          AND (providerAccountLabel = :identifier OR providerAccountId = :identifier)
        """,
    )
    fun getOrganizationSpend(windowStart: Long, reference: Long, identifier: String): Double
}

@Dao
interface BudgetOrgRollupDao {
    @Query(
        """
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
    """,
    )
    fun orgRollupByUser(windowStart: Long, limit: Int): List<OrgRollupRow>

    @Query(
        """
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
    """,
    )
    fun orgRollupByProject(windowStart: Long, limit: Int): List<OrgRollupRow>

    @Query(
        """
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
    """,
    )
    fun orgRollupByCredential(windowStart: Long, limit: Int): List<OrgRollupRow>

    @Query(
        """
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
    """,
    )
    fun orgRollupByProvider(windowStart: Long, limit: Int): List<OrgRollupRow>
}

@Dao
interface TokenUsageWriteDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertTokenUsage(usage: TokenUsageEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertTokenUsages(usages: List<TokenUsageEntity>)
}

/**
 * Facade over split budget DAOs for callers that previously used [BudgetDao].
 */
class BudgetDatabaseAccess(
    private val ruleDao: BudgetRuleDao,
    private val eventDao: BudgetEventDao,
    private val spendDao: BudgetSpendDao,
    private val orgRollupDao: BudgetOrgRollupDao,
    private val tokenUsageWriteDao: TokenUsageWriteDao,
) {
    fun getAllEnabledRules(): List<BudgetRuleEntity> = ruleDao.getAllEnabledRules()

    fun getCredentialRules(providerID: String, accountID: String?): List<BudgetRuleEntity> =
        ruleDao.getCredentialRules(providerID, accountID)

    fun getProjectRules(projectName: String): List<BudgetRuleEntity> = ruleDao.getProjectRules(projectName)

    fun getGlobalRules(): List<BudgetRuleEntity> = ruleDao.getGlobalRules()

    fun upsertRule(rule: BudgetRuleEntity) = ruleDao.upsertRule(rule)

    fun deleteRule(id: String) = ruleDao.deleteRule(id)

    fun insertEvent(event: BudgetEventEntity) = eventDao.insertEvent(event)

    fun getEventsForRule(ruleID: String, limit: Int = 100): List<BudgetEventEntity> =
        eventDao.getEventsForRule(ruleID, limit)

    fun getRecentEvents(limit: Int = 100): List<BudgetEventEntity> = eventDao.getRecentEvents(limit)

    fun getGlobalSpend(windowStart: Long, reference: Long): Double = spendDao.getGlobalSpend(windowStart, reference)

    fun getCredentialSpend(windowStart: Long, reference: Long, providerID: String, accountID: String): Double =
        spendDao.getCredentialSpend(windowStart, reference, providerID, accountID)

    fun getProjectSpend(windowStart: Long, reference: Long, projectName: String): Double =
        spendDao.getProjectSpend(windowStart, reference, projectName)

    fun getOrganizationSpend(windowStart: Long, reference: Long, identifier: String): Double =
        spendDao.getOrganizationSpend(windowStart, reference, identifier)

    fun orgRollupByUser(windowStart: Long, limit: Int): List<OrgRollupRow> =
        orgRollupDao.orgRollupByUser(windowStart, limit)

    fun orgRollupByProject(windowStart: Long, limit: Int): List<OrgRollupRow> =
        orgRollupDao.orgRollupByProject(windowStart, limit)

    fun orgRollupByCredential(windowStart: Long, limit: Int): List<OrgRollupRow> =
        orgRollupDao.orgRollupByCredential(windowStart, limit)

    fun orgRollupByProvider(windowStart: Long, limit: Int): List<OrgRollupRow> =
        orgRollupDao.orgRollupByProvider(windowStart, limit)

    fun insertTokenUsage(usage: TokenUsageEntity) = tokenUsageWriteDao.insertTokenUsage(usage)

    fun insertTokenUsages(usages: List<TokenUsageEntity>) = tokenUsageWriteDao.insertTokenUsages(usages)
}
