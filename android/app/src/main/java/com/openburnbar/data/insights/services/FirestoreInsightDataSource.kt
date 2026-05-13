package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.QuotaStore

/**
 * Android-native data source that builds InsightDigest from
 * Firestore rollups and direct provider APIs.
 *
 * Fields that require macOS-only local data (useCaseHistogram,
 * agentFocusSignals, modelFocusSignals) are left empty.
 */
class FirestoreInsightDataSource(
    private val dashboardStore: DashboardStore,
    private val quotaStore: QuotaStore
) : InsightDataSource {

    override suspend fun buildDigest(filter: InsightFilter): InsightDigest {
        return buildDigest(filter.window)
    }

    override suspend fun buildDigest(window: InsightTimeWindow): InsightDigest {
        val rollups = dashboardStore.rollups.value ?: return InsightDigest()

        val totals = InsightDigest.Totals(
            costUSD = rollups.today,
            totalTokens = rollups.todayTokens,
            sessionCount = (rollups.totals["totalSessions"]?.toInt() ?: 0),
            inputTokens = (rollups.totals["inputTokens"]?.toLong() ?: 0L),
            outputTokens = (rollups.totals["outputTokens"]?.toLong() ?: 0L),
            reasoningTokens = (rollups.totals["reasoningTokens"]?.toLong() ?: 0L),
            cacheReadTokens = (rollups.totals["cacheReadTokens"]?.toLong() ?: 0L),
            cacheCreationTokens = (rollups.totals["cacheCreationTokens"]?.toLong() ?: 0L)
        )

        val providers = rollups.providerSummaries.map { ps ->
            InsightDigest.ProviderSnapshot(
                id = ps.provider,
                displayName = ps.provider.replaceFirstChar { it.uppercase() },
                costUSD = ps.totalCost,
                totalTokens = ps.totalTokens,
                sessionCount = ps.totalRequests
            )
        }

        val models = rollups.modelSummaries.map { ms ->
            InsightDigest.ModelSnapshot(
                id = ms.provider, // modelSummaries use provider field for model name
                providerID = ms.providerId ?: ms.provider,
                costUSD = ms.totalCost,
                totalTokens = ms.totalTokens,
                sessionCount = ms.totalRequests,
                avgCostPerSession = if (ms.totalRequests > 0) ms.totalCost / ms.totalRequests else 0.0,
                cacheHitRate = 0.0
            )
        }

        val daily = rollups.dailyPoints.entries.map { (date, cost) ->
            InsightDigest.DailyPoint(day = date, costUSD = cost, totalTokens = 0L, sessionCount = 0)
        }.sortedBy { it.day }

        val quotaSnapshots = quotaStore.snapshots.value.map { snap ->
            InsightDigest.QuotaSnapshotSummary(
                id = snap.id,
                providerID = snap.provider,
                bucketName = snap.buckets.firstOrNull()?.name ?: "",
                used = snap.buckets.sumOf { it.used },
                limit = snap.quotaLimit
            )
        }

        return InsightDigestBuilder.build(
            filter = InsightFilter(window = window),
            totals = totals,
            providers = providers,
            models = models,
            projects = emptyList(),
            daily = daily,
            quotaSnapshots = quotaSnapshots
        )
    }
}
