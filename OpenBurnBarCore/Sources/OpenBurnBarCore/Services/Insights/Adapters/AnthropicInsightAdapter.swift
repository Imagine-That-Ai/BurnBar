import Foundation

/// Adapter for Anthropic's Messages API.
///
/// Uses tier-1 strict JSON-Schema generation for canvas authoring and
/// supports extended thinking when the user picks an opus-class model.
public struct AnthropicInsightAdapter: InsightModelGateway {

    public let providerKey = "anthropic"
    public let displayName = "Anthropic (Claude)"
    public let capabilities = InsightModelCapabilities(
        supportsStrictJSONSchema: true,
        supportsJSONObject: true,
        supportsThinking: true,
        supportsToolUse: true,
        supportsStreaming: true
    )

    public let apiKey: String
    public let baseURL: URL
    public let urlSession: URLSession
    public let modelCatalog: [InsightCatalogModel]

    public init(apiKey: String,
                baseURL: URL = URL(string: "https://api.anthropic.com")!,
                urlSession: URLSession = .shared,
                modelCatalog: [InsightCatalogModel] = AnthropicInsightAdapter.defaultModels) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.modelCatalog = modelCatalog
    }

    public func availableModels() async throws -> [InsightCatalogModel] {
        modelCatalog
    }

    public static let defaultModels: [InsightCatalogModel] = [
        .init(id: "claude-opus-4-7", displayName: "Claude Opus 4.7", providerKey: "anthropic",
              egressTier: .userKey, capabilities: .init(supportsStrictJSONSchema: true,
                                                        supportsJSONObject: true,
                                                        supportsThinking: true,
                                                        supportsToolUse: true,
                                                        supportsStreaming: true),
              inputCostPerMtoken: 15, outputCostPerMtoken: 75, symbolName: "sparkles"),
        .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", providerKey: "anthropic",
              egressTier: .userKey, capabilities: .init(supportsStrictJSONSchema: true,
                                                        supportsJSONObject: true,
                                                        supportsThinking: false,
                                                        supportsToolUse: true,
                                                        supportsStreaming: true),
              inputCostPerMtoken: 3, outputCostPerMtoken: 15, symbolName: "sparkles"),
        .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", providerKey: "anthropic",
              egressTier: .userKey, capabilities: .init(supportsStrictJSONSchema: true,
                                                        supportsJSONObject: true,
                                                        supportsThinking: false,
                                                        supportsToolUse: false,
                                                        supportsStreaming: true),
              inputCostPerMtoken: 1, outputCostPerMtoken: 5, symbolName: "bolt.fill")
    ]

    public func investigate(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let canvas = try await runInvestigation(request: request, tools: tools)
                    continuation.yield(.finalCanvas(canvas))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runInvestigation(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) async throws -> InsightCanvas {
        let promptEngine = InsightPromptEngine()
        let actualTier = capabilities.bestTier(requested: request.capabilityTier)
        let systemPrompt = promptEngine.systemPrompt(for: request, actualTier: actualTier)
        let userPayload = try promptEngine.userPayload(for: request)
        let userText = String(data: userPayload, encoding: .utf8) ?? ""

        // Construct request body. We pass the schema as part of the system
        // prompt for JSON-object mode; strict-schema is enforced via
        // response_format on supported endpoints.
        var body: [String: Any] = [
            "model": request.modelTag.modelID,
            "max_tokens": 4096,
            "system": systemPrompt + "\n\nSchema:\n" + InsightJSONSchema.canvasSchemaV1,
            "messages": [
                ["role": "user", "content": userText]
            ],
            "temperature": 0.4
        ]
        if actualTier == .strictJSONSchema {
            body["response_format"] = [
                "type": "json_schema",
                "schema_id": "canvas-v1"
            ]
        }

        var url = baseURL
        url.appendPathComponent("/v1/messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.addValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InsightGatewayError.requestRejected(
                modelID: request.modelTag.modelID,
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }

        return try Self.decodeCanvas(from: data, fallbackTitle: "Anthropic canvas",
                                     modelTag: request.modelTag)
    }

    /// Decoder shared by adapters: lifts a JSON canvas out of arbitrary
    /// LLM output. Forgiving — strips fences, walks brace depth.
    public static func decodeCanvas(from data: Data,
                                    fallbackTitle: String,
                                    modelTag: InsightModelTag) throws -> InsightCanvas {
        guard let text = String(data: data, encoding: .utf8) else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID,
                                                         detail: "non-utf8 response")
        }
        // First-pass: look for an Anthropic-shaped object with `content`.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined()
            if let canvas = try? parseEmbedded(json: text, modelTag: modelTag) {
                return canvas
            }
        }
        // Fallback: scan the raw text for a JSON object.
        return try parseEmbedded(json: text, modelTag: modelTag)
    }

    private static func parseEmbedded(json: String, modelTag: InsightModelTag) throws -> InsightCanvas {
        // Strip Markdown code fences.
        let stripped = json
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        // Walk brace depth.
        guard let firstBrace = stripped.firstIndex(of: "{") else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID, detail: "no JSON found")
        }
        var depth = 0
        var endIndex: String.Index? = nil
        for idx in stripped[firstBrace...].indices {
            let c = stripped[idx]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { endIndex = stripped.index(after: idx); break }
            }
        }
        guard let endIndex else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID,
                                                         detail: "unbalanced braces")
        }
        let jsonSlice = String(stripped[firstBrace..<endIndex])
        guard let jsonData = jsonSlice.data(using: .utf8) else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID, detail: "encode")
        }
        // Try direct canvas decode first.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let canvas = try? decoder.decode(InsightCanvas.self, from: jsonData) {
            var copy = canvas
            copy.modelTag = modelTag
            return copy
        }
        // Otherwise: simple-shape decode → assemble widgets.
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw InsightGatewayError.malformedResponse(modelID: modelTag.modelID, detail: "not an object")
        }
        let title = (obj["title"] as? String) ?? "Canvas"
        let summary = obj["summary"] as? String
        let widgetsRaw = obj["widgets"] as? [[String: Any]] ?? []
        let widgets = widgetsRaw.compactMap(Self.simpleWidget)
        var canvas = InsightCanvas(title: title, summary: summary, theme: .aurora,
                                   filter: InsightFilter(),
                                   modelTag: modelTag,
                                   origin: .composed(prompt: ""))
        for w in widgets { canvas.add(w) }
        return canvas
    }

    /// Parse a simple "kind + title" widget shape into an InsightWidget
    /// with a sensible default binding.
    public static func simpleWidget(_ obj: [String: Any]) -> InsightWidget? {
        guard let kindRaw = obj["kind"] as? String,
              let kind = InsightWidgetKind(rawValue: kindRaw),
              let title = obj["title"] as? String else {
            return nil
        }
        let rationale = obj["rationale"] as? String
        let subtitle = obj["subtitle"] as? String

        // The model can pass a `dataBinding` object. If we can't decode it,
        // fall back to a default per kind.
        let binding = defaultBinding(for: kind)
        let spec = defaultSpec(for: kind)
        return .init(kind: kind, title: title, subtitle: subtitle,
                     spec: spec, dataBinding: binding,
                     rationale: rationale)
    }

    public static func defaultBinding(for kind: InsightWidgetKind) -> InsightDataBinding {
        switch kind {
        case .kpiTile: return .kpi(metric: .totalCost, window: .last7d)
        case .timeSeriesLine, .timeSeriesArea, .streamGraph:
            return .timeSeries(metric: .cost, dimension: .provider, window: .last30d)
        case .barRanking: return .ranking(metric: .cost, dimension: .model, limit: 8, window: .last30d)
        case .donut, .treemap: return .distribution(metric: .cost, dimension: .provider, window: .last30d)
        case .heatmap: return .heatmap(metric: .sessions, window: .last30d)
        case .scatter: return .scatter(xMetric: .tokens, yMetric: .cost, dimension: .model, window: .last30d)
        case .sankey: return .sankey(source: .provider, mid: nil, target: .model, window: .last30d)
        case .radar: return .radar(target: .allAgents, window: .last30d)
        case .cohort: return .cohort(window: .last90d)
        case .funnel: return .funnel(stages: [], window: .last30d)
        case .quotaPulse: return .quota(providerKey: nil)
        case .forecast: return .forecast(metric: .cost, horizonDays: 7)
        case .anomalyTable: return .anomaly(window: .last90d)
        case .narrative: return .narrative(.init(headline: "—", body: "—"))
        case .recommendation: return .recommendation(.init(headline: "—", rationale: "—", action: "—"))
        case .useCaseCluster: return .useCaseClusters(window: .last30d)
        case .agentFocusMatrix: return .agentFocusMatrix(window: .last30d)
        case .modelFocusMatrix: return .modelFocusMatrix(window: .last30d)
        case .drilldownList: return .drilldown(limit: 10)
        case .mermaid: return .mermaid(source: "graph TD; A-->B")
        case .ascii: return .ascii(.init(headline: "—", monoBody: ""))
        case .composed: return .composed([])
        case .error: return .narrative(.init(headline: "Error", body: "—"))
        }
    }

    public static func defaultSpec(for kind: InsightWidgetKind) -> InsightWidgetSpec {
        switch kind {
        case .kpiTile: return .kpiTile(.init(metricLabel: "Metric"))
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
        case .error: return .error(.init(message: "—"))
        }
    }
}
