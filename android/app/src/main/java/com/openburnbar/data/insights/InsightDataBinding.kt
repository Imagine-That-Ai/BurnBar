package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * Declarative description of "what data does this widget want?".
 * InsightExecutor turns a binding into concrete InsightWidgetData.
 * Mirrors Swift InsightDataBinding.
 */
@Serializable
sealed class InsightDataBinding {
    @Serializable data class Kpi(val metric: String, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class TimeSeries(val metric: String, val dimension: InsightWidgetSpec.Dimension? = null, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Ranking(val metric: String, val dimension: InsightWidgetSpec.Dimension, val limit: Int, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Distribution(val metric: String, val dimension: InsightWidgetSpec.Dimension, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Heatmap(val metric: String, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Scatter(val xMetric: String, val yMetric: String, val dimension: InsightWidgetSpec.Dimension, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Sankey(val source: InsightWidgetSpec.Dimension, val mid: InsightWidgetSpec.Dimension? = null, val target: InsightWidgetSpec.Dimension, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Radar(val target: RadarTarget, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Cohort(val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Funnel(val stages: List<String>, val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Quota(val providerKey: String? = null) : InsightDataBinding()
    @Serializable data class Forecast(val metric: String, val horizonDays: Int) : InsightDataBinding()
    @Serializable data class Anomaly(val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class UseCaseClusters(val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class AgentFocusMatrix(val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class ModelFocusMatrix(val window: InsightTimeWindow) : InsightDataBinding()
    @Serializable data class Drilldown(val limit: Int) : InsightDataBinding()
    @Serializable data class Narrative(val data: InsightWidgetData.Narrative) : InsightDataBinding()
    @Serializable data class Recommendation(val data: InsightWidgetData.Recommendation) : InsightDataBinding()
    @Serializable data class MermaidSource(val source: String) : InsightDataBinding()
    @Serializable data class Ascii(val data: InsightWidgetData.ASCIICard) : InsightDataBinding()
    @Serializable data class Composed(val bindings: List<InsightDataBinding>) : InsightDataBinding()

    @Serializable
    sealed class RadarTarget {
        @Serializable data class Agent(val id: String) : RadarTarget()
        @Serializable data class Model(val id: String) : RadarTarget()
        @Serializable data object AllAgents : RadarTarget()
        @Serializable data object AllModels : RadarTarget()
    }

    @Serializable
    enum class KPIMetric(val key: String) {
        TOTAL_COST("totalCost"), TOTAL_TOKENS("totalTokens"), TOTAL_SESSIONS("totalSessions"),
        CACHE_HIT_RATE("cacheHitRate"), INPUT_TOKENS("inputTokens"), OUTPUT_TOKENS("outputTokens"),
        REASONING_TOKENS("reasoningTokens"), AVG_COST_PER_SESSION("avgCostPerSession"),
        AVG_TOKENS_PER_SESSION("avgTokensPerSession"), PROVIDER_COUNT("providerCount"),
        MODEL_COUNT("modelCount"), PROJECT_COUNT("projectCount"), QUOTA_HEADROOM("quotaHeadroom")
    }

    @Serializable
    enum class TimeSeriesMetric(val key: String) {
        COST("cost"), TOKENS("tokens"), SESSIONS("sessions"), CACHE_RATE("cacheRate"), REASONING_SHARE("reasoningShare")
    }

    @Serializable
    enum class RankingMetric(val key: String) {
        COST("cost"), TOKENS("tokens"), SESSIONS("sessions"), COST_PER_SESSION("costPerSession"), CACHE_HIT_RATE("cacheHitRate")
    }

    @Serializable
    enum class DistributionMetric(val key: String) {
        COST("cost"), TOKENS("tokens"), SESSIONS("sessions")
    }

    @Serializable
    enum class HeatmapMetric(val key: String) {
        SESSIONS("sessions"), COST("cost"), TOKENS("tokens")
    }

    @Serializable
    enum class ScatterMetric(val key: String) {
        COST("cost"), TOKENS("tokens"), SESSIONS("sessions"),
        COST_PER_MTOKEN("costPerMtoken"), CACHE_RATE("cacheRate"), AVG_DURATION_SECONDS("avgDurationSeconds")
    }
}
