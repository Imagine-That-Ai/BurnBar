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
    static func applyProviderPrivacyPreferences(to object: inout DaemonJSONObject, providerID: String?) {
        guard providerID?.lowercased() == "openrouter" else { return }
        var provider = (object["provider"] as? DaemonJSONObject) ?? [:]
        provider["data_collection"] = "deny"
        object["provider"] = provider
    }

    /// `POST {baseURL}/embeddings` (OpenAI shape). Buffered only.
    public func proxyEmbeddings(body: Data, route: BurnBarProviderRoute) async throws -> BurnBarProviderProxyResponse {
        let baseURL = try BurnBarProviderExecutorError.validatedProviderBaseURL(route.baseURL)
        let json = try JSONSerialization.jsonObject(with: body)
        guard var object = json as? DaemonJSONObject else {
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
        guard var object = json as? DaemonJSONObject else {
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
        guard var object = json as? DaemonJSONObject else {
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
            var streamOptions = (object["stream_options"] as? DaemonJSONObject) ?? [:]
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
        to object: inout DaemonJSONObject,
        isResponsesShape: Bool,
        effortOnly: Bool = false
    ) {
        let effort = variant.thinkingLevel.openAIEffort
        if isResponsesShape {
            var reasoning = (object["reasoning"] as? DaemonJSONObject) ?? [:]
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
            var reasoning = (object["reasoning"] as? DaemonJSONObject) ?? [:]
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

    static func normalizeOpenAICompatibleMessages(in object: inout DaemonJSONObject) {
        guard let messages = object["messages"] as? [DaemonJSONObject] else { return }
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
        let body: DaemonJSONObject = [
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
