import CryptoKit
import Foundation

/// Builds the model prompt for the structured Insights intelligence layer.
///
/// This sits above the canvas prompt: models return analysis JSON first
/// (findings, anomalies, recommendations, citations, generated widget
/// proposals). The app then materializes those generated widget proposals into
/// an `InsightCanvas`.
public struct InsightAnalysisModelPrompt: Sendable {
    public init() {}

    public func systemPrompt(
        for request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        strictSchema: Bool
    ) -> String {
        var lines: [String] = []
        lines.append(Self.preamble)
        lines.append("")
        lines.append("# Platform")
        lines.append(platform.rawValue)
        lines.append("")
        lines.append("# Privacy rules")
        lines.append("- Use only the compact digest, evidence index, budget report, and prior-run summaries supplied by the user payload.")
        lines.append("- Never ask for or infer secrets, credentials, raw source files, or full transcripts.")
        lines.append("- Treat citations as evidence handles. Only cite handles that appear in `evidenceIndex`.")
        lines.append("- When `modelBenchmarks` or `model_benchmarks` evidence exists, compare observed model usage against benchmark score/rank, cost signal, latency, task category, freshness, and attribution.")
        lines.append("- Never invent benchmark ranks, prices, or savings. If exact prices are absent, say `cost signal`, not dollar savings.")
        lines.append("- For UI/design work, call out design/coding benchmark fit separately from general reasoning fit.")
        lines.append("- Treat iOS, iPadOS, Android, and macOS Insights as mission-control remotes for the user's local Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex agents.")
        lines.append("- When a user asks for a mission, produce dispatch-ready work: recommended agent, target project, evidence to inspect, acceptance criteria, validation commands, risks, and what mobile should show when complete.")
        if !request.allowDeepTranscriptAnalysis {
            lines.append("- Deep transcript analysis is disabled. Do not request transcript content.")
        }
        lines.append("")
        lines.append("# Output")
        lines.append("- Emit one JSON object only.")
        lines.append("- Match the `InsightAnalysisResult` schema subset exactly.")
        lines.append("- Every finding and recommendation must include evidence and a concrete recommended action.")
        lines.append("- Return `missionCandidates` separately from findings and recommendations. Missions must be concrete work packages, not duplicate insight prose.")
        lines.append("- Use accretion, diligence, techDebt, routing, quota, and focus lenses to propose greater-purpose missions from the evidence.")
        lines.append("- Recommend adjacent security, UI improvement, modernization, and cost-efficiency missions when the digest or benchmark evidence supports them.")
        lines.append("- Propose at most \(request.maxGeneratedWidgets) generated widgets.")
        lines.append("- Prefer concise, decision-grade language over generic commentary.")
        lines.append("- Strict schema requested: \(strictSchema ? "yes" : "no").")
        lines.append("")
        lines.append("# Widget kinds")
        lines.append(InsightWidgetKind.allCases.filter { $0 != .error }.map(\.rawValue).joined(separator: ", "))
        lines.append("")
        lines.append("# Instruction")
        lines.append(Self.instructionDescription(request.instruction))
        return lines.joined(separator: "\n")
    }

    public func userPayload(for request: InsightAnalysisRequest) throws -> Data {
        struct Payload: Encodable {
            let prompt: String
            let instruction: String
            let selectedModel: InsightModelTag
            let currentCanvas: InsightCanvas?
            let context: InsightAnalysisContext
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(
            prompt: request.prompt,
            instruction: request.instruction.rawValue,
            selectedModel: request.selectedModel,
            currentCanvas: request.currentCanvas,
            context: request.context
        ))
    }

    public static let preamble = """
    You are OpenBurnBar Insights: an expert analyst for a developer's AI usage,
    cost, quota, routing, and workflow data. Your job is to explain what
    changed, why it matters, what caused it, what looks wasteful or risky, and
    what the user should do next.

    The user is paying with their own selected model/provider credentials. Be
    careful with cost and privacy. Use the evidence index. Do not fabricate
    sessions, providers, models, quotas, projects, or costs.
    """

    public static func instructionDescription(_ instruction: InsightAnalysisRequest.Instruction) -> String {
        switch instruction {
        case .defaultBrief:
            return "Generate the default Insights brief: what changed, top 3 findings, biggest waste opportunity, most important anomaly, quota/provider risk, one supporting chart/widget, and useful follow-up questions."
        case .answerFollowUp:
            return "Answer the user's follow-up question using cited evidence, and propose widget updates only where they help the answer."
        case .generateReport:
            return "Generate a report-grade analysis with findings, anomalies, recommendations, and widget proposals suitable for a monthly or weekly usage review."
        case .updateCanvas:
            return "Update the current canvas by proposing widgets that directly support the analysis. Preserve evidence citations."
        }
    }
}

enum InsightAnalysisModelDecoder {
    struct Envelope: Decodable {
        var executiveSummary: String
        var findings: [Finding]
        var anomalies: [Anomaly]
        var recommendations: [Recommendation]
        var missionCandidates: [MissionCandidate]?
        var generatedWidgets: [GeneratedWidget]
        var followUpQuestions: [FollowUpQuestion]
        var citations: [CitationRef]
    }

    struct Finding: Decodable {
        var title: String
        var whyItMatters: String
        var evidence: [CitationRef]
        var confidence: InsightConfidence
        var severity: InsightSeverity
        var recommendedAction: String
    }

    struct Anomaly: Decodable {
        var title: String
        var occurredAt: Date?
        var detail: String
        var score: Double
        var evidence: [CitationRef]
        var confidence: InsightConfidence
    }

    struct Recommendation: Decodable {
        var title: String
        var rationale: String
        var recommendedAction: String
        var estimatedImpact: String?
        var evidence: [CitationRef]
        var confidence: InsightConfidence
        var severity: InsightSeverity
    }

    struct MissionCandidate: Decodable {
        var title: String
        var summary: String
        var projectID: String?
        var projectDisplayName: String?
        var lens: InsightMissionCandidate.Lens
        var priority: InsightMissionCandidate.Priority
        var confidence: InsightConfidence
        var expectedImpact: String
        var effort: InsightMissionCandidate.Effort
        var acceptanceCriteria: [String]
        var sourceInsightIDs: [String]?
        var evidence: [CitationRef]
        var dispatchMetadata: [String: String]?
    }

    struct GeneratedWidget: Decodable {
        var kind: String
        var title: String
        var reason: String
        var citations: [CitationRef]
    }

    struct FollowUpQuestion: Decodable {
        var question: String
        var rationale: String?
    }

    struct CitationRef: Decodable, Hashable {
        var id: String?
        var label: String
    }

    static func decode(
        from data: Data,
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tokenUsage: InsightTokenUsage? = nil
    ) throws -> InsightAnalysisResult {
        let jsonData = try extractJSONObjectData(from: data, modelTag: request.selectedModel)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: jsonData)
        return hydrate(
            envelope,
            request: request,
            platform: platform,
            tokenUsage: tokenUsage
        )
    }

    static func hydrate(
        _ envelope: Envelope,
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tokenUsage: InsightTokenUsage? = nil
    ) -> InsightAnalysisResult {
        let resolver = CitationResolver(context: request.context)
        let citations = envelope.citations.map { resolver.resolve($0) }
        let findings = envelope.findings.map { raw in
            InsightFinding(
                title: raw.title,
                whyItMatters: raw.whyItMatters,
                evidence: raw.evidence.map { resolver.resolve($0) },
                confidence: raw.confidence,
                severity: raw.severity,
                recommendedAction: raw.recommendedAction
            )
        }
        let anomalies = envelope.anomalies.map { raw in
            InsightAnomaly(
                title: raw.title,
                occurredAt: raw.occurredAt,
                detail: raw.detail,
                score: raw.score,
                evidence: raw.evidence.map { resolver.resolve($0) },
                confidence: raw.confidence
            )
        }
        let recommendations = envelope.recommendations.map { raw in
            InsightRecommendation(
                title: raw.title,
                rationale: raw.rationale,
                recommendedAction: raw.recommendedAction,
                estimatedImpact: raw.estimatedImpact,
                evidence: raw.evidence.map { resolver.resolve($0) },
                confidence: raw.confidence,
                severity: raw.severity
            )
        }
        let missionCandidates = (envelope.missionCandidates ?? []).map { raw in
            InsightMissionCandidate(
                title: raw.title,
                summary: raw.summary,
                projectID: raw.projectID,
                projectDisplayName: raw.projectDisplayName,
                lens: raw.lens,
                priority: raw.priority,
                confidence: raw.confidence,
                expectedImpact: raw.expectedImpact,
                effort: raw.effort,
                acceptanceCriteria: raw.acceptanceCriteria,
                sourceInsightIDs: (raw.sourceInsightIDs ?? []).compactMap(UUID.init(uuidString:)),
                evidence: raw.evidence.map { resolver.resolve($0) },
                dispatchMetadata: raw.dispatchMetadata ?? [:]
            )
        }
        let widgets = envelope.generatedWidgets.prefix(request.maxGeneratedWidgets).map { raw in
            generatedWidget(
                raw,
                citations: raw.citations.map { resolver.resolve($0) },
                modelTag: request.selectedModel,
                fallbackRecommendation: recommendations.first
            )
        }
        let followUps = envelope.followUpQuestions.map {
            InsightFollowUpQuestion(question: $0.question, rationale: $0.rationale)
        }

        var result = InsightAnalysisResult(
            requestID: request.id,
            platform: platform,
            timeWindow: request.currentCanvas?.filter.window ?? .last7d,
            executiveSummary: envelope.executiveSummary,
            modelTag: request.selectedModel,
            contextBudget: request.context.budgetReport,
            findings: findings,
            anomalies: anomalies,
            recommendations: recommendations,
            missionCandidates: missionCandidates,
            generatedWidgets: Array(widgets),
            followUpQuestions: followUps,
            citations: citations.isEmpty ? request.context.evidenceIndex.map(\.citation) : citations,
            tokenUsage: tokenUsage,
            estimatedCostUSD: tokenUsage?.estimatedCostUSD
        )
        result.resultHash = resultHash(result)
        return result
    }

    static func resultFromCanvas(
        _ canvas: InsightCanvas,
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tokenUsage: InsightTokenUsage? = nil
    ) -> InsightAnalysisResult {
        var baseline = RuleBasedInsightAnalysisEngine.buildResult(request: request, platform: platform)
        baseline.modelTag = canvas.modelTag ?? request.selectedModel
        baseline.executiveSummary = canvas.summary ?? baseline.executiveSummary
        baseline.tokenUsage = tokenUsage
        baseline.estimatedCostUSD = tokenUsage?.estimatedCostUSD
        baseline.generatedWidgets = canvas.widgets.prefix(request.maxGeneratedWidgets).map { widget in
            InsightGeneratedWidget(
                widget: widget,
                reason: widget.rationale ?? "Generated by \(baseline.modelTag.displayName).",
                citations: citations(for: widget)
            )
        }
        baseline.resultHash = resultHash(baseline)
        return baseline
    }

    private static func generatedWidget(
        _ raw: GeneratedWidget,
        citations: [InsightCitation],
        modelTag: InsightModelTag,
        fallbackRecommendation: InsightRecommendation?
    ) -> InsightGeneratedWidget {
        let kind = InsightWidgetKind(rawValue: raw.kind) ?? .narrative
        let binding: InsightDataBinding
        let data: InsightWidgetData?
        switch kind {
        case .narrative:
            let narrative = InsightWidgetData.Narrative(
                headline: raw.title,
                body: raw.reason,
                citations: citations
            )
            binding = .narrative(narrative)
            data = .narrative(narrative)
        case .recommendation:
            let recommendation = InsightWidgetData.Recommendation(
                headline: raw.title,
                rationale: raw.reason,
                action: fallbackRecommendation?.recommendedAction ?? raw.reason,
                estimatedImpact: fallbackRecommendation?.estimatedImpact,
                confidence: .medium,
                citations: citations
            )
            binding = .recommendation(recommendation)
            data = .recommendation(recommendation)
        default:
            binding = AnthropicInsightAdapter.defaultBinding(for: kind)
            data = nil
        }
        let widget = InsightWidget(
            kind: kind,
            title: raw.title,
            spec: AnthropicInsightAdapter.defaultSpec(for: kind),
            dataBinding: binding,
            data: data,
            freshness: .fresh,
            modelTag: modelTag,
            lastComputedAt: Date(),
            rationale: raw.reason
        )
        return InsightGeneratedWidget(widget: widget, reason: raw.reason, citations: citations)
    }

    private static func citations(for widget: InsightWidget) -> [InsightCitation] {
        switch widget.data {
        case .narrative(let narrative): return narrative.citations
        case .recommendation(let recommendation): return recommendation.citations
        default: return []
        }
    }

    private static func extractJSONObjectData(from data: Data, modelTag: InsightModelTag) throws -> Data {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if json["executiveSummary"] != nil {
                return data
            }
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String,
               let contentData = content.data(using: .utf8) {
                return try extractJSONObjectData(from: contentData, modelTag: modelTag)
            }
            if let content = json["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined()
                if let contentData = text.data(using: .utf8) {
                    return try extractJSONObjectData(from: contentData, modelTag: modelTag)
                }
            }
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String,
               let contentData = content.data(using: .utf8) {
                return try extractJSONObjectData(from: contentData, modelTag: modelTag)
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID, detail: "non-utf8 response")
        }
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let firstBrace = stripped.firstIndex(of: "{") else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID, detail: "no JSON found")
        }
        var depth = 0
        var endIndex: String.Index?
        for idx in stripped[firstBrace...].indices {
            let c = stripped[idx]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = stripped.index(after: idx)
                    break
                }
            }
        }
        guard let endIndex else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID, detail: "unbalanced JSON object")
        }
        let json = String(stripped[firstBrace..<endIndex])
        guard let jsonData = json.data(using: .utf8) else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID, detail: "could not encode JSON")
        }
        return jsonData
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

    private struct CitationResolver {
        private let byUUID: [String: InsightCitation]
        private let bySourceID: [String: InsightCitation]
        private let byLabel: [String: InsightCitation]

        init(context: InsightAnalysisContext) {
            var uuid: [String: InsightCitation] = [:]
            var source: [String: InsightCitation] = [:]
            var label: [String: InsightCitation] = [:]
            for evidence in context.evidenceIndex {
                uuid[evidence.citation.id.uuidString.lowercased()] = evidence.citation
                source[evidence.id.lowercased()] = evidence.citation
                label[evidence.citation.label.lowercased()] = evidence.citation
                label[evidence.summary.lowercased()] = evidence.citation
            }
            self.byUUID = uuid
            self.bySourceID = source
            self.byLabel = label
        }

        func resolve(_ ref: CitationRef) -> InsightCitation {
            if let id = ref.id?.lowercased() {
                if let exact = byUUID[id] ?? bySourceID[id] { return exact }
            }
            if let exact = byLabel[ref.label.lowercased()] { return exact }
            return InsightCitation(kind: .query(text: ref.id ?? ref.label), label: ref.label)
        }
    }
}
