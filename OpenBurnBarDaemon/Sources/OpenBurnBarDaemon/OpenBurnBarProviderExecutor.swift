import OpenBurnBarCore
import Foundation
import LocalAuthentication
import Security

public struct BurnBarProviderExecutionResult: Sendable {
    public let outputText: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    public init(
        outputText: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) {
        self.outputText = outputText
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

public struct BurnBarProviderProxyUsage: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let confidence: BurnBarUsageConfidence

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        reasoningTokens: Int,
        confidence: BurnBarUsageConfidence
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.confidence = confidence
    }
}

public struct BurnBarProviderProxyResponse: Sendable {
    public let statusCode: Int
    public let contentType: String
    public let body: Data
    public let usage: BurnBarProviderProxyUsage?

    public init(
        statusCode: Int,
        contentType: String,
        body: Data,
        usage: BurnBarProviderProxyUsage?
    ) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
        self.usage = usage
    }
}

public struct BurnBarStructuredPromptRequest: Sendable {
    public let systemPrompt: String?
    public let userPrompt: String
    public let assistantContextBlocks: [String]
    public let jsonOnly: Bool

    public init(
        systemPrompt: String? = nil,
        userPrompt: String,
        assistantContextBlocks: [String] = [],
        jsonOnly: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.assistantContextBlocks = assistantContextBlocks
        self.jsonOnly = jsonOnly
    }
}

public protocol BurnBarProviderExecuting: Sendable {
    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult
}

public extension BurnBarProviderExecuting {
    func complete(prompt: String, route: BurnBarProviderRoute) async throws -> BurnBarProviderExecutionResult {
        try await completeStructured(
            BurnBarStructuredPromptRequest(userPrompt: prompt),
            route: route
        )
    }
}

public enum BurnBarProviderExecutorError: Error, LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case upstreamError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "Invalid OpenBurnBar provider base URL: \(baseURL)"
        case .invalidResponse:
            return "OpenBurnBar provider returned an invalid response."
        case .upstreamError(let statusCode, let body):
            return "OpenBurnBar provider request failed with status \(statusCode): \(body)"
        }
    }
}

public struct BurnBarOpenAICompatibleProviderExecutor: BurnBarProviderExecuting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func completeStructured(
        _ promptRequest: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        if let fakeResult = try BurnBarFakeProviderExecution.consumeNextResult(
            promptRequest: promptRequest,
            route: route
        ) {
            return fakeResult
        }

        guard let baseURL = URL(string: route.baseURL) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(route.baseURL)
        }

        var messages: [ProviderCompletionRequest.Message] = []
        if let systemPrompt = promptRequest.systemPrompt, !systemPrompt.isEmpty {
            messages.append(.init(role: "system", content: systemPrompt))
        }
        for assistantBlock in promptRequest.assistantContextBlocks where !assistantBlock.isEmpty {
            messages.append(.init(role: "assistant", content: assistantBlock))
        }
        messages.append(.init(role: "user", content: promptRequest.userPrompt))
        let requestBody = try JSONEncoder().encode(
            ProviderCompletionRequest(
                model: route.resolvedModelID,
                messages: messages,
                responseFormat: promptRequest.jsonOnly ? .init(type: "json_object") : nil
            )
        )

        if Self.shouldUseOllamaNativeAPI(route: route, baseURL: baseURL) {
            let proxyResponse = try await proxyChatCompletions(body: requestBody, route: route)
            return try Self.executionResult(
                fromOpenAICompletionBody: proxyResponse.body,
                promptRequest: promptRequest
            )
        }

        let endpoint = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = requestBody

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BurnBarProviderExecutorError.upstreamError(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        return try Self.executionResult(
            fromOpenAICompletionBody: data,
            promptRequest: promptRequest
        )
    }

    private static func executionResult(
        fromOpenAICompletionBody data: Data,
        promptRequest: BurnBarStructuredPromptRequest
    ) throws -> BurnBarProviderExecutionResult {
        let decoded = try JSONDecoder().decode(ProviderCompletionResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        let usage = decoded.usage?.normalized(
            inputHint: max(1, promptRequest.userPrompt.count / 4),
            outputHint: max(1, choice.message.content.count / 4)
        ) ?? .init(
            promptTokens: max(1, promptRequest.userPrompt.count / 4),
            completionTokens: max(1, choice.message.content.count / 4),
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0
        )

        return BurnBarProviderExecutionResult(
            outputText: choice.message.content,
            inputTokens: usage.promptTokens,
            outputTokens: usage.completionTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens
        )
    }

    public func proxyChatCompletions(
        body: Data,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderProxyResponse {
        guard let baseURL = URL(string: route.baseURL) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(route.baseURL)
        }

        if Self.shouldUseOllamaNativeAPI(route: route, baseURL: baseURL) {
            return try await proxyOllamaNativeChatCompletions(
                body: body,
                route: route,
                baseURL: baseURL
            )
        }

        let outboundBody = try Self.rewritingModel(in: body, to: route.resolvedModelID)
        let endpoint = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = outboundBody

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BurnBarProviderExecutorError.upstreamError(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        return BurnBarProviderProxyResponse(
            statusCode: httpResponse.statusCode,
            contentType: contentType,
            body: data,
            usage: Self.extractProxyUsage(requestBody: outboundBody, responseBody: data)
        )
    }

    public func proxyResponses(
        body: Data,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderProxyResponse {
        guard let baseURL = URL(string: route.baseURL) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(route.baseURL)
        }

        guard !Self.shouldUseOllamaNativeAPI(route: route, baseURL: baseURL) else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Provider \(route.providerDisplayName) does not expose OpenAI /v1/responses through this configured endpoint."
            )
        }

        let outboundBody = try Self.rewritingModel(in: body, to: route.resolvedModelID)
        let endpoint = baseURL.appending(path: "responses")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = outboundBody

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BurnBarProviderExecutorError.upstreamError(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        return BurnBarProviderProxyResponse(
            statusCode: httpResponse.statusCode,
            contentType: contentType,
            body: data,
            usage: Self.extractResponsesUsage(responseBody: data)
        )
    }

    private func proxyOllamaNativeChatCompletions(
        body: Data,
        route: BurnBarProviderRoute,
        baseURL: URL
    ) async throws -> BurnBarProviderProxyResponse {
        let (outboundBody, streamRequested) = try Self.ollamaNativeRequestBody(
            from: body,
            modelID: route.resolvedModelID
        )
        let endpoint = Self.ollamaNativeChatEndpoint(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = outboundBody

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BurnBarProviderExecutorError.upstreamError(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        return try Self.openAIProxyResponseFromOllama(
            requestBody: outboundBody,
            responseBody: data,
            modelID: route.resolvedModelID,
            streamRequested: streamRequested
        )
    }

    private static func rewritingModel(in body: Data, to modelID: String) throws -> Data {
        let json = try JSONSerialization.jsonObject(with: body)
        guard var object = json as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        object["model"] = modelID
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func shouldUseOllamaNativeAPI(route: BurnBarProviderRoute, baseURL: URL) -> Bool {
        guard route.providerID.lowercased() == "ollama" else { return false }
        return !baseURL.path.lowercased().hasSuffix("/v1")
    }

    private static func ollamaNativeChatEndpoint(baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if normalizedPath == "api" || normalizedPath.hasSuffix("/api") {
            return baseURL.appending(path: "chat")
        }
        return baseURL.appending(path: "api").appending(path: "chat")
    }

    private static func ollamaNativeRequestBody(
        from body: Data,
        modelID: String
    ) throws -> (Data, Bool) {
        let json = try JSONSerialization.jsonObject(with: body)
        guard var object = json as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        let streamRequested = object["stream"] as? Bool ?? false
        object["model"] = modelID
        object["stream"] = streamRequested

        if let responseFormat = object.removeValue(forKey: "response_format") as? [String: Any] {
            if (responseFormat["type"] as? String) == "json_object" {
                object["format"] = "json"
            } else if let jsonSchema = responseFormat["json_schema"] as? [String: Any],
                      let schema = jsonSchema["schema"] {
                object["format"] = schema
            }
        }

        var options = object["options"] as? [String: Any] ?? [:]
        moveOpenAIOption("max_completion_tokens", to: "num_predict", from: &object, options: &options)
        moveOpenAIOption("max_tokens", to: "num_predict", from: &object, options: &options)
        moveOpenAIOption("temperature", to: "temperature", from: &object, options: &options)
        moveOpenAIOption("top_p", to: "top_p", from: &object, options: &options)
        if !options.isEmpty {
            object["options"] = options
        }

        if let reasoning = object.removeValue(forKey: "reasoning") as? [String: Any],
           let effort = reasoning["effort"] as? String {
            applyOllamaThinkValue(effort, to: &object)
        }
        if let effort = object.removeValue(forKey: "reasoning_effort") as? String {
            applyOllamaThinkValue(effort, to: &object)
        }

        for unsupportedKey in ["n", "user", "logit_bias", "presence_penalty", "frequency_penalty", "stream_options", "tool_choice"] {
            object.removeValue(forKey: unsupportedKey)
        }

        return (try JSONSerialization.data(withJSONObject: object, options: []), streamRequested)
    }

    private static func moveOpenAIOption(
        _ sourceKey: String,
        to targetKey: String,
        from object: inout [String: Any],
        options: inout [String: Any]
    ) {
        guard let value = object.removeValue(forKey: sourceKey) else { return }
        options[targetKey] = value
    }

    private static func applyOllamaThinkValue(_ rawEffort: String, to object: inout [String: Any]) {
        switch rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "medium", "low":
            object["think"] = rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case "none", "off", "false":
            object["think"] = false
        default:
            break
        }
    }

    private static func openAIProxyResponseFromOllama(
        requestBody: Data,
        responseBody: Data,
        modelID: String,
        streamRequested: Bool
    ) throws -> BurnBarProviderProxyResponse {
        if streamRequested {
            return try openAIStreamResponseFromOllama(
                requestBody: requestBody,
                responseBody: responseBody,
                modelID: modelID
            )
        }

        let decoded = try JSONDecoder().decode(OllamaNativeChatResponse.self, from: responseBody)
        let body = try openAICompletionBodyFromOllama(decoded, modelID: modelID)
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: body,
            usage: ollamaProxyUsage(requestBody: requestBody, response: decoded)
        )
    }

    private static func openAIStreamResponseFromOllama(
        requestBody: Data,
        responseBody: Data,
        modelID: String
    ) throws -> BurnBarProviderProxyResponse {
        let responseID = "chatcmpl-\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var sse = Data()
        var finalResponse: OllamaNativeChatResponse?

        let lines = String(decoding: responseBody, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        for line in lines {
            guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
            let decoded = try JSONDecoder().decode(OllamaNativeChatResponse.self, from: data)
            finalResponse = decoded

            let content = decoded.message?.content ?? ""
            if !content.isEmpty {
                try appendServerSentEvent(
                    chunk: openAIStreamChunk(
                        id: responseID,
                        created: created,
                        modelID: modelID,
                        content: content,
                        finishReason: nil
                    ),
                    to: &sse
                )
            }

            if decoded.done == true {
                try appendServerSentEvent(
                    chunk: openAIStreamChunk(
                        id: responseID,
                        created: created,
                        modelID: modelID,
                        content: nil,
                        finishReason: finishReason(from: decoded.doneReason)
                    ),
                    to: &sse
                )
            }
        }

        sse.append(Data("data: [DONE]\n\n".utf8))

        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            body: sse,
            usage: finalResponse.map { ollamaProxyUsage(requestBody: requestBody, response: $0) }
        )
    }

    private static func openAICompletionBodyFromOllama(
        _ response: OllamaNativeChatResponse,
        modelID: String
    ) throws -> Data {
        let content = response.message?.content ?? ""
        let body: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": response.model ?? modelID,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": response.message?.role ?? "assistant",
                        "content": content
                    ],
                    "finish_reason": finishReason(from: response.doneReason)
                ]
            ],
            "usage": openAIUsageFromOllama(response)
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private static func openAIUsageFromOllama(_ response: OllamaNativeChatResponse) -> [String: Any] {
        let promptTokens = max(response.promptEvalCount ?? 0, 0)
        let completionTokens = max(response.evalCount ?? 0, 0)
        return [
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "total_tokens": promptTokens + completionTokens
        ]
    }

    private static func openAIStreamChunk(
        id: String,
        created: Int,
        modelID: String,
        content: String?,
        finishReason: String?
    ) -> [String: Any] {
        var delta: [String: Any] = [:]
        if let content {
            delta["content"] = content
        }
        if finishReason == nil {
            delta["role"] = "assistant"
        }
        return [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": modelID,
            "choices": [
                [
                    "index": 0,
                    "delta": delta,
                    "finish_reason": finishReason.map { $0 as Any } ?? NSNull()
                ]
            ]
        ]
    }

    private static func appendServerSentEvent(chunk: [String: Any], to data: inout Data) throws {
        let payload = try JSONSerialization.data(withJSONObject: chunk, options: [])
        data.append(Data("data: ".utf8))
        data.append(payload)
        data.append(Data("\n\n".utf8))
    }

    private static func finishReason(from doneReason: String?) -> String {
        switch doneReason?.lowercased() {
        case "length":
            return "length"
        case "tool_calls":
            return "tool_calls"
        default:
            return "stop"
        }
    }

    private static func ollamaProxyUsage(
        requestBody: Data,
        response: OllamaNativeChatResponse
    ) -> BurnBarProviderProxyUsage {
        let outputText = response.message?.content ?? ""
        let inputHint = max(1, requestBody.count / 4)
        let outputHint = max(1, outputText.count / 4)
        let hasExplicitUsage = response.promptEvalCount != nil || response.evalCount != nil
        return BurnBarProviderProxyUsage(
            inputTokens: max(response.promptEvalCount ?? inputHint, 0),
            outputTokens: max(response.evalCount ?? outputHint, 0),
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            confidence: hasExplicitUsage ? .exact : .lowConfidenceEstimate
        )
    }

    private static func extractProxyUsage(
        requestBody: Data,
        responseBody: Data
    ) -> BurnBarProviderProxyUsage? {
        let inputHint = max(1, requestBody.count / 4)
        let decoded = try? JSONDecoder().decode(ProviderCompletionResponse.self, from: responseBody)
        let outputText = decoded?.choices.first?.message.content ?? ""
        let outputHint = max(1, outputText.count / 4)

        if let normalized = decoded?.usage?.normalized(inputHint: inputHint, outputHint: outputHint) {
            return BurnBarProviderProxyUsage(
                inputTokens: normalized.promptTokens,
                outputTokens: normalized.completionTokens,
                cacheCreationTokens: normalized.cacheCreationTokens,
                cacheReadTokens: normalized.cacheReadTokens,
                reasoningTokens: normalized.reasoningTokens,
                confidence: .exact
            )
        }

        guard decoded != nil else {
            return nil
        }

        return BurnBarProviderProxyUsage(
            inputTokens: inputHint,
            outputTokens: outputHint,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            confidence: .lowConfidenceEstimate
        )
    }

    private static func extractResponsesUsage(responseBody: Data) -> BurnBarProviderProxyUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return nil
        }

        let inputTokens = intValue(usage["input_tokens"])
            ?? intValue(usage["prompt_tokens"])
            ?? 0
        let outputTokens = intValue(usage["output_tokens"])
            ?? intValue(usage["completion_tokens"])
            ?? 0
        let reasoningTokens = intValue(usage["reasoning_tokens"]) ?? 0

        guard inputTokens > 0 || outputTokens > 0 || reasoningTokens > 0 else {
            return nil
        }

        return BurnBarProviderProxyUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: reasoningTokens,
            confidence: .exact
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

private enum BurnBarFakeProviderExecution {
    private struct Payload: Codable {
        var outputs: [String]
    }

    static func consumeNextResult(
        promptRequest: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) throws -> BurnBarProviderExecutionResult? {
        guard let filePath = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
              !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: filePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        var payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.outputs.isEmpty else {
            return BurnBarProviderExecutionResult(
                outputText: #"{"action":"fail","rationale":"No fake provider outputs remaining.","message":"No fake provider outputs remaining."}"#,
                inputTokens: max(1, promptRequest.userPrompt.count / 4),
                outputTokens: 16,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            )
        }

        let outputText = payload.outputs.removeFirst()
        try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)

        let inputPrompt = [promptRequest.systemPrompt, promptRequest.userPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return BurnBarProviderExecutionResult(
            outputText: outputText,
            inputTokens: max(1, inputPrompt.count / 4),
            outputTokens: max(1, outputText.count / 4),
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }
}

public actor BurnBarKeychainSecretStore: BurnBarProviderSecretStoring {
    public static let defaultService = "com.openburnbar.daemon.provider-secrets"
    public static let legacyCursorConnectorService = "com.openburnbar.cursor-connector"

    private let service: String
    private let legacyServices: [String]
    private let hermesCredentialPoolURL: URL?

    public init(
        service: String = BurnBarKeychainSecretStore.defaultService,
        legacyServices: [String]? = nil,
        hermesCredentialPoolURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/auth.json", isDirectory: false)
    ) {
        self.service = service
        self.legacyServices = legacyServices ?? (
            service == Self.defaultService ? [Self.legacyCursorConnectorService] : []
        )
        self.hermesCredentialPoolURL = hermesCredentialPoolURL
    }

    public func secret(for providerID: String) async throws -> String? {
        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "openburnbar-fake-provider-key-\(providerID)"
        }

        let account = "provider.\(providerID).apiKey"
        if let secret = try secret(forService: service, account: account) {
            return secret
        }
        for legacyService in legacyServices where legacyService != service {
            if let secret = try secret(forService: legacyService, account: account) {
                return secret
            }
        }
        return hermesCredentialPoolSecret(for: providerID)
    }

    private func secret(forService service: String, account: String) throws -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        // Daemon reads must never surface interactive keychain prompts.
        // LAContext.interactionNotAllowed handles this on macOS 11+.
        if #unavailable(macOS 11.0) {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
            || status == errSecAuthFailed {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = item as? Data else {
            return nil
        }
        let decoded = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded?.isEmpty == false ? decoded : nil
    }

    public func setSecret(_ secret: String?, for providerID: String) async throws {
        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let account = "provider.\(providerID).apiKey"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = Data(secret.utf8)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = withKeychainUserInteractionDisabled {
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
            if updateStatus == errSecItemNotFound {
                var createQuery = query
                createQuery[kSecValueData as String] = data
                createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let addStatus = withKeychainUserInteractionDisabled {
                    SecItemAdd(createQuery as CFDictionary, nil)
                }
                guard addStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
                }
            } else if updateStatus != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
            }
        } else {
            let deleteStatus = withKeychainUserInteractionDisabled {
                SecItemDelete(query as CFDictionary)
            }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }
        }
    }

    private func hermesCredentialPoolSecret(for providerID: String) -> String? {
        guard let hermesCredentialPoolURL else { return nil }
        let normalizedProviderID = providerID
            .components(separatedBy: ".slot.")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedProviderID, !normalizedProviderID.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: hermesCredentialPoolURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pool = root["credential_pool"] as? [String: Any],
              let entries = pool[normalizedProviderID] as? [[String: Any]] else {
            return nil
        }

        for entry in entries {
            let status = (entry["last_status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if status == "exhausted" || status == "disabled" {
                continue
            }
            guard let token = entry["access_token"] as? String else { continue }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

private struct ProviderCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
    }
}

private struct ProviderCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String

            private struct ContentPart: Decodable {
                let text: String?
                let type: String?
            }

            private enum CodingKeys: String, CodingKey {
                case content
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let stringContent = try? container.decode(String.self, forKey: .content) {
                    content = stringContent
                    return
                }
                if let contentParts = try? container.decode([ContentPart].self, forKey: .content) {
                    content = contentParts
                        .compactMap { part in
                            if let text = part.text, !text.isEmpty { return text }
                            return nil
                        }
                        .joined(separator: "\n")
                    return
                }
                content = ""
            }
        }

        let message: Message
    }

    struct UsageDetails: Decodable {
        let cached_tokens: Int?
        let cachedTokens: Int?
        let cache_read_tokens: Int?
        let cacheReadTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cached_tokens
            case cachedTokens
            case cache_read_tokens
            case cacheReadTokens
        }
    }

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_creation_tokens: Int?
        let promptTokens: Int?
        let completionTokens: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationTokens: Int?
        let total_tokens: Int?
        let totalTokens: Int?
        let cache_read_tokens: Int?
        let cache_read_input_tokens: Int?
        let cacheReadTokens: Int?
        let cached_tokens: Int?
        let cachedTokens: Int?
        let prompt_tokens_details: UsageDetails?
        let promptTokensDetails: UsageDetails?
        let thinking_tokens: Int?
        let reasoning_tokens: Int?
        let thinkingTokens: Int?
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case prompt_tokens
            case completion_tokens
            case input_tokens
            case output_tokens
            case cache_creation_input_tokens
            case cache_creation_tokens
            case promptTokens
            case completionTokens
            case inputTokens
            case outputTokens
            case cacheCreationTokens
            case total_tokens
            case totalTokens
            case cache_read_tokens
            case cache_read_input_tokens
            case cacheReadTokens
            case cached_tokens
            case cachedTokens
            case prompt_tokens_details
            case promptTokensDetails
            case thinking_tokens
            case reasoning_tokens
            case thinkingTokens
            case reasoningTokens
        }

        struct NormalizedUsage {
            let promptTokens: Int
            let completionTokens: Int
            let cacheCreationTokens: Int
            let cacheReadTokens: Int
            let reasoningTokens: Int
        }

        private func firstValue(_ values: Int?...) -> Int {
            for value in values {
                if let value {
                    return value
                }
            }
            return 0
        }

        func normalized(inputHint: Int, outputHint: Int) -> NormalizedUsage {
            var prompt = prompt_tokens
                ?? input_tokens
                ?? promptTokens
                ?? inputTokens
                ?? 0

            var completion = completion_tokens
                ?? output_tokens
                ?? completionTokens
                ?? outputTokens
                ?? 0

            let cacheRead = firstValue(
                cache_read_tokens,
                cache_read_input_tokens,
                cacheReadTokens,
                cached_tokens,
                cachedTokens,
                prompt_tokens_details?.cached_tokens,
                prompt_tokens_details?.cachedTokens,
                prompt_tokens_details?.cache_read_tokens,
                prompt_tokens_details?.cacheReadTokens,
                promptTokensDetails?.cached_tokens,
                promptTokensDetails?.cachedTokens,
                promptTokensDetails?.cache_read_tokens,
                promptTokensDetails?.cacheReadTokens
            )

            let cacheCreation = firstValue(
                cache_creation_input_tokens,
                cache_creation_tokens,
                cacheCreationTokens
            )

            let thinking = firstValue(
                thinking_tokens,
                reasoning_tokens,
                thinkingTokens,
                reasoningTokens
            )

            let total = total_tokens ?? totalTokens ?? 0
            let explicitTotal = prompt + completion + cacheCreation + cacheRead
            let normalizedTotal = max(total, explicitTotal)
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead, 0)

            if prompt == 0 && completion == 0 && availableForInOut > 0 {
                let safeInputHint = max(inputHint, 1)
                let safeOutputHint = max(outputHint, 1)
                let ratio = Double(safeInputHint) / Double(safeInputHint + safeOutputHint)
                prompt = Int((Double(availableForInOut) * ratio).rounded())
                completion = max(availableForInOut - prompt, 0)
            } else if prompt == 0 && completion > 0 && availableForInOut > completion {
                prompt = availableForInOut - completion
            } else if completion == 0 && prompt > 0 && availableForInOut > prompt {
                completion = availableForInOut - prompt
            } else if prompt + completion < availableForInOut {
                completion += availableForInOut - (prompt + completion)
            }

            if thinking > 0 && total == 0 {
                completion += thinking
            }

            return NormalizedUsage(
                promptTokens: max(prompt, 0),
                completionTokens: max(completion, 0),
                cacheCreationTokens: max(cacheCreation, 0),
                cacheReadTokens: max(cacheRead, 0),
                reasoningTokens: max(thinking, 0)
            )
        }
    }

    let choices: [Choice]
    let usage: Usage?
}

private struct OllamaNativeChatResponse: Decodable {
    struct Message: Decodable {
        let role: String?
        let content: String?
        let thinking: String?
    }

    let model: String?
    let createdAt: String?
    let message: Message?
    let done: Bool?
    let doneReason: String?
    let promptEvalCount: Int?
    let evalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message
        case done
        case doneReason = "done_reason"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}
