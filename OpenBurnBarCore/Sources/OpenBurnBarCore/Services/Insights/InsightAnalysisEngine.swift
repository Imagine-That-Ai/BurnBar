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

        // Classify the prompt up front so the executive summary,
        // finding ordering, and headline can all specialize on it.
        let intent = Self.classifyPromptIntent(request.prompt)
        let baseSummary = executiveSummary(digest: digest, topProvider: topProvider, biggestDay: biggestDay)
        let summary = Self.specialize(
            summary: baseSummary,
            for: intent,
            digest: digest,
            topProvider: topProvider,
            topModel: topModel,
            biggestDay: biggestDay,
            quotaRisk: quotaRisk
        )
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
                citations: [citation],
                digest: digest
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
        var missionCandidates: [InsightMissionCandidate] = []
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
                citations: [citation],
                digest: digest
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

        let benchmarkAdvice = modelBenchmarkAdvice(
            digest: digest,
            topModel: topModel,
            selectedModel: request.selectedModel,
            window: request.currentCanvas?.filter.window ?? .last7d
        )
        findings.append(contentsOf: benchmarkAdvice.findings)
        recommendations.append(contentsOf: benchmarkAdvice.recommendations)
        generatedWidgets.append(contentsOf: benchmarkAdvice.widgets)

        let missionAdvice = missionIntelligence(
            digest: digest,
            topProvider: topProvider,
            topModel: topModel,
            quotaRisk: quotaRisk,
            existingInsightIDs: findings.map(\.id)
        )
        findings.append(contentsOf: missionAdvice.findings)
        recommendations.append(contentsOf: missionAdvice.recommendations)
        missionCandidates.append(contentsOf: missionAdvice.missions)

        generatedWidgets.append(generatedWidget(
            kind: .timeSeriesLine,
            title: "Main supporting trend",
            dataBinding: .timeSeries(metric: .cost, dimension: .provider, window: request.currentCanvas?.filter.window ?? .last7d),
            reason: "Shows whether the main finding is a one-day spike or a sustained trend.",
            modelTag: request.selectedModel,
            citations: Array(citations.prefix(3)),
            digest: digest
        ))

        let followUps = [
            "Why did cost spike this week?",
            "Which project or workflow wasted the most money?",
            "Which model should I route routine work to instead?",
            "Which benchmarked model is cheapest at similar performance?",
            "Which model should handle UI and design tasks?",
            "Find quota risks in the next 24 hours."
        ].map { InsightFollowUpQuestion(question: $0) }

        // Compose the executive summary with a "Answering: ..."
        // eyebrow so the user can immediately see the brief is
        // tailored to the question they tapped.
        let composedSummary: String
        if let eyebrow = Self.answerEyebrow(for: intent) {
            composedSummary = "\(eyebrow) — \(summary.body)"
        } else {
            composedSummary = summary.body
        }
        // Pull the most prompt-relevant finding to position #1.
        let orderedFindings = Self.reorderFindings(
            findings,
            for: intent,
            topProvider: topProvider,
            topModel: topModel
        )

        // Build the conversational reply card whenever this is a user
        // turn (`answerFollowUp` instruction). The rule path always
        // produces the deterministic, data-grounded body — when an
        // LLM gateway is available, the orchestrator overrides this
        // field with the model's reply. Either way the user sees a
        // visible Q&A surface above the brief.
        let briefingAnswer: InsightBriefingAnswer? = {
            guard request.instruction == .answerFollowUp else { return nil }
            let groundedPoints = Self.groundedPointsForReply(
                intent: intent,
                digest: digest,
                topProvider: topProvider,
                topModel: topModel,
                biggestDay: biggestDay,
                quotaRisk: quotaRisk
            )
            // Be honest about what kind of reply this is.
            //
            // Local rules never *answer* a freeform question — they only
            // surface deterministic data summaries from the digest. When
            // the orchestrator routes here because no LLM gateway is
            // configured, the reply is explicitly framed as a data
            // summary, not an LLM answer, so the user isn't tricked by
            // template-generated narrative prose.
            let isLocalRulesOnly = request.selectedModel.providerKey == "local-rules"
            let body: String
            let displayName: String
            if isLocalRulesOnly {
                body = """
                Local rules can only summarize the data — they can't answer freeform questions. Connect a model gateway in the inspector to get an LLM-authored reply.

                Here's what the data shows for this window:

                \(summary.headline). \(summary.body)
                """
                displayName = "Local rules · no LLM configured"
            } else {
                body = "\(summary.headline). \(summary.body) \(summary.action)"
                displayName = request.selectedModel.displayName
            }
            return InsightBriefingAnswer(
                question: request.prompt,
                answer: body,
                bullets: groundedPoints,
                citations: Array(citations.prefix(3)),
                source: .localRules,
                modelDisplayName: displayName
            )
        }()

        return InsightAnalysisResult(
            requestID: request.id,
            platform: platform,
            timeWindow: request.currentCanvas?.filter.window ?? .last7d,
            executiveSummary: composedSummary,
            modelTag: request.selectedModel,
            contextBudget: request.context.budgetReport,
            findings: Array(orderedFindings.prefix(6)),
            anomalies: anomalies,
            recommendations: recommendations,
            missionCandidates: Array(missionCandidates.prefix(5)),
            generatedWidgets: Array(generatedWidgets.prefix(request.maxGeneratedWidgets)),
            followUpQuestions: followUps,
            citations: citations,
            briefingAnswer: briefingAnswer
        )
    }

    /// Produces a small set of "computed from the digest" attestations
    /// that the briefing-answer card renders as chips beneath the body.
    /// Each chip cites a real number from the privacy-bounded digest so
    /// the user can see the answer is grounded.
    static func groundedPointsForReply(
        intent: PromptIntent,
        digest: InsightDigest,
        topProvider: InsightDigest.ProviderSnapshot?,
        topModel: InsightDigest.ModelSnapshot?,
        biggestDay: InsightDigest.DailyPoint?,
        quotaRisk: InsightDigest.QuotaSnapshotSummary?
    ) -> [String] {
        var points: [String] = []
        if let topProvider {
            points.append("\(topProvider.displayName): \(currency(topProvider.costUSD)) · \(topProvider.sessionCount) sessions")
        }
        if let topModel {
            points.append("Top model: \(topModel.id) · \(currency(topModel.costUSD))")
        }
        if let biggestDay {
            let day = String(ISO8601DateFormatter().string(from: biggestDay.day).prefix(10))
            points.append("Peak day \(day) at \(currency(biggestDay.costUSD))")
        }
        if let quotaRisk, let limit = quotaRisk.limit, limit > 0 {
            let pct = Int((quotaRisk.used / limit) * 100)
            points.append("\(quotaRisk.providerID) \(quotaRisk.bucketName) at \(pct)%")
        }
        if intent == .quotaRisk, points.contains(where: { $0.contains("at ") && $0.contains("%") }) == false {
            points.append("No quota bucket above its known limit in this window.")
        }
        if points.isEmpty {
            points.append("\(digest.totals.sessionCount) sessions · \(currency(digest.totals.costUSD)) total")
        }
        return Array(points.prefix(4))
    }

    public static func enrichMissionCandidates(
        in result: InsightAnalysisResult,
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform
    ) -> InsightAnalysisResult {
        guard result.missionCandidates.isEmpty else { return result }
        let baseline = buildResult(request: request, platform: platform)
        guard baseline.missionCandidates.isEmpty == false else { return result }
        var enriched = result
        enriched.missionCandidates = baseline.missionCandidates
        enriched.resultHash = resultHash(enriched)
        return enriched
    }

    private static func missionIntelligence(
        digest: InsightDigest,
        topProvider: InsightDigest.ProviderSnapshot?,
        topModel: InsightDigest.ModelSnapshot?,
        quotaRisk: InsightDigest.QuotaSnapshotSummary?,
        existingInsightIDs: [UUID]
    ) -> (
        findings: [InsightFinding],
        recommendations: [InsightRecommendation],
        missions: [InsightMissionCandidate]
    ) {
        guard digest.rowCount > 0 || digest.totals.sessionCount > 0 else { return ([], [], []) }

        let topProject = digest.projects.max { $0.costUSD < $1.costUSD }
        let projectCitation = topProject.map { InsightCitation(kind: .project(name: $0.id), label: $0.displayName) }
        let modelCitation = topModel.map { InsightCitation(kind: .model(id: $0.id), label: $0.id) }
        let providerCitation = topProvider.map { InsightCitation(kind: .agent(provider: $0.id), label: $0.displayName) }
        let quotaCitation = quotaRisk.map { InsightCitation(kind: .quota(provider: $0.providerID, bucket: $0.bucketName), label: "\($0.providerID) quota") }
        let activityCitation = InsightCitation(
            kind: .query(text: digest.contentHash.isEmpty ? "insight-activity" : "insight-activity-\(digest.contentHash)"),
            label: "Activity digest"
        )
        let projectName = topProject?.displayName ?? "the busiest project"
        let projectCost = topProject.map { currency($0.costUSD) } ?? currency(digest.totals.costUSD)
        let projectSessions = topProject?.sessionCount ?? digest.totals.sessionCount

        var findings: [InsightFinding] = []
        var recommendations: [InsightRecommendation] = []
        var missions: [InsightMissionCandidate] = []

        if let topProject, let citation = projectCitation {
            let finding = InsightFinding(
                title: "\(topProject.displayName) is where the work concentrated",
                whyItMatters: "\(topProject.displayName) accounts for \(projectCost) across \(projectSessions) sessions, so missions should start where repeated AI effort is already compounding.",
                evidence: [citation],
                confidence: .high,
                severity: projectSessions >= 3 ? .medium : .low,
                recommendedAction: "Create one focused mission for \(topProject.displayName) instead of treating the brief as isolated observations."
            )
            findings.append(finding)
        }

        let accretionEvidence = nonEmptyEvidence([projectCitation, modelCitation, providerCitation], fallback: activityCitation)
        if accretionEvidence.isEmpty == false {
            missions.append(.init(
                title: "Turn repeated \(projectName) work into an accretive feature",
                summary: "Use the accretion lens to convert the highest-activity project into a small product or workflow improvement that reuses existing primitives instead of becoming a one-off analysis.",
                projectID: topProject?.id,
                projectDisplayName: topProject?.displayName,
                lens: .accretion,
                priority: projectSessions >= 3 ? .high : .medium,
                confidence: topProject == nil ? .medium : .high,
                expectedImpact: "Compounds current AI spend into a durable workflow, trust cue, or UI affordance.",
                effort: .medium,
                acceptanceCriteria: [
                    "Name the concrete user job currently driving the repeated sessions.",
                    "Ship one native workflow or polish layer that reuses existing BurnBar primitives.",
                    "Verify the next brief can cite reduced friction, clearer routing, or better user confidence."
                ],
                sourceInsightIDs: existingInsightIDs,
                evidence: accretionEvidence,
                dispatchMetadata: ["lens": "accretion", "source": "insight_engine"]
            ))
        }

        let diligenceEvidence = nonEmptyEvidence([projectCitation, quotaCitation, providerCitation], fallback: activityCitation)
        if diligenceEvidence.isEmpty == false {
            let quotaHot = quotaRisk.flatMap { snap -> Bool? in
                guard let limit = snap.limit, limit > 0 else { return nil }
                return snap.used / limit >= 0.8
            } ?? false
            missions.append(.init(
                title: quotaHot ? "Run a diligence pass before the next heavy session" : "Run a diligence pass on \(projectName)",
                summary: "Use the diligence lens to turn the brief's risk signals into an evidence-backed launch-readiness check with explicit blockers, owner, and proof.",
                projectID: topProject?.id,
                projectDisplayName: topProject?.displayName,
                lens: .diligence,
                priority: quotaHot ? .critical : .high,
                confidence: .medium,
                expectedImpact: "Prevents cost, quota, or release surprises from hiding behind a normal-looking usage summary.",
                effort: .small,
                acceptanceCriteria: [
                    "List the top production, cost, privacy, and reliability risks with citations.",
                    "Separate blockers from serious concerns and acceptable tradeoffs.",
                    "Attach the verification command or live evidence that closes each blocker."
                ],
                sourceInsightIDs: existingInsightIDs,
                evidence: diligenceEvidence,
                dispatchMetadata: ["lens": "diligence", "source": "insight_engine"]
            ))
        }

        if let topModel {
            let debtEvidence = nonEmptyEvidence([modelCitation, projectCitation], fallback: activityCitation)
            missions.append(.init(
                title: "Reduce repeated \(topModel.id) drag",
                summary: "Use the debt lens to decide whether high recurring model usage is doing essential expert work or masking unclear requirements, weak tests, brittle routing, or missing automation.",
                projectID: topProject?.id,
                projectDisplayName: topProject?.displayName,
                lens: .techDebt,
                priority: topModel.costUSD > max(1, digest.totals.costUSD * 0.35) ? .high : .medium,
                confidence: .medium,
                expectedImpact: "Cuts future analysis spend by removing the underlying delivery friction, not just swapping models.",
                effort: .medium,
                acceptanceCriteria: [
                    "Identify the repeated work pattern causing the expensive model usage.",
                    "Choose the smallest remediation that prevents the same class of future sessions.",
                    "Add or update a test, runbook, or automation proof that the drag was actually reduced."
                ],
                sourceInsightIDs: existingInsightIDs,
                evidence: debtEvidence,
                dispatchMetadata: ["lens": "techDebt", "source": "insight_engine"]
            ))
        } else if topProject == nil {
            missions.append(.init(
                title: "Upgrade the next brief with project and model attribution",
                summary: "The digest has activity totals but lacks enough project, provider, or model breakdown to explain the work intelligently. Use the focus lens to make the next analysis more actionable instead of accepting generic totals.",
                lens: .focus,
                priority: digest.totals.sessionCount > 0 ? .high : .medium,
                confidence: .medium,
                expectedImpact: "Turns an opaque usage summary into a useful brief that can name the workflow, model choice, and cost driver.",
                effort: .small,
                acceptanceCriteria: [
                    "Confirm mobile sync is receiving provider, model, and project summaries.",
                    "Refresh Insights and verify the Mission Board names at least one concrete driver.",
                    "Use the new driver to create one accretion, diligence, or debt mission."
                ],
                sourceInsightIDs: existingInsightIDs,
                evidence: [activityCitation],
                dispatchMetadata: ["lens": "focus", "source": "insight_engine"]
            ))
        }

        if modelCitation != nil, digest.modelBenchmarks.isEmpty == false {
            let routingEvidence: [InsightCitation] = [modelCitation].compactMap { $0 } + digest.modelBenchmarks.prefix(2).map(benchmarkCitation(_:))
            recommendations.append(.init(
                title: "Convert model-board advice into a routing experiment",
                rationale: "Benchmark evidence is useful only after a bounded comparison against your actual \(projectName) work.",
                recommendedAction: "Run one UI/design or routine-coding session through the best-fit candidate, then compare quality, cost signal, and quota health before changing defaults.",
                estimatedImpact: "Turns abstract model rankings into a safer routing decision.",
                evidence: routingEvidence,
                confidence: .medium,
                severity: .medium
            ))
        }

        return (findings, recommendations, missions)
    }

    private static func nonEmptyEvidence(
        _ candidates: [InsightCitation?],
        fallback: InsightCitation
    ) -> [InsightCitation] {
        let evidence = candidates.compactMap { $0 }
        return evidence.isEmpty ? [fallback] : evidence
    }

    private static func modelBenchmarkAdvice(
        digest: InsightDigest,
        topModel: InsightDigest.ModelSnapshot?,
        selectedModel: InsightModelTag,
        window: InsightTimeWindow
    ) -> (
        findings: [InsightFinding],
        recommendations: [InsightRecommendation],
        widgets: [InsightGeneratedWidget]
    ) {
        let benchmarks = digest.modelBenchmarks
        guard benchmarks.isEmpty == false else { return ([], [], []) }

        let usedModels = Dictionary(uniqueKeysWithValues: digest.models.map { (normalizedModelID($0.id), $0) })
        let benchmarkByModel = Dictionary(grouping: benchmarks, by: { normalizedModelID($0.modelID) })
        let topUsedBenchmark = topModel.flatMap { bestBenchmark(for: normalizedModelID($0.id), in: benchmarkByModel) }
        let bestDesign = bestBenchmark(in: benchmarks.filter { $0.taskCategory == "design" })
            ?? bestBenchmark(in: benchmarks.filter { $0.taskCategory == "coding" })
        let bestAny = bestBenchmark(in: benchmarks)
        let cheapestSimilar = cheapestSimilarAlternative(
            usedModel: topModel,
            usedBenchmark: topUsedBenchmark,
            benchmarks: benchmarks
        )

        var findings: [InsightFinding] = []
        var recommendations: [InsightRecommendation] = []
        var widgets: [InsightGeneratedWidget] = []

        if let topModel, let bestDesign, normalizedModelID(bestDesign.modelID) != normalizedModelID(topModel.id) {
            let modelCitation = InsightCitation(kind: .model(id: topModel.id), label: topModel.id)
            let benchmarkCitation = benchmarkCitation(bestDesign)
            findings.append(.init(
                title: "UI/design work should be checked against \(bestDesign.modelID)",
                whyItMatters: "\(topModel.id) leads your spend, but \(bestDesign.modelID) is the strongest cited \(bestDesign.taskCategory) benchmark candidate in the synced model board\(scorePhrase(bestDesign)).",
                evidence: [modelCitation, benchmarkCitation],
                confidence: confidence(for: bestDesign),
                severity: .medium,
                recommendedAction: "Use \(bestDesign.modelID) for the next UI-heavy task only if quota and routing are healthy; keep \(topModel.id) for work where its context or reliability matters."
            ))
        }

        if let topModel, let alternative = cheapestSimilar {
            let topCitation = InsightCitation(kind: .model(id: topModel.id), label: topModel.id)
            let altCitation = benchmarkCitation(alternative)
            let impact = savingsPhrase(current: topModel, alternative: alternative)
            recommendations.append(.init(
                title: "\(alternative.modelID) looks cheaper at similar benchmark strength",
                rationale: "\(topModel.id) is your largest cost contributor. \(alternative.modelID) is close on benchmark evidence\(scorePhrase(alternative)) and has a stronger cost signal.",
                recommendedAction: "Route one routine \(alternative.taskCategory) session to \(alternative.modelID), then compare output quality before changing defaults.",
                estimatedImpact: impact,
                evidence: [topCitation, altCitation],
                confidence: confidence(for: alternative),
                severity: .high
            ))
            widgets.append(generatedWidget(
                kind: .recommendation,
                title: "Cost-efficient alternative",
                dataBinding: .recommendation(.init(
                    headline: "\(alternative.modelID) for routine \(alternative.taskCategory)",
                    rationale: "\(alternative.modelID) has similar public benchmark evidence and a better cost signal than the current top-spend model.",
                    action: "Try it on one low-risk session before changing the router default.",
                    estimatedImpact: impact,
                    confidence: .medium,
                    citations: [altCitation]
                )),
                reason: "Compares observed spend against public benchmark and cost signals.",
                modelTag: selectedModel,
                citations: [topCitation, altCitation],
                digest: digest
            ))
        }

        let benchmarkRows = benchmarkRankingRows(
            benchmarks: benchmarks,
            usedModels: usedModels,
            limit: 6
        )
        if benchmarkRows.isEmpty == false {
            widgets.append(.init(
                widget: .init(
                    kind: .barRanking,
                    title: "Benchmark-aware model board",
                    spec: .ranking(.init()),
                    dataBinding: .ranking(metric: .cost, dimension: .model, limit: 6, window: window),
                    data: .ranking(.init(rows: benchmarkRows, valueFormat: .percent, dimensionLabel: "Benchmark")),
                    freshness: .fresh,
                    modelTag: selectedModel,
                    lastComputedAt: Date(),
                    rationale: "Ranks cited benchmark candidates beside models used in this window."
                ),
                reason: "Shows where used models sit against public model-board evidence.",
                citations: benchmarks.prefix(6).map(benchmarkCitation(_:))
            ))
        }

        if let bestAny {
            recommendations.append(.init(
                title: "Do not blindly switch to \(bestAny.modelID)",
                rationale: "Benchmarks are advisory. A higher public score loses when quota, account health, privacy mode, or task fit is worse.",
                recommendedAction: "Treat \(bestAny.modelID) as a candidate for \(bestAny.taskCategory), not as a global default.",
                estimatedImpact: "Avoids over-routing premium or unavailable models.",
                evidence: [benchmarkCitation(bestAny)],
                confidence: confidence(for: bestAny),
                severity: .medium
            ))
        }

        return (
            Array(findings.prefix(2)),
            Array(recommendations.prefix(3)),
            Array(widgets.prefix(2))
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
        citations: [InsightCitation],
        digest: InsightDigest? = nil
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
        default:
            // Synthesize data straight from the digest so the brief's
            // generated widgets paint a real chart on first render —
            // otherwise we'd ship an empty chrome that waits for a
            // canvas refresh to fill in its body.
            data = digest.flatMap { Self.synthesizeData(for: kind, binding: dataBinding, digest: $0) }
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

    /// Build the `InsightWidgetData` payload from the privacy-bounded
    /// digest so the brief's auto-generated widgets render with real
    /// numbers immediately instead of as empty chrome.
    private static func synthesizeData(
        for kind: InsightWidgetKind,
        binding: InsightDataBinding,
        digest: InsightDigest
    ) -> InsightWidgetData? {
        switch kind {
        case .barRanking:
            // Provider spend ranking — sort by cost, cap at 5.
            let sorted = digest.providers
                .sorted { $0.costUSD > $1.costUSD }
                .prefix(5)
            guard !sorted.isEmpty else { return nil }
            let rows = sorted.map { provider in
                InsightWidgetData.Ranking.Row(
                    id: provider.id,
                    label: provider.displayName,
                    value: provider.costUSD,
                    secondaryLabel: "\(provider.sessionCount) session\(provider.sessionCount == 1 ? "" : "s")"
                )
            }
            return .ranking(.init(
                rows: rows,
                valueFormat: .currency,
                dimensionLabel: "Provider"
            ))

        case .timeSeriesLine:
            // Cost by day, one series total. Skip if we have fewer than
            // two points (a line with one point is just a dot).
            let daily = digest.daily.sorted { $0.day < $1.day }
            guard daily.count >= 2 else { return nil }
            let points = daily.map { day in
                InsightWidgetData.TimeSeries.Point(date: day.day, value: day.costUSD)
            }
            let series = InsightWidgetData.TimeSeries.Series(
                id: "total-cost",
                name: "Daily cost",
                colorHex: "#E87060", // coral
                points: points
            )
            let peak = daily.max { $0.costUSD < $1.costUSD }
            let annotations: [InsightWidgetData.TimeSeries.Annotation] = peak.map { day in
                [.init(date: day.day, label: "Peak", tone: .warning)]
            } ?? []
            return .timeSeries(.init(
                series: [series],
                xAxisLabel: "Day",
                yAxisLabel: "USD",
                yFormat: .currency,
                annotations: annotations
            ))

        case .quotaPulse:
            // Show every quota bucket with a known limit, hottest first.
            let bucketSummaries = digest.quotaSnapshots
                .filter { ($0.limit ?? 0) > 0 }
                .sorted { lhs, rhs in
                    (lhs.used / max(lhs.limit ?? 1, 1)) > (rhs.used / max(rhs.limit ?? 1, 1))
                }
                .prefix(4)
            guard !bucketSummaries.isEmpty else { return nil }
            let buckets = bucketSummaries.map { snap in
                InsightWidgetData.QuotaState.Bucket(
                    id: "\(snap.providerID)-\(snap.bucketName)",
                    providerLabel: snap.providerID,
                    bucketName: snap.bucketName,
                    used: snap.used,
                    limit: snap.limit,
                    resetsAt: snap.resetsAt,
                    symbolName: "gauge",
                    colorHex: nil
                )
            }
            return .quota(.init(buckets: Array(buckets)))

        default:
            return nil
        }
    }

    private static func benchmarkRankingRows(
        benchmarks: [InsightDigest.ModelBenchmarkSummary],
        usedModels: [String: InsightDigest.ModelSnapshot],
        limit: Int
    ) -> [InsightWidgetData.Ranking.Row] {
        var bestByModel: [String: InsightDigest.ModelBenchmarkSummary] = [:]
        for benchmark in benchmarks {
            let key = normalizedModelID(benchmark.modelID)
            guard benchmark.score != nil || benchmark.rank != nil else { continue }
            if let existing = bestByModel[key] {
                let existingScore = existing.score ?? -1
                let score = benchmark.score ?? -1
                if score > existingScore || (score == existingScore && (benchmark.rank ?? Int.max) < (existing.rank ?? Int.max)) {
                    bestByModel[key] = benchmark
                }
            } else {
                bestByModel[key] = benchmark
            }
        }
        return bestByModel.values
            .sorted {
                let lhsUsed = usedModels[normalizedModelID($0.modelID)] != nil
                let rhsUsed = usedModels[normalizedModelID($1.modelID)] != nil
                if lhsUsed != rhsUsed { return lhsUsed }
                let lhsScore = $0.score ?? -1
                let rhsScore = $1.score ?? -1
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return ($0.rank ?? Int.max) < ($1.rank ?? Int.max)
            }
            .prefix(limit)
            .map { benchmark in
                let used = usedModels[normalizedModelID(benchmark.modelID)]
                let value = benchmark.score ?? (benchmark.rank.map { 1 / Double(max($0, 1)) } ?? 0)
                let secondaryParts = [
                    benchmark.taskCategory,
                    benchmark.attribution ?? benchmark.source,
                    used.map { String(format: "$%.2f used", $0.costUSD) }
                ].compactMap { $0 }
                return .init(
                    id: benchmark.id,
                    label: benchmark.modelID,
                    value: value,
                    secondaryLabel: secondaryParts.joined(separator: " · ")
                )
            }
    }

    private static func cheapestSimilarAlternative(
        usedModel: InsightDigest.ModelSnapshot?,
        usedBenchmark: InsightDigest.ModelBenchmarkSummary?,
        benchmarks: [InsightDigest.ModelBenchmarkSummary]
    ) -> InsightDigest.ModelBenchmarkSummary? {
        guard let usedModel else { return nil }
        let usedKey = normalizedModelID(usedModel.id)
        let usedScore = usedBenchmark?.score
        let usedCostSignal = usedBenchmark?.costSignal ?? 0
        return benchmarks
            .filter { normalizedModelID($0.modelID) != usedKey }
            .filter { candidate in
                guard candidate.costSignal ?? -1 > usedCostSignal + 0.12 else { return false }
                guard let usedScore, let candidateScore = candidate.score else { return true }
                return candidateScore >= usedScore - 0.08
            }
            .sorted {
                let lhsCost = $0.costSignal ?? 0
                let rhsCost = $1.costSignal ?? 0
                if lhsCost != rhsCost { return lhsCost > rhsCost }
                return ($0.score ?? 0) > ($1.score ?? 0)
            }
            .first
    }

    private static func bestBenchmark(
        for modelKey: String,
        in benchmarkByModel: [String: [InsightDigest.ModelBenchmarkSummary]]
    ) -> InsightDigest.ModelBenchmarkSummary? {
        bestBenchmark(in: benchmarkByModel[modelKey] ?? [])
    }

    private static func bestBenchmark(in benchmarks: [InsightDigest.ModelBenchmarkSummary]) -> InsightDigest.ModelBenchmarkSummary? {
        benchmarks.sorted {
            let lhsScore = $0.score ?? -1
            let rhsScore = $1.score ?? -1
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return ($0.rank ?? Int.max) < ($1.rank ?? Int.max)
        }.first
    }

    private static func benchmarkCitation(_ benchmark: InsightDigest.ModelBenchmarkSummary) -> InsightCitation {
        .init(
            kind: .benchmark(source: benchmark.source, modelID: benchmark.modelID, taskCategory: benchmark.taskCategory),
            label: "\(benchmark.attribution ?? benchmark.source) \(benchmark.taskCategory)"
        )
    }

    private static func confidence(for benchmark: InsightDigest.ModelBenchmarkSummary) -> InsightConfidence {
        let value = benchmark.confidence ?? 0.6
        if value >= 0.75 { return .high }
        if value <= 0.45 { return .low }
        return .medium
    }

    private static func scorePhrase(_ benchmark: InsightDigest.ModelBenchmarkSummary) -> String {
        if let rank = benchmark.rank, let score = benchmark.score {
            return " (#\(rank), \(Int((score * 100).rounded()))/100)"
        }
        if let score = benchmark.score {
            return " (\(Int((score * 100).rounded()))/100)"
        }
        if let rank = benchmark.rank {
            return " (#\(rank))"
        }
        return ""
    }

    private static func savingsPhrase(
        current: InsightDigest.ModelSnapshot,
        alternative: InsightDigest.ModelBenchmarkSummary
    ) -> String? {
        if let blended = alternative.blendedCostPerMtoken {
            return String(format: "Alternative blended price is $%.2f/MTok; validate quality before moving %.0f%% of current spend.", blended, min(50, max(10, current.costUSD > 0 ? 25 : 10)))
        }
        if let signal = alternative.costSignal {
            return "Cost signal \(Int((signal * 100).rounded()))/100; exact dollar savings need provider price confirmation."
        }
        return nil
    }

    private static func normalizedModelID(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
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

    /// Replaces or augments the base executive summary so the hero
    /// headline + body reflect what the user actually asked, not the
    /// default "biggest provider" framing.
    static func specialize(
        summary: (headline: String, body: String, bullets: [String], tone: InsightWidgetData.Narrative.Tone, action: String),
        for intent: PromptIntent,
        digest: InsightDigest,
        topProvider: InsightDigest.ProviderSnapshot?,
        topModel: InsightDigest.ModelSnapshot?,
        biggestDay: InsightDigest.DailyPoint?,
        quotaRisk: InsightDigest.QuotaSnapshotSummary?
    ) -> (headline: String, body: String, bullets: [String], tone: InsightWidgetData.Narrative.Tone, action: String) {
        switch intent {
        case .generalBrief:
            return summary

        case .costSpike:
            guard let biggestDay else { return summary }
            let day = String(ISO8601DateFormatter().string(from: biggestDay.day).prefix(10))
            let cost = currency(biggestDay.costUSD)
            let provider = topProvider?.displayName ?? "your top provider"
            return (
                headline: "Cost peaked on \(day) at \(cost)",
                body: "\(provider) was the largest contributor on that day. Re-run with a tighter window or cap top-spend models if the spike isn't a planned investment.",
                bullets: summary.bullets,
                tone: .warning,
                action: "Open the highest-cost session for \(provider) and confirm it was intentional."
            )

        case .wasteByProject:
            // The digest exposes projects as ID hashes (no raw paths).
            // If we have at least one project, build a deterministic
            // "where it leaked" story; otherwise fall back.
            if let leakProvider = topProvider {
                return (
                    headline: "Where spend leaked",
                    body: "\(leakProvider.displayName) led with \(currency(leakProvider.costUSD)) across \(leakProvider.sessionCount) sessions. Inspect that provider's biggest sessions first — that's where the dollar density is.",
                    bullets: summary.bullets,
                    tone: summary.tone,
                    action: "Sort sessions by cost descending and audit the top three."
                )
            }
            return summary

        case .routeToCheaper:
            guard let topModel else { return summary }
            return (
                headline: "Route routine work off \(topModel.id)",
                body: "\(topModel.id) is carrying the largest model cost in this window. For prompts under ~2K input tokens and short replies, a cheaper sibling model usually closes the quality gap.",
                bullets: summary.bullets,
                tone: .neutral,
                action: "Route Claude-class traffic with conversationDepth < 3 to Haiku for one week and re-measure."
            )

        case .benchmarkPerformance:
            return (
                headline: "Cheapest benchmark-equivalent route",
                body: "The router can compare your top models against public benchmark scores (Artificial Analysis / Design Arena / Terminal-Bench). Look for a sibling model with similar rank but a meaningfully lower cost signal.",
                bullets: summary.bullets,
                tone: .neutral,
                action: "Open the benchmark column in the model picker and swap any top-cost model whose lower-rank neighbor is within one tier."
            )

        case .uiOrDesignFit:
            return (
                headline: "UI / design work model fit",
                body: "Design tasks reward visual reasoning more than raw token throughput. If a top spender is the routine default for layout / Figma reads, swap to a vision-capable Sonnet-class model and keep the cheaper one for boilerplate.",
                bullets: summary.bullets,
                tone: .neutral,
                action: "Tag design-heavy sessions and route them to the highest visual-reasoning score."
            )

        case .quotaRisk:
            if let risky = quotaRisk, let limit = risky.limit, limit > 0 {
                let pct = Int((risky.used / limit) * 100)
                return (
                    headline: "\(risky.providerID) \(risky.bucketName) at \(pct)%",
                    body: "This bucket is the closest to its ceiling in the included window. If you have a heavy run planned in the next 24h, switch the router default before you start.",
                    bullets: summary.bullets,
                    tone: pct >= 80 ? .warning : .neutral,
                    action: "Pre-route the next deep session to a healthier provider until this bucket resets."
                )
            }
            return summary
        }
    }

    // MARK: - Prompt intent classification

    /// Tagged intents extracted from the natural-language `prompt`.
    /// The follow-up question links and the inline composer both feed
    /// the engine through the same pipe, so this classifier is the
    /// single hinge that makes tapping "Why did cost spike?" produce a
    /// different brief than tapping "Which model is cheapest at
    /// similar performance?".
    public enum PromptIntent: Sendable, Equatable {
        case costSpike            // "why did cost spike", "what blew up"
        case wasteByProject       // "which project / workflow wasted"
        case routeToCheaper       // "route routine work", "cheaper alternative"
        case benchmarkPerformance // "similar performance", "benchmark", "leaderboard"
        case uiOrDesignFit        // "ui", "design", "design tasks"
        case quotaRisk            // "quota risk", "limit", "headroom"
        case generalBrief         // catch-all / default brief
    }

    /// Classifies a free-text prompt into one of the canonical intents
    /// the rule engine knows how to specialize for. Pure function over
    /// the prompt text — no I/O, no locale assumptions beyond ASCII
    /// keyword matching (all canonical questions are English).
    public static func classifyPromptIntent(_ prompt: String) -> PromptIntent {
        let lower = prompt.lowercased()
        // Order matters: more specific intents check first so
        // "benchmark cost" lands on `.benchmarkPerformance`, not
        // `.routeToCheaper`.
        if lower.contains("benchmark") || lower.contains("leaderboard")
            || (lower.contains("similar") && lower.contains("performance")) {
            return .benchmarkPerformance
        }
        if lower.contains(" ui ") || lower.hasPrefix("ui ")
            || lower.contains("design task") || lower.contains("design tasks")
            || lower.contains("ux") {
            return .uiOrDesignFit
        }
        if lower.contains("quota") || lower.contains("headroom")
            || lower.contains("rate limit") || lower.contains(" limit") {
            return .quotaRisk
        }
        if lower.contains("route") || lower.contains("cheaper")
            || lower.contains("cost relief") || lower.contains("haiku") {
            return .routeToCheaper
        }
        if lower.contains("project") || lower.contains("workflow")
            || lower.contains("waste") || lower.contains("wasted") {
            return .wasteByProject
        }
        if lower.contains("spike") || lower.contains("blew up")
            || lower.contains("why did") || lower.contains("what changed") {
            return .costSpike
        }
        return .generalBrief
    }

    /// A one-line "you asked about X" eyebrow that the brief renders
    /// above the executive summary so the user can see the tap they
    /// just made is actually steering the output.
    public static func answerEyebrow(for intent: PromptIntent) -> String? {
        switch intent {
        case .costSpike:            return "Answering: why cost moved"
        case .wasteByProject:       return "Answering: where spend leaked"
        case .routeToCheaper:       return "Answering: routing to cheaper"
        case .benchmarkPerformance: return "Answering: benchmark-equivalent cost"
        case .uiOrDesignFit:        return "Answering: UI / design model fit"
        case .quotaRisk:            return "Answering: 24h quota risk"
        case .generalBrief:         return nil
        }
    }

    /// Re-orders findings so the most prompt-relevant one becomes #1.
    /// Uses a small bag-of-words match against each finding's title
    /// and `whyItMatters` text — deterministic, no model call.
    static func reorderFindings(
        _ findings: [InsightFinding],
        for intent: PromptIntent,
        topProvider: InsightDigest.ProviderSnapshot?,
        topModel: InsightDigest.ModelSnapshot?
    ) -> [InsightFinding] {
        guard !findings.isEmpty, intent != .generalBrief else { return findings }
        // Score each finding for the intent.
        func score(_ f: InsightFinding) -> Int {
            let blob = (f.title + " " + f.whyItMatters).lowercased()
            switch intent {
            case .costSpike:
                return blob.contains("spike") || blob.contains("change") || blob.contains("absorb") ? 3
                    : (blob.contains("cost") ? 1 : 0)
            case .wasteByProject:
                return blob.contains("project") || blob.contains("workflow") || blob.contains("session")
                    ? 3 : (blob.contains("waste") ? 2 : 0)
            case .routeToCheaper:
                return blob.contains("route") || blob.contains("haiku") || blob.contains("cheaper")
                    ? 3 : (blob.contains("default") ? 1 : 0)
            case .benchmarkPerformance:
                return blob.contains("benchmark") || blob.contains("performance") || blob.contains("similar")
                    ? 3 : 0
            case .uiOrDesignFit:
                return blob.contains("ui") || blob.contains("design") ? 3 : 0
            case .quotaRisk:
                return blob.contains("quota") || blob.contains("headroom") || blob.contains("limit")
                    ? 3 : 0
            case .generalBrief:
                return 0
            }
        }
        // Stable sort: keep relative order within the same score, but
        // pull higher-scoring items to the top.
        return findings.enumerated()
            .sorted { lhs, rhs in
                let ls = score(lhs.element)
                let rs = score(rhs.element)
                if ls == rs { return lhs.offset < rhs.offset }
                return ls > rs
            }
            .map(\.element)
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
                    result.briefingAnswer = InsightBriefingAnswer(
                        question: request.prompt,
                        answer: Self.composeAnswerBody(from: result),
                        bullets: Self.composeGroundedPoints(from: result),
                        citations: Array(result.citations.prefix(3)),
                        source: .modelGateway,
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
            do {
                var result = try await gateway.analyze(
                    request: request,
                    platform: platform,
                    tools: toolBroker
                )
                // If the gateway didn't already embed a `briefingAnswer`,
                // synthesize one from its tailored executive summary +
                // top finding so the UI's Q&A card always has a real
                // LLM-authored reply to render. The gateway path went
                // out to an actual model; this is *not* a rule
                // fallback — flag the source accordingly.
                if request.instruction == .answerFollowUp, result.briefingAnswer == nil {
                    let body = Self.composeAnswerBody(from: result)
                    let grounded = Self.composeGroundedPoints(from: result)
                    result.briefingAnswer = InsightBriefingAnswer(
                        question: request.prompt,
                        answer: body,
                        bullets: grounded,
                        citations: Array(result.citations.prefix(3)),
                        source: .modelGateway,
                        modelDisplayName: result.modelTag.displayName,
                        isFallback: false
                    )
                }
                return result
            } catch {
                // Gateway failed (network, auth, rate limit, etc.).
                // Degrade gracefully to the local rule engine so the
                // user *always* gets a reply, with `isFallback: true`
                // so the UI can surface a "showing local fallback"
                // hint and a Retry affordance.
                guard request.instruction == .answerFollowUp else { throw error }
                var fallbackResult = try await fallback.analyze(request)
                if var answer = fallbackResult.briefingAnswer {
                    answer.isFallback = true
                    answer.modelDisplayName = "\(request.selectedModel.displayName) → Local rules"
                    fallbackResult.briefingAnswer = answer
                }
                return fallbackResult
            }
        }

        if configuration.failWhenSelectedGatewayUnavailable {
            if request.instruction == .answerFollowUp {
                var fallbackResult = try await fallback.analyze(request)
                if var answer = fallbackResult.briefingAnswer {
                    answer.isFallback = true
                    answer.modelDisplayName = "\(request.selectedModel.displayName) → Local rules"
                    fallbackResult.briefingAnswer = answer
                }
                return fallbackResult
            }
            throw InsightGatewayError.modelUnavailable(
                modelID: request.selectedModel.modelID,
                reason: "no analysis gateway registered for \(request.selectedModel.providerKey)"
            )
        }

        return try await fallback.analyze(request)
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
