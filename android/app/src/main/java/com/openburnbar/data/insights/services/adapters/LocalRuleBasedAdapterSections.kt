
package com.openburnbar.data.insights.services.adapters

import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightFreshness
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.ValueFormat

private const val OVERVIEW_PROVIDER_BULLET_LIMIT = 3

internal fun localRuleBasedKpiWidgets(digest: InsightDigest): List<InsightWidget> {
    val widgets = mutableListOf<InsightWidget>()
    widgets.add(localRuleBasedKpi("Total Cost", "totalCost", digest.totals.costUSD, ValueFormat.CURRENCY, digest))
    widgets.add(localRuleBasedKpi("Tokens", "totalTokens", digest.totals.totalTokens.toDouble(), ValueFormat.TOKENS, digest))
    if (digest.totals.cacheReadTokens > 0) {
        val rate = if (digest.totals.totalTokens > 0) digest.totals.cacheReadTokens.toDouble() / digest.totals.totalTokens.toDouble() else 0.0
        widgets.add(localRuleBasedKpi("Cache Hit Rate", "cacheHitRate", rate, ValueFormat.PERCENT, digest))
    }
    widgets.add(localRuleBasedKpi("Sessions", "totalSessions", digest.totals.sessionCount.toDouble(), ValueFormat.COUNT, digest))
    return widgets
}

internal fun localRuleBasedCostTrendWidget(digest: InsightDigest, filter: InsightFilter): InsightWidget? {
    if (digest.daily.isEmpty()) return null
    return InsightWidget(
        kind = InsightWidgetKind.TIME_SERIES_LINE,
        title = "Cost Trend",
        spec = InsightWidgetSpec.TimeSeries(InsightWidgetSpec.TimeSeriesSpec()),
        dataBinding = InsightDataBinding.TimeSeries(metric = "cost", window = filter.window),
        data =
        InsightWidgetData.TimeSeries(
            series =
            listOf(
                InsightWidgetData.TimeSeries.Series(
                    id = "cost",
                    name = "Cost",
                    points = digest.daily.map { InsightWidgetData.TimeSeries.Point(date = it.day, value = it.costUSD) },
                ),
            ),
            xAxisLabel = "Date",
            yAxisLabel = "Cost (USD)",
            yFormat = ValueFormat.CURRENCY,
        ),
        freshness = InsightFreshness.FRESH,
    )
}

internal fun localRuleBasedProviderDonutWidget(digest: InsightDigest, filter: InsightFilter): InsightWidget? {
    if (digest.providers.size < 2) return null
    return InsightWidget(
        kind = InsightWidgetKind.DONUT,
        title = "Cost by Provider",
        spec = InsightWidgetSpec.Distribution(InsightWidgetSpec.DistributionSpec()),
        dataBinding = InsightDataBinding.Distribution(metric = "cost", dimension = InsightWidgetSpec.Dimension.PROVIDER, window = filter.window),
        data =
        InsightWidgetData.Distribution(
            slices =
            digest.providers.mapIndexed { idx, p ->
                InsightWidgetData.Distribution.Slice(id = "p$idx", label = p.displayName, value = p.costUSD)
            },
            valueFormat = ValueFormat.CURRENCY,
            total = digest.providers.sumOf { it.costUSD },
        ),
        freshness = InsightFreshness.FRESH,
    )
}

internal fun localRuleBasedQuotaWidget(digest: InsightDigest): InsightWidget? {
    if (digest.quotaSnapshots.isEmpty()) return null
    return InsightWidget(
        kind = InsightWidgetKind.QUOTA_PULSE,
        title = "Quota Status",
        spec = InsightWidgetSpec.QuotaPulse(InsightWidgetSpec.QuotaPulseSpec()),
        dataBinding = InsightDataBinding.Quota(),
        data =
        InsightWidgetData.QuotaState(
            buckets =
            digest.quotaSnapshots.map {
                InsightWidgetData.QuotaState.Bucket(
                    id = it.id,
                    providerLabel = it.providerID,
                    bucketName = it.bucketName,
                    used = it.used,
                    limit = it.limit,
                    resetsAt = it.resetsAt,
                    symbolName = "gauge.with.dots.needle.67percent",
                )
            },
        ),
        freshness = InsightFreshness.FRESH,
    )
}

internal fun localRuleBasedOverviewWidget(digest: InsightDigest): InsightWidget {
    val cacheRate = if (digest.totals.totalTokens > 0) (digest.totals.cacheReadTokens.toDouble() / digest.totals.totalTokens.toDouble() * 100).toInt() else 0
    val overview =
        InsightWidgetData.Narrative(
            headline = "Spent \$${String.format(java.util.Locale.US, "%.2f", digest.totals.costUSD)} across ${digest.providers.size} provider(s)",
            body = "${digest.totals.sessionCount} sessions, ${digest.totals.totalTokens} tokens. Cache hit rate: $cacheRate%.",
            bullets = digest.providers.take(
                OVERVIEW_PROVIDER_BULLET_LIMIT,
            ).map { "${it.displayName}: \$${String.format(java.util.Locale.US, "%.2f", it.costUSD)}" },
            tone = InsightWidgetData.Narrative.Tone.NEUTRAL,
            sparkline = digest.daily.map { it.costUSD },
        )
    return InsightWidget(
        kind = InsightWidgetKind.NARRATIVE,
        title = "Overview",
        spec = InsightWidgetSpec.Narrative(InsightWidgetSpec.NarrativeSpec()),
        dataBinding = InsightDataBinding.Narrative(overview),
        data = overview,
        freshness = InsightFreshness.FRESH,
        modelTag =
        com.openburnbar.data.insights.InsightModelTag(
            providerKey = "local",
            modelID = "rules",
            displayName = "Local Rules",
            egressTier = com.openburnbar.data.insights.InsightEgressTier.LOCAL_ONLY,
        ),
    )
}

private fun localRuleBasedKpi(label: String, metric: String, value: Double, format: ValueFormat, digest: InsightDigest): InsightWidget = InsightWidget(
    kind = InsightWidgetKind.KPI_TILE,
    title = label,
    spec = InsightWidgetSpec.KPITile(InsightWidgetSpec.KPITileSpec(metricLabel = metric)),
    dataBinding = InsightDataBinding.Kpi(metric = metric, window = com.openburnbar.data.insights.InsightTimeWindow.Last7d),
    data =
    InsightWidgetData.KPI(
        metricLabel = label,
        value = value,
        valueFormat = format,
        sparkline = digest.daily.map { it.costUSD },
    ),
    freshness = InsightFreshness.FRESH,
)
