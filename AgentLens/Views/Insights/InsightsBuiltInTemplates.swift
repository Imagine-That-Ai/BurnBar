import Foundation
import OpenBurnBarCore

/// Eight ready-to-go canvas templates the user can stamp.
enum InsightsBuiltInTemplates {

    static var all: [InsightCanvasTemplate] {
        [today, costAudit, agentFocus, modelFocus, useCaseLibrary, quotaHealth, quarterlyReview, anomalies]
    }

    // MARK: - Today

    static var today: InsightCanvasTemplate {
        .init(
            id: "today",
            title: "Today",
            summary: "A daily snapshot of cost, sessions, cache, and your top model.",
            symbolName: "sun.max.fill",
            theme: .aurora,
            widgets: [
                widget(.kpiTile, title: "Cost", binding: .kpi(metric: .totalCost, window: .today)),
                widget(.kpiTile, title: "Sessions", binding: .kpi(metric: .totalSessions, window: .today)),
                widget(.kpiTile, title: "Cache hit", binding: .kpi(metric: .cacheHitRate, window: .today)),
                widget(.kpiTile, title: "Tokens", binding: .kpi(metric: .totalTokens, window: .today)),
                widget(.timeSeriesLine, title: "Today by provider",
                       binding: .timeSeries(metric: .cost, dimension: .provider, window: .today),
                       spec: .timeSeries(.init(style: .line))),
                widget(.heatmap, title: "When you worked",
                       binding: .heatmap(metric: .sessions, window: .today)),
                widget(.narrative, title: "Today's narrative",
                       binding: .narrative(.init(headline: "Today",
                                                  body: "A daily summary will appear here once you run an investigation.")),
                       spec: .narrative(.init())),
                widget(.quotaPulse, title: "Quota pulse",
                       binding: .quota(providerKey: nil))
            ],
            layout: defaultLayout(),
            filter: InsightFilter(window: .today)
        )
    }

    // MARK: - Cost audit

    static var costAudit: InsightCanvasTemplate {
        .init(
            id: "cost-audit-7d",
            title: "Cost Audit (7d)",
            summary: "Where the money went last week.",
            symbolName: "dollarsign.circle.fill",
            theme: .ember,
            widgets: [
                widget(.kpiTile, title: "7d cost", binding: .kpi(metric: .totalCost, window: .last7d)),
                widget(.kpiTile, title: "Avg / session",
                       binding: .kpi(metric: .avgCostPerSession, window: .last7d)),
                widget(.timeSeriesLine, title: "Cost trend",
                       binding: .timeSeries(metric: .cost, dimension: .provider, window: .last7d),
                       spec: .timeSeries(.init(style: .area))),
                widget(.treemap, title: "Spend by provider × model",
                       binding: .distribution(metric: .cost, dimension: .model, window: .last7d),
                       spec: .distribution(.init(style: .treemap))),
                widget(.scatter, title: "Efficiency frontier",
                       binding: .scatter(xMetric: .tokens, yMetric: .cost, dimension: .model, window: .last7d)),
                widget(.barRanking, title: "Top spenders",
                       binding: .ranking(metric: .cost, dimension: .model, limit: 10, window: .last7d)),
                widget(.forecast, title: "Next 7d projection",
                       binding: .forecast(metric: .cost, horizonDays: 7)),
                widget(.recommendation, title: "Top recommendation",
                       binding: .recommendation(.init(headline: "Run an investigation",
                                                       rationale: "Recommendations populate after the first investigation.",
                                                       action: "Ask the composer 'how do I spend less?'")))
            ],
            layout: defaultLayout(),
            filter: InsightFilter(window: .last7d)
        )
    }

    // MARK: - Agent focus

    static var agentFocus: InsightCanvasTemplate {
        .init(
            id: "agent-focus",
            title: "Agent Focus",
            summary: "What each agent is being used for.",
            symbolName: "person.crop.square.filled.and.at.rectangle",
            theme: .whimsy,
            widgets: [
                widget(.agentFocusMatrix, title: "Focuses by agent",
                       binding: .agentFocusMatrix(window: .last30d)),
                widget(.radar, title: "Top agents — capability fingerprint",
                       binding: .radar(target: .allAgents, window: .last30d)),
                widget(.useCaseCluster, title: "Common use cases",
                       binding: .useCaseClusters(window: .last30d)),
                widget(.drilldownList, title: "Recent sessions",
                       binding: .drilldown(limit: 20))
            ],
            layout: defaultLayout(),
            filter: InsightFilter(window: .last30d)
        )
    }

    // MARK: - Model focus

    static var modelFocus: InsightCanvasTemplate {
        .init(
            id: "model-focus",
            title: "Model Focus",
            summary: "Where each model excels.",
            symbolName: "cpu.fill",
            theme: .mercury,
            widgets: [
                widget(.donut, title: "Model mix",
                       binding: .distribution(metric: .tokens, dimension: .model, window: .last30d)),
                widget(.modelFocusMatrix, title: "Focuses by model",
                       binding: .modelFocusMatrix(window: .last30d)),
                widget(.scatter, title: "Cost-per-Mtoken vs. volume",
                       binding: .scatter(xMetric: .tokens, yMetric: .costPerMtoken,
                                          dimension: .model, window: .last30d)),
                widget(.narrative, title: "Model shift",
                       binding: .narrative(.init(headline: "—", body: "Run an investigation for narrative.")),
                       spec: .narrative(.init()))
            ],
            layout: defaultLayout(),
            filter: InsightFilter(window: .last30d)
        )
    }

    // MARK: - Use-case library

    static var useCaseLibrary: InsightCanvasTemplate {
        .init(
            id: "use-case-library",
            title: "Use-Case Library",
            summary: "Tags, clusters, and examples.",
            symbolName: "tag.circle.fill",
            theme: .aurora,
            widgets: [
                widget(.useCaseCluster, title: "Use case clusters",
                       binding: .useCaseClusters(window: .last90d)),
                widget(.agentFocusMatrix, title: "Agent × focus",
                       binding: .agentFocusMatrix(window: .last90d)),
                widget(.drilldownList, title: "Top sessions",
                       binding: .drilldown(limit: 20))
            ],
            layout: defaultLayout(),
            filter: InsightFilter(window: .last90d)
        )
    }

    // MARK: - Quota health

    static var quotaHealth: InsightCanvasTemplate {
        .init(
            id: "quota-health",
            title: "Quota Health",
            summary: "How close you are to your provider caps.",
            symbolName: "gauge.with.dots.needle.67percent",
            theme: .ember,
            widgets: [
                widget(.quotaPulse, title: "Quota pulse", binding: .quota(providerKey: nil)),
                widget(.recommendation, title: "Headroom suggestion",
                       binding: .recommendation(.init(headline: "—", rationale: "—", action: "Ask the composer."))),
                widget(.timeSeriesLine, title: "Usage trend",
                       binding: .timeSeries(metric: .tokens, dimension: .provider, window: .last7d))
            ],
            layout: defaultLayout(),
            filter: InsightFilter(window: .last7d)
        )
    }

    // MARK: - Quarterly review

    static var quarterlyReview: InsightCanvasTemplate {
        .init(
            id: "quarterly-review",
            title: "Quarterly Review",
            summary: "90 days at a glance.",
            symbolName: "calendar",
            theme: .mercury,
            widgets: [
                widget(.kpiTile, title: "90d cost", binding: .kpi(metric: .totalCost, window: .last90d)),
                widget(.kpiTile, title: "Sessions", binding: .kpi(metric: .totalSessions, window: .last90d)),
                widget(.timeSeriesLine, title: "Cost over 90d",
                       binding: .timeSeries(metric: .cost, dimension: .provider, window: .last90d),
                       spec: .timeSeries(.init(style: .area))),
                widget(.cohort, title: "Cohort retention",
                       binding: .cohort(window: .last90d)),
                widget(.barRanking, title: "Top 10 models",
                       binding: .ranking(metric: .cost, dimension: .model, limit: 10, window: .last90d)),
                widget(.narrative, title: "Highlights",
                       binding: .narrative(.init(headline: "—", body: "Run an investigation.")),
                       spec: .narrative(.init()))
            ],
            layout: defaultLayout(),
            filter: InsightFilter(window: .last90d)
        )
    }

    // MARK: - Anomalies

    static var anomalies: InsightCanvasTemplate {
        .init(
            id: "anomalies",
            title: "Anomalies",
            summary: "Outlier days, spikes, and dips.",
            symbolName: "exclamationmark.triangle.fill",
            theme: .ember,
            widgets: [
                widget(.anomalyTable, title: "Anomaly table",
                       binding: .anomaly(window: .last90d)),
                widget(.timeSeriesLine, title: "Cost with anomalies",
                       binding: .timeSeries(metric: .cost, dimension: nil, window: .last90d)),
                widget(.drilldownList, title: "Sessions on outlier days",
                       binding: .drilldown(limit: 12)),
                widget(.narrative, title: "Per-anomaly explanation",
                       binding: .narrative(.init(headline: "—", body: "—")),
                       spec: .narrative(.init()))
            ],
            layout: defaultLayout(),
            filter: InsightFilter(window: .last90d)
        )
    }

    // MARK: - Helpers

    private static func widget(_ kind: InsightWidgetKind,
                               title: String,
                               binding: InsightDataBinding,
                               spec: InsightWidgetSpec? = nil) -> InsightWidget {
        InsightWidget(
            kind: kind,
            title: title,
            spec: spec ?? defaultSpec(for: kind),
            dataBinding: binding
        )
    }

    private static func defaultSpec(for kind: InsightWidgetKind) -> InsightWidgetSpec {
        switch kind {
        case .kpiTile: return .kpiTile(.init(metricLabel: ""))
        case .timeSeriesLine: return .timeSeries(.init(style: .line))
        case .timeSeriesArea: return .timeSeries(.init(style: .area))
        case .streamGraph: return .timeSeries(.init(style: .stream))
        case .barRanking: return .ranking(.init())
        case .donut: return .distribution(.init(style: .donut))
        case .treemap: return .distribution(.init(style: .treemap))
        case .heatmap: return .heatmap(.init())
        case .scatter: return .scatter(.init())
        case .sankey: return .sankey(.init())
        case .radar: return .radar(.init())
        case .cohort: return .cohort(.init())
        case .funnel: return .funnel(.init())
        case .quotaPulse: return .quotaPulse(.init())
        case .forecast: return .forecast(.init())
        case .anomalyTable: return .anomalyTable(.init())
        case .narrative: return .narrative(.init())
        case .recommendation: return .recommendation(.init())
        case .useCaseCluster: return .useCaseCluster(.init())
        case .agentFocusMatrix: return .agentFocusMatrix(.init())
        case .modelFocusMatrix: return .modelFocusMatrix(.init())
        case .drilldownList: return .drilldownList(.init())
        case .mermaid: return .mermaid(.init())
        case .ascii: return .ascii(.init())
        case .composed: return .composed(.init(children: []))
        case .error: return .error(.init(message: ""))
        }
    }

    /// Layout that places widgets row-major into 12 columns.
    private static func defaultLayout() -> InsightLayout {
        InsightLayout(columnCount: 12, rowHeight: 96, gap: 12)
    }
}
