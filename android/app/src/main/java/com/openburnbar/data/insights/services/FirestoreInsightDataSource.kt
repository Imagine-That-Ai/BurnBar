package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.dedupeFresh

/**
 * Android-native data source that builds InsightDigest from
 * Firestore rollups and direct provider APIs.
 *
 * Fields that require macOS-only local data (useCaseHistogram,
 * agentFocusSignals, modelFocusSignals) are left empty.
 */
class FirestoreInsightDataSource(
    private val dashboardStore: DashboardStore? = null,
    private val quotaStore: QuotaStore? = null,
    private val repo: FirestoreRepository = FirestoreRepository()
) : InsightDataSource {

    override suspend fun buildDigest(filter: InsightFilter): InsightDigest {
        return buildDigest(filter.window)
    }

    override suspend fun buildDigest(window: InsightTimeWindow): InsightDigest {
        val rollups = dashboardStore?.rollups?.value ?: repo.fetchRollups()
        val windowCost = rollups.costFor(window)
        val windowTokens = rollups.tokensFor(window)

        val totals = InsightDigest.Totals(
            costUSD = windowCost,
            totalTokens = windowTokens,
            sessionCount = sessionCountFor(rollups),
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

        val quotaSnapshots = quotaStore?.snapshots?.value?.takeIf { it.isNotEmpty() }
            ?: repo.fetchQuotaSnapshots().dedupeFresh()
        val modelBenchmarks = runCatching { repo.fetchModelBenchmarkSnapshots() }.getOrDefault(emptyList())

        val daily = rollups.dailyPoints.entries.map { (date, cost) ->
            InsightDigest.DailyPoint(day = date, costUSD = cost, totalTokens = 0L, sessionCount = 0)
        }.sortedBy { it.day }

        val quotaSummaries = quotaSnapshots.map { snap ->
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
            quotaSnapshots = quotaSummaries,
            modelBenchmarks = modelBenchmarks
        )
    }
}

private fun UsageRollups.costFor(window: InsightTimeWindow): Double = when (window) {
    InsightTimeWindow.Today,
    InsightTimeWindow.Last24h -> today
    InsightTimeWindow.Last7d -> sevenDays
    InsightTimeWindow.Last30d -> thirtyDays
    InsightTimeWindow.Last90d -> ninetyDays
    InsightTimeWindow.Last365d,
    InsightTimeWindow.AllTime,
    is InsightTimeWindow.Custom -> allTime
}

private fun UsageRollups.tokensFor(window: InsightTimeWindow): Long = when (window) {
    InsightTimeWindow.Today,
    InsightTimeWindow.Last24h -> todayTokens
    InsightTimeWindow.Last7d -> sevenDayTokens
    InsightTimeWindow.Last30d -> thirtyDayTokens
    InsightTimeWindow.Last90d -> ninetyDayTokens
    InsightTimeWindow.Last365d,
    InsightTimeWindow.AllTime,
    is InsightTimeWindow.Custom -> allTimeTokens
}

private fun sessionCountFor(rollups: UsageRollups): Int =
    rollups.totals["totalSessions"]?.toInt()
        ?: rollups.totals["sessionCount"]?.toInt()
        ?: rollups.totals["sessions"]?.toInt()
        ?: rollups.providerSummaries.sumOf { it.totalRequests }.takeIf { it > 0 }
        ?: rollups.modelSummaries.sumOf { it.totalRequests }.takeIf { it > 0 }
        ?: 0
