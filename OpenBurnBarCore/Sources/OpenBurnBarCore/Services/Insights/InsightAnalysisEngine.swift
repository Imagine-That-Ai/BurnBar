import CryptoKit
import Foundation

public protocol InsightAnalysisEngine: Sendable {
    func analyze(_ request: InsightAnalysisRequest) async throws -> InsightAnalysisResult
}

/// Shared deterministic engine used as the safe local fallback and as the
/// baseline canvas materializer for model-generated analysis.
public struct RuleBasedInsightAnalysisEngine: InsightAnalysisEngine {
    public var platform: InsightAnalysisPlatform

    public init(platform: InsightAnalysisPlatform) {
        self.platform = platform
    }

    public func analyze(_ request: InsightAnalysisRequest) async throws -> InsightAnalysisResult {
        var result = Self.buildResult(request: request, platform: platform)
        result.resultHash = Self.resultHash(result)
        return result
    }

    public static func buildResult(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform
    ) -> InsightAnalysisResult {
        let digest = request.context.digest
        let topProvider = digest.providers.max { $0.costUSD < $1.costUSD }
        let topModel = digest.models.max { $0.costUSD < $1.costUSD }
        let biggestDay = digest.daily.max { $0.costUSD < $1.costUSD }
        let quotaRisk = digest.quotaSnapshots
            .filter { ($0.limit ?? 0) > 0 }
            .max { lhs, rhs in
                (lhs.used / max(lhs.limit ?? 1, 1)) < (rhs.used / max(rhs.limit ?? 1, 1))
            }

        var citations = request.context.evidenceIndex.map(\.citation)
        if citations.isEmpty {
            citations.append(.init(kind: .query(text: "empty-insight-context"), label: "No synced activity"))
        }

        let summary = executiveSummary(digest: digest, topProvider: topProvider, biggestDay: biggestDay)
        var findings: [InsightFinding] = []
        var generatedWidgets: [InsightGeneratedWidget] = []

        let changeWidget = generatedWidget(
            kind: .narrative,
            title: "What changed",
            dataBinding: .narrative(.init(
                headline: summary.headline,
                body: summary.body,
                bullets: summary.bullets,
                tone: summary.tone,
                citations: Array(citations.prefix(3)),
                sparkline: digest.daily.map(\.costUSD)
            )),
            reason: "Default brief lead finding.",
            modelTag: request.selectedModel,
            citations: Array(citations.prefix(3))
        )
        generatedWidgets.append(changeWidget)
        findings.append(.init(
            title: summary.headline,
            whyItMatters: summary.body,
            evidence: Array(citations.prefix(3)),
            confidence: digest.rowCount > 0 ? .high : .low,
            severity: summary.tone == .warning ? .high : .medium,
            recommendedAction: summary.action,
            generatedWidgetID: changeWidget.widget.id
        ))

        if let topProvider {
            let citation = InsightCitation(kind: .agent(provider: topProvider.id), label: topProvider.displayName)
            let widget = generatedWidget(
                kind: .barRanking,
                title: "Provider spend ranking",
                dataBinding: .ranking(metric: .cost, dimension: .provider, limit: 5, window: request.context.digest.window.asInsightWindow(default: request.currentCanvas?.filter.window ?? .last7d)),
                reason: "Shows the provider driving the main cost signal.",
                modelTag: request.selectedModel,
                citations: [citation]
            )
            generatedWidgets.append(widget)
            findings.append(.init(
                title: "\(topProvider.displayName) is the main spend driver",
                whyItMatters: "\(topProvider.displayName) accounts for \(Self.currency(topProvider.costUSD)) across \(topProvider.sessionCount) sessions in this context.",
                evidence: [citation],
                confidence: .high,
                severity: topProvider.costUSD > 0 ? .medium : .low,
                recommendedAction: "Compare \(topProvider.displayName)'s top models against lower-cost routes before the next heavy session.",
                generatedWidgetID: widget.widget.id
            ))
        }

        var anomalies: [InsightAnomaly] = digest.anomalies.prefix(3).map { anomaly in
            let citation = InsightCitation(kind: .anomaly(id: anomaly.id), label: anomaly.label)
            return .init(
                title: anomaly.label,
                occurredAt: anomaly.occurredAt,
                detail: anomaly.detail ?? "Local robust-z scoring marked this as an outlier.",
                score: anomaly.score,
                evidence: [citation],
                confidence: anomaly.score >= 3 ? .high : .medium
            )
        }
        if anomalies.isEmpty, let biggestDay {
            let day = ISO8601DateFormatter().string(from: biggestDay.day)
            anomalies.append(.init(
                title: "Highest-cost day: \(String(day.prefix(10)))",
                occurredAt: biggestDay.day,
                detail: "\(Self.currency(biggestDay.costUSD)) was the largest daily cost point in the included context.",
                score: biggestDay.costUSD,
                evidence: [.init(kind: .day(date: day), label: String(day.prefix(10)))],
                confidence: biggestDay.costUSD > 0 ? .medium : .low
            ))
        }

        var recommendations: [InsightRecommendation] = []
        if let quotaRisk, let limit = quotaRisk.limit, limit > 0 {
            let fraction = quotaRisk.used / limit
            let citation = InsightCitation(kind: .quota(provider: quotaRisk.providerID, bucket: quotaRisk.bucketName),
                                           label: "\(quotaRisk.providerID) quota")
            recommendations.append(.init(
                title: fraction >= 0.8 ? "Route away from \(quotaRisk.providerID) soon" : "Watch \(quotaRisk.providerID) quota",
                rationale: "\(quotaRisk.bucketName) is at \(Int(fraction * 100))% of its known limit.",
                recommendedAction: "Prefer a healthier configured provider before starting a deep analysis or long coding run.",
                estimatedImpact: "Avoids failed or throttled sessions when quota tightens.",
                evidence: [citation],
                confidence: .high,
                severity: fraction >= 0.8 ? .high : .medium
            ))
            generatedWidgets.append(generatedWidget(
                kind: .quotaPulse,
                title: "Quota/provider risk",
                dataBinding: .quota(providerKey: nil),
                reason: "Supports the quota-risk recommendation.",
                modelTag: request.selectedModel,
                citations: [citation]
            ))
        }
        if let topModel {
            let citation = InsightCitation(kind: .model(id: topModel.id), label: topModel.id)
            recommendations.append(.init(
                title: "Check whether \(topModel.id) is the right default",
                rationale: "\(topModel.id) is the largest model cost contributor in the included window.",
                recommendedAction: "Compare this model against the current Hermes/router default for routine work.",
                estimatedImpact: "Can reduce cost if high-capability models are handling low-risk tasks.",
                evidence: [citation],
                confidence: .medium,
                severity: .medium
            ))
        }

        generatedWidgets.append(generatedWidget(
            kind: .timeSeriesLine,
            title: "Main supporting trend",
            dataBinding: .timeSeries(metric: .cost, dimension: .provider, window: request.currentCanvas?.filter.window ?? .last7d),
            reason: "Shows whether the main finding is a one-day spike or a sustained trend.",
            modelTag: request.selectedModel,
            citations: Array(citations.prefix(3))
        ))

        let followUps = [
            "Why did cost spike this week?",
            "Which project or workflow wasted the most money?",
            "Which model should I route routine work to instead?",
            "Find quota risks in the next 24 hours."
        ].map { InsightFollowUpQuestion(question: $0) }

        return InsightAnalysisResult(
            requestID: request.id,
            platform: platform,
            timeWindow: request.currentCanvas?.filter.window ?? .last7d,
            executiveSummary: summary.body,
            modelTag: request.selectedModel,
            contextBudget: request.context.budgetReport,
            findings: Array(findings.prefix(3)),
            anomalies: anomalies,
            recommendations: recommendations,
            generatedWidgets: Array(generatedWidgets.prefix(request.maxGeneratedWidgets)),
            followUpQuestions: followUps,
            citations: citations
        )
    }

    public static func materializeCanvas(from result: InsightAnalysisResult, prompt: String) -> InsightCanvas {
        var canvas = InsightCanvas(
            title: "Intelligence Brief",
            summary: result.executiveSummary,
            symbolName: "sparkles.tv",
            theme: .aurora,
            filter: InsightFilter(window: result.timeWindow),
            modelTag: result.modelTag,
            origin: .composed(prompt: prompt)
        )
        for generated in result.generatedWidgets {
            var widget = generated.widget
            widget.modelTag = result.modelTag
            widget.freshness = .fresh
            widget.lastComputedAt = result.generatedAt
            canvas.add(widget)
        }
        return canvas
    }

    private static func executiveSummary(
        digest: InsightDigest,
        topProvider: InsightDigest.ProviderSnapshot?,
        biggestDay: InsightDigest.DailyPoint?
    ) -> (headline: String, body: String, bullets: [String], tone: InsightWidgetData.Narrative.Tone, action: String) {
        guard digest.rowCount > 0 || digest.totals.sessionCount > 0 else {
            return (
                "No synced activity in this window",
                "Insights has no usable rows for this window yet. The next useful move is to refresh sync or choose a broader window.",
                ["Included sources were still budgeted and audited.", "No raw transcript content was sent."],
                .neutral,
                "Refresh data or switch the window to 30 days."
            )
        }
        let cost = currency(digest.totals.costUSD)
        let topProviderName = topProvider?.displayName ?? "your top provider"
        let topDayText = biggestDay.map { "\(ISO8601DateFormatter().string(from: $0.day).prefix(10)) at \(currency($0.costUSD))" }
        var bullets = [
            "\(digest.totals.sessionCount) sessions and \(digest.totals.totalTokens) tokens.",
            "\(topProviderName) led provider spend.",
        ]
        if let topDayText { bullets.append("Highest day was \(topDayText).") }
        let tone: InsightWidgetData.Narrative.Tone = digest.anomalies.contains { $0.score >= 3 } ? .warning : .neutral
        return (
            "\(cost) analyzed across \(digest.totals.sessionCount) sessions",
            "The main thing to inspect is whether \(topProviderName) is doing the right work for its cost profile.",
            bullets,
            tone,
            "Open the generated provider ranking and compare the top model against cheaper configured routes."
        )
    }

    private static func generatedWidget(
        kind: InsightWidgetKind,
        title: String,
        dataBinding: InsightDataBinding,
        reason: String,
        modelTag: InsightModelTag,
        citations: [InsightCitation]
    ) -> InsightGeneratedWidget {
        let spec: InsightWidgetSpec
        switch kind {
        case .narrative: spec = .narrative(.init())
        case .barRanking: spec = .ranking(.init())
        case .quotaPulse: spec = .quotaPulse(.init())
        case .timeSeriesLine: spec = .timeSeries(.init(style: .line))
        case .recommendation: spec = .recommendation(.init())
        default: spec = AnthropicInsightAdapter.defaultSpec(for: kind)
        }
        let data: InsightWidgetData?
        switch dataBinding {
        case .narrative(let value): data = .narrative(value)
        case .recommendation(let value): data = .recommendation(value)
        default: data = nil
        }
        return .init(
            widget: .init(
                kind: kind,
                title: title,
                spec: spec,
                dataBinding: dataBinding,
                data: data,
                freshness: .fresh,
                modelTag: modelTag,
                lastComputedAt: Date(),
                rationale: reason
            ),
            reason: reason,
            citations: citations
        )
    }

    private static func resultHash(_ result: InsightAnalysisResult) -> String {
        var copy = result
        copy.resultHash = ""
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(copy) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

/// Orchestrating engine shared across platforms. Wires the rule-based
/// fallback to the audit log + analysis cache so every call writes one
/// audit row and is content-addressed for replay.
///
/// Dispatches to the selected user-owned model gateway when one is registered;
/// otherwise the same pipeline can use the local rules fallback. The
/// orchestration here — privacy gate, cache lookup, audit start, model call,
/// audit complete, cache write — stays put.
public actor OrchestratedInsightAnalysisEngine: InsightAnalysisEngine {
    public let platform: InsightAnalysisPlatform
    public let fallback: any InsightAnalysisEngine
    public let auditLog: InsightAnalysisAuditLog?
    public let cache: InsightAnalysisCache?
    public let catalog: InsightModelCatalog?
    public let toolBroker: InsightToolBroker?
    public var configuration: Configuration

    public struct Configuration: Sendable {
        public var privacyModeRestrictsToLocal: Bool
        public var failWhenSelectedGatewayUnavailable: Bool

        public init(
            privacyModeRestrictsToLocal: Bool = false,
            failWhenSelectedGatewayUnavailable: Bool = true
        ) {
            self.privacyModeRestrictsToLocal = privacyModeRestrictsToLocal
            self.failWhenSelectedGatewayUnavailable = failWhenSelectedGatewayUnavailable
        }
    }

    public init(
        platform: InsightAnalysisPlatform,
        fallback: any InsightAnalysisEngine,
        auditLog: InsightAnalysisAuditLog? = nil,
        cache: InsightAnalysisCache? = nil,
        catalog: InsightModelCatalog? = nil,
        toolBroker: InsightToolBroker? = nil,
        configuration: Configuration = .init()
    ) {
        self.platform = platform
        self.fallback = fallback
        self.auditLog = auditLog
        self.cache = cache
        self.catalog = catalog
        self.toolBroker = toolBroker
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    public nonisolated func analyze(_ request: InsightAnalysisRequest) async throws -> InsightAnalysisResult {
        try await analyzeInternal(request)
    }

    private func analyzeInternal(_ request: InsightAnalysisRequest) async throws -> InsightAnalysisResult {
        let cacheKey = InsightAnalysisCache.key(
            prompt: request.prompt,
            digestContentHash: request.context.digest.contentHash,
            modelID: request.selectedModel.modelID,
            instruction: request.instruction
        )

        if let cache, let cached = await cache.lookup(key: cacheKey) {
            return cached.result
        }

        let auditID = UUID()
        let startedAt = Date()
        let timeWindow = request.currentCanvas?.filter.window ?? .last7d
        let started = InsightAnalysisAuditEntry(
            id: auditID,
            requestID: request.id,
            platform: platform,
            selectedModel: request.selectedModel,
            egressTier: request.selectedModel.egressTier,
            timeWindow: timeWindow,
            contextBudget: request.context.budgetReport,
            includedDataSources: request.context.budgetReport.includedDataSources,
            truncationSummary: request.context.budgetReport.truncationSummary,
            promptHash: Self.promptHash(request.prompt),
            resultHash: "",
            status: .started,
            startedAt: startedAt,
            completedAt: nil,
            errorDescription: nil,
            tokenUsage: nil,
            estimatedCostUSD: nil,
            ranAt: startedAt
        )
        try? await auditLog?.upsertLatest(started)

        do {
            var result = try await executeSelectedModel(request)
            result.auditID = auditID
            let completedAt = Date()

            let completed = InsightAnalysisAuditEntry(
                id: auditID,
                requestID: request.id,
                platform: platform,
                selectedModel: result.modelTag,
                egressTier: result.modelTag.egressTier,
                timeWindow: result.timeWindow,
                contextBudget: result.contextBudget,
                includedDataSources: result.contextBudget.includedDataSources,
                truncationSummary: result.contextBudget.truncationSummary,
                promptHash: Self.promptHash(request.prompt),
                resultHash: result.resultHash,
                status: .succeeded,
                startedAt: startedAt,
                completedAt: completedAt,
                errorDescription: nil,
                tokenUsage: result.tokenUsage,
                estimatedCostUSD: result.estimatedCostUSD,
                ranAt: completedAt
            )
            try? await auditLog?.upsertLatest(completed)

            try? await cache?.store(.init(key: cacheKey, result: result))
            return result
        } catch {
            let completedAt = Date()
            let failed = InsightAnalysisAuditEntry(
                id: auditID,
                requestID: request.id,
                platform: platform,
                selectedModel: request.selectedModel,
                egressTier: request.selectedModel.egressTier,
                timeWindow: timeWindow,
                contextBudget: request.context.budgetReport,
                includedDataSources: request.context.budgetReport.includedDataSources,
                truncationSummary: request.context.budgetReport.truncationSummary,
                promptHash: Self.promptHash(request.prompt),
                resultHash: "",
                status: .failed,
                startedAt: startedAt,
                completedAt: completedAt,
                errorDescription: String(describing: error),
                tokenUsage: nil,
                estimatedCostUSD: nil,
                ranAt: completedAt
            )
            try? await auditLog?.upsertLatest(failed)
            throw error
        }
    }

    public nonisolated static func materializeCanvas(
        from result: InsightAnalysisResult,
        prompt: String
    ) -> InsightCanvas {
        RuleBasedInsightAnalysisEngine.materializeCanvas(from: result, prompt: prompt)
    }

    private func executeSelectedModel(_ request: InsightAnalysisRequest) async throws -> InsightAnalysisResult {
        if configuration.privacyModeRestrictsToLocal,
           request.selectedModel.egressTier != .localOnly {
            throw InsightGatewayError.egressBlockedByPrivacyMode(modelID: request.selectedModel.modelID)
        }

        if request.selectedModel.providerKey == "local-rules" {
            return try await fallback.analyze(request)
        }

        if let catalog,
           let gateway = await catalog.gateway(for: request.selectedModel.providerKey) {
            return try await gateway.analyze(
                request: request,
                platform: platform,
                tools: toolBroker
            )
        }

        if configuration.failWhenSelectedGatewayUnavailable {
            throw InsightGatewayError.modelUnavailable(
                modelID: request.selectedModel.modelID,
                reason: "no analysis gateway registered for \(request.selectedModel.providerKey)"
            )
        }

        return try await fallback.analyze(request)
    }

    private static func promptHash(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// macOS-flavored engine. Defaults to the rule-based fallback if no audit/cache
/// is provided, so callers can opt in incrementally.
public struct MacInsightAnalysisEngine: InsightAnalysisEngine {
    private let orchestrator: OrchestratedInsightAnalysisEngine

    public init(
        auditLog: InsightAnalysisAuditLog? = nil,
        cache: InsightAnalysisCache? = nil,
        catalog: InsightModelCatalog? = nil,
        toolBroker: InsightToolBroker? = nil,
        configuration: OrchestratedInsightAnalysisEngine.Configuration = .init()
    ) {
        self.orchestrator = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            auditLog: auditLog,
            cache: cache,
            catalog: catalog,
            toolBroker: toolBroker,
            configuration: configuration
        )
    }

    public func analyze(_ request: InsightAnalysisRequest) async throws -> InsightAnalysisResult {
        try await orchestrator.analyze(request)
    }

    public func updateConfiguration(_ configuration: OrchestratedInsightAnalysisEngine.Configuration) async {
        await orchestrator.updateConfiguration(configuration)
    }
}

/// iOS / iPadOS-flavored engine. Same shape as the mac engine; the
/// platform argument lets iPad runs be tagged distinctly in the audit log.
public struct MobileInsightAnalysisEngine: InsightAnalysisEngine {
    public let platform: InsightAnalysisPlatform
    private let orchestrator: OrchestratedInsightAnalysisEngine

    public init(
        platform: InsightAnalysisPlatform = .iOS,
        auditLog: InsightAnalysisAuditLog? = nil,
        cache: InsightAnalysisCache? = nil,
        catalog: InsightModelCatalog? = nil,
        toolBroker: InsightToolBroker? = nil,
        configuration: OrchestratedInsightAnalysisEngine.Configuration = .init()
    ) {
        self.platform = platform
        self.orchestrator = OrchestratedInsightAnalysisEngine(
            platform: platform,
            fallback: RuleBasedInsightAnalysisEngine(platform: platform),
            auditLog: auditLog,
            cache: cache,
            catalog: catalog,
            toolBroker: toolBroker,
            configuration: configuration
        )
    }

    public func analyze(_ request: InsightAnalysisRequest) async throws -> InsightAnalysisResult {
        try await orchestrator.analyze(request)
    }

    public func updateConfiguration(_ configuration: OrchestratedInsightAnalysisEngine.Configuration) async {
        await orchestrator.updateConfiguration(configuration)
    }
}

private extension DateInterval {
    func asInsightWindow(default fallback: InsightTimeWindow) -> InsightTimeWindow {
        let seconds = end.timeIntervalSince(start)
        switch seconds {
        case 0...(25 * 60 * 60): return .last24h
        case 0...(8 * 24 * 60 * 60): return .last7d
        case 0...(31 * 24 * 60 * 60): return .last30d
        case 0...(92 * 24 * 60 * 60): return .last90d
        default: return fallback
        }
    }
}
