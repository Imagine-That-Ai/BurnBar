import OpenBurnBarEngine
import OpenBurnBarLinuxSecurity
import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

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
    public let headers: [String: String]
    public let body: Data
    public let usage: BurnBarProviderProxyUsage?

    public init(
        statusCode: Int,
        contentType: String,
        headers: [String: String] = [:],
        body: Data,
        usage: BurnBarProviderProxyUsage?
    ) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.headers = headers
        self.body = body
        self.usage = usage
    }
}

/// A live, chunk-by-chunk upstream response used for true streaming
/// passthrough. The gateway relays `chunks` to the client verbatim as they
/// arrive instead of buffering the whole body, which avoids client idle
/// timeouts (and the full-request retries they trigger) on long generations.
public struct BurnBarProviderProxyStream: Sendable {
    public let statusCode: Int
    public let contentType: String
    public let headers: [String: String]
    public let chunks: AsyncThrowingStream<Data, Error>

    public init(
        statusCode: Int,
        contentType: String,
        headers: [String: String] = [:],
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.headers = headers
        self.chunks = chunks
    }
}

/// Thrown by `open*Stream` helpers when an upstream cannot be streamed
/// verbatim (e.g. the Ollama native API, which only speaks its own
/// non-SSE chunk format). The gateway catches this and falls back to the
/// buffered path on the same route instead of failing the request.
public struct BurnBarProxyStreamingUnsupported: Error, Sendable {
    public let reason: String
    public init(reason: String) {
        self.reason = reason
    }
}

/// Shared streaming primitives: a long-lived `URLSession` tuned for SSE and
/// a helper that opens a line-framed byte stream from a `URLRequest`.
public enum BurnBarProxyStreaming {
    private static let logger = BurnBarDaemonLogger(category: "provider-stream")
    #if os(Linux)
    // swift-corelibs-foundation can fail to complete a data task after an
    // upstream RST. Bound post-response silence so the gateway always closes
    // the downstream client instead of holding a streamed request forever.
    private static let linuxStreamInactivityTimeoutNanoseconds: UInt64 = 15_000_000_000
    #endif

    /// Streaming responses can stay open far longer than a normal request,
    /// so this session relaxes the per-request and resource timeouts that
    /// `URLSession.shared` enforces. Without this, long Opus generations
    /// trip the default 60s request timeout mid-stream.
    public static let streamingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 86_400
        #if !os(Linux)
        configuration.waitsForConnectivity = true
        #endif
        configuration.httpShouldUsePipelining = false
        return URLSession(configuration: configuration)
    }()

    /// Open a line-framed byte stream for `request`. On a non-2xx response the
    /// error body is drained and surfaced as `upstreamError` *before* any
    /// bytes reach the client, so the caller can still fail over safely.
    public static func openByteStream(
        session: URLSession,
        request: URLRequest,
        defaultContentType: String
    ) async throws -> BurnBarProviderProxyStream {
        #if os(Linux)
        let delegate = LinuxURLSessionByteStreamDelegate(
            defaultContentType: defaultContentType,
            inactivityTimeoutNanoseconds: linuxStreamInactivityTimeoutNanoseconds
        )
        let stream = delegate.makeStream()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 86_400
        configuration.httpShouldUsePipelining = false
        let streamingSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = streamingSession.dataTask(with: request)
        delegate.setTerminationHandler {
            task.cancel()
            streamingSession.invalidateAndCancel()
        }
        task.resume()

        let response = try await delegate.awaitHTTPResponse()

        return BurnBarProviderProxyStream(
            statusCode: response.statusCode,
            contentType: response.contentType,
            chunks: stream
        )
        #else
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorData = Data()
            do {
                for try await byte in bytes {
                    errorData.append(byte)
                    if errorData.count > 64 * 1024 { break }
                }
            } catch {
                // Best-effort drain; fall through with whatever we captured.
                logger.silentFailure(
                    "BurnBarProxyStreaming.drainUpstreamErrorBody",
                    error: error,
                    context: [
                        "statusCode": "\(httpResponse.statusCode)",
                        "capturedBytes": "\(errorData.count)"
                    ]
                )
            }
            throw BurnBarProviderExecutorError.upstreamErrorWithHeaders(
                httpResponse.statusCode,
                String(data: errorData, encoding: .utf8) ?? "",
                BurnBarProxyStreaming.normalizedHeaders(from: httpResponse)
            )
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? defaultContentType
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var buffer = Data()
                buffer.reserveCapacity(4096)

                do {
                    // Preserve blank SSE separator lines; AsyncBytes.lines drops
                    // them, which prevents downstream event parsers from dispatching.
                    for try await byte in bytes {
                        if let chunk = appendBytePreservingStreamFraming(byte, to: &buffer) {
                            continuation.yield(chunk)
                        }
                    }

                    if let chunk = flushBytePreservingStreamFramingBuffer(&buffer) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return BurnBarProviderProxyStream(
            statusCode: httpResponse.statusCode,
            contentType: contentType,
            headers: normalizedHeaders(from: httpResponse),
            chunks: stream
        )
        #endif
    }

    static func normalizedHeaders(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [String: String]()) { result, element in
            guard let key = element.key as? String else { return }
            let value: String
            if let stringValue = element.value as? String {
                value = stringValue
            } else {
                value = "\(element.value)"
            }
            result[key] = value
        }
    }

    static func appendBytePreservingStreamFraming(_ byte: UInt8, to buffer: inout Data) -> Data? {
        buffer.append(byte)
        guard byte == 0x0A || buffer.count >= 4096 else { return nil }
        return flushBytePreservingStreamFramingBuffer(&buffer)
    }

    static func flushBytePreservingStreamFramingBuffer(_ buffer: inout Data) -> Data? {
        guard !buffer.isEmpty else { return nil }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: true)
        return chunk
    }
}

public struct BurnBarStructuredPromptRequest: Sendable {
    public let systemPrompt: String?
    public let userPrompt: String
    public let assistantContextBlocks: [String]
    public let jsonOnly: Bool
    /// When set, sent to the provider as `max_tokens` so the output ceiling a
    /// budget preflight priced is actually enforced at generation time.
    public let maxOutputTokens: Int?

    public init(
        systemPrompt: String? = nil,
        userPrompt: String,
        assistantContextBlocks: [String] = [],
        jsonOnly: Bool = false,
        maxOutputTokens: Int? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.assistantContextBlocks = assistantContextBlocks
        self.jsonOnly = jsonOnly
        self.maxOutputTokens = maxOutputTokens
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

public struct BurnBarOpenAICompatibleProviderExecutor: BurnBarProviderExecuting {
    private let session: URLSession
    private let codexExecutor: BurnBarCodexProviderExecutor

    public init(
        session: URLSession = .shared,
        codexExecutor: BurnBarCodexProviderExecutor = BurnBarCodexProviderExecutor()
    ) {
        self.session = session
        self.codexExecutor = codexExecutor
    }

    static func isCodexRoute(_ route: BurnBarProviderRoute) -> Bool {
        route.providerID.caseInsensitiveCompare("codex") == .orderedSame
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

        if Self.isCodexRoute(route) {
            return try await codexExecutor.completeStructured(promptRequest, route: route)
        }

        let baseURL = try BurnBarProviderExecutorError.validatedProviderBaseURL(route.baseURL)

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
                responseFormat: promptRequest.jsonOnly ? .init(type: "json_object") : nil,
                maxTokens: promptRequest.maxOutputTokens
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
            throw BurnBarProviderExecutorError.upstreamErrorWithHeaders(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? "",
                BurnBarProxyStreaming.normalizedHeaders(from: httpResponse)
            )
        }

        return try Self.executionResult(
            fromOpenAICompletionBody: data,
            promptRequest: promptRequest
        )
    }

    static func executionResult(
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
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        if Self.isCodexRoute(route) {
            return try await codexExecutor.proxyChatCompletions(body: body, route: route, variant: variant)
        }

        let baseURL = try BurnBarProviderExecutorError.validatedProviderBaseURL(route.baseURL)

        if Self.shouldUseOllamaNativeAPI(route: route, baseURL: baseURL) {
            return try await proxyOllamaNativeChatCompletions(
                body: body,
                route: route,
                baseURL: baseURL,
                variant: variant
            )
        }

        let outboundBody = try Self.rewritingChatCompletionsBody(
            in: body,
            to: route.resolvedModelID,
            variant: variant,
            providerID: route.providerID
        )
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
            throw BurnBarProviderExecutorError.upstreamErrorWithHeaders(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? "",
                BurnBarProxyStreaming.normalizedHeaders(from: httpResponse)
            )
        }
        try Self.validateOpenAICompatibleChatResponse(data, modelID: route.resolvedModelID)

        return BurnBarProviderProxyResponse(
            statusCode: httpResponse.statusCode,
            contentType: contentType,
            headers: BurnBarProxyStreaming.normalizedHeaders(from: httpResponse),
            body: data,
            usage: Self.extractProxyUsage(requestBody: outboundBody, responseBody: data)
        )
    }

    /// Open a true streaming Chat Completions request for verbatim SSE
    /// passthrough. Forces `stream: true` and `stream_options.include_usage`
    /// so the final chunk carries token usage for accounting. Throws
    /// `BurnBarProxyStreamingUnsupported` for the Ollama native API, which
    /// does not speak OpenAI-style SSE.
    public func openChatCompletionsStream(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyStream {
        if Self.isCodexRoute(route) {
            // The local `codex` CLI produces a one-shot transcript, not live
            // OpenAI SSE. Signal unsupported so the gateway falls back to the
            // buffered `proxyChatCompletions` path on the same route.
            throw BurnBarProxyStreamingUnsupported(reason: "codex-cli")
        }

        let baseURL = try BurnBarProviderExecutorError.validatedProviderBaseURL(route.baseURL)

        if Self.shouldUseOllamaNativeAPI(route: route, baseURL: baseURL) {
            throw BurnBarProxyStreamingUnsupported(reason: "ollama-native-api")
        }

        let outboundBody = try Self.rewritingChatCompletionsBody(
            in: body,
            to: route.resolvedModelID,
            variant: variant,
            effortOnly: true,
            enableStreamUsage: true,
            providerID: route.providerID
        )
        let endpoint = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = outboundBody

        return try await BurnBarProxyStreaming.openByteStream(
            session: BurnBarProxyStreaming.streamingSession,
            request: request,
            defaultContentType: "text/event-stream"
        )
    }

    public func proxyResponses(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        if Self.isCodexRoute(route) {
            return try await codexExecutor.proxyResponses(body: body, route: route, variant: variant)
        }

        let baseURL = try BurnBarProviderExecutorError.validatedProviderBaseURL(route.baseURL)

        if Self.shouldUseOllamaNativeAPI(route: route, baseURL: baseURL) {
            return try await proxyResponsesViaChatCompletions(body: body, route: route, variant: variant)
        }

        let outboundBody = try Self.rewritingModel(in: body, to: route.resolvedModelID, variant: variant)
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
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                return try await proxyResponsesViaChatCompletions(body: body, route: route, variant: variant)
            }
            throw BurnBarProviderExecutorError.upstreamErrorWithHeaders(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? "",
                BurnBarProxyStreaming.normalizedHeaders(from: httpResponse)
            )
        }

        return BurnBarProviderProxyResponse(
            statusCode: httpResponse.statusCode,
            contentType: contentType,
            headers: BurnBarProxyStreaming.normalizedHeaders(from: httpResponse),
            body: data,
            usage: Self.extractResponsesUsage(responseBody: data)
        )
    }

    func proxyResponsesViaChatCompletions(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let (chatBody, streamRequested) = try Self.chatCompletionsBodyFromResponsesRequest(
            body,
            modelID: route.resolvedModelID
        )
        let chatResponse = try await proxyChatCompletions(body: chatBody, route: route, variant: variant)

        if streamRequested || chatResponse.contentType.lowercased().contains("text/event-stream") {
            return try Self.responsesStreamFromChatCompletionStream(
                chatResponse,
                modelID: route.resolvedModelID
            )
        }

        let body = try Self.responsesBodyFromChatCompletion(
            chatResponse.body,
            modelID: route.resolvedModelID
        )
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            headers: chatResponse.headers,
            body: body,
            usage: chatResponse.usage
        )
    }

    func proxyOllamaNativeChatCompletions(
        body: Data,
        route: BurnBarProviderRoute,
        baseURL: URL,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let stagedBody: Data
        if variant != nil {
            stagedBody = try Self.rewritingChatCompletionsBody(
                in: body,
                to: route.resolvedModelID,
                variant: variant,
                providerID: route.providerID
            )
        } else {
            stagedBody = body
        }
        let (outboundBody, streamRequested) = try Self.ollamaNativeRequestBody(
            from: stagedBody,
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
            throw BurnBarProviderExecutorError.upstreamErrorWithHeaders(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? "",
                BurnBarProxyStreaming.normalizedHeaders(from: httpResponse)
            )
        }

        return try Self.openAIProxyResponseFromOllama(
            requestBody: outboundBody,
            responseBody: data,
            modelID: route.resolvedModelID,
            streamRequested: streamRequested,
            headers: BurnBarProxyStreaming.normalizedHeaders(from: httpResponse)
        )
    }

    /// OpenRouter honors a per-request data-collection preference; Memory Pro
    /// treats OpenRouter as a no-retention provider only because every request
    /// carries it.
    static func applyProviderPrivacyPreferences(to object: inout [String: Any], providerID: String?) {
        guard providerID?.lowercased() == "openrouter" else { return }
        var provider = (object["provider"] as? [String: Any]) ?? [:]
        provider["data_collection"] = "deny"
        object["provider"] = provider
    }

    /// `POST {baseURL}/embeddings` (OpenAI shape). Buffered only.
    public func proxyEmbeddings(body: Data, route: BurnBarProviderRoute) async throws -> BurnBarProviderProxyResponse {
        let baseURL = try BurnBarProviderExecutorError.validatedProviderBaseURL(route.baseURL)
        let json = try JSONSerialization.jsonObject(with: body)
        guard var object = json as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        object["model"] = route.resolvedModelID
        Self.applyProviderPrivacyPreferences(to: &object, providerID: route.providerID)
        let outboundBody = try JSONSerialization.data(withJSONObject: object, options: [])
        var request = URLRequest(url: baseURL.appending(path: "embeddings"))
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
            throw BurnBarProviderExecutorError.upstreamErrorWithHeaders(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? "",
                BurnBarProxyStreaming.normalizedHeaders(from: httpResponse)
            )
        }
        return BurnBarProviderProxyResponse(
            statusCode: httpResponse.statusCode,
            contentType: contentType,
            headers: BurnBarProxyStreaming.normalizedHeaders(from: httpResponse),
            body: data,
            usage: Self.extractEmbeddingsUsage(requestBody: outboundBody, responseBody: data)
        )
    }

    static func extractEmbeddingsUsage(requestBody: Data, responseBody: Data) -> BurnBarProviderProxyUsage? {
        struct Usage: Decodable {
            let promptTokens: Int?
            let totalTokens: Int?
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case totalTokens = "total_tokens"
            }
        }
        struct Envelope: Decodable {
            let usage: Usage?
        }
        let decoded = try? JSONDecoder().decode(Envelope.self, from: responseBody)
        if let inputTokens = decoded?.usage?.promptTokens ?? decoded?.usage?.totalTokens {
            return BurnBarProviderProxyUsage(inputTokens: inputTokens, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0, confidence: .exact)
        }
        guard decoded != nil else { return nil }
        return BurnBarProviderProxyUsage(inputTokens: max(1, requestBody.count / 4), outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0, confidence: .lowConfidenceEstimate)
    }

    static func rewritingModel(
        in body: Data,
        to modelID: String,
        variant: BurnBarModelVariant? = nil
    ) throws -> Data {
        let json = try JSONSerialization.jsonObject(with: body)
        guard var object = json as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        object["model"] = modelID
        if let variant {
            // Live proxy forwarding: inject reasoning effort without raising
            // the caller's token ceiling (see A3 — variant inflation fix).
            applyOpenAIVariant(variant, to: &object, isResponsesShape: true, effortOnly: true)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func rewritingChatCompletionsBody(
        in body: Data,
        to modelID: String,
        variant: BurnBarModelVariant? = nil,
        effortOnly: Bool = true,
        enableStreamUsage: Bool = false,
        providerID: String? = nil
    ) throws -> Data {
        let json = try JSONSerialization.jsonObject(with: body)
        guard var object = json as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        object["model"] = modelID
        Self.applyProviderPrivacyPreferences(to: &object, providerID: providerID)
        normalizeOpenAICompatibleMessages(in: &object)
        if let variant {
            applyOpenAIVariant(variant, to: &object, isResponsesShape: false, effortOnly: effortOnly)
        }
        if enableStreamUsage {
            object["stream"] = true
            var streamOptions = (object["stream_options"] as? [String: Any]) ?? [:]
            streamOptions["include_usage"] = true
            object["stream_options"] = streamOptions
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// Variant-always-wins injection of `reasoning_effort` / `reasoning.effort`
    /// (and `max_output_tokens` / `max_completion_tokens` when the variant
    /// supplies one) into an OpenAI-shape request body. Caller-supplied values
    /// for these fields are deliberately overwritten — the whole point of
    /// picking `gpt-5-3-codex-xhigh` is to lock in xhigh regardless of what
    /// the CLI default would otherwise send.
    static func applyOpenAIVariant(
        _ variant: BurnBarModelVariant,
        to object: inout [String: Any],
        isResponsesShape: Bool,
        effortOnly: Bool = false
    ) {
        let effort = variant.thinkingLevel.openAIEffort
        if isResponsesShape {
            var reasoning = (object["reasoning"] as? [String: Any]) ?? [:]
            reasoning["effort"] = effort
            object["reasoning"] = reasoning
            if let maxOutputTokens = variant.maxOutputTokens {
                if effortOnly {
                    // Treat the variant max as a ceiling: never raise the
                    // caller's existing budget; only clamp it downward.
                    let callerMax = intValue(object["max_output_tokens"])
                    if let clamped = Self.clampedMaxTokens(variantMax: maxOutputTokens, callerMax: callerMax) {
                        object["max_output_tokens"] = clamped
                    }
                } else {
                    object["max_output_tokens"] = maxOutputTokens
                    object.removeValue(forKey: "max_completion_tokens")
                    object.removeValue(forKey: "max_tokens")
                }
            }
        } else {
            object["reasoning_effort"] = effort
            var reasoning = (object["reasoning"] as? [String: Any]) ?? [:]
            reasoning["effort"] = effort
            object["reasoning"] = reasoning
            if let maxOutputTokens = variant.maxOutputTokens {
                if effortOnly {
                    let callerMax = intValue(object["max_completion_tokens"]) ?? intValue(object["max_tokens"])
                    if let clamped = Self.clampedMaxTokens(variantMax: maxOutputTokens, callerMax: callerMax) {
                        if object["max_completion_tokens"] != nil {
                            object["max_completion_tokens"] = clamped
                        }
                        if object["max_tokens"] != nil {
                            object["max_tokens"] = clamped
                        }
                    }
                } else {
                    object["max_completion_tokens"] = maxOutputTokens
                    object["max_tokens"] = maxOutputTokens
                }
            }
        }
    }

    /// In effort-only mode the variant's `maxOutputTokens` acts as a ceiling,
    /// never a raise: when the caller already set a smaller budget we keep it,
    /// when the caller set a larger one we clamp down to the variant, and when
    /// the caller set nothing we leave the field unset (returning `nil`) so we
    /// never inflate a request that had no explicit limit.
    static func clampedMaxTokens(variantMax: Int, callerMax: Int?) -> Int? {
        guard let callerMax, callerMax > 0 else { return nil }
        return min(callerMax, variantMax)
    }

    static func normalizeOpenAICompatibleMessages(in object: inout [String: Any]) {
        guard let messages = object["messages"] as? [[String: Any]] else { return }
        object["messages"] = messages.map { message in
            var normalized = message
            if normalized["content"] is NSNull {
                normalized["content"] = ""
            } else if let content = normalized["content"],
                      !(content is String) {
                normalized["content"] = chatCompletionsContent(from: content)
                    ?? responsesContentText(content)
            }
            return normalized
        }
    }

    static func extractProxyUsage(
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

    static func validateOpenAICompatibleChatResponse(
        _ data: Data,
        modelID: String
    ) throws {
        guard let response = try? JSONDecoder().decode(ProviderCompletionResponse.self, from: data),
              let firstChoice = response.choices.first else {
            return
        }

        let content = firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty else { return }

        let finishReason = firstChoice.finishReason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard finishReason == "length" || finishReason == "max_tokens" else {
            return
        }

        let reasoningContent = firstChoice.message.reasoningContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if reasoningContent.isEmpty {
            detail = "Upstream returned no assistant text for \(modelID) because it hit the output token limit before producing final content. Increase max_tokens/max_output_tokens or choose a non-reasoning model."
        } else {
            detail = "Upstream returned reasoning-only output for \(modelID) and hit the output token limit before final assistant text. Increase max_tokens/max_output_tokens or choose a non-reasoning model."
        }

        throw BurnBarProviderExecutorError.upstreamError(
            502,
            Self.openAICompatibleErrorBody(message: detail, code: "empty_assistant_content")
        )
    }

    static func openAICompatibleErrorBody(message: String, code: String) -> String {
        let body: [String: Any] = [
            "error": [
                "message": message,
                "type": "upstream_invalid_response",
                "code": code
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"error":{"message":"Upstream returned an invalid response.","type":"upstream_invalid_response","code":"invalid_upstream_response"}}"#
        }
        return string
    }

    static func intValue(_ value: Any?) -> Int? {
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
    /// All Keychain services the app has used to store provider API keys.
    /// The daemon checks every one so credentials entered through any app
    /// version or code path are resolvable.
    public static let allLegacyServices: [String] = [
        "com.openburnbar.cursor-connector",
        "com.burnbar.cursor-connector",
        "com.agentlens.cursor-connector",
        "com.openburnbar.provider-api-keys",
        "com.burnbar.provider-api-keys"
    ]
    private static let logger = BurnBarDaemonLogger(category: "provider-secret-store")

    private let service: String
    private let legacyServices: [String]
    private let hermesCredentialPoolURL: URL?
    private let claudeCodeCredentialsURL: URL?
    private let claudeOAuthRefreshSession: URLSession
    private let linuxSecretCustodian: LinuxSecretCustodian

    public init(
        service: String = BurnBarKeychainSecretStore.defaultService,
        legacyServices: [String]? = nil,
        hermesCredentialPoolURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/auth.json", isDirectory: false),
        claudeCodeCredentialsURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json", isDirectory: false),
        fallbackSecretFileURL: URL? = BurnBarDaemonPaths.defaultProviderSecretContinuityURL,
        claudeOAuthRefreshSession: URLSession = .shared,
        linuxSecretCustodian: LinuxSecretCustodian = LinuxSecretStoreFactory.production()
    ) {
        self.service = service
        self.legacyServices = legacyServices ?? (
            service == Self.defaultService ? Self.allLegacyServices : []
        )
        self.hermesCredentialPoolURL = hermesCredentialPoolURL
        self.claudeCodeCredentialsURL = claudeCodeCredentialsURL
        self.claudeOAuthRefreshSession = claudeOAuthRefreshSession
        self.linuxSecretCustodian = linuxSecretCustodian
        if let fallbackSecretFileURL {
            // Legacy continuity vaults were plaintext JSON. They are no longer
            // trusted as a credential source; best-effort scrub stale copies.
            try? FileManager.default.removeItem(at: fallbackSecretFileURL)
        }
    }

    public func secret(for providerID: String) async throws -> String? {
        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "openburnbar-fake-provider-key-\(providerID)"
        }

        if Self.isCurrentClaudeCodeCredentialSlot(providerID),
           let ccToken = try await claudeCodeCredentialSecret(
            for: providerID,
            expectedOrganizationUuid: nil,
            enforceOrganizationMatch: false
           ) {
            return ccToken
        }

        let account = "provider.\(providerID).apiKey"
        var storedAnthropicCredentialRefreshFailed = false
        var failedAnthropicOrganizationUuid: String?
        var foundStoredSecret = false
        if let secret = try secret(forService: service, account: account) {
            foundStoredSecret = true
            if let routed = try await routeSecret(from: secret, providerID: providerID) {
                return routed
            }
            storedAnthropicCredentialRefreshFailed = Self.isExpiredClaudeOAuthSecret(secret, providerID: providerID)
            failedAnthropicOrganizationUuid = Self.organizationUuid(fromClaudeOAuthSecret: secret, providerID: providerID)
            // routeSecret returned nil: the stored OAuth token is expired and
            // refresh failed. Fall through to alternative credential sources
            // instead of returning an unusable expired token that would cause
            // a 401 on the live model refresh and block all models for this
            // provider until the next catalog rebuild.
        }
        for legacyService in legacyServices where legacyService != service {
            if let secret = try secret(forService: legacyService, account: account) {
                foundStoredSecret = true
                if let routed = try await routeSecret(from: secret, providerID: providerID) {
                    // Self-heal: promote the credential to the daemon's primary
                    // service so subsequent reads don't depend on the legacy
                    // service being readable. Best-effort — the routed secret is
                    // still returned even if promotion fails.
                    if !Self.isExpiredClaudeOAuthSecret(secret, providerID: providerID) {
                        try? await setSecret(secret, for: providerID)
                    }
                    return routed
                }
                storedAnthropicCredentialRefreshFailed = storedAnthropicCredentialRefreshFailed
                    || Self.isExpiredClaudeOAuthSecret(secret, providerID: providerID)
                if failedAnthropicOrganizationUuid == nil {
                    failedAnthropicOrganizationUuid = Self.organizationUuid(fromClaudeOAuthSecret: secret, providerID: providerID)
                }
            }
        }
        // Try Claude Code's own credential file or Keychain item as a fallback.
        // Claude Code maintains its own OAuth session with a separate refresh
        // token that may still be valid when the daemon's stored refresh token
        // has been revoked or expired, or when the daemon cannot read its own
        // provider Keychain entry (for example after a manual import).
        if Self.normalizedProviderID(providerID) == "anthropic",
           storedAnthropicCredentialRefreshFailed || !foundStoredSecret,
           let ccToken = try await claudeCodeCredentialSecret(
            for: providerID,
            expectedOrganizationUuid: failedAnthropicOrganizationUuid,
            enforceOrganizationMatch: storedAnthropicCredentialRefreshFailed
           ) {
            return ccToken
        }
        return hermesCredentialPoolSecret(for: providerID)
    }

    private func routeSecret(from storedSecret: String, providerID: String) async throws -> String? {
        let trimmed = storedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard Self.normalizedProviderID(providerID) == "anthropic",
              var claudeCredential = BurnBarClaudeOAuthRouteCredential.decode(trimmed) else {
            return trimmed
        }

        if claudeCredential.isExpired() {
            if let refreshed = await refreshClaudeOAuthCredential(claudeCredential) {
                claudeCredential = refreshed
                try await setSecret(refreshed.encodedStorageSecret(), for: providerID)
            } else {
                // Refresh failed: return nil so callers can fall back to
                // alternative credential sources (Claude Code credentials,
                // Hermes pool, other credential slots). Returning the expired
                // access token would cause a 401 on the live model refresh,
                // which sets blocksRouting=true and blocks ALL models for this
                // provider until the next catalog rebuild.
                return nil
            }
        }

        return claudeCredential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedProviderID(_ providerID: String) -> String {
        providerID
            .components(separatedBy: ".slot.")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isCurrentClaudeCodeCredentialSlot(_ providerID: String) -> Bool {
        providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "anthropic.slot.current-claude-code-login"
    }

    private static func isExpiredClaudeOAuthSecret(_ storedSecret: String, providerID: String) -> Bool {
        guard normalizedProviderID(providerID) == "anthropic",
              let credential = BurnBarClaudeOAuthRouteCredential.decode(storedSecret) else {
            return false
        }
        return credential.isExpired()
    }

    private static func organizationUuid(fromClaudeOAuthSecret storedSecret: String, providerID: String) -> String? {
        guard normalizedProviderID(providerID) == "anthropic" else { return nil }
        return BurnBarClaudeOAuthRouteCredential.decode(storedSecret)?.organizationUuid
    }

    private func refreshClaudeOAuthCredential(
        _ credential: BurnBarClaudeOAuthRouteCredential
    ) async -> BurnBarClaudeOAuthRouteCredential? {
        guard let refreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty,
              let url = URL(string: "https://platform.claude.com/v1/oauth/token") else {
            return nil
        }

        let formAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
        }

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(encode(refreshToken))",
            "client_id=\(encode(BurnBarClaudeOAuthRouteCredential.clientID))"
        ].joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Claude-Code/2.1 (OpenBurnBar route refresh)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await claudeOAuthRefreshSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = (json["access_token"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !newAccessToken.isEmpty else {
                return nil
            }
            let newRefreshToken = (json["refresh_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? refreshToken
            let expiresValue = json["expires_in"]
            let expiresIn: Double
            if let seconds = expiresValue as? Double {
                expiresIn = seconds
            } else if let seconds = expiresValue as? Int {
                expiresIn = Double(seconds)
            } else {
                expiresIn = 8 * 60 * 60
            }
            return credential.refreshed(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken,
                expiresAt: Date().addingTimeInterval(expiresIn)
            )
        } catch {
            return nil
        }
    }

    private func secret(forService service: String, account: String) throws -> String? {
#if canImport(Security) && canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext as String: context
        ]
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
#elseif os(Linux)
        do {
            return try linuxSecretCustodian.requireHighValueSecret(
                id: "\(service):\(account)",
                secretClass: .providerCredential
            ).secret
        } catch LinuxSecretStoreError.missingSecret(_) {
            return nil
        }
#else
        return nil
#endif
    }

    public func setSecret(_ secret: String?, for providerID: String) async throws {
        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

#if canImport(Security) && canImport(LocalAuthentication)
        let account = "provider.\(providerID).apiKey"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = Data(secret.utf8)
            let deleteStatus = withKeychainUserInteractionDisabled {
                SecItemDelete(query as CFDictionary)
            }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }

            var createQuery = query
            createQuery[kSecValueData as String] = data
            createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = withKeychainUserInteractionDisabled {
                SecItemAdd(createQuery as CFDictionary, nil)
            }
            if addStatus == errSecDuplicateItem {
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                ]
                let updateStatus = withKeychainUserInteractionDisabled {
                    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                }
                guard updateStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
                }
            } else if addStatus != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else {
            let deleteStatus = withKeychainUserInteractionDisabled {
                SecItemDelete(query as CFDictionary)
            }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }
        }
#elseif os(Linux)
        let account = "provider.\(providerID).apiKey"
        let id = "\(service):\(account)"
        if let normalized = secret?.trimmingCharacters(in: .whitespacesAndNewlines),
           normalized.isEmpty == false {
            _ = try linuxSecretCustodian.storeHighValueSecret(
                normalized,
                id: id,
                secretClass: .providerCredential
            )
        } else {
            try linuxSecretCustodian.deleteHighValueSecret(
                id: id,
                secretClass: .providerCredential
            )
        }
#else
        throw NSError(
            domain: "BurnBarProviderKeychainSecretStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Provider keychain secrets are unavailable on this platform."]
        )
#endif
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

    /// Read the Claude Code credential file (`~/.claude/.credentials.json`)
    /// as a fallback when the daemon's own Keychain credential is expired and
    /// refresh failed. Claude Code maintains its own OAuth session; the daemon
    /// only consumes a still-valid access token and never refreshes or rewrites
    /// Claude Code's file.
    ///
    /// The fallback is intentionally read-only: copying Claude Code's refresh
    /// token into BurnBar's Keychain would let two processes rotate the same
    /// OAuth session independently.
    private func claudeCodeCredentialSecret(
        for providerID: String,
        expectedOrganizationUuid: String?,
        enforceOrganizationMatch: Bool
    ) async throws -> String? {
        guard Self.normalizedProviderID(providerID) == "anthropic" else {
            return nil
        }

        let credentialSources = claudeCodeCredentialPayloads()
        for raw in credentialSources {
            guard let credential = BurnBarClaudeOAuthRouteCredential.decode(raw) else {
                continue
            }
            // When a daemon credential failed we may only borrow a Claude Code credential
            // from the same organization. The match is nil-aware: a daemon credential with
            // no organization may only borrow a Claude Code credential that also has none
            // (so org-scoped CC credentials are never used for an org-less daemon slot).
            // When there is no daemon credential to match against, any valid CC credential
            // is acceptable.
            if enforceOrganizationMatch || expectedOrganizationUuid != nil {
                guard credential.organizationUuid == expectedOrganizationUuid else {
                    continue
                }
            }
            guard !credential.isExpired() else {
                continue
            }
            let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private func claudeCodeCredentialPayloads() -> [String] {
        var payloads: [String] = []

        if let claudeCodeCredentialsURL,
           FileManager.default.fileExists(atPath: claudeCodeCredentialsURL.path),
           let data = try? Data(contentsOf: claudeCodeCredentialsURL),
           let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            payloads.append(raw)
        }

        let username = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        // Tests set this so the developer's real "Claude Code-credentials" Keychain item
        // never leaks into fixtures (CI runners have no such item; dev machines do).
        if ProcessInfo.processInfo.environment["BURNBAR_DISABLE_CLAUDE_CODE_KEYCHAIN_FALLBACK"] != "1" {
            for service in [Self.claudeCodeKeychainService] {
                if let raw = Self.readKeychainPassword(service: service, account: username)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    payloads.append(raw)
                }
            }
        }

        return payloads
    }

    private static let claudeCodeKeychainService = "Claude Code-credentials"

    private static func readKeychainPassword(service: String, account: String) -> String? {
        #if os(macOS)
        let securityURL = URL(fileURLWithPath: "/usr/bin/security")
        guard FileManager.default.isExecutableFile(atPath: securityURL.path) else { return nil }

        let process = Process()
        process.executableURL = securityURL
        process.arguments = [
            "find-generic-password",
            "-w",
            "-s", service,
            "-a", account
        ]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        defer {
            try? outputPipe.fileHandleForReading.close()
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + 2) == .success else {
            if process.isRunning {
                process.terminate()
            }
            try? outputPipe.fileHandleForReading.close()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    /// Proactively refresh Anthropic OAuth credentials that will expire within
    /// `refreshWindow` seconds. Called by the daemon's background refresh timer
    /// to prevent tokens from expiring between user requests.
    ///
    /// For each Anthropic credential slot, reads the stored OAuth credential,
    /// checks if it expires within the window, and refreshes it if so. On
    /// successful refresh, the Keychain is updated. On refresh failure, the
    /// next `secret(for:)` call may use a still-valid canonical Claude Code
    /// credential fallback.
    public func proactivelyRefreshExpiringOAuthCredentials(
        for slotKeys: [String],
        refreshWindow: TimeInterval = 3600
    ) async {
        for slotKey in slotKeys {
            guard Self.normalizedProviderID(slotKey) == "anthropic" else { continue }
            let account = "provider.\(slotKey).apiKey"
            guard let secret = try? secret(forService: service, account: account) else { continue }
            guard let credential = BurnBarClaudeOAuthRouteCredential.decode(secret) else { continue }
            guard let expiresAtMs = credential.expiresAtMilliseconds else { continue }
            let expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
            guard expiresAt <= Date().addingTimeInterval(refreshWindow) else { continue }
            // Token expires within the window, refresh it now.
            if let refreshed = await refreshClaudeOAuthCredential(credential) {
                do {
                    try await setSecret(refreshed.encodedStorageSecret(), for: slotKey)
                } catch {
                    Self.logger.error("provider_oauth_proactive_refresh_store_failed", metadata: [
                        "provider": slotKey,
                        "error": String(describing: error)
                    ])
                }
            }
            // If refresh failed, the next secret(for:) call will fall through
            // to the Claude Code credential fallback automatically.
        }
    }
}

private struct BurnBarClaudeOAuthRouteCredential {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    var accessToken: String
    var refreshToken: String?
    var expiresAtMilliseconds: Double?
    var scopes: [String]
    var subscriptionType: String?
    var rateLimitTier: String?
    var organizationUuid: String?

    static func decode(_ storageSecret: String) -> BurnBarClaudeOAuthRouteCredential? {
        guard let data = storageSecret.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let accessToken = (oauth["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }

        return BurnBarClaudeOAuthRouteCredential(
            accessToken: accessToken,
            refreshToken: (oauth["refreshToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            expiresAtMilliseconds: Self.expiresAtMilliseconds(oauth["expiresAt"]),
            scopes: oauth["scopes"] as? [String] ?? [],
            subscriptionType: (oauth["subscriptionType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            rateLimitTier: (oauth["rateLimitTier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            organizationUuid: ((root["organizationUuid"] as? String) ?? (oauth["organizationUuid"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        )
    }

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        let expiresAt = Date(timeIntervalSince1970: expiresAtMilliseconds / 1000)
        return expiresAt <= now.addingTimeInterval(60)
    }

    func refreshed(accessToken: String, refreshToken: String, expiresAt: Date) -> Self {
        BurnBarClaudeOAuthRouteCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMilliseconds: expiresAt.timeIntervalSince1970 * 1000,
            scopes: scopes,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            organizationUuid: organizationUuid
        )
    }

    func encodedStorageSecret() -> String {
        var oauth: [String: Any] = [
            "accessToken": accessToken
        ]
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAtMilliseconds { oauth["expiresAt"] = expiresAtMilliseconds }
        if !scopes.isEmpty { oauth["scopes"] = scopes }
        if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
        if let rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }

        var root: [String: Any] = ["claudeAiOauth": oauth]
        if let organizationUuid { root["organizationUuid"] = organizationUuid }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return accessToken
        }
        return string
    }

    private static func expiresAtMilliseconds(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
    /// Provider-enforced output ceiling. Optional so existing callers keep the
    /// provider default; per-reply budgeted calls (AI Inbox dialogue) pass the
    /// same figure their preflight cost estimate priced, closing the gap
    /// between "estimated" and "enforceable" spend.
    let maxTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
    }
}

struct ProviderCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
            let reasoningContent: String

            private struct ContentPart: Decodable {
                let text: String?
                let type: String?
            }

            private enum CodingKeys: String, CodingKey {
                case content
                case reasoning_content
                case reasoningContent
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                reasoningContent = (try? container.decode(String.self, forKey: .reasoning_content))
                    ?? (try? container.decode(String.self, forKey: .reasoningContent))
                    ?? ""
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
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finish_reason
            case finishReason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decode(Message.self, forKey: .message)
            finishReason = (try? container.decode(String.self, forKey: .finish_reason))
                ?? (try? container.decode(String.self, forKey: .finishReason))
        }
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
        let input_cached_tokens: Int?
        let inputCachedTokens: Int?
        let cached_input_tokens: Int?
        let cachedInputTokens: Int?
        let prompt_tokens_details: UsageDetails?
        let promptTokensDetails: UsageDetails?
        let input_tokens_details: UsageDetails?
        let inputTokensDetails: UsageDetails?
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
            case input_cached_tokens
            case inputCachedTokens
            case cached_input_tokens
            case cachedInputTokens
            case prompt_tokens_details
            case promptTokensDetails
            case input_tokens_details
            case inputTokensDetails
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

            let exclusiveCacheRead = firstValue(
                cache_read_tokens,
                cache_read_input_tokens,
                cacheReadTokens
            )
            let inclusiveCacheRead = firstValue(
                input_cached_tokens,
                inputCachedTokens,
                cached_input_tokens,
                cachedInputTokens,
                cached_tokens,
                cachedTokens,
                prompt_tokens_details?.cached_tokens,
                prompt_tokens_details?.cachedTokens,
                prompt_tokens_details?.cache_read_tokens,
                prompt_tokens_details?.cacheReadTokens,
                input_tokens_details?.cached_tokens,
                input_tokens_details?.cachedTokens,
                input_tokens_details?.cache_read_tokens,
                input_tokens_details?.cacheReadTokens,
                promptTokensDetails?.cached_tokens,
                promptTokensDetails?.cachedTokens,
                promptTokensDetails?.cache_read_tokens,
                promptTokensDetails?.cacheReadTokens,
                inputTokensDetails?.cached_tokens,
                inputTokensDetails?.cachedTokens,
                inputTokensDetails?.cache_read_tokens,
                inputTokensDetails?.cacheReadTokens
            )
            let cacheRead = exclusiveCacheRead > 0 ? exclusiveCacheRead : inclusiveCacheRead
            if inclusiveCacheRead > 0 && exclusiveCacheRead == 0 {
                prompt = max(prompt - inclusiveCacheRead, 0)
            }

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
