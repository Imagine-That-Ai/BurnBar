import Foundation

/// Gateway that produces a canvas without any LLM call.
///
/// **Why it exists.** Insights is useful from day one — even with no
/// providers configured. This adapter runs locally over the digest and
/// emits a sensible canvas of 6–8 widgets using deterministic rules
/// (extending the existing `InsightEngine` heuristics into widget form).
///
/// Selected by the model picker as "Local rules · free, on-device".
public struct LocalRuleBasedAdapter: InsightModelGateway {

    public let providerKey: String = "local-rules"
    public let displayName: String = "Local rules"
    public let capabilities = InsightModelCapabilities(
        supportsStrictJSONSchema: true,
        supportsJSONObject: true,
        supportsThinking: false,
        supportsToolUse: false,
        supportsStreaming: true
    )

    public init() {}

    public func availableModels() async throws -> [InsightCatalogModel] {
        [.init(
            id: "local-rules-v1",
            displayName: "Local rules",
            providerKey: providerKey,
            egressTier: .localOnly,
            capabilities: capabilities,
            inputCostPerMtoken: 0,
            outputCostPerMtoken: 0,
            symbolName: "lock.shield.fill"
        )]
    }

    public func investigate(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let canvas = Self.buildCanvas(for: request)
                continuation.yield(.partialCanvas(canvas))
                continuation.yield(.usage(.init(
                    providerKey: providerKey,
                    modelID: "local-rules-v1",
                    startedAt: Date(),
                    completedAt: Date()
                )))
                continuation.yield(.finalCanvas(canvas))
                continuation.finish()
            }
        }
    }

    /// Build the deterministic "no model" canvas.
    public static func buildCanvas(for request: InsightInvestigateRequest) -> InsightCanvas {
        let digest = request.digest
        let window = request.canvas?.filter.window ?? .last7d
        let attribution = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )

        var canvas = InsightCanvas(
            title: request.canvas?.title ?? "Local rules · \(window.displayName)",
            summary: "Authored on-device from your digest.",
            symbolName: "sparkles.tv",
            theme: request.canvas?.theme ?? .aurora,
            filter: InsightFilter(window: window),
            modelTag: attribution,
            origin: .composed(prompt: request.prompt)
        )

        // 1. KPI tiles — cost, sessions, cache.
        canvas.add(.init(
            kind: .kpiTile,
            title: "Cost",
            spec: .kpiTile(.init(metricLabel: "Cost")),
            dataBinding: .kpi(metric: .totalCost, window: window)
        ))
        canvas.add(.init(
            kind: .kpiTile,
            title: "Sessions",
            spec: .kpiTile(.init(metricLabel: "Sessions")),
            dataBinding: .kpi(metric: .totalSessions, window: window)
        ))
        canvas.add(.init(
            kind: .kpiTile,
            title: "Cache hit",
            spec: .kpiTile(.init(metricLabel: "Cache hit")),
            dataBinding: .kpi(metric: .cacheHitRate, window: window)
        ))
        canvas.add(.init(
            kind: .kpiTile,
            title: "Models",
            spec: .kpiTile(.init(metricLabel: "Models")),
            dataBinding: .kpi(metric: .modelCount, window: window)
        ))

        // 2. Trend by provider.
        canvas.add(.init(
            kind: .timeSeriesLine,
            title: "Cost trend by provider",
            spec: .timeSeries(.init(style: .line)),
            dataBinding: .timeSeries(metric: .cost, dimension: .provider, window: window)
        ))

        // 3. Distribution donut.
        canvas.add(.init(
            kind: .donut,
            title: "Spend share",
            spec: .distribution(.init(style: .donut)),
            dataBinding: .distribution(metric: .cost, dimension: .provider, window: window)
        ))

        // 4. Top models ranking.
        canvas.add(.init(
            kind: .barRanking,
            title: "Top models",
            spec: .ranking(.init()),
            dataBinding: .ranking(metric: .cost, dimension: .model, limit: 8, window: window)
        ))

        // 5. Heatmap of usage rhythm.
        canvas.add(.init(
            kind: .heatmap,
            title: "When you work",
            spec: .heatmap(.init()),
            dataBinding: .heatmap(metric: .sessions, window: window)
        ))

        // 6. Use-case cluster.
        canvas.add(.init(
            kind: .useCaseCluster,
            title: "Use cases",
            spec: .useCaseCluster(.init()),
            dataBinding: .useCaseClusters(window: window)
        ))

        // 7. Narrative from the existing rule engine.
        canvas.add(.init(
            kind: .narrative,
            title: "What stands out",
            spec: .narrative(.init()),
            dataBinding: .narrative(buildNarrative(from: digest)),
            rationale: "Composed by local rules — no model call."
        ))

        // Propagate canvas attribution to each widget so the chrome footer
        // shows "Local rules · Stays on device" on every card.
        for idx in canvas.widgets.indices {
            canvas.widgets[idx].modelTag = attribution
        }

        // 8. Quota gauges.
        if !digest.quotaSnapshots.isEmpty {
            canvas.add(.init(
                kind: .quotaPulse,
                title: "Quota pulse",
                spec: .quotaPulse(.init()),
                dataBinding: .quota(providerKey: nil),
                modelTag: attribution
            ))
        }

        return canvas
    }

    private static func buildNarrative(from digest: InsightDigest) -> InsightWidgetData.Narrative {
        let totalCost = String(format: "$%.2f", digest.totals.costUSD)
        let topProvider = digest.providers.first?.displayName ?? "your agents"
        let topModel = digest.models.first?.id ?? "no single model"
        let sessionCount = digest.totals.sessionCount
        let cacheRate = digest.totals.totalTokens > 0
            ? Int(round(Double(digest.totals.cacheReadTokens) / Double(digest.totals.totalTokens) * 100))
            : 0

        var bullets: [String] = []
        if sessionCount > 0 { bullets.append("\(sessionCount) sessions, \(totalCost) total.") }
        if !digest.providers.isEmpty { bullets.append("\(topProvider) led on spend.") }
        if cacheRate > 0 { bullets.append("Cache covered \(cacheRate)% of tokens.") }
        if let topAnomaly = digest.anomalies.first {
            bullets.append("Outlier day detected: \(topAnomaly.label).")
        }

        let headline: String
        if sessionCount == 0 {
            headline = "No sessions recorded yet"
        } else {
            headline = "\(sessionCount) sessions · \(totalCost)"
        }

        let body = digest.providers.isEmpty
            ? "Connect a provider or run a scan to see this canvas come alive."
            : "Your most-used model is \(topModel) on \(topProvider). The chart above tracks spend by provider — drag any widget to rearrange, and ask the composer for deeper analysis when a real model is available."

        let tone: InsightWidgetData.Narrative.Tone
        if let topAnomaly = digest.anomalies.first, topAnomaly.score > 3 {
            tone = .warning
        } else if cacheRate > 40 {
            tone = .positive
        } else {
            tone = .neutral
        }

        return .init(headline: headline, body: body, bullets: bullets, tone: tone)
    }
}
