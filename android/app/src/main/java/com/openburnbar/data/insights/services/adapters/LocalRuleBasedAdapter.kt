package com.openburnbar.data.insights.services.adapters

import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightFreshness
import com.openburnbar.data.insights.InsightLayout
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.ValueFormat
import com.openburnbar.data.insights.InsightModelCapabilities
import com.openburnbar.data.insights.InsightModelGateway
import com.openburnbar.data.insights.InsightCatalogModel
import com.openburnbar.data.insights.InsightCapabilityTier

/**
 * Pure-Kotlin rule-based canvas builder. Zero-egress, zero-cost.
 * Produces a reasonable first canvas from the digest without calling any LLM.
 * Mirrors the Swift LocalRuleBasedAdapter heuristics.
 */
object LocalRuleBasedAdapter {

    fun buildCanvas(digest: InsightDigest, filter: InsightFilter = InsightFilter()): InsightCanvas {
        val widgets = mutableListOf<InsightWidget>()
        val layout = InsightLayout()

        // 1. KPI tiles for top metrics
        widgets.add(makeKpi("Total Cost", "totalCost", digest.totals.costUSD, ValueFormat.CURRENCY, digest))
        widgets.add(makeKpi("Tokens", "totalTokens", digest.totals.totalTokens.toDouble(), ValueFormat.TOKENS, digest))
        if (digest.totals.cacheReadTokens > 0) {
            val rate = if (digest.totals.totalTokens > 0) digest.totals.cacheReadTokens.toDouble() / digest.totals.totalTokens.toDouble() else 0.0
            widgets.add(makeKpi("Cache Hit Rate", "cacheHitRate", rate, ValueFormat.PERCENT, digest))
        }
        widgets.add(makeKpi("Sessions", "totalSessions", digest.totals.sessionCount.toDouble(), ValueFormat.COUNT, digest))

        // 2. Time series for cost trend
        if (digest.daily.isNotEmpty()) {
            widgets.add(InsightWidget(
                kind = InsightWidgetKind.TIME_SERIES_LINE,
                title = "Cost Trend",
                spec = InsightWidgetSpec.TimeSeries(InsightWidgetSpec.TimeSeriesSpec()),
                dataBinding = InsightDataBinding.TimeSeries(metric = "cost", window = filter.window),
                data = InsightWidgetData.TimeSeries(
                    series = listOf(InsightWidgetData.TimeSeries.Series(
                        id = "cost", name = "Cost",
                        points = digest.daily.map { InsightWidgetData.TimeSeries.Point(date = it.day, value = it.costUSD) }
                    )),
                    xAxisLabel = "Date", yAxisLabel = "Cost (USD)", yFormat = ValueFormat.CURRENCY
                ),
                freshness = InsightFreshness.FRESH
            ))
        }

        // 3. Provider distribution (donut)
        if (digest.providers.size >= 2) {
            widgets.add(InsightWidget(
                kind = InsightWidgetKind.DONUT,
                title = "Cost by Provider",
                spec = InsightWidgetSpec.Distribution(InsightWidgetSpec.DistributionSpec()),
                dataBinding = InsightDataBinding.Distribution(metric = "cost", dimension = InsightWidgetSpec.Dimension.PROVIDER, window = filter.window),
                data = InsightWidgetData.Distribution(
                    slices = digest.providers.mapIndexed { idx, p ->
                        InsightWidgetData.Distribution.Slice(id = "p$idx", label = p.displayName, value = p.costUSD)
                    },
                    valueFormat = ValueFormat.CURRENCY,
                    total = digest.providers.sumOf { it.costUSD }
                ),
                freshness = InsightFreshness.FRESH
            ))
        }

        // 4. Quota pulse if data available
        if (digest.quotaSnapshots.isNotEmpty()) {
            widgets.add(InsightWidget(
                kind = InsightWidgetKind.QUOTA_PULSE,
                title = "Quota Status",
                spec = InsightWidgetSpec.QuotaPulse(InsightWidgetSpec.QuotaPulseSpec()),
                dataBinding = InsightDataBinding.Quota(),
                data = InsightWidgetData.QuotaState(
                    buckets = digest.quotaSnapshots.map {
                        InsightWidgetData.QuotaState.Bucket(
                            id = it.id, providerLabel = it.providerID, bucketName = it.bucketName,
                            used = it.used, limit = it.limit, resetsAt = it.resetsAt,
                            symbolName = "gauge.with.dots.needle.67percent"
                        )
                    }
                ),
                freshness = InsightFreshness.FRESH
            ))
        }

        // 5. Narrative with high-level summary
        val cacheRate = if (digest.totals.totalTokens > 0) (digest.totals.cacheReadTokens.toDouble() / digest.totals.totalTokens.toDouble() * 100).toInt() else 0
        val overview = InsightWidgetData.Narrative(
            headline = "Spent \$${String.format("%.2f", digest.totals.costUSD)} across ${digest.providers.size} provider(s)",
            body = "${digest.totals.sessionCount} sessions, ${digest.totals.totalTokens} tokens. Cache hit rate: $cacheRate%.",
            bullets = digest.providers.take(3).map { "${it.displayName}: \$${String.format("%.2f", it.costUSD)}" },
            tone = InsightWidgetData.Narrative.Tone.NEUTRAL,
            sparkline = digest.daily.map { it.costUSD }
        )
        widgets.add(InsightWidget(
            kind = InsightWidgetKind.NARRATIVE,
            title = "Overview",
            spec = InsightWidgetSpec.Narrative(InsightWidgetSpec.NarrativeSpec()),
            dataBinding = InsightDataBinding.Narrative(overview),
            data = overview,
            freshness = InsightFreshness.FRESH,
            modelTag = InsightModelTag(
                providerKey = "local", modelID = "rules", displayName = "Local Rules",
                egressTier = InsightEgressTier.LOCAL_ONLY
            )
        ))

        // Build canvas with layout
        var canvasLayout = layout
        for (w in widgets) {
            canvasLayout = canvasLayout.placeNew(w.id, w.kind.defaultSpanColumns to w.kind.defaultSpanRows)
        }
        return InsightCanvas(
            title = "Today",
            summary = "Auto-generated overview",
            symbolName = "sparkles.tv",
            theme = InsightTheme.AURORA,
            widgets = widgets,
            layout = canvasLayout,
            filter = filter,
            origin = InsightCanvas.Origin.UserCreated
        )
    }

    private fun makeKpi(label: String, metric: String, value: Double, format: ValueFormat, digest: InsightDigest): InsightWidget {
        return InsightWidget(
            kind = InsightWidgetKind.KPI_TILE,
            title = label,
            spec = InsightWidgetSpec.KPITile(InsightWidgetSpec.KPITileSpec(metricLabel = metric)),
            dataBinding = InsightDataBinding.Kpi(metric = metric, window = InsightTimeWindow.Last7d),
            data = InsightWidgetData.KPI(
                metricLabel = label, value = value, valueFormat = format,
                sparkline = digest.daily.map { it.costUSD }
            ),
            freshness = InsightFreshness.FRESH
        )
    }
}
