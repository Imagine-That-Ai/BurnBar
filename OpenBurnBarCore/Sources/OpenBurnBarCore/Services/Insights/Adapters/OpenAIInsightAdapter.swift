import Foundation

/// Adapter for OpenAI's Chat Completions API. Same shape as Anthropic
/// modulo wire format. Uses strict JSON-Schema on `gpt-5*` and later.
public struct OpenAIInsightAdapter: InsightModelGateway {

    public let providerKey = "openai"
    public let displayName = "OpenAI (GPT)"
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
                baseURL: URL = URL(string: "https://api.openai.com")!,
                urlSession: URLSession = .shared,
                modelCatalog: [InsightCatalogModel] = OpenAIInsightAdapter.defaultModels) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.modelCatalog = modelCatalog
    }

    public func availableModels() async throws -> [InsightCatalogModel] {
        modelCatalog
    }

    public static let defaultModels: [InsightCatalogModel] = [
        .init(id: "gpt-5", displayName: "GPT-5", providerKey: "openai",
              egressTier: .userKey,
              capabilities: .init(supportsStrictJSONSchema: true,
                                   supportsJSONObject: true,
                                   supportsThinking: true,
                                   supportsToolUse: true,
                                   supportsStreaming: true),
              inputCostPerMtoken: 10, outputCostPerMtoken: 40, symbolName: "brain.fill"),
        .init(id: "gpt-5-mini", displayName: "GPT-5 mini", providerKey: "openai",
              egressTier: .userKey,
              capabilities: .init(supportsStrictJSONSchema: true,
                                   supportsJSONObject: true,
                                   supportsThinking: false,
                                   supportsToolUse: true,
                                   supportsStreaming: true),
              inputCostPerMtoken: 0.5, outputCostPerMtoken: 2, symbolName: "bolt.fill")
    ]

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

    private func runInvestigation(request: InsightInvestigateRequest) async throws -> InsightCanvas {
        let promptEngine = InsightPromptEngine()
        let actualTier = capabilities.bestTier(requested: request.capabilityTier)
        let systemPrompt = promptEngine.systemPrompt(for: request, actualTier: actualTier)
        let userPayload = try promptEngine.userPayload(for: request)
        let userText = String(data: userPayload, encoding: .utf8) ?? ""

        var body: [String: Any] = [
            "model": request.modelTag.modelID,
            "messages": [
                ["role": "system", "content": systemPrompt + "\n\nSchema:\n" + InsightJSONSchema.canvasSchemaV1],
                ["role": "user", "content": userText]
            ],
            "temperature": 0.4
        ]
        switch actualTier {
        case .strictJSONSchema:
            body["response_format"] = ["type": "json_schema", "json_schema": [
                "name": "canvas_v1",
                "schema": (try? JSONSerialization.jsonObject(with: Data(InsightJSONSchema.canvasSchemaV1.utf8))) ?? [:]
            ]]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .narrativeOnly:
            break
        }

        var url = baseURL
        url.appendPathComponent("/v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InsightGatewayError.requestRejected(
                modelID: request.modelTag.modelID,
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }
        // Extract OpenAI-shaped content[0].message.content first.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           let canvasData = content.data(using: .utf8) {
            return try AnthropicInsightAdapter.decodeCanvas(from: canvasData,
                                                            fallbackTitle: "GPT canvas",
                                                            modelTag: request.modelTag)
        }
        return try AnthropicInsightAdapter.decodeCanvas(from: data,
                                                        fallbackTitle: "GPT canvas",
                                                        modelTag: request.modelTag)
    }
}
