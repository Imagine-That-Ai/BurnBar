import Foundation
import OpenBurnBarKernel

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
            contextContentHash: request.context.cacheIdentityHash,
            modelID: request.selectedModel.modelID,
            instruction: request.instruction
        )

        if let cache, let cached = await cache.lookup(key: cacheKey) {
            var result = RuleBasedInsightAnalysisEngine.enrichMissionCandidates(
                in: cached.result,
                request: request,
                platform: platform
            )
            if request.instruction == .answerFollowUp, result.briefingAnswer == nil {
                if result.modelTag.providerKey == "local-rules" {
                    let local = try? await fallback.analyze(request)
                    result.briefingAnswer = local?.briefingAnswer
                } else {
                    // Attribute the cached briefing to the *actual* route
                    // that produced the result, not blanket `.modelGateway`.
                    // Pre-hostedFallback cache rows that were stamped by
                    // the BurnBar hosted gateway must surface as
                    // `.hostedFallback` in the UI eyebrow and audit log.
                    let answerSource: InsightBriefingAnswer.Source =
                        result.modelTag.providerKey == BurnBarHostedInsightAdapter.providerKeyRaw
                        ? .hostedFallback : .modelGateway
                    result.briefingAnswer = InsightBriefingAnswer(
                        question: request.prompt,
                        answer: Self.composeAnswerBody(from: result),
                        bullets: Self.composeGroundedPoints(from: result),
                        citations: Array(result.citations.prefix(3)),
                        source: answerSource,
                        modelDisplayName: result.modelTag.displayName,
                        isFallback: false
                    )
                }
            }
            if result != cached.result {
                try? await cache.store(.init(key: cacheKey, result: result, estimatedCostSavedUSD: cached.estimatedCostSavedUSD))
            }
            return result
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
            result = RuleBasedInsightAnalysisEngine.enrichMissionCandidates(
                in: result,
                request: request,
                platform: platform
            )
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

            // Cache key is computed from the user's *selected* model.
            // Two reasons we may decline to cache:
            //   1. The orchestrator redirected this run through the
            //      BurnBar hosted fallback (or another route) when
            //      the selected gateway was unreachable — caching
            //      under the user's selection would serve the
            //      fallback after their own route recovers.
            //   2. The answering route IS the hosted route. Caching
            //      that result would let a once-Pro-now-cancelled
            //      caller keep getting hosted answers for the same
            //      question after their subscription lapsed. Pro is
            //      a live entitlement; we re-verify on every turn.
            let answeringRouteMatchesSelection =
                result.modelTag.providerKey == request.selectedModel.providerKey
                && result.modelTag.modelID == request.selectedModel.modelID
            let isHostedRoute =
                result.modelTag.providerKey == BurnBarHostedInsightAdapter.providerKeyRaw
            if answeringRouteMatchesSelection && !isHostedRoute {
                try? await cache?.store(.init(key: cacheKey, result: result))
            }
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

        // Local-rules selection is the deliberate "no LLM" tier — go
        // straight to deterministic. Privacy mode also lands here.
        if request.selectedModel.providerKey == "local-rules" {
            return try await fallback.analyze(request)
        }

        if let catalog,
           let gateway = await catalog.gateway(for: request.selectedModel.providerKey) {
            do {
                var result = try await gateway.analyze(
                    request: request,
                    platform: platform,
                    tools: toolBroker
                )
                if request.instruction == .answerFollowUp, result.briefingAnswer == nil {
                    let body = Self.composeAnswerBody(from: result)
                    let grounded = Self.composeGroundedPoints(from: result)
                    let answerSource: InsightBriefingAnswer.Source =
                        result.modelTag.providerKey == BurnBarHostedInsightAdapter.providerKeyRaw
                        ? .hostedFallback : .modelGateway
                    result.briefingAnswer = InsightBriefingAnswer(
                        question: request.prompt,
                        answer: body,
                        bullets: grounded,
                        citations: Array(result.citations.prefix(3)),
                        source: answerSource,
                        modelDisplayName: result.modelTag.displayName,
                        isFallback: false
                    )
                }
                return result
            } catch {
                // If the selected gateway itself returned the Pro
                // paywall (typically when the user explicitly picked
                // `burnbar-hosted` and isn't subscribed), short-circuit
                // straight to the upgrade disclosure instead of
                // re-invoking the same hosted gateway through
                // `tryHostedFallback` — that second call would 403
                // again and double the server-side rejection cost.
                if request.instruction == .answerFollowUp,
                   case InsightGatewayError.subscriptionRequired = error {
                    return await composeSubscriptionRequiredFallback(for: request)
                }
                // Other gateway failures (network, auth, rate-limit)
                // try the hosted fallback before degrading to local
                // rules so the user still gets an LLM-authored answer
                // when their own route is briefly down.
                if let hosted = try await tryHostedFallback(
                    after: error,
                    for: request
                ) {
                    return hosted
                }
                guard request.instruction == .answerFollowUp else { throw error }
                return await composeLocalRulesFallback(
                    for: request,
                    requestedDisplay: request.selectedModel.displayName
                )
            }
        }

        // No gateway registered for the selected provider — attempt
        // the hosted route before refusing.
        if let hosted = try await tryHostedFallback(
            after: InsightGatewayError.modelUnavailable(
                modelID: request.selectedModel.modelID,
                reason: "no gateway registered for \(request.selectedModel.providerKey)"
            ),
            for: request
        ) {
            return hosted
        }

        if configuration.failWhenSelectedGatewayUnavailable {
            if request.instruction == .answerFollowUp {
                return await composeLocalRulesFallback(
                    for: request,
                    requestedDisplay: request.selectedModel.displayName
                )
            }
            throw InsightGatewayError.modelUnavailable(
                modelID: request.selectedModel.modelID,
                reason: "no analysis gateway registered for \(request.selectedModel.providerKey)"
            )
        }

        return try await fallback.analyze(request)
    }

    /// Attempt the BurnBar-hosted fallback when the selected user-owned
    /// gateway is unreachable or unregistered. Returns `nil` when no
    /// hosted adapter is registered (e.g. unit tests, offline dev),
    /// signalling the caller to fall back to local rules. When privacy
    /// mode requires `localOnly` egress, returns `nil` without trying
    /// the hosted route — the caller will land on local rules.
    private func tryHostedFallback(
        after originalError: Error,
        for request: InsightAnalysisRequest
    ) async throws -> InsightAnalysisResult? {
        // The hosted fallback is only viable for Q&A turns when the
        // visible selected model already permits non-local egress.
        // Local-only choices are the user's egress contract; a missing
        // or failed local gateway must degrade to local rules, not
        // silently promote the context to BurnBar Hosted.
        guard request.instruction == .answerFollowUp else { return nil }
        guard request.selectedModel.egressTier != .localOnly else { return nil }
        if configuration.privacyModeRestrictsToLocal { return nil }

        guard let catalog else { return nil }
        guard let hosted = await catalog.gateway(
            for: BurnBarHostedInsightAdapter.providerKeyRaw
        ) else { return nil }

        // Build a request that asks the hosted gateway for the
        // hosted model, regardless of what the user originally
        // picked. This keeps the audit honest: the answer came from
        // BurnBar Hosted, not from the user's selection.
        let hostedModel = InsightModelTag(
            providerKey: BurnBarHostedInsightAdapter.providerKeyRaw,
            modelID: BurnBarHostedInsightAdapter.defaultModelID,
            displayName: BurnBarHostedInsightAdapter.defaultModelDisplayName,
            egressTier: .hosted
        )
        var hostedRequest = request
        hostedRequest.selectedModel = hostedModel

        do {
            var hostedResult = try await hosted.analyze(
                request: hostedRequest,
                platform: platform,
                tools: toolBroker
            )
            if hostedResult.briefingAnswer == nil {
                let body = Self.composeAnswerBody(from: hostedResult)
                hostedResult.briefingAnswer = InsightBriefingAnswer(
                    question: request.prompt,
                    answer: body,
                    bullets: Self.composeGroundedPoints(from: hostedResult),
                    citations: Array(hostedResult.citations.prefix(3)),
                    source: .hostedFallback,
                    modelDisplayName: hostedResult.modelTag.displayName,
                    isFallback: false
                )
            } else {
                hostedResult.briefingAnswer?.source = .hostedFallback
            }
            return hostedResult
        } catch InsightGatewayError.subscriptionRequired {
            // Free-tier / anonymous caller hit the hosted paywall.
            // Land on local rules with the dedicated "BurnBar Pro
            // required" disclosure so the UI shows the upgrade CTA
            // instead of a generic gateway failure.
            return await composeSubscriptionRequiredFallback(for: request)
        } catch {
            // Hosted route failed for some other reason — return nil
            // so the caller lands on local rules with the standard
            // "→ Local rules" disclosure. Preserve the original
            // gateway error in the audit/log; we don't surface a
            // different error here because the user will see local
            // fallback with a clear disclosure.
            _ = originalError
            return nil
        }
    }

    /// Local-rules fallback specifically when the hosted route is
    /// gated by an inactive BurnBar Pro subscription. Uses a
    /// distinct `modelDisplayName` marker the UI can detect to swap
    /// the "Connect your own model" CTA for "Upgrade to BurnBar
    /// Pro". The answer is honest: no LLM ran, the user can fix it.
    private func composeSubscriptionRequiredFallback(
        for request: InsightAnalysisRequest
    ) async -> InsightAnalysisResult {
        var fallbackResult: InsightAnalysisResult
        do {
            fallbackResult = try await fallback.analyze(request)
        } catch {
            fallbackResult = RuleBasedInsightAnalysisEngine.buildResult(
                request: request,
                platform: platform
            )
        }
        if var answer = fallbackResult.briefingAnswer {
            answer.isFallback = true
            answer.modelDisplayName = InsightBriefingAnswer.subscriptionRequiredDisplayName
            answer.answer = """
            BurnBar Pro subscription required to run hosted Intelligence Brief answers. \
            Connect your own LLM (Hermes, Claude, OpenAI, Ollama, Pi, etc.) or upgrade to BurnBar Pro to use our hosted MiniMax route.

            \(answer.answer)
            """
            fallbackResult.briefingAnswer = answer
        }
        return fallbackResult
    }

    /// Local-rules fallback for a Q&A turn after every LLM route was
    /// exhausted. Stamps the briefing answer with `isFallback = true`
    /// and an explicit "→ Local rules" suffix so the UI banner can
    /// disclose that no LLM answered.
    private func composeLocalRulesFallback(
        for request: InsightAnalysisRequest,
        requestedDisplay: String
    ) async -> InsightAnalysisResult {
        // `fallback` is the local-rules engine and never throws in
        // practice (only computation, no I/O). Use a safe materialize
        // to keep the orchestrator's failure contract simple.
        do {
            var fallbackResult = try await fallback.analyze(request)
            if var answer = fallbackResult.briefingAnswer {
                answer.isFallback = true
                answer.modelDisplayName = "\(requestedDisplay) → Local rules"
                fallbackResult.briefingAnswer = answer
            }
            return fallbackResult
        } catch {
            // Should be unreachable for the local-rules engine, but
            // keep a synchronous safety net so the orchestrator can
            // never strand a Q&A turn without a reply.
            return RuleBasedInsightAnalysisEngine.buildResult(
                request: request,
                platform: platform
            )
        }
    }

    /// Composes a multi-sentence answer body from a gateway's
    /// tailored `InsightAnalysisResult`. Combines the executive
    /// summary with the lead finding so the user reads a complete
    /// reply (not just a headline).
    private static func composeAnswerBody(from result: InsightAnalysisResult) -> String {
        var parts: [String] = []
        if !result.executiveSummary.isEmpty {
            parts.append(result.executiveSummary)
        }
        if let lead = result.findings.first {
            // Avoid double-rendering if the gateway already echoed the
            // finding text inside the executive summary.
            if !result.executiveSummary.lowercased().contains(lead.title.lowercased()) {
                parts.append(lead.whyItMatters)
            }
            parts.append(lead.recommendedAction)
        }
        return parts.joined(separator: " ")
    }

    /// Lifts evidence chips from the gateway's findings + anomalies
    /// for the grounded-points row.
    private static func composeGroundedPoints(from result: InsightAnalysisResult) -> [String] {
        var points: [String] = []
        for finding in result.findings.prefix(3) {
            points.append(finding.title)
        }
        for anomaly in result.anomalies.prefix(2) {
            points.append("⚡ \(anomaly.title)")
        }
        for rec in result.recommendations.prefix(2) {
            points.append("→ \(rec.title)")
        }
        return Array(points.prefix(4))
    }

    private static func promptHash(_ prompt: String) -> String {
        PlatformCrypto.sha256Hex(Data(prompt.utf8))
    }
}
