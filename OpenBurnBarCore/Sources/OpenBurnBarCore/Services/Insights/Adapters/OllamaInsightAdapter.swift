import Foundation

/// Adapter for a locally-hosted Ollama (or compatible) endpoint.
///
/// Tier-2 (`json_object`) only. Stays in the `localOnly` egress tier
/// because traffic never leaves the device's network.
public struct OllamaInsightAdapter: InsightModelGateway {

    public let providerKey = "ollama"
    public let displayName = "Ollama"
    public let capabilities = InsightModelCapabilities(
        supportsStrictJSONSchema: false,
        supportsJSONObject: true,
        supportsThinking: false,
        supportsToolUse: false,
        supportsStreaming: true
    )

    public let baseURL: URL
    public let urlSession: URLSession
    public let modelCatalog: [InsightCatalogModel]

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                urlSession: URLSession = .shared,
                modelCatalog: [InsightCatalogModel] = []) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.modelCatalog = modelCatalog
    }

    public func availableModels() async throws -> [InsightCatalogModel] {
        if !modelCatalog.isEmpty { return modelCatalog }
        // Probe /api/tags.
        var url = baseURL
        url.appendPathComponent("/api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let parsed = try JSONDecoder().decode(TagsResponse.self, from: data)
        return parsed.models.map { m in
            .init(id: m.name, displayName: m.name, providerKey: providerKey,
                  egressTier: .localOnly, capabilities: capabilities,
                  inputCostPerMtoken: 0, outputCostPerMtoken: 0,
                  symbolName: "desktopcomputer")
        }
    }

    public func investigate(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let canvas = try await runInvestigation(request: request)
                    continuation.yield(.finalCanvas(canvas))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func analyze(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tools: InsightToolBroker?
    ) async throws -> InsightAnalysisResult {
        let startedAt = Date()
        let prompt = InsightAnalysisModelPrompt()
        let system = prompt.systemPrompt(for: request, platform: platform, strictSchema: false)
        let payload = try prompt.userPayload(for: request)
        let userText = String(data: payload, encoding: .utf8) ?? ""

        let body: [String: Any] = [
            "model": request.selectedModel.modelID,
            "messages": [
                ["role": "system", "content": system + "\n\nSchema:\n" + InsightJSONSchema.analysisResultSchemaV1],
                ["role": "user", "content": userText]
            ],
            "format": "json",
            "stream": false
        ]

        var url = baseURL
        url.appendPathComponent("/api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InsightGatewayError.requestRejected(
                modelID: request.selectedModel.modelID,
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }
        let usage = tokenUsage(from: data, request: request, startedAt: startedAt, completedAt: Date())
        return try InsightAnalysisModelDecoder.decode(
            from: data,
            request: request,
            platform: platform,
            tokenUsage: usage
        )
    }

    private func runInvestigation(request: InsightInvestigateRequest) async throws -> InsightCanvas {
        let promptEngine = InsightPromptEngine()
        let tier = capabilities.bestTier(requested: request.capabilityTier)
        let system = promptEngine.systemPrompt(for: request, actualTier: tier)
        let payload = try promptEngine.userPayload(for: request)
        let userText = String(data: payload, encoding: .utf8) ?? ""

        let body: [String: Any] = [
            "model": request.modelTag.modelID,
            "messages": [
                ["role": "system", "content": system + "\n\nSchema:\n" + InsightJSONSchema.canvasSchemaV1],
                ["role": "user", "content": userText]
            ],
            "format": "json",
            "stream": false
        ]

        var url = baseURL
        url.appendPathComponent("/api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InsightGatewayError.requestRejected(
                modelID: request.modelTag.modelID,
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? [String: Any],
           let content = message["content"] as? String,
           let canvasData = content.data(using: .utf8) {
            return try AnthropicInsightAdapter.decodeCanvas(from: canvasData,
                                                            fallbackTitle: "Ollama canvas",
                                                            modelTag: request.modelTag)
        }
        return try AnthropicInsightAdapter.decodeCanvas(from: data,
                                                        fallbackTitle: "Ollama canvas",
                                                        modelTag: request.modelTag)
    }

    private func tokenUsage(
        from data: Data,
        request: InsightAnalysisRequest,
        startedAt: Date,
        completedAt: Date
    ) -> InsightTokenUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let input = json["prompt_eval_count"] as? Int ?? 0
        let output = json["eval_count"] as? Int ?? 0
        return InsightTokenUsage(
            providerKey: providerKey,
            modelID: request.selectedModel.modelID,
            inputTokens: input,
            outputTokens: output,
            estimatedCostUSD: 0,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
