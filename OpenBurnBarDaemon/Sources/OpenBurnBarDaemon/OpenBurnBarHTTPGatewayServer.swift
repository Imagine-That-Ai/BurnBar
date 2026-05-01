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
    private let logger: BurnBarDaemonLogger
    private let rateLimiter: BurnBarRateLimiter?
    private var listener: NWListener?

    public init(
        configuration: BurnBarGatewayConfiguration,
        configStore: BurnBarConfigStore,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "http-gateway"),
        rateLimiter: BurnBarRateLimiter? = nil
    ) {
        self.configuration = configuration
        self.configStore = configStore
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

        let (status, responseBody) = await routeRequest(request)
        var headers: [String: String] = ["Content-Type": "application/json"]
        for (key, value) in corsHeaders(for: request) {
            headers[key] = value
        }
        await writeResponse(on: connection, status: status, headers: headers, body: responseBody)
        connection.cancel()
    }

    private func routeRequest(_ request: HTTPRequest) async -> (Int, String) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return (200, encodeBody(HealthResponse(ok: true, version: BurnBarDaemonVersion.current)))

        case ("GET", "/v1/models"):
            return await handleModels()

        case ("POST", "/v1/chat/completions"):
            return await handleChatCompletions(body: request.body)

        default:
            return (404, errorBody("not found"))
        }
    }

    // MARK: - /v1/models

    private func handleModels() async -> (Int, String) {
        do {
            let configurations = try await configStore.resolvedConfigurations()
            let enabledConfigs = configurations.filter { $0.settings.isEnabled && $0.hasCredential }
            var models: [ModelDescriptor] = []
            for config in enabledConfigs {
                for model in config.preferredModels {
                    models.append(ModelDescriptor(id: model.id, ownedBy: config.provider.id))
                }
            }
            return (200, encodeBody(ModelsResponse(data: models)))
        } catch {
            logger.error("gateway_models_error", metadata: ["error": "\(error)"])
            return (500, errorBody("internal error"))
        }
    }

    // MARK: - /v1/chat/completions

    private func handleChatCompletions(body: String?) async -> (Int, String) {
        guard let body, !body.isEmpty else {
            return (400, errorBody("request body required"))
        }

        guard let bodyData = body.data(using: .utf8) else {
            return (400, errorBody("request body must be valid UTF-8"))
        }

        let completionRequest: ChatCompletionsRequest
        do {
            completionRequest = try JSONDecoder().decode(ChatCompletionsRequest.self, from: bodyData)
        } catch {
            return (400, errorBody("invalid JSON request body"))
        }

        let modelID = completionRequest.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelID.isEmpty == false else {
            return (400, errorBody("model field required"))
        }

        do {
            let router = BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "gateway-router")
            )
            let route = try await router.route(modelName: modelID)

            let response = ChatCompletionRouteResponse(
                id: "gw-\(UUID().uuidString.prefix(8))",
                model: route.resolvedModelID,
                providerID: route.providerID,
                baseURL: route.baseURL,
                credentialSlot: route.credentialSlotID ?? "default",
                created: Int(Date().timeIntervalSince1970),
                choices: []
            )
            return (200, encodeBody(response))
        } catch {
            logger.error("gateway_route_error", metadata: ["model": modelID, "error": "\(error)"])
            return (502, errorBody("routing failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - HTTP I/O (NWConnection)

    private func writeResponse(on connection: NWConnection, status: Int, headers: [String: String], body: String) async {
        let statusText: String
        switch status {
        case 204: statusText = "No Content"
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 429: statusText = "Too Many Requests"
        case 500: statusText = "Internal Server Error"
        case 502: statusText = "Bad Gateway"
        default: statusText = "Unknown"
        }

        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "Content-Length: \(body.utf8.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        response += body

        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
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

    private struct ChatCompletionRouteResponse: Encodable {
        let id: String
        let object = "chat.completion"
        let model: String
        let providerID: String
        let baseURL: String
        let credentialSlot: String
        let created: Int
        let choices: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case object
            case model
            case providerID = "provider_id"
            case baseURL = "base_url"
            case credentialSlot = "credential_slot"
            case created
            case choices
        }
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
