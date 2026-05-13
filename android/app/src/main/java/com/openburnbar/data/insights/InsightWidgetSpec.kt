package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Compile-time-exhaustive sum of every widget's authoring spec.
 * Mirrors Swift InsightWidgetSpec — each variant maps to its InsightWidgetKind.
 * All nested enums carry @SerialName matching the Swift Codable keys.
 */
@Serializable
sealed class InsightWidgetSpec {
    abstract val kind: InsightWidgetKind

    @Serializable data class KPITile(val spec: KPITileSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.KPI_TILE
    }
    @Serializable data class TimeSeries(val spec: TimeSeriesSpec) : InsightWidgetSpec() {
        override val kind get() = with(spec) {
            when (style) {
                TimeSeriesSpec.Style.AREA -> InsightWidgetKind.TIME_SERIES_AREA
                TimeSeriesSpec.Style.STREAM -> InsightWidgetKind.STREAM_GRAPH
                else -> InsightWidgetKind.TIME_SERIES_LINE
            }
        }
    }
    @Serializable data class Ranking(val spec: RankingSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.BAR_RANKING
    }
    @Serializable data class Distribution(val spec: DistributionSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.DONUT
    }
    @Serializable data class Heatmap(val spec: HeatmapSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.HEATMAP
    }
    @Serializable data class Scatter(val spec: ScatterSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.SCATTER
    }
    @Serializable data class Sankey(val spec: SankeySpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.SANKEY
    }
    @Serializable data class Radar(val spec: RadarSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.RADAR
    }
    @Serializable data class Cohort(val spec: CohortSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.COHORT
    }
    @Serializable data class Funnel(val spec: FunnelSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.FUNNEL
    }
    @Serializable data class QuotaPulse(val spec: QuotaPulseSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.QUOTA_PULSE
    }
    @Serializable data class Forecast(val spec: ForecastSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.FORECAST
    }
    @Serializable data class AnomalyTable(val spec: AnomalyTableSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.ANOMALY_TABLE
    }
    @Serializable data class Narrative(val spec: NarrativeSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.NARRATIVE
    }
    @Serializable data class Recommendation(val spec: RecommendationSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.RECOMMENDATION
    }
    @Serializable data class UseCaseCluster(val spec: UseCaseClusterSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.USE_CASE_CLUSTER
    }
    @Serializable data class AgentFocusMatrix(val spec: FocusMatrixSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.AGENT_FOCUS_MATRIX
    }
    @Serializable data class ModelFocusMatrix(val spec: FocusMatrixSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.MODEL_FOCUS_MATRIX
    }
    @Serializable data class DrilldownList(val spec: DrilldownSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.DRILLDOWN_LIST
    }
    @Serializable data class Mermaid(val spec: MermaidSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.MERMAID
    }
    @Serializable data class Ascii(val spec: ASCIISpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.ASCII
    }
    @Serializable data class Composed(val spec: ComposedSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.COMPOSED
    }
    @Serializable data class Error(val spec: ErrorSpec) : InsightWidgetSpec() {
        override val kind get() = InsightWidgetKind.ERROR
    }

    // --- Per-variant spec structs ---

    @Serializable data class KPITileSpec(
        val metricLabel: String,
        val compareWindow: CompareWindow = CompareWindow.PREVIOUS_PERIOD,
        val emphasizeDelta: Boolean = true
    )

    @Serializable data class TimeSeriesSpec(
        val style: Style = Style.LINE,
        val smoothing: Smoothing = Smoothing.NONE,
        val showAnnotations: Boolean = true
    ) {
        @Serializable enum class Style {
            @SerialName("line") LINE,
            @SerialName("area") AREA,
            @SerialName("stackedArea") STACKED_AREA,
            @SerialName("stream") STREAM,
            @SerialName("bar") BAR,
            @SerialName("stackedBar") STACKED_BAR
        }
        @Serializable enum class Smoothing {
            @SerialName("none") NONE,
            @SerialName("monotone") MONOTONE,
            @SerialName("rolling7") ROLLING7
        }
    }

    @Serializable data class RankingSpec(
        val orientation: Orientation = Orientation.HORIZONTAL,
        val showValues: Boolean = true
    ) {
        @Serializable enum class Orientation {
            @SerialName("horizontal") HORIZONTAL,
            @SerialName("vertical") VERTICAL
        }
    }

    @Serializable data class DistributionSpec(
        val style: Style = Style.DONUT,
        val showLegend: Boolean = true
    ) {
        @Serializable enum class Style {
            @SerialName("donut") DONUT,
            @SerialName("pie") PIE,
            @SerialName("treemap") TREEMAP
        }
    }

    @Serializable data class HeatmapSpec(val palette: Palette = Palette.EMBER) {
        @Serializable enum class Palette {
            @SerialName("ember") EMBER,
            @SerialName("mercury") MERCURY,
            @SerialName("whimsy") WHIMSY,
            @SerialName("mono") MONO
        }
    }

    @Serializable data class ScatterSpec(val logX: Boolean = false, val logY: Boolean = false, val bubble: Boolean = false)
    @Serializable data class SankeySpec(val placeholder: Unit = Unit)
    @Serializable data class RadarSpec(val fill: Boolean = true)
    @Serializable data class CohortSpec(val placeholder: Unit = Unit)
    @Serializable data class FunnelSpec(val placeholder: Unit = Unit)
    @Serializable data class QuotaPulseSpec(val compact: Boolean = false)
    @Serializable data class ForecastSpec(val showBands: Boolean = true)
    @Serializable data class AnomalyTableSpec(val minScore: Double = 2.0)

    @Serializable data class NarrativeSpec(val emphasize: Emphasis = Emphasis.BALANCED) {
        @Serializable enum class Emphasis {
            @SerialName("headlineOnly") HEADLINE_ONLY,
            @SerialName("balanced") BALANCED,
            @SerialName("deepDive") DEEP_DIVE
        }
    }

    @Serializable data class RecommendationSpec(val category: Category = Category.EFFICIENCY) {
        @Serializable enum class Category {
            @SerialName("efficiency") EFFICIENCY,
            @SerialName("quality") QUALITY,
            @SerialName("cost") COST,
            @SerialName("quota") QUOTA,
            @SerialName("risk") RISK,
            @SerialName("learning") LEARNING
        }
    }

    @Serializable data class UseCaseClusterSpec(val maxClusters: Int = 12)
    @Serializable data class FocusMatrixSpec(val palette: HeatmapSpec.Palette = HeatmapSpec.Palette.WHIMSY)
    @Serializable data class DrilldownSpec(val groupBy: Dimension? = null)
    @Serializable data class MermaidSpec(val placeholder: Unit = Unit)
    @Serializable data class ASCIISpec(val placeholder: Unit = Unit)
    @Serializable data class ComposedSpec(val children: List<InsightWidgetSpec>)
    @Serializable data class ErrorSpec(val message: String)

    @Serializable enum class CompareWindow {
        @SerialName("none") NONE,
        @SerialName("previousPeriod") PREVIOUS_PERIOD,
        @SerialName("weekOverWeek") WEEK_OVER_WEEK,
        @SerialName("monthOverMonth") MONTH_OVER_MONTH,
        @SerialName("yearOverYear") YEAR_OVER_YEAR
    }

    @Serializable enum class Dimension {
        @SerialName("provider") PROVIDER,
        @SerialName("model") MODEL,
        @SerialName("project") PROJECT,
        @SerialName("device") DEVICE,
        @SerialName("session") SESSION,
        @SerialName("file") FILE,
        @SerialName("day") DAY,
        @SerialName("hourOfDay") HOUR_OF_DAY,
        @SerialName("dayOfWeek") DAY_OF_WEEK,
        @SerialName("focus") FOCUS,
        @SerialName("useCase") USE_CASE
    }
}
