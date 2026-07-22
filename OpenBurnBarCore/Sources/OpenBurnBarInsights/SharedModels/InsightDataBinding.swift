import Foundation

/// Declarative description of "what data does this widget want?".
///
/// `InsightExecutor` turns a binding into concrete `InsightWidgetData`.
/// Bindings are produced by the LLM (when authoring a canvas), by built-in
/// templates, or by the user editing a widget in the inspector. Bindings
/// never reach the data store directly — `InsightExecutor` does.
public enum InsightDataBinding: Codable, Hashable, Sendable {
    case kpi(metric: KPIMetric, window: InsightTimeWindow)
    case timeSeries(metric: TimeSeriesMetric, dimension: Dimension?, window: InsightTimeWindow)
    case ranking(metric: RankingMetric, dimension: Dimension, limit: Int, window: InsightTimeWindow)
    case distribution(metric: DistributionMetric, dimension: Dimension, window: InsightTimeWindow)
    case heatmap(metric: HeatmapMetric, window: InsightTimeWindow)
    case scatter(xMetric: ScatterMetric, yMetric: ScatterMetric, dimension: Dimension, window: InsightTimeWindow)
    case sankey(source: Dimension, mid: Dimension?, target: Dimension, window: InsightTimeWindow)
    case radar(target: RadarTarget, window: InsightTimeWindow)
    case cohort(window: InsightTimeWindow)
    case funnel(stages: [String], window: InsightTimeWindow)
    case quota(providerKey: String?)
    case forecast(metric: TimeSeriesMetric, horizonDays: Int)
    case anomaly(window: InsightTimeWindow)
    case useCaseClusters(window: InsightTimeWindow)
    case agentFocusMatrix(window: InsightTimeWindow)
    case modelFocusMatrix(window: InsightTimeWindow)
    case drilldown(limit: Int)
    /// Body provided by the LLM directly.
    case narrative(InsightWidgetData.Narrative)
    case recommendation(InsightWidgetData.Recommendation)
    case mermaid(source: String)
    case ascii(InsightWidgetData.ASCIICard)
    case composed([InsightDataBinding])

    public enum KPIMetric: String, Codable, Hashable, Sendable, CaseIterable {
        case totalCost, totalTokens, totalSessions, cacheHitRate
        case inputTokens, outputTokens, reasoningTokens
        case avgCostPerSession, avgTokensPerSession
        case providerCount, modelCount, projectCount
        case quotaHeadroom    // weighted average across quota buckets
    }

    public enum TimeSeriesMetric: String, Codable, Hashable, Sendable, CaseIterable {
        case cost, tokens, sessions, cacheRate, reasoningShare
    }

    public enum RankingMetric: String, Codable, Hashable, Sendable, CaseIterable {
        case cost, tokens, sessions, costPerSession, cacheHitRate
    }

    public enum DistributionMetric: String, Codable, Hashable, Sendable, CaseIterable {
        case cost, tokens, sessions
    }

    public enum HeatmapMetric: String, Codable, Hashable, Sendable, CaseIterable {
        case sessions, cost, tokens
    }

    public enum ScatterMetric: String, Codable, Hashable, Sendable, CaseIterable {
        case cost, tokens, sessions, costPerMtoken, cacheRate, avgDurationSeconds
    }

    public enum Dimension: String, Codable, Hashable, Sendable, CaseIterable {
        case provider
        case model
        case project
        case device
        case session
        case file
        case day
        case hourOfDay
        case dayOfWeek
        case focus
        case useCase
    }

    public enum RadarTarget: Codable, Hashable, Sendable {
        case agent(String)    // AgentProvider rawValue
        case model(String)    // model identifier
        case allAgents
        case allModels
    }
}
