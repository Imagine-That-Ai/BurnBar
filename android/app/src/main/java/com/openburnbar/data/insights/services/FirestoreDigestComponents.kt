@file:Suppress("MatchingDeclarationName")

package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.UsageRollups

internal data class FirestoreDigestComponents(
    val totals: InsightDigest.Totals,
    val providers: List<InsightDigest.ProviderSnapshot>,
    val models: List<InsightDigest.ModelSnapshot>,
    val daily: List<InsightDigest.DailyPoint>,
    val quotaSummaries: List<InsightDigest.QuotaSnapshotSummary>,
)

internal fun buildFirestoreDigestComponents(
    rollups: UsageRollups,
    window: InsightTimeWindow,
    quotaSnapshots: List<ProviderQuotaSnapshot>,
): FirestoreDigestComponents {
    val totals =
        InsightDigest.Totals(
            costUSD = rollups.costFor(window),
            totalTokens = rollups.tokensFor(window),
            sessionCount = sessionCountFor(rollups),
            inputTokens = rollups.totals["inputTokens"]?.toLong() ?: 0L,
            outputTokens = rollups.totals["outputTokens"]?.toLong() ?: 0L,
            reasoningTokens = rollups.totals["reasoningTokens"]?.toLong() ?: 0L,
            cacheReadTokens = rollups.totals["cacheReadTokens"]?.toLong() ?: 0L,
            cacheCreationTokens = rollups.totals["cacheCreationTokens"]?.toLong() ?: 0L,
        )
    val providers =
        rollups.providerSummaries.map { ps ->
            InsightDigest.ProviderSnapshot(
                id = ps.provider,
                displayName = ps.provider.replaceFirstChar { it.uppercase() },
                costUSD = ps.totalCost,
                totalTokens = ps.totalTokens,
                sessionCount = ps.totalRequests,
            )
        }
    val models =
        rollups.modelSummaries.map { ms ->
            InsightDigest.ModelSnapshot(
                id = ms.provider,
                providerID = ms.providerId ?: ms.provider,
                costUSD = ms.totalCost,
                totalTokens = ms.totalTokens,
                sessionCount = ms.totalRequests,
                avgCostPerSession = if (ms.totalRequests > 0) ms.totalCost / ms.totalRequests else 0.0,
                cacheHitRate = 0.0,
            )
        }
    val daily =
        rollups.dailyPoints.entries.map { (date, cost) ->
            InsightDigest.DailyPoint(day = date, costUSD = cost, totalTokens = 0L, sessionCount = 0)
        }.sortedBy { it.day }
    val quotaSummaries =
        quotaSnapshots.map { snap ->
            InsightDigest.QuotaSnapshotSummary(
                id = snap.id,
                providerID = snap.provider,
                bucketName = snap.buckets.firstOrNull()?.name ?: "",
                used = snap.buckets.sumOf { it.used },
                limit = snap.quotaLimit,
            )
        }
    return FirestoreDigestComponents(
        totals = totals,
        providers = providers,
        models = models,
        daily = daily,
        quotaSummaries = quotaSummaries,
    )
}

internal fun assembleFirestoreDigest(
    window: InsightTimeWindow,
    components: FirestoreDigestComponents,
    modelBenchmarks: List<InsightDigest.ModelBenchmarkSummary>,
): InsightDigest =
    InsightDigestBuilder.build(
        input =
        InsightDigestBuildInput(
            filter = InsightFilter(window = window),
            totals = components.totals,
            providers = components.providers,
            models = components.models,
            projects = emptyList(),
            daily = components.daily,
            quotaSnapshots = components.quotaSummaries,
            modelBenchmarks = modelBenchmarks,
        ),
    )
