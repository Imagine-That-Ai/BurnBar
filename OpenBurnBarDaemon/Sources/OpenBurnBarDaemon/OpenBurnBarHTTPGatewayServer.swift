import OpenBurnBarCore
import CryptoKit
import Foundation
import Network

/// HTTP gateway server exposing OpenAI-compatible endpoints for external clients.
/// Binds to configurable host:port (default 127.0.0.1:8317) and routes requests
/// through the daemon's existing provider router and config store.
///
/// Built on `Network.framework` (`NWListener`/`NWConnection`) for safe, reliable
/// TCP handling — no hand-rolled `socket()`/`bind()`/`listen()`/`accept()` calls.
public actor BurnBarHTTPGatewayServer {
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 1 * 1024 * 1024

    private let configuration: BurnBarGatewayConfiguration
    private let configStore: BurnBarConfigStore
    private let usageRecorder: BurnBarUsageRecorder?
    private let providerExecutor: BurnBarOpenAICompatibleProviderExecutor
    private let anthropicExecutor: BurnBarAnthropicProviderExecutor
    private let logger: BurnBarDaemonLogger
    private let rateLimiter: BurnBarRateLimiter?
    private var listener: NWListener?

    public init(
        configuration: BurnBarGatewayConfiguration,
        configStore: BurnBarConfigStore,
        usageRecorder: BurnBarUsageRecorder? = nil,
        providerExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        anthropicExecutor: BurnBarAnthropicProviderExecutor = BurnBarAnthropicProviderExecutor(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "http-gateway"),
        rateLimiter: BurnBarRateLimiter? = nil
    ) {
        self.configuration = configuration
        self.configStore = configStore
        self.usageRecorder = usageRecorder
        self.providerExecutor = providerExecutor
        self.anthropicExecutor = anthropicExecutor
        self.logger = logger
        self.rateLimiter = rateLimiter ?? configuration.rateLimit.map {
            BurnBarRateLimiter(configuration: $0)
        }
    }

    public func start() throws {
        guard listener == nil else { return }
        guard configuration.isEnabled else {
            logger.debug("gateway_disabled", metadata: [:])
            return
        }
        if let error = configuration.validationError {
            logger.error("gateway_config_invalid", metadata: ["error": error])
            throw BurnBarHTTPGatewayError.invalidConfiguration(error)
        }

        let host = configuration.normalizedHost
        let port = UInt16(configuration.port)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: params)
        } catch {
            throw BurnBarHTTPGatewayError.listenerCreationFailed(error: error)
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }

        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.notice("gateway_started", metadata: [
                    "host": host,
                    "port": "\(self.configuration.port)",
                    "auth_required": "\(self.configuration.authToken != nil)"
                ])
            case .failed(let error):
                self.logger.error("gateway_listener_failed", metadata: ["error": "\(error)"])
            default:
                break
            }
        }

        self.listener = nwListener
        nwListener.start(queue: .global(qos: .utility))
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        logger.notice("gateway_stopped", metadata: [:])
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        readRequest(on: connection)
    }

    private func readRequest(on connection: NWConnection) {
        var buffer = Data()
        buffer.reserveCapacity(4096)

        readLoop(on: connection, buffer: buffer, headerRange: nil, expectedBodyLength: 0)
    }

    private func readLoop(
        on connection: NWConnection,
        buffer: Data,
        headerRange: Range<Data.Index>?,
        expectedBodyLength: Int
    ) {
        let chunkSize = 4096
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.error("gateway_connection_read_error", metadata: ["error": "\(error)"])
                connection.cancel()
                return
            }

            var mutableBuffer = buffer
            if let data {
                mutableBuffer.append(data)
            }

            if isComplete {
                // Client closed connection — process whatever we have
                Task { await self.processBuffer(mutableBuffer, headerRange: headerRange, connection: connection) }
                return
            }

            Task { await self.processIncomingData(mutableBuffer, connection: connection, headerRange: headerRange, expectedBodyLength: expectedBodyLength) }
        }
    }

    private func processIncomingData(
        _ buffer: Data,
        connection: NWConnection,
        headerRange: Range<Data.Index>?,
        expectedBodyLength: Int
    ) async {
        let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        // Check for header terminator
        var currentHeaderRange = headerRange
        if currentHeaderRange == nil {
            if buffer.count > Self.maxHeaderBytes {
                await writeResponse(
                    on: connection,
                    status: 400,
                    headers: ["Content-Type": "application/json"],
                    body: errorBody("bad request")
                )
                connection.cancel()
                return
            }
            if let range = buffer.range(of: headerTerminator) {
                currentHeaderRange = range
            }
        }

        guard let foundHeaderRange = currentHeaderRange else {
            // Still waiting for headers
            readLoop(on: connection, buffer: buffer, headerRange: nil, expectedBodyLength: 0)
            return
        }

        // Parse headers to get content-length
        let headerData = buffer.prefix(upTo: foundHeaderRange.lowerBound)
        guard let parsed = try? parseRequestHead(headerData) else {
            await writeResponse(on: connection, status: 400, headers: ["Content-Type": "application/json"], body: errorBody("bad request"))
            connection.cancel()
            return
        }

        if parsed.contentLength > Self.maxBodyBytes {
            await writeResponse(on: connection, status: 413, headers: ["Content-Type": "application/json"], body: errorBody("request body exceeds \(Self.maxBodyBytes) bytes"))
            connection.cancel()
            return
        }

        let availableBody = buffer.count - foundHeaderRange.upperBound
        if availableBody >= parsed.contentLength {
            await processBuffer(buffer, headerRange: foundHeaderRange, connection: connection)
        } else {
            readLoop(on: connection, buffer: buffer, headerRange: foundHeaderRange, expectedBodyLength: parsed.contentLength)
        }
    }

    private func processBuffer(_ buffer: Data, headerRange: Range<Data.Index>?, connection: NWConnection) async {
        let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        guard let foundHeaderRange = headerRange ?? buffer.range(of: headerTerminator) else {
            await writeResponse(on: connection, status: 400, headers: ["Content-Type": "application/json"], body: errorBody("bad request"))
            connection.cancel()
            return
        }

        let headerData = buffer.prefix(upTo: foundHeaderRange.lowerBound)
        guard let parsed = try? parseRequestHead(headerData) else {
            await writeResponse(on: connection, status: 400, headers: ["Content-Type": "application/json"], body: errorBody("bad request"))
            connection.cancel()
            return
        }

        if parsed.contentLength > Self.maxBodyBytes {
            await writeResponse(on: connection, status: 413, headers: ["Content-Type": "application/json"], body: errorBody("request body exceeds \(Self.maxBodyBytes) bytes"))
            connection.cancel()
            return
        }

        let bodyData = buffer.suffix(from: foundHeaderRange.upperBound).prefix(parsed.contentLength)
        let body: String?
        if parsed.contentLength == 0 {
            body = nil
        } else if let decoded = String(data: bodyData, encoding: .utf8) {
            body = decoded
        } else {
            await writeResponse(on: connection, status: 400, headers: ["Content-Type": "application/json"], body: errorBody("bad request"))
            connection.cancel()
            return
        }

        let request = HTTPRequest(method: parsed.method, path: parsed.path, headers: parsed.headers, body: body)
        await handleRequest(request, connection: connection)
    }

    // MARK: - Request Routing

    private func handleRequest(_ request: HTTPRequest, connection: NWConnection) async {
        if request.method == "OPTIONS" {
            await writeResponse(on: connection, status: 204, headers: corsHeaders(for: request), body: "")
            connection.cancel()
            return
        }

        if let requiredToken = configuration.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            guard bearerToken(from: request.headers["authorization"]) == requiredToken else {
                await writeResponse(on: connection, status: 401, headers: ["Content-Type": "application/json"], body: errorBody("unauthorized"))
                connection.cancel()
                return
            }
        }

        // Rate limiting check
        if let rateLimiter {
            let clientKey = rateLimitClientKey(for: request)
            let limitResult = await rateLimiter.checkLimit(clientKey: clientKey)
            if case .throttled(let retryAfter) = limitResult {
                logger.warning(
                    "gateway_rate_limit_exceeded",
                    metadata: [
                        "client_key": clientKey,
                        "retry_after": "\(retryAfter)"
                    ]
                )
                var rateLimitHeaders: [String: String] = [
                    "Content-Type": "application/json",
                    "Retry-After": "\(Int(ceil(retryAfter)))"
                ]
                for (key, value) in corsHeaders(for: request) {
                    rateLimitHeaders[key] = value
                }
                await writeResponse(on: connection, status: 429, headers: rateLimitHeaders, body: errorBody("rate limit exceeded"))
                connection.cancel()
                return
            }
        }

        let routedResponse = await routeRequest(request)
        var headers = routedResponse.headers
        for (key, value) in corsHeaders(for: request) {
            headers[key] = value
        }
        await writeResponse(on: connection, response: routedResponse.withHeaders(headers))
        connection.cancel()
    }

    private func routeRequest(_ request: HTTPRequest) async -> GatewayHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return jsonResponse(status: 200, body: encodeBody(HealthResponse(ok: true, version: BurnBarDaemonVersion.current)))

        case ("GET", "/v1/models"):
            return await handleModels()

        case ("POST", "/v1/chat/completions"):
            return await handleChatCompletions(body: request.body)

        case ("POST", "/v1/messages"):
            return await handleAnthropicMessages(body: request.body)

        default:
            return jsonResponse(status: 404, body: errorBody("not found"))
        }
    }

    // MARK: - /v1/models

    private func handleModels() async -> GatewayHTTPResponse {
        do {
            let configurations = try await configStore.resolvedConfigurations()
            let enabledConfigs = configurations.filter { $0.settings.isEnabled && $0.hasCredential }
            var models: [ModelDescriptor] = []
            for config in enabledConfigs {
                for model in config.preferredModels {
                    models.append(ModelDescriptor(id: model.id, ownedBy: config.provider.id))
                }
            }
            return jsonResponse(status: 200, body: encodeBody(ModelsResponse(data: models)))
        } catch {
            logger.error("gateway_models_error", metadata: ["error": "\(error)"])
            return jsonResponse(status: 500, body: errorBody("internal error"))
        }
    }

    // MARK: - /v1/chat/completions

    private func handleChatCompletions(body: String?) async -> GatewayHTTPResponse {
        guard let body, !body.isEmpty else {
            return jsonResponse(status: 400, body: errorBody("request body required"))
        }

        guard let bodyData = body.data(using: .utf8) else {
            return jsonResponse(status: 400, body: errorBody("request body must be valid UTF-8"))
        }

        let completionRequest: ChatCompletionsRequest
        do {
            completionRequest = try JSONDecoder().decode(ChatCompletionsRequest.self, from: bodyData)
        } catch {
            return jsonResponse(status: 400, body: errorBody("invalid JSON request body"))
        }

        let modelID = completionRequest.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelID.isEmpty == false else {
            return jsonResponse(status: 400, body: errorBody("model field required"))
        }

        do {
            let router = BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "gateway-router"),
                routingEventStore: BurnBarProviderRoutingDecisionEventStore()
            )
            let ranking = try await router.scoreAndRankRoutes(
                modelName: modelID,
                requestedFormatFamily: .openaiCompat
            )
            await router.persistDecisionIfNeeded(ranking: ranking, modelName: modelID)
            let rankedRoutes = ranking.rankedRoutes.map(\.route)
            guard rankedRoutes.isEmpty == false else {
                return jsonResponse(
                    status: 503,
                    body: errorBody(
                        "no eligible OpenAI-compatible route for \(modelID). Add or enable an OpenAI-family account (OpenAI, Z.ai, MiniMax, Kimi, Ollama, …) to serve /v1/chat/completions."
                    )
                )
            }
            let selectedCapabilityClassID = rankedRoutes.first?.modelCapabilityClassID
            let routes = selectedCapabilityClassID.map { capabilityClassID in
                rankedRoutes.filter { $0.modelCapabilityClassID == capabilityClassID }
            } ?? rankedRoutes
            let blockedCapabilityAlternatives = selectedCapabilityClassID.map { capabilityClassID in
                ranking.rankedRoutes
                    .map(\.route)
                    .filter { $0.modelCapabilityClassID != capabilityClassID }
            } ?? []

            var lastError: Error?
            for (index, route) in routes.enumerated() {
                if let slotID = route.credentialSlotID {
                    try? await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
                }

                do {
                    let response = try await providerExecutor.proxyChatCompletions(
                        body: bodyData,
                        route: route
                    )
                    await router.markRouteSuccess(route)
                    await recordUsageIfAvailable(response.usage, route: route)
                    return GatewayHTTPResponse(
                        status: response.statusCode,
                        headers: ["Content-Type": response.contentType],
                        body: response.body
                    )
                } catch {
                    lastError = error
                    await router.markRouteFailure(route, error: error)
                    let hasMoreCandidates = index < routes.count - 1
                    if shouldFailOverProviderError(error), hasMoreCandidates {
                        continue
                    }
                    break
                }
            }

            if !blockedCapabilityAlternatives.isEmpty,
               let lastError,
               shouldFailOverProviderError(lastError) {
                let classLabel = selectedCapabilityClassID ?? modelID
                return jsonResponse(
                    status: 503,
                    body: errorBody(
                        "all routed accounts in capability class \(classLabel) failed; no same-tier fallback remained and downgrade is disabled."
                    )
                )
            }

            let message = lastError?.localizedDescription ?? "no eligible route for \(modelID)"
            return jsonResponse(status: 502, body: errorBody("routing failed: \(message)"))
        } catch {
            logger.error("gateway_route_error", metadata: ["model": modelID, "error": "\(error)"])
            return jsonResponse(status: 502, body: errorBody("routing failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - /v1/messages (Anthropic Messages format)

    private func handleAnthropicMessages(body: String?) async -> GatewayHTTPResponse {
        guard let body, !body.isEmpty else {
            return jsonResponse(status: 400, body: errorBody("request body required"))
        }

        guard let bodyData = body.data(using: .utf8) else {
            return jsonResponse(status: 400, body: errorBody("request body must be valid UTF-8"))
        }

        let messagesRequest: AnthropicMessagesRequest
        do {
            messagesRequest = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: bodyData)
        } catch {
            return jsonResponse(status: 400, body: errorBody("invalid JSON request body"))
        }

        let modelID = messagesRequest.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelID.isEmpty == false else {
            return jsonResponse(status: 400, body: errorBody("model field required"))
        }

        do {
            let router = BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "gateway-router-anthropic"),
                routingEventStore: BurnBarProviderRoutingDecisionEventStore()
            )
            let ranking = try await router.scoreAndRankRoutes(
                modelName: modelID,
                requestedFormatFamily: .anthropic
            )
            await router.persistDecisionIfNeeded(ranking: ranking, modelName: modelID)
            let rankedRoutes = ranking.rankedRoutes.map(\.route)
            guard rankedRoutes.isEmpty == false else {
                return jsonResponse(
                    status: 503,
                    body: errorBody(
                        "no eligible Anthropic-family route for \(modelID). Add an Anthropic Console API key or an Anthropic Pro/Team plan to serve /v1/messages."
                    )
                )
            }
            let selectedCapabilityClassID = rankedRoutes.first?.modelCapabilityClassID
            let routes = selectedCapabilityClassID.map { capabilityClassID in
                rankedRoutes.filter { $0.modelCapabilityClassID == capabilityClassID }
            } ?? rankedRoutes
            let blockedCapabilityAlternatives = selectedCapabilityClassID.map { capabilityClassID in
                ranking.rankedRoutes
                    .map(\.route)
                    .filter { $0.modelCapabilityClassID != capabilityClassID }
            } ?? []

            var lastError: Error?
            for (index, route) in routes.enumerated() {
                if let slotID = route.credentialSlotID {
                    try? await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
                }

                do {
                    let response = try await anthropicExecutor.proxyMessages(
                        body: bodyData,
                        route: route
                    )
                    await router.markRouteSuccess(route)
                    await recordUsageIfAvailable(response.usage, route: route)
                    return GatewayHTTPResponse(
                        status: response.statusCode,
                        headers: ["Content-Type": response.contentType],
                        body: response.body
                    )
                } catch {
                    lastError = error
                    await router.markRouteFailure(route, error: error)
                    let hasMoreCandidates = index < routes.count - 1
                    if shouldFailOverProviderError(error), hasMoreCandidates {
                        continue
                    }
                    break
                }
            }

            if !blockedCapabilityAlternatives.isEmpty,
               let lastError,
               shouldFailOverProviderError(lastError) {
                let classLabel = selectedCapabilityClassID ?? modelID
                return jsonResponse(
                    status: 503,
                    body: errorBody(
                        "all routed accounts in capability class \(classLabel) failed; no same-tier fallback remained and downgrade is disabled."
                    )
                )
            }

            let message = lastError?.localizedDescription ?? "no eligible route for \(modelID)"
            return jsonResponse(status: 502, body: errorBody("routing failed: \(message)"))
        } catch {
            logger.error("gateway_anthropic_route_error", metadata: ["model": modelID, "error": "\(error)"])
            return jsonResponse(status: 502, body: errorBody("routing failed: \(error.localizedDescription)"))
        }
    }

    private func recordUsageIfAvailable(
        _ usage: BurnBarProviderProxyUsage?,
        route: BurnBarProviderRoute
    ) async {
        guard let usage, let usageRecorder else { return }
        let event = BurnBarUsageEvent(
            providerID: route.providerID,
            modelID: route.resolvedModelID,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens,
            reasoningTokens: usage.reasoningTokens,
            cost: route.pricing.cost(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens
            ),
            recordedAt: Date(),
            projectName: "OpenBurnBar Gateway",
            confidence: usage.confidence
        )
        do {
            _ = try await usageRecorder.record(
                event,
                idempotencyKey: "gateway:\(UUID().uuidString)"
            )
        } catch {
            logger.silentFailure("gateway_usage_record", error: error)
        }
    }

    private func shouldFailOverProviderError(_ error: Error) -> Bool {
        if let providerError = error as? BurnBarProviderExecutorError {
            switch providerError {
            case .upstreamError(let statusCode, let body):
                if statusCode == 429 || statusCode == 401 || statusCode == 403 || statusCode == 402 {
                    return true
                }
                let normalizedBody = body.lowercased()
                return normalizedBody.contains("quota")
                    || normalizedBody.contains("rate")
                    || normalizedBody.contains("insufficient")
                    || normalizedBody.contains("exhaust")
            case .invalidBaseURL, .invalidResponse:
                return false
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("quota")
            || description.contains("rate limit")
            || description.contains("429")
    }

    // MARK: - HTTP I/O (NWConnection)

    private func writeResponse(on connection: NWConnection, response: GatewayHTTPResponse) async {
        let statusText: String
        switch response.status {
        case 204: statusText = "No Content"
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 429: statusText = "Too Many Requests"
        case 500: statusText = "Internal Server Error"
        case 502: statusText = "Bad Gateway"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Unknown"
        }

        var head = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        for (key, value) in response.headers {
            head += "\(key): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        guard var data = head.data(using: .utf8) else {
            connection.cancel()
            return
        }
        data.append(response.body)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func writeResponse(on connection: NWConnection, status: Int, headers: [String: String], body: String) async {
        await writeResponse(
            on: connection,
            response: GatewayHTTPResponse(
                status: status,
                headers: headers,
                body: Data(body.utf8)
            )
        )
    }

    // MARK: - HTTP Parsing

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String?
    }

    private struct ParsedRequestHead {
        let method: String
        let path: String
        let headers: [String: String]
        let contentLength: Int
    }

    private func parseRequestHead(_ headerData: Data) throws -> ParsedRequestHead {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPRequestReadError.invalidRequest
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPRequestReadError.invalidRequest
        }

        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else {
            throw HTTPRequestReadError.invalidRequest
        }

        let method = String(requestLineParts[0]).uppercased()
        let rawPath = String(requestLineParts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.isEmpty == false {
            guard let separator = line.firstIndex(of: ":") else {
                throw HTTPRequestReadError.invalidRequest
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if let transferEncoding = headers["transfer-encoding"], transferEncoding.lowercased().contains("chunked") {
            throw HTTPRequestReadError.invalidRequest
        }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsedLength = Int(rawContentLength), parsedLength >= 0 else {
                throw HTTPRequestReadError.invalidRequest
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }

        return ParsedRequestHead(method: method, path: path, headers: headers, contentLength: contentLength)
    }

    private func bearerToken(from authorizationHeader: String?) -> String? {
        guard let authorizationHeader else { return nil }
        let parts = authorizationHeader.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else {
            return nil
        }
        let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func rateLimitClientKey(for request: HTTPRequest) -> String {
        if let token = bearerToken(from: request.headers["authorization"]) {
            return "token:\(Self.stableDigest(token))"
        }
        return "anonymous"
    }

    private static func stableDigest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func corsHeaders(for request: HTTPRequest) -> [String: String] {
        guard let origin = request.headers["origin"], isAllowedCORSOrigin(origin) else {
            return [:]
        }
        return [
            "Access-Control-Allow-Origin": origin,
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type",
            "Vary": "Origin"
        ]
    }

    private func isAllowedCORSOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func errorBody(_ message: String) -> String {
        encodeBody(GatewayErrorResponse(error: message))
    }

    private func jsonResponse(status: Int, body: String) -> GatewayHTTPResponse {
        GatewayHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }

    private func encodeBody<Value: Encodable>(_ value: Value) -> String {
        do {
            let payload = try JSONEncoder().encode(value)
            return String(decoding: payload, as: UTF8.self)
        } catch {
            return "{\"error\":\"internal error\"}"
        }
    }

    private enum HTTPRequestReadError: Error {
        case invalidRequest
        case payloadTooLarge
    }

    private struct GatewayHTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: Data

        func withHeaders(_ headers: [String: String]) -> GatewayHTTPResponse {
            GatewayHTTPResponse(status: status, headers: headers, body: body)
        }
    }

    private struct HealthResponse: Encodable {
        let ok: Bool
        let version: String
    }

    private struct GatewayErrorResponse: Encodable {
        let error: String
    }

    private struct ModelsResponse: Encodable {
        let object = "list"
        let data: [ModelDescriptor]
    }

    private struct ModelDescriptor: Encodable {
        let id: String
        let object = "model"
        let ownedBy: String

        enum CodingKeys: String, CodingKey {
            case id
            case object
            case ownedBy = "owned_by"
        }
    }

    private struct ChatCompletionsRequest: Decodable {
        let model: String
    }

    private struct AnthropicMessagesRequest: Decodable {
        let model: String
    }

}

public enum BurnBarHTTPGatewayError: Error, LocalizedError {
    case invalidConfiguration(String)
    case listenerCreationFailed(error: Error)
    case invalidHost(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg):
            return "Gateway configuration error: \(msg)"
        case .listenerCreationFailed(let error):
            return "Failed to create gateway listener: \(error.localizedDescription)"
        case .invalidHost(let host):
            return "Invalid gateway host address: \(host)"
        }
    }
}
