package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The complete registry of widget kinds the Insights tab can render.
 * Mirrors `InsightWidgetKind` in Swift — adding a new kind requires
 * updating this enum, the matching spec, data binding, executor, and renderer.
 */
@Serializable
enum class InsightWidgetKind(val displayName: String, val defaultSpanColumns: Int, val defaultSpanRows: Int, val isLLMAuthored: Boolean) {
    @SerialName("kpiTile") KPI_TILE("KPI Tile", 3, 2, false),
    @SerialName("timeSeriesLine") TIME_SERIES_LINE("Trend (Line)", 8, 3, false),
    @SerialName("timeSeriesArea") TIME_SERIES_AREA("Trend (Area)", 8, 3, false),
    @SerialName("streamGraph") STREAM_GRAPH("Stream Graph", 12, 3, false),
    @SerialName("barRanking") BAR_RANKING("Top-N Ranking", 4, 4, false),
    @SerialName("donut") DONUT("Donut", 4, 3, false),
    @SerialName("treemap") TREEMAP("Treemap", 6, 4, false),
    @SerialName("heatmap") HEATMAP("Heatmap", 6, 3, false),
    @SerialName("scatter") SCATTER("Scatter", 6, 4, false),
    @SerialName("sankey") SANKEY("Sankey Flow", 12, 4, false),
    @SerialName("radar") RADAR("Radar", 6, 4, false),
    @SerialName("cohort") COHORT("Cohort Retention", 8, 4, false),
    @SerialName("funnel") FUNNEL("Funnel", 4, 4, false),
    @SerialName("quotaPulse") QUOTA_PULSE("Quota Pulse", 6, 3, false),
    @SerialName("forecast") FORECAST("Forecast", 8, 3, false),
    @SerialName("anomalyTable") ANOMALY_TABLE("Anomaly Table", 6, 4, false),
    @SerialName("narrative") NARRATIVE("Narrative", 8, 3, true),
    @SerialName("recommendation") RECOMMENDATION("Recommendation", 8, 3, true),
    @SerialName("useCaseCluster") USE_CASE_CLUSTER("Use-Case Cluster", 8, 4, true),
    @SerialName("agentFocusMatrix") AGENT_FOCUS_MATRIX("Agent Focus Matrix", 6, 4, true),
    @SerialName("modelFocusMatrix") MODEL_FOCUS_MATRIX("Model Focus Matrix", 6, 4, true),
    @SerialName("drilldownList") DRILLDOWN_LIST("Drilldown List", 6, 4, false),
    @SerialName("mermaid") MERMAID("Diagram", 8, 4, true),
    @SerialName("ascii") ASCII("ASCII Card", 6, 3, true),
    @SerialName("composed") COMPOSED("Composed", 8, 6, false),
    @SerialName("error") ERROR("Error", 4, 2, false);
}
