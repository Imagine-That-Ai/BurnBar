package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Concrete value-typed data shape that renderers consume.
 * Produced by InsightExecutor or by the LLM gateway.
 * Mirrors Swift InsightWidgetData one-to-one.
 */
@Serializable
sealed class InsightWidgetData {
    @Serializable data class KPI(
        val metricLabel: String, val value: Double, val valueFormat: ValueFormat,
        val delta: Double? = null, val deltaIsPercent: Boolean = true,
        val sparkline: List<Double> = emptyList(), val contextLabel: String? = null
    ) : InsightWidgetData()

    @Serializable data class TimeSeries(
        val series: List<Series>, val xAxisLabel: String, val yAxisLabel: String,
        val yFormat: ValueFormat, val annotations: List<Annotation> = emptyList()
    ) : InsightWidgetData() {
        @Serializable data class Series(val id: String, val name: String, val colorHex: String? = null, val points: List<Point>)
        @Serializable data class Point(val date: String, val value: Double)
        @Serializable data class Annotation(val date: String, val label: String, val tone: Tone)
        @Serializable enum class Tone {
            @SerialName("positive") POSITIVE,
            @SerialName("neutral") NEUTRAL,
            @SerialName("warning") WARNING,
            @SerialName("negative") NEGATIVE
        }
    }

    @Serializable data class Ranking(
        val rows: List<Row>, val valueFormat: ValueFormat, val dimensionLabel: String
    ) : InsightWidgetData() {
        @Serializable data class Row(val id: String, val label: String, val value: Double, val secondaryLabel: String? = null, val colorHex: String? = null)
    }

    @Serializable data class Distribution(
        val slices: List<Slice>, val valueFormat: ValueFormat, val total: Double
    ) : InsightWidgetData() {
        @Serializable data class Slice(val id: String, val label: String, val value: Double, val colorHex: String? = null)
    }

    @Serializable data class Heatmap(
        val rowLabels: List<String>, val columnLabels: List<String>,
        val cells: List<List<Double>>, val valueFormat: ValueFormat
    ) : InsightWidgetData()

    @Serializable data class Scatter(
        val points: List<Point>, val xAxisLabel: String, val yAxisLabel: String,
        val xFormat: ValueFormat, val yFormat: ValueFormat
    ) : InsightWidgetData() {
        @Serializable data class Point(val id: String, val label: String, val x: Double, val y: Double, val size: Double = 1.0, val colorHex: String? = null)
    }

    @Serializable data class Sankey(val nodes: List<Node>, val links: List<Link>) : InsightWidgetData() {
        @Serializable data class Node(val id: String, val label: String, val colorHex: String? = null)
        @Serializable data class Link(val source: String, val target: String, val value: Double) {
            val id: String get() = "$source→$target"
        }
    }

    @Serializable data class Radar(val axes: List<String>, val series: List<Series>) : InsightWidgetData() {
        @Serializable data class Series(val id: String, val name: String, val values: List<Double>, val colorHex: String? = null)
    }

    @Serializable data class Cohort(
        val cohortLabels: List<String>, val periodLabels: List<String>, val cells: List<List<Double?>>
    ) : InsightWidgetData()

    @Serializable data class Funnel(val steps: List<Step>) : InsightWidgetData() {
        @Serializable data class Step(val id: String, val label: String, val count: Double)
    }

    @Serializable data class QuotaState(val buckets: List<Bucket>) : InsightWidgetData() {
        @Serializable data class Bucket(
            val id: String, val providerLabel: String, val bucketName: String,
            val used: Double, val limit: Double? = null, val resetsAt: String? = null,
            val symbolName: String, val colorHex: String? = null
        ) {
            val fraction: Double get() = limit?.let { if (it > 0) (used / it).coerceIn(0.0, 1.0) else 0.0 } ?: 0.0
        }
    }

    @Serializable data class Forecast(
        val actual: List<TimeSeries.Point>, val forecast: List<TimeSeries.Point>,
        val lowerBound: List<TimeSeries.Point>, val upperBound: List<TimeSeries.Point>,
        val xAxisLabel: String, val yAxisLabel: String, val yFormat: ValueFormat,
        val summary: String? = null
    ) : InsightWidgetData()

    @Serializable data class AnomalyTable(val rows: List<Row>) : InsightWidgetData() {
        @Serializable data class Row(val id: String, val occurredAt: String, val label: String, val detail: String? = null, val score: Double, val citations: List<InsightCitation> = emptyList())
    }

    @Serializable data class Narrative(
        val headline: String, val body: String, val bullets: List<String> = emptyList(),
        val tone: Tone = Tone.NEUTRAL, val citations: List<InsightCitation> = emptyList(),
        val sparkline: List<Double> = emptyList()
    ) : InsightWidgetData() {
        @Serializable enum class Tone {
            @SerialName("positive") POSITIVE,
            @SerialName("neutral") NEUTRAL,
            @SerialName("warning") WARNING,
            @SerialName("negative") NEGATIVE
        }
    }

    @Serializable data class Recommendation(
        val headline: String, val rationale: String, val action: String,
        val estimatedImpact: String? = null, val confidence: Confidence = Confidence.MEDIUM,
        val citations: List<InsightCitation> = emptyList()
    ) : InsightWidgetData() {
        @Serializable enum class Confidence {
            @SerialName("low") LOW,
            @SerialName("medium") MEDIUM,
            @SerialName("high") HIGH
        }
    }

    @Serializable data class UseCaseCluster(val clusters: List<Cluster>) : InsightWidgetData() {
        @Serializable data class Cluster(val id: String, val label: String, val size: Int, val exampleSessionIDs: List<String> = emptyList(), val colorHex: String? = null)
    }

    @Serializable data class FocusMatrix(
        val rowLabels: List<String>, val columnLabels: List<String>, val cells: List<List<Double>>
    ) : InsightWidgetData()

    @Serializable data class Drilldown(val rows: List<Row>) : InsightWidgetData() {
        @Serializable data class Row(val id: String, val title: String, val subtitle: String? = null, val occurredAt: String, val costUSD: Double? = null, val tokens: Int? = null, val citation: InsightCitation)
    }

    @Serializable data class MermaidDiagram(val source: String) : InsightWidgetData()

    @Serializable data class ASCIICard(val headline: String, val monoBody: String, val caption: String? = null) : InsightWidgetData()

    @Serializable data class Composed(val children: List<InsightWidgetData>) : InsightWidgetData()

    @Serializable data class Empty(val reason: String) : InsightWidgetData()

    @Serializable data class Error(val message: String) : InsightWidgetData()
}

@Serializable
enum class ValueFormat {
    @SerialName("currency") CURRENCY,
    @SerialName("tokens") TOKENS,
    @SerialName("percent") PERCENT,
    @SerialName("duration") DURATION,
    @SerialName("count") COUNT,
    @SerialName("raw") RAW
}
