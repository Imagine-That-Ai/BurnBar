import Foundation

/// Generic OpenAI-compatible chat-completions adapter used for user-key
/// providers that expose `/v1/chat/completions` but are not OpenAI itself
/// (MiniMax, Z.ai, Kimi/Moonshot, OpenRouter/Hermes gateways, etc.).
public struct OpenAICompatibleInsightAdapter: InsightModelGateway {
    public let providerKey: String
    public let displayName: String
    public let capabilities = InsightModelCapabilities(
        supportsStrictJSONSchema: false,
        supportsJSONObject: true,
        supportsThinking: false,
        supportsToolUse: false,
        supportsStreaming: true
    )

    public let apiKey: String
    public let baseURL: URL
    public let urlSession: URLSession
    public let modelCatalog: [InsightCatalogModel]
    public let authorizationHeaderName: String
    public let authorizationHeaderValuePrefix: String
    public let chatCompletionsPath: String
    public let maxTokens: Int

    public init(
        providerKey: String,
        displayName: String,
        apiKey: String,
        baseURL: URL,
        modelCatalog: [InsightCatalogModel],
        urlSession: URLSession = .shared,
        authorizationHeaderName: String = "Authorization",
        authorizationHeaderValuePrefix: String = "Bearer ",
        chatCompletionsPath: String = "/v1/chat/completions",
        maxTokens: Int = 1400
    ) {
        self.providerKey = providerKey
        self.displayName = displayName
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelCatalog = modelCatalog
        self.urlSession = urlSession
        self.authorizationHeaderName = authorizationHeaderName
        self.authorizationHeaderValuePrefix = authorizationHeaderValuePrefix
        self.chatCompletionsPath = chatCompletionsPath
        self.maxTokens = maxTokens
    }

    public func availableModels() async throws -> [InsightCatalogModel] {
        modelCatalog
    }

    public func investigate(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await analyze(
                        request: .init(
                            prompt: request.prompt,
                            context: .init(
                                digest: request.digest,
                                evidenceIndex: [],
                                budgetReport: .init(
                                    encodedBytes: 0,
                                    estimatedPromptTokens: 0,
                                    includedDataSources: []
                                )
                            ),
                            currentCanvas: request.canvas,
                            selectedModel: request.modelTag,
                            instruction: .updateCanvas,
                            maxGeneratedWidgets: request.maxNewWidgets
                        ),
                        platform: .macOS,
                        tools: tools
                    )
                    continuation.yield(.finalCanvas(RuleBasedInsightAnalysisEngine.materializeCanvas(from: result, prompt: request.prompt)))
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
        let systemPrompt = prompt.systemPrompt(for: request, platform: platform, strictSchema: false)
        let userPayload = try prompt.userPayload(for: request)
        let userText = String(data: userPayload, encoding: .utf8) ?? ""

        let body: [String: Any] = [
            "model": request.selectedModel.modelID,
            "messages": [
                ["role": "system", "content": systemPrompt + "\n\nSchema:\n" + InsightJSONSchema.analysisResultSchemaV1],
                ["role": "user", "content": userText]
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"]
        ]

        var urlRequest = URLRequest(url: endpointURL())
        urlRequest.httpMethod = "POST"
        urlRequest.addValue(authorizationHeaderValuePrefix + apiKey, forHTTPHeaderField: authorizationHeaderName)
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

    private func tokenUsage(
        from data: Data,
        request: InsightAnalysisRequest,
        startedAt: Date,
        completedAt: Date
    ) -> InsightTokenUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            return nil
        }
        let input = usage["prompt_tokens"] as? Int ?? usage["input_tokens"] as? Int ?? 0
        let output = usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int ?? 0
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let cacheCreation = intValue(usage["cache_creation_input_tokens"])
            ?? intValue(usage["cache_creation_tokens"])
            ?? 0
        let exclusiveCacheRead = intValue(usage["cache_read_input_tokens"])
            ?? intValue(usage["cache_read_tokens"])
            ?? 0
        let inclusiveCacheRead = intValue(usage["input_cached_tokens"])
            ?? intValue(usage["cached_input_tokens"])
            ?? intValue(usage["cached_tokens"])
            ?? intValue(promptDetails?["cached_tokens"])
            ?? intValue(inputDetails?["cached_tokens"])
            ?? 0
        let cacheRead = exclusiveCacheRead > 0 ? exclusiveCacheRead : inclusiveCacheRead
        let uncachedInput = inclusiveCacheRead > 0 && exclusiveCacheRead == 0 ? max(input - inclusiveCacheRead, 0) : input
        let estimated = estimateCost(
            input: uncachedInput,
            output: output,
            cacheCreation: cacheCreation,
            cacheRead: cacheRead,
            modelID: request.selectedModel.modelID
        )
        return InsightTokenUsage(
            providerKey: providerKey,
            modelID: request.selectedModel.modelID,
            inputTokens: uncachedInput,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: estimated,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func estimateCost(input: Int, output: Int, cacheCreation: Int = 0, cacheRead: Int = 0, modelID: String) -> Double {
        if let pricing = BurnBarCatalogLoader.bundledCatalog.pricing(forModelName: modelID) {
            return pricing.cost(
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheCreation,
                cacheReadTokens: cacheRead
            )
        }
        let price = modelCatalog.first { $0.id == modelID }
        let inputRate = price?.inputCostPerMtoken ?? 0
        return (Double(input) / 1_000_000.0) * inputRate
            + (Double(output) / 1_000_000.0) * (price?.outputCostPerMtoken ?? 0)
            + (Double(cacheCreation) / 1_000_000.0) * inputRate
            + (Double(cacheRead) / 1_000_000.0) * (inputRate * 0.1)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func endpointURL() -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent(chatCompletionsPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = chatCompletionsPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        return components.url ?? baseURL.appendingPathComponent(endpointPath)
    }
}
