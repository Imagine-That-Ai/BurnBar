package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.ValueFormat

private const val FORECAST_UNCERTAINTY_FACTOR = 0.15
private const val SANKEY_MODEL_LIMIT = 5

internal object InsightExecutorExtendedBindings {
    fun executeForecast(binding: InsightDataBinding.Forecast, digest: InsightDigest): InsightWidgetData.Forecast {
        val actual = digest.daily.map { InsightWidgetData.TimeSeries.Point(date = it.day, value = it.costUSD) }
        val lastValue = actual.lastOrNull()?.value ?: 0.0
        val forecast =
            (1..binding.horizonDays).mapIndexed { idx, _ ->
                InsightWidgetData.TimeSeries.Point(
                    date = java.time.LocalDate.now().plusDays(idx.toLong() + 1).toString(),
                    value = lastValue * (1.0 + idx * 0.01),
                )
            }
        val uncertainty = lastValue * FORECAST_UNCERTAINTY_FACTOR
        val lowerBound = forecast.map { it.copy(value = (it.value - uncertainty).coerceAtLeast(0.0)) }
        val upperBound = forecast.map { it.copy(value = it.value + uncertainty) }
        return InsightWidgetData.Forecast(
            actual = actual,
            forecast = forecast,
            lowerBound = lowerBound,
            upperBound = upperBound,
            xAxisLabel = "Date",
            yAxisLabel = "Cost (USD)",
            yFormat = ValueFormat.CURRENCY,
            summary = "Projected cost based on recent trend",
        )
    }

    @Suppress("UnusedParameter")
    fun executeAnomaly(binding: InsightDataBinding.Anomaly, digest: InsightDigest): InsightWidgetData.AnomalyTable {
        val rows =
            digest.anomalies.map { a ->
                InsightWidgetData.AnomalyTable.Row(id = a.id, occurredAt = a.occurredAt, label = a.label, detail = a.detail, score = a.score)
            }
        return InsightWidgetData.AnomalyTable(rows = rows)
    }

    fun executeDrilldown(binding: InsightDataBinding.Drilldown, digest: InsightDigest): InsightWidgetData.Drilldown {
        val rows =
            digest.daily.take(binding.limit).mapIndexed { idx, dp ->
                InsightWidgetData.Drilldown.Row(
                    id = "d$idx",
                    title = dp.day,
                    occurredAt = dp.day,
                    costUSD = dp.costUSD,
                    tokens = dp.totalTokens.toInt(),
                    citation = com.openburnbar.data.insights.InsightCitation(
                        id = "c$idx",
                        kind = com.openburnbar.data.insights.InsightCitation.Kind.Day(date = dp.day),
                        label = dp.day,
                    ),
                )
            }
        return InsightWidgetData.Drilldown(rows = rows)
    }

    fun executeScatter(binding: InsightDataBinding.Scatter, digest: InsightDigest): InsightWidgetData.Scatter {
        val points =
            digest.providers.mapIndexed { idx, p ->
                InsightWidgetData.Scatter.Point(
                    id = "p$idx",
                    label = p.displayName,
                    x =
                    when (binding.xMetric) {
                        "cost" -> p.costUSD
                        "tokens" -> p.totalTokens.toDouble()
                        else -> p.sessionCount.toDouble()
                    },
                    y =
                    when (binding.yMetric) {
                        "cost" -> p.costUSD
                        "tokens" -> p.totalTokens.toDouble()
                        else -> p.sessionCount.toDouble()
                    },
                )
            }
        return InsightWidgetData.Scatter(
            points = points,
            xAxisLabel = binding.xMetric,
            yAxisLabel = binding.yMetric,
            xFormat = ValueFormat.RAW,
            yFormat = ValueFormat.RAW,
        )
    }

    @Suppress("UnusedParameter")
    fun executeSankey(binding: InsightDataBinding.Sankey, digest: InsightDigest): InsightWidgetData.Sankey {
        val providerNodes = digest.providers.map { InsightWidgetData.Sankey.Node(id = it.id, label = it.displayName) }
        val modelNodes = digest.models.take(SANKEY_MODEL_LIMIT).map { InsightWidgetData.Sankey.Node(id = it.id, label = it.id) }
        val links = digest.models.map { m ->
            InsightWidgetData.Sankey.Link(source = m.providerID, target = m.id, value = m.costUSD)
        }
        return InsightWidgetData.Sankey(nodes = providerNodes + modelNodes, links = links)
    }

    @Suppress("UnusedParameter")
    fun executeRadar(binding: InsightDataBinding.Radar, digest: InsightDigest): InsightWidgetData.Radar {
        val axes = listOf("Cost", "Tokens", "Sessions", "Cache Hit Rate", "Efficiency")
        val series =
            digest.providers.map { p ->
                InsightWidgetData.Radar.Series(
                    id = p.id,
                    name = p.displayName,
                    values = listOf(p.costUSD, p.totalTokens.toDouble(), p.sessionCount.toDouble(), 0.0, 0.0),
                )
            }
        return InsightWidgetData.Radar(axes = axes, series = series)
    }
}
