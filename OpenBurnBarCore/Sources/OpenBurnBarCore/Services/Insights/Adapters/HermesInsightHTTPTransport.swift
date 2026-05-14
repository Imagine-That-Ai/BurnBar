import Foundation

/// Reusable HTTP transport that talks to a Hermes relay over the
/// OpenAI-compatible `POST /v1/chat/completions` grammar.
///
/// Mobile, macOS, and Android shells all already speak this grammar
/// (Hermes is OpenAI-compatible on the wire), so this transport
/// concentrates the request-building + SSE-parsing logic in one place
/// instead of duplicating it across three platforms.
///
/// The shell layer wires:
/// - `baseURL` — the relay's HTTP base (`http://127.0.0.1:8642` for LAN,
///   or the user's selected remote relay's URL).
/// - `authorizationHeader` — optional bearer token; LAN sessions usually
///   pass `nil`, hosted relays pass the user's relay credential.
/// - `pathOverride` — defaults to `/v1/chat/completions`. Some relays
///   want a different path (legacy `/openai/v1/chat/completions`).
/// - `urlSession` — defaults to `.shared`; tests inject ephemeral
///   sessions with stubbed `URLProtocol` so the test runs offline.
public struct HermesInsightHTTPTransport: HermesInsightTransport {

    public let baseURL: URL
    public let authorizationHeader: String?
    public let pathOverride: String
    public let urlSession: URLSession
    public let advertisedModels: [InsightCatalogModel]

    public init(
        baseURL: URL,
        authorizationHeader: String? = nil,
        pathOverride: String = "/v1/chat/completions",
        urlSession: URLSession = .shared,
        advertisedModels: [InsightCatalogModel] = []
    ) {
        self.baseURL = baseURL
        self.authorizationHeader = authorizationHeader
        self.pathOverride = pathOverride
        self.urlSession = urlSession
        self.advertisedModels = advertisedModels
    }

    public func discoverModels() async throws -> [InsightCatalogModel] {
        advertisedModels
    }

    public func sendCanvasRequest(request: InsightInvestigateRequest) async throws -> InsightCanvas {
        // The HTTP transport doesn't materialize a canvas directly —
        // shells that want the legacy canvas path keep using their
        // existing Hermes bridge. We surface a clear error rather than
        // pretending to support it.
        throw InsightGatewayError.modelUnavailable(
            modelID: request.modelTag.modelID,
            reason: "HermesInsightHTTPTransport does not implement canvas requests; use analyze/stream instead."
        )
    }

    public func runAnalysisCompletion(
        request: HermesInsightChatRequest
    ) async throws -> HermesInsightChatResponse {
        let urlRequest = try makeURLRequest(for: request, streaming: false)
        let (data, response) = try await urlSession.data(for: urlRequest)
        try Self.validate(response: response, modelID: request.modelID)
        return HermesInsightChatResponse(
            responseJSON: data,
            usage: Self.usageFromJSON(data)
        )
    }

    public func streamAnalysisCompletion(
        request: HermesInsightChatRequest
    ) -> AsyncThrowingStream<HermesInsightChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(for: request, streaming: true)
                    let (bytes, response) = try await urlSession.bytes(for: urlRequest)
                    try Self.validate(response: response, modelID: request.modelID)
                    var assembled = ""
                    var terminalUsage: HermesInsightTokenUsage?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst("data: ".count)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let delta = Self.deltaText(from: json), !delta.isEmpty {
                            assembled += delta
                            continuation.yield(.delta(delta))
                        }
                        if let usage = Self.usage(from: json["usage"] as? [String: Any]) {
                            terminalUsage = usage
                        }
                    }
                    try Task.checkCancellation()
                    if let terminalUsage {
                        continuation.yield(.usage(terminalUsage))
                    }
                    continuation.yield(.completed(fullAnswer: assembled))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: InsightGatewayError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request building

    private func makeURLRequest(
        for request: HermesInsightChatRequest,
        streaming: Bool
    ) throws -> URLRequest {
        var url = baseURL
        url.appendPathComponent(pathOverride)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if streaming {
            urlRequest.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        if let authorizationHeader, !authorizationHeader.isEmpty {
            urlRequest.addValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        let userText = String(data: request.userPayload, encoding: .utf8) ?? ""
        var body: [String: Any] = [
            "model": request.modelID,
            "temperature": request.prefersAnswerLatency ? 0.3 : 0.2,
            "max_tokens": request.maxOutputTokens,
            "messages": [
                ["role": "system", "content": request.systemPrompt + "\n\nSchema:\n" + InsightJSONSchema.analysisResultSchemaV1],
                ["role": "user", "content": userText]
            ],
            "stream": streaming
        ]
        if streaming {
            body["stream_options"] = ["include_usage": true]
        }
        switch request.capabilityTier {
        case .strictJSONSchema:
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "insight_analysis_result_v1",
                    "strict": true,
                    "schema": (try? JSONSerialization.jsonObject(with: Data(InsightJSONSchema.analysisResultSchemaV1.utf8))) ?? [:]
                ]
            ]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .narrativeOnly:
            break
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    // MARK: - Response parsing

    private static func validate(response: URLResponse, modelID: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw InsightGatewayError.requestRejected(modelID: modelID, reason: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw InsightGatewayError.requestRejected(modelID: modelID, reason: "HTTP \(http.statusCode)")
        }
    }

    private static func deltaText(from json: [String: Any]) -> String? {
        // OpenAI streaming: choices[0].delta.content
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }
        // Some relays use top-level "content" / "text" / "delta".
        if let content = json["content"] as? String { return content }
        if let delta = json["delta"] as? String { return delta }
        if let text = json["text"] as? String { return text }
        return nil
    }

    private static func usage(from raw: [String: Any]?) -> HermesInsightTokenUsage? {
        guard let raw else { return nil }
        let input = (raw["prompt_tokens"] as? Int) ?? (raw["input_tokens"] as? Int) ?? 0
        let output = (raw["completion_tokens"] as? Int) ?? (raw["output_tokens"] as? Int) ?? 0
        let reasoning = (raw["reasoning_tokens"] as? Int)
            ?? ((raw["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int)
            ?? 0
        let cacheRead = (raw["cache_read_input_tokens"] as? Int)
            ?? ((raw["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
            ?? 0
        let cacheCreation = (raw["cache_creation_input_tokens"] as? Int) ?? 0
        let cost = (raw["estimated_cost_usd"] as? Double)
            ?? (raw["cost_usd"] as? Double)
            ?? 0
        return HermesInsightTokenUsage(
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: cost
        )
    }

    private static func usageFromJSON(_ data: Data) -> HermesInsightTokenUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return usage(from: json["usage"] as? [String: Any])
    }
}
