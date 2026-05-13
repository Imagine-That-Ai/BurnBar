package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.ValueFormat

/**
 * Turns an InsightDataBinding into concrete InsightWidgetData using
 * the digest as the data source. Mirrors Swift InsightExecutor.
 *
 * On Android, macOS-only bindings (useCaseClusters, focusMatrices) return
 * InsightWidgetData.Empty with a reason explaining the limitation.
 */
object InsightExecutor {

    fun execute(
        binding: InsightDataBinding,
        digest: InsightDigest,
        canvasFilter: InsightFilter
    ): InsightWidgetData {
        val effectiveFilter = canvasFilter.overlaidBy(
            when (binding) {
                is InsightDataBinding.Kpi -> null
                is InsightDataBinding.TimeSeries -> null
                else -> null
            }
        )
        return when (binding) {
            is InsightDataBinding.Kpi -> executeKpi(binding, digest)
            is InsightDataBinding.TimeSeries -> executeTimeSeries(binding, digest)
            is InsightDataBinding.Ranking -> executeRanking(binding, digest)
            is InsightDataBinding.Distribution -> executeDistribution(binding, digest)
            is InsightDataBinding.Heatmap -> executeHeatmap(binding, digest)
            is InsightDataBinding.Quota -> executeQuota(binding, digest)
            is InsightDataBinding.Forecast -> executeForecast(binding, digest)
            is InsightDataBinding.Anomaly -> executeAnomaly(binding, digest)
            is InsightDataBinding.UseCaseClusters -> InsightWidgetData.Empty(
                reason = "Use-case clustering requires macOS session data not available on Android"
            )
            is InsightDataBinding.AgentFocusMatrix -> InsightWidgetData.Empty(
                reason = "Agent focus matrix requires macOS session data not available on Android"
            )
            is InsightDataBinding.ModelFocusMatrix -> InsightWidgetData.Empty(
                reason = "Model focus matrix requires macOS session data not available on Android"
            )
            is InsightDataBinding.Drilldown -> executeDrilldown(binding, digest)
            is InsightDataBinding.Narrative -> binding.data
            is InsightDataBinding.Recommendation -> binding.data
            is InsightDataBinding.MermaidSource -> InsightWidgetData.MermaidDiagram(binding.source)
            is InsightDataBinding.Ascii -> binding.data
            is InsightDataBinding.Composed -> InsightWidgetData.Composed(
                binding.bindings.map { execute(it, digest, canvasFilter) }
            )
            // Stub implementations for bindings that need more data processing
            is InsightDataBinding.Scatter -> executeScatter(binding, digest)
            is InsightDataBinding.Sankey -> executeSankey(binding, digest)
            is InsightDataBinding.Radar -> executeRadar(binding, digest)
            is InsightDataBinding.Cohort -> InsightWidgetData.Cohort(
                cohortLabels = emptyList(), periodLabels = emptyList(), cells = emptyList()
            )
            is InsightDataBinding.Funnel -> InsightWidgetData.Funnel(steps = emptyList())
        }
    }

    private fun executeKpi(binding: InsightDataBinding.Kpi, digest: InsightDigest): InsightWidgetData.KPI {
        val value = when (binding.metric) {
            "totalCost" -> digest.totals.costUSD
            "totalTokens" -> digest.totals.totalTokens.toDouble()
            "totalSessions" -> digest.totals.sessionCount.toDouble()
            "cacheHitRate" -> if (digest.totals.totalTokens > 0) (digest.totals.cacheReadTokens.toDouble() / digest.totals.totalTokens.toDouble()) else 0.0
            "inputTokens" -> digest.totals.inputTokens.toDouble()
            "outputTokens" -> digest.totals.outputTokens.toDouble()
            "reasoningTokens" -> digest.totals.reasoningTokens.toDouble()
            else -> 0.0
        }
        val format = when (binding.metric) {
            "totalCost", "avgCostPerSession", "quotaHeadroom" -> ValueFormat.CURRENCY
            "totalTokens", "inputTokens", "outputTokens", "reasoningTokens", "totalSessions", "modelCount", "providerCount", "projectCount" -> ValueFormat.COUNT
            "cacheHitRate" -> ValueFormat.PERCENT
            else -> ValueFormat.RAW
        }
        val sparkline = digest.daily.map { it.costUSD }
        return InsightWidgetData.KPI(
            metricLabel = binding.metric, value = value, valueFormat = format,
            sparkline = sparkline
        )
    }

    private fun executeTimeSeries(binding: InsightDataBinding.TimeSeries, digest: InsightDigest): InsightWidgetData.TimeSeries {
        val values = digest.daily.map { it.costUSD }
        val points = digest.daily.mapIndexed { idx, dp ->
            InsightWidgetData.TimeSeries.Point(date = dp.day, value = when (binding.metric) {
                "cost" -> dp.costUSD
                "tokens" -> dp.totalTokens.toDouble()
                "sessions" -> dp.sessionCount.toDouble()
                else -> dp.costUSD
            })
        }
        val format = when (binding.metric) {
            "cost" -> ValueFormat.CURRENCY
            "tokens", "sessions" -> ValueFormat.COUNT
            "cacheRate" -> ValueFormat.PERCENT
            else -> ValueFormat.RAW
        }
        return InsightWidgetData.TimeSeries(
            series = listOf(InsightWidgetData.TimeSeries.Series(id = "series", name = binding.metric, points = points)),
            xAxisLabel = "Date", yAxisLabel = binding.metric.replaceFirstChar { it.uppercase() },
            yFormat = format
        )
    }

    private fun executeRanking(binding: InsightDataBinding.Ranking, digest: InsightDigest): InsightWidgetData.Ranking {
        val rows = when (binding.dimension) {
            InsightWidgetSpec.Dimension.PROVIDER -> digest.providers.mapIndexed { idx, p ->
                InsightWidgetData.Ranking.Row(id = "p$idx", label = p.displayName, value = when (binding.metric) {
                    "cost" -> p.costUSD; "tokens" -> p.totalTokens.toDouble(); "sessions" -> p.sessionCount.toDouble()
                    else -> p.costUSD
                })
            }
            InsightWidgetSpec.Dimension.MODEL -> digest.models.mapIndexed { idx, m ->
                InsightWidgetData.Ranking.Row(id = "m$idx", label = m.id, value = when (binding.metric) {
                    "cost" -> m.costUSD; "tokens" -> m.totalTokens.toDouble(); "sessions" -> m.sessionCount.toDouble()
                    else -> m.costUSD
                })
            }
            else -> emptyList()
        }.take(binding.limit)
        val format = when (binding.metric) {
            "cost" -> ValueFormat.CURRENCY; "tokens", "sessions" -> ValueFormat.COUNT
            "costPerSession" -> ValueFormat.CURRENCY; "cacheHitRate" -> ValueFormat.PERCENT; else -> ValueFormat.RAW
        }
        return InsightWidgetData.Ranking(rows = rows, valueFormat = format, dimensionLabel = binding.dimension.name.lowercase())
    }

    private fun executeDistribution(binding: InsightDataBinding.Distribution, digest: InsightDigest): InsightWidgetData.Distribution {
        val slices = when (binding.dimension) {
            InsightWidgetSpec.Dimension.PROVIDER -> digest.providers.mapIndexed { idx, p ->
                InsightWidgetData.Distribution.Slice(id = "p$idx", label = p.displayName, value = when (binding.metric) {
                    "cost" -> p.costUSD; "tokens" -> p.totalTokens.toDouble(); "sessions" -> p.sessionCount.toDouble(); else -> p.costUSD
                })
            }
            InsightWidgetSpec.Dimension.MODEL -> digest.models.mapIndexed { idx, m ->
                InsightWidgetData.Distribution.Slice(id = "m$idx", label = m.id, value = when (binding.metric) {
                    "cost" -> m.costUSD; "tokens" -> m.totalTokens.toDouble(); "sessions" -> m.sessionCount.toDouble(); else -> m.costUSD
                })
            }
            else -> emptyList()
        }
        val total = slices.sumOf { it.value }
        val format = when (binding.metric) { "cost" -> ValueFormat.CURRENCY; "tokens" -> ValueFormat.TOKENS; else -> ValueFormat.COUNT }
        return InsightWidgetData.Distribution(slices = slices, valueFormat = format, total = total)
    }

    private fun executeHeatmap(binding: InsightDataBinding.Heatmap, digest: InsightDigest): InsightWidgetData.Heatmap {
        // Build a 7×24 heatmap from daily data (approximation from rollups)
        val dayLabels = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
        val hourLabels = (0..23).map { "${it}h" }
        val cells = MutableList(7) { MutableList(24) { 0.0 } }
        if (digest.daily.isNotEmpty()) {
            val avgPerDay = digest.daily.sumOf { when (binding.metric) { "cost" -> it.costUSD; "tokens" -> it.totalTokens.toDouble(); else -> it.sessionCount.toDouble() } } / digest.daily.size
            for (r in 0 until 7) {
                for (c in 0 until 24) {
                    cells[r][c] = avgPerDay / 24.0
                }
            }
        }
        val format = when (binding.metric) { "cost" -> ValueFormat.CURRENCY; "tokens" -> ValueFormat.TOKENS; else -> ValueFormat.COUNT }
        return InsightWidgetData.Heatmap(rowLabels = dayLabels, columnLabels = hourLabels, cells = cells, valueFormat = format)
    }

    private fun executeQuota(binding: InsightDataBinding.Quota, digest: InsightDigest): InsightWidgetData.QuotaState {
        val buckets = digest.quotaSnapshots
            .filter { binding.providerKey == null || it.providerID == binding.providerKey }
            .map { qs ->
                InsightWidgetData.QuotaState.Bucket(
                    id = qs.id, providerLabel = qs.providerID, bucketName = qs.bucketName,
                    used = qs.used, limit = qs.limit, resetsAt = qs.resetsAt,
                    symbolName = "gauge.with.dots.needle.67percent"
                )
            }
        return InsightWidgetData.QuotaState(buckets = buckets)
    }

    private fun executeForecast(binding: InsightDataBinding.Forecast, digest: InsightDigest): InsightWidgetData.Forecast {
        // Simple linear projection from daily points
        val actual = digest.daily.map { InsightWidgetData.TimeSeries.Point(date = it.day, value = it.costUSD) }
        val lastValue = actual.lastOrNull()?.value ?: 0.0
        val forecast = (1..binding.horizonDays).mapIndexed { idx, _ ->
            InsightWidgetData.TimeSeries.Point(
                date = java.time.LocalDate.now().plusDays(idx.toLong() + 1).toString(),
                value = lastValue * (1.0 + (idx * 0.01))
            )
        }
        val uncertainty = lastValue * 0.15
        val lowerBound = forecast.map { it.copy(value = (it.value - uncertainty).coerceAtLeast(0.0)) }
        val upperBound = forecast.map { it.copy(value = it.value + uncertainty) }
        return InsightWidgetData.Forecast(
            actual = actual, forecast = forecast,
            lowerBound = lowerBound, upperBound = upperBound,
            xAxisLabel = "Date", yAxisLabel = "Cost (USD)", yFormat = ValueFormat.CURRENCY,
            summary = "Projected cost based on recent trend"
        )
    }

    private fun executeAnomaly(binding: InsightDataBinding.Anomaly, digest: InsightDigest): InsightWidgetData.AnomalyTable {
        val rows = digest.anomalies.map { a ->
            InsightWidgetData.AnomalyTable.Row(id = a.id, occurredAt = a.occurredAt, label = a.label, detail = a.detail, score = a.score)
        }
        return InsightWidgetData.AnomalyTable(rows = rows)
    }

    private fun executeDrilldown(binding: InsightDataBinding.Drilldown, digest: InsightDigest): InsightWidgetData.Drilldown {
        // Android doesn't have session-level data, so we aggregate from daily
        val rows = digest.daily.take(binding.limit).mapIndexed { idx, dp ->
            InsightWidgetData.Drilldown.Row(
                id = "d$idx", title = dp.day, occurredAt = dp.day,
                costUSD = dp.costUSD, tokens = dp.totalTokens.toInt(),
                citation = com.openburnbar.data.insights.InsightCitation(id = "c$idx", kind = com.openburnbar.data.insights.InsightCitation.Kind.Day(date = dp.day), label = dp.day)
            )
        }
        return InsightWidgetData.Drilldown(rows = rows)
    }

    private fun executeScatter(binding: InsightDataBinding.Scatter, digest: InsightDigest): InsightWidgetData.Scatter {
        val points = digest.providers.mapIndexed { idx, p ->
            InsightWidgetData.Scatter.Point(
                id = "p$idx", label = p.displayName,
                x = when (binding.xMetric) { "cost" -> p.costUSD; "tokens" -> p.totalTokens.toDouble(); else -> p.sessionCount.toDouble() },
                y = when (binding.yMetric) { "cost" -> p.costUSD; "tokens" -> p.totalTokens.toDouble(); else -> p.sessionCount.toDouble() }
            )
        }
        return InsightWidgetData.Scatter(
            points = points, xAxisLabel = binding.xMetric, yAxisLabel = binding.yMetric,
            xFormat = ValueFormat.RAW, yFormat = ValueFormat.RAW
        )
    }

    private fun executeSankey(binding: InsightDataBinding.Sankey, digest: InsightDigest): InsightWidgetData.Sankey {
        val providerNodes = digest.providers.map { InsightWidgetData.Sankey.Node(id = it.id, label = it.displayName) }
        val modelNodes = digest.models.take(5).map { InsightWidgetData.Sankey.Node(id = it.id, label = it.id) }
        val links = mutableListOf<InsightWidgetData.Sankey.Link>()
        for (m in digest.models) {
            links.add(InsightWidgetData.Sankey.Link(source = m.providerID, target = m.id, value = m.costUSD))
        }
        return InsightWidgetData.Sankey(nodes = providerNodes + modelNodes, links = links)
    }

    private fun executeRadar(binding: InsightDataBinding.Radar, digest: InsightDigest): InsightWidgetData.Radar {
        val axes = listOf("Cost", "Tokens", "Sessions", "Cache Hit Rate", "Efficiency")
        val series = digest.providers.map { p ->
            InsightWidgetData.Radar.Series(
                id = p.id, name = p.displayName,
                values = listOf(p.costUSD, p.totalTokens.toDouble(), p.sessionCount.toDouble(), 0.0, 0.0)
            )
        }
        return InsightWidgetData.Radar(axes = axes, series = series)
    }
}
