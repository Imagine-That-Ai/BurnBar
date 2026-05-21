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
              inputCostPerMtoken: 1.25, outputCostPerMtoken: 10, symbolName: "brain.fill"),
        .init(id: "gpt-5-mini", displayName: "GPT-5 mini", providerKey: "openai",
              egressTier: .userKey,
              capabilities: .init(supportsStrictJSONSchema: true,
                                   supportsJSONObject: true,
                                   supportsThinking: false,
                                   supportsToolUse: true,
                                   supportsStreaming: true),
              inputCostPerMtoken: 0.25, outputCostPerMtoken: 2, symbolName: "bolt.fill")
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

    public func analyze(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tools: InsightToolBroker?
    ) async throws -> InsightAnalysisResult {
        let startedAt = Date()
        let budget = InsightInvestigationBudget.default
        let prompt = InsightAnalysisModelPrompt()
        let systemPrompt = prompt.systemPrompt(
            for: request,
            platform: platform,
            strictSchema: capabilities.supportsStrictJSONSchema
        )
        let userPayload = try prompt.userPayload(for: request)
        let userText = String(data: userPayload, encoding: .utf8) ?? ""

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt + "\n\nSchema:\n" + InsightJSONSchema.analysisResultSchemaV1],
            ["role": "user", "content": userText]
        ]

        var toolCallCount = 0
        var accumulatedInputTokens = 0
        var accumulatedOutputTokens = 0
        var accumulatedCacheCreationTokens = 0
        var accumulatedCacheReadTokens = 0

        while true {
            var body: [String: Any] = [
                "model": request.selectedModel.modelID,
                "messages": messages,
                "temperature": 0.2
            ]
            if capabilities.supportsStrictJSONSchema {
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": [
                        "name": "insight_analysis_result_v1",
                        "strict": true,
                        "schema": (try? JSONSerialization.jsonObject(with: Data(InsightJSONSchema.analysisResultSchemaV1.utf8))) ?? [:]
                    ]
                ]
            } else {
                body["response_format"] = ["type": "json_object"]
            }

            let shouldPassTools = tools != nil && toolCallCount < budget.maxToolCalls
            if shouldPassTools {
                body["tools"] = InsightToolDefinitions.openAITools
                body["tool_choice"] = "auto"
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
                    modelID: request.selectedModel.modelID,
                    reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                )
            }

            if let usage = usageFrom(data: data) {
                accumulatedInputTokens += usage.inputTokens
                accumulatedOutputTokens += usage.outputTokens
                accumulatedCacheCreationTokens += usage.cacheCreationTokens
                accumulatedCacheReadTokens += usage.cacheReadTokens
            }

            guard let toolCalls = extractOpenAIToolCalls(from: data),
                  !toolCalls.isEmpty,
                  shouldPassTools,
                  let broker = tools else {
                let finalUsage = InsightTokenUsage(
                    providerKey: providerKey,
                    modelID: request.selectedModel.modelID,
                    inputTokens: accumulatedInputTokens,
                    outputTokens: accumulatedOutputTokens,
                    cacheCreationTokens: accumulatedCacheCreationTokens,
                    cacheReadTokens: accumulatedCacheReadTokens,
                    estimatedCostUSD: estimateCost(
                        input: accumulatedInputTokens,
                        output: accumulatedOutputTokens,
                        cacheCreation: accumulatedCacheCreationTokens,
                        cacheRead: accumulatedCacheReadTokens,
                        modelID: request.selectedModel.modelID
                    ),
                    startedAt: startedAt,
                    completedAt: Date()
                )
                return try InsightAnalysisModelDecoder.decode(
                    from: data,
                    request: request,
                    platform: platform,
                    tokenUsage: finalUsage
                )
            }

            let assistantMessage = buildOpenAIAssistantMessage(from: data)
            messages.append(assistantMessage)

            for call in toolCalls {
                toolCallCount += 1
                let toolResult = await broker.dispatch(call)
                let resultPayload = try JSONEncoder().encode(toolResult.payload)
                let resultJSON = String(data: resultPayload, encoding: .utf8) ?? "{}"
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": resultJSON
                ])
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

    // MARK: - Tool-use helpers

    private func extractOpenAIToolCalls(from data: Data) -> [InsightToolCall]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]] else {
            return nil
        }
        let calls = toolCalls.compactMap { call -> InsightToolCall? in
            guard call["type"] as? String == "function",
                  let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let argumentsJSON = function["arguments"] as? String,
                  let argumentsData = argumentsJSON.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
                return nil
            }
            return InsightToolCall(
                id: id,
                name: name,
                arguments: parseToolArguments(name: name, input: arguments)
            )
        }
        return calls.isEmpty ? nil : calls
    }

    private func buildOpenAIAssistantMessage(from data: Data) -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            return ["role": "assistant", "content": ""]
        }
        var copy = message
        copy["role"] = "assistant"
        return copy
    }

    private func parseToolArguments(name: String, input: [String: Any]) -> InsightToolArguments {
        switch name {
        case "drilldown_search":
            return .drilldownSearch(
                query: input["query"] as? String ?? "",
                filter: parseWindowFilter(input["window"] as? String)
            )
        case "drilldown_session":
            return .drilldownSession(sessionID: input["session_id"] as? String ?? "")
        case "agent_usage":
            return .agentUsage(
                agent: input["agent"] as? String ?? "",
                window: parseTimeWindow(input["window"] as? String) ?? .last30d
            )
        case "model_usage":
            return .modelUsage(
                modelID: input["model_id"] as? String ?? "",
                window: parseTimeWindow(input["window"] as? String) ?? .last30d
            )
        case "operating_actions":
            return .operatingActions(
                window: parseTimeWindow(input["window"] as? String) ?? .last30d
            )
        case "quota_snapshot":
            return .quotaSnapshot(providerKey: input["provider_key"] as? String)
        case "anomaly_detail":
            return .anomalyDetail(anomalyID: input["anomaly_id"] as? String ?? "")
        case "list_focuses":
            return .listFocuses
        case "list_use_cases":
            return .listUseCases
        default:
            return .listFocuses
        }
    }

    private func parseWindowFilter(_ raw: String?) -> InsightFilter? {
        guard let raw = raw, let window = parseTimeWindow(raw) else { return nil }
        return InsightFilter(window: window)
    }

    private func parseTimeWindow(_ raw: String?) -> InsightTimeWindow? {
        guard let raw = raw else { return nil }
        switch raw {
        case "today": return .today
        case "last24h": return .last24h
        case "last7d": return .last7d
        case "last30d": return .last30d
        case "last90d": return .last90d
        case "last365d": return .last365d
        case "allTime": return .allTime
        default: return nil
        }
    }

    private func usageFrom(data: Data) -> (inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int)? {
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
        return (uncachedInput, output, cacheCreation, cacheRead)
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
        let parsed = usageFrom(data: data)
        let cacheCreation = parsed?.cacheCreationTokens ?? 0
        let cacheRead = parsed?.cacheReadTokens ?? 0
        let uncachedInput = parsed?.inputTokens ?? input
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

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
