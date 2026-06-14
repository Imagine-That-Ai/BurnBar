package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.ValueFormat

private const val HEATMAP_DAY_COUNT = 7
private const val HEATMAP_HOUR_COUNT = 24
private const val HOURS_PER_DAY = 24
private const val HEATMAP_HOURS_PER_DAY = 24.0

internal object InsightExecutorBindings {
    fun executeKpi(binding: InsightDataBinding.Kpi, digest: InsightDigest): InsightWidgetData.KPI {
        val value =
            when (binding.metric) {
                "totalCost" -> digest.totals.costUSD
                "totalTokens" -> digest.totals.totalTokens.toDouble()
                "totalSessions" -> digest.totals.sessionCount.toDouble()
                "cacheHitRate" -> if (digest.totals.totalTokens > 0) digest.totals.cacheReadTokens.toDouble() / digest.totals.totalTokens.toDouble() else 0.0
                "inputTokens" -> digest.totals.inputTokens.toDouble()
                "outputTokens" -> digest.totals.outputTokens.toDouble()
                "reasoningTokens" -> digest.totals.reasoningTokens.toDouble()
                else -> 0.0
            }
        val format =
            when (binding.metric) {
                "totalCost", "avgCostPerSession", "quotaHeadroom" -> ValueFormat.CURRENCY
                "totalTokens", "inputTokens", "outputTokens", "reasoningTokens", "totalSessions",
                "modelCount", "providerCount", "projectCount",
                -> ValueFormat.COUNT
                "cacheHitRate" -> ValueFormat.PERCENT
                else -> ValueFormat.RAW
            }
        val sparkline = digest.daily.map { it.costUSD }
        return InsightWidgetData.KPI(
            metricLabel = binding.metric,
            value = value,
            valueFormat = format,
            sparkline = sparkline,
        )
    }

    fun executeTimeSeries(binding: InsightDataBinding.TimeSeries, digest: InsightDigest): InsightWidgetData.TimeSeries {
        val points =
            digest.daily.mapIndexed { _, dp ->
                InsightWidgetData.TimeSeries.Point(
                    date = dp.day,
                    value =
                    when (binding.metric) {
                        "cost" -> dp.costUSD
                        "tokens" -> dp.totalTokens.toDouble()
                        "sessions" -> dp.sessionCount.toDouble()
                        else -> dp.costUSD
                    },
                )
            }
        val format =
            when (binding.metric) {
                "cost" -> ValueFormat.CURRENCY
                "tokens", "sessions" -> ValueFormat.COUNT
                "cacheRate" -> ValueFormat.PERCENT
                else -> ValueFormat.RAW
            }
        return InsightWidgetData.TimeSeries(
            series = listOf(InsightWidgetData.TimeSeries.Series(id = "series", name = binding.metric, points = points)),
            xAxisLabel = "Date",
            yAxisLabel = binding.metric.replaceFirstChar { it.uppercase() },
            yFormat = format,
        )
    }

    fun executeRanking(binding: InsightDataBinding.Ranking, digest: InsightDigest): InsightWidgetData.Ranking {
        val rows =
            when (binding.dimension) {
                InsightWidgetSpec.Dimension.PROVIDER ->
                    digest.providers.mapIndexed { idx, p ->
                        InsightWidgetData.Ranking.Row(
                            id = "p$idx",
                            label = p.displayName,
                            value =
                            when (binding.metric) {
                                "cost" -> p.costUSD
                                "tokens" -> p.totalTokens.toDouble()
                                "sessions" -> p.sessionCount.toDouble()
                                else -> p.costUSD
                            },
                        )
                    }
                InsightWidgetSpec.Dimension.MODEL ->
                    digest.models.mapIndexed { idx, m ->
                        InsightWidgetData.Ranking.Row(
                            id = "m$idx",
                            label = m.id,
                            value =
                            when (binding.metric) {
                                "cost" -> m.costUSD
                                "tokens" -> m.totalTokens.toDouble()
                                "sessions" -> m.sessionCount.toDouble()
                                else -> m.costUSD
                            },
                        )
                    }
                else -> emptyList()
            }.take(binding.limit)
        val format =
            when (binding.metric) {
                "cost" -> ValueFormat.CURRENCY
                "tokens", "sessions" -> ValueFormat.COUNT
                "costPerSession" -> ValueFormat.CURRENCY
                "cacheHitRate" -> ValueFormat.PERCENT
                else -> ValueFormat.RAW
            }
        return InsightWidgetData.Ranking(rows = rows, valueFormat = format, dimensionLabel = binding.dimension.name.lowercase())
    }

    fun executeDistribution(binding: InsightDataBinding.Distribution, digest: InsightDigest): InsightWidgetData.Distribution {
        val slices =
            when (binding.dimension) {
                InsightWidgetSpec.Dimension.PROVIDER ->
                    digest.providers.mapIndexed { idx, p ->
                        InsightWidgetData.Distribution.Slice(
                            id = "p$idx",
                            label = p.displayName,
                            value =
                            when (binding.metric) {
                                "cost" -> p.costUSD
                                "tokens" -> p.totalTokens.toDouble()
                                "sessions" -> p.sessionCount.toDouble()
                                else -> p.costUSD
                            },
                        )
                    }
                InsightWidgetSpec.Dimension.MODEL ->
                    digest.models.mapIndexed { idx, m ->
                        InsightWidgetData.Distribution.Slice(
                            id = "m$idx",
                            label = m.id,
                            value =
                            when (binding.metric) {
                                "cost" -> m.costUSD
                                "tokens" -> m.totalTokens.toDouble()
                                "sessions" -> m.sessionCount.toDouble()
                                else -> m.costUSD
                            },
                        )
                    }
                else -> emptyList()
            }
        val total = slices.sumOf { it.value }
        val format =
            when (binding.metric) {
                "cost" -> ValueFormat.CURRENCY
                "tokens" -> ValueFormat.TOKENS
                else -> ValueFormat.COUNT
            }
        return InsightWidgetData.Distribution(slices = slices, valueFormat = format, total = total)
    }

    fun executeHeatmap(binding: InsightDataBinding.Heatmap, digest: InsightDigest): InsightWidgetData.Heatmap {
        val dayLabels = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
        val hourLabels = (0 until HOURS_PER_DAY).map { "${it}h" }
        val cells = MutableList(HEATMAP_DAY_COUNT) { MutableList(HEATMAP_HOUR_COUNT) { 0.0 } }
        if (digest.daily.isNotEmpty()) {
            val avgPerDay =
                digest.daily.sumOf {
                    when (binding.metric) {
                        "cost" -> it.costUSD
                        "tokens" -> it.totalTokens.toDouble()
                        else -> it.sessionCount.toDouble()
                    }
                } / digest.daily.size
            for (r in 0 until HEATMAP_DAY_COUNT) {
                for (c in 0 until HEATMAP_HOUR_COUNT) {
                    cells[r][c] = avgPerDay / HEATMAP_HOURS_PER_DAY
                }
            }
        }
        val format =
            when (binding.metric) {
                "cost" -> ValueFormat.CURRENCY
                "tokens" -> ValueFormat.TOKENS
                else -> ValueFormat.COUNT
            }
        return InsightWidgetData.Heatmap(rowLabels = dayLabels, columnLabels = hourLabels, cells = cells, valueFormat = format)
    }

    fun executeQuota(binding: InsightDataBinding.Quota, digest: InsightDigest): InsightWidgetData.QuotaState {
        val buckets =
            digest.quotaSnapshots
                .filter { binding.providerKey == null || it.providerID == binding.providerKey }
                .map { qs ->
                    InsightWidgetData.QuotaState.Bucket(
                        id = qs.id,
                        providerLabel = qs.providerID,
                        bucketName = qs.bucketName,
                        used = qs.used,
                        limit = qs.limit,
                        resetsAt = qs.resetsAt,
                        symbolName = "gauge.with.dots.needle.67percent",
                    )
                }
        return InsightWidgetData.QuotaState(buckets = buckets)
    }
}
