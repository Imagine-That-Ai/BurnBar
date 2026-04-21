import OpenBurnBarCore
import Foundation

/// HTTP gateway server exposing OpenAI-compatible endpoints for external clients.
/// Binds to configurable host:port (default 127.0.0.1:8317) and routes requests
/// through the daemon's existing provider router and config store.
public actor BurnBarHTTPGatewayServer {
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 1 * 1024 * 1024
    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private let configuration: BurnBarGatewayConfiguration
    private let configStore: BurnBarConfigStore
    private let logger: BurnBarDaemonLogger
    private var serverSocket: Int32?
    private var acceptLoopTask: Task<Void, Never>?

    public init(
        configuration: BurnBarGatewayConfiguration,
        configStore: BurnBarConfigStore,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "http-gateway")
    ) {
        self.configuration = configuration
        self.configStore = configStore
        self.logger = logger
    }

    public func start() throws {
        guard serverSocket == nil else { return }
        guard configuration.isEnabled else {
            logger.debug("gateway_disabled", metadata: [:])
            return
        }
        if let error = configuration.validationError {
            logger.error("gateway_config_invalid", metadata: ["error": error])
            throw BurnBarHTTPGatewayError.invalidConfiguration(error)
        }

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw BurnBarHTTPGatewayError.socketCreationFailed(errno: errno)
        }

        // Allow address reuse
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        let addr = try bindAddress(socket: socket)
        guard listen(socket, 128) == 0 else {
            Darwin.close(socket)
            throw BurnBarHTTPGatewayError.listenFailed(errno: errno)
        }

        self.serverSocket = socket

        logger.notice(
            "gateway_started",
            metadata: [
                "host": configuration.host,
                "port": "\(configuration.port)",
                "auth_required": "\(configuration.authToken != nil)"
            ]
        )

        acceptLoopTask = Task { [weak self] in
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            while !Task.isCancelled {
                guard let self else { break }
                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    Darwin.accept(socket, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), &clientAddrLen)
                }
                guard clientSocket >= 0 else { continue }
                await self.handleClient(socket: clientSocket)
                Darwin.close(clientSocket)
            }
        }

        _ = addr // suppress unused warning
    }

    public func stop() {
        if let socket = serverSocket {
            Darwin.close(socket)
            serverSocket = nil
        }
        acceptLoopTask?.cancel()
        acceptLoopTask = nil
        logger.notice("gateway_stopped", metadata: [:])
    }

    // MARK: - Private

    private func bindAddress(socket: Int32) throws -> String {
        let host = configuration.normalizedHost
        let port = configuration.port

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            addr.sin_addr.s_addr = 0x0100007F  // 127.0.0.1 in network byte order
        } else {
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
                Darwin.close(socket)
                throw BurnBarHTTPGatewayError.invalidHost(host)
            }
        }

        let bindResult = withUnsafeMutablePointer(to: &addr) { ptr in
            Darwin.bind(socket, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard bindResult == 0 else {
            Darwin.close(socket)
            throw BurnBarHTTPGatewayError.bindFailed(errno: errno)
        }
        return "\(configuration.host):\(port)"
    }

    private func handleClient(socket: Int32) async {
        let request: HTTPRequest
        do {
            request = try readRequest(socket: socket)
        } catch let error as HTTPRequestReadError {
            switch error {
            case .payloadTooLarge:
                writeResponse(
                    socket: socket,
                    status: 413,
                    headers: ["Content-Type": "application/json"],
                    body: errorBody("request body exceeds \(Self.maxBodyBytes) bytes")
                )
            case .invalidRequest:
                writeResponse(
                    socket: socket,
                    status: 400,
                    headers: ["Content-Type": "application/json"],
                    body: errorBody("bad request")
                )
            }
            return
        } catch {
            writeResponse(
                socket: socket,
                status: 400,
                headers: ["Content-Type": "application/json"],
                body: errorBody("bad request")
            )
            return
        }

        if request.method == "OPTIONS" {
            writeResponse(socket: socket, status: 204, headers: corsHeaders(for: request), body: "")
            return
        }

        if let requiredToken = configuration.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            guard bearerToken(from: request.headers["authorization"]) == requiredToken else {
                writeResponse(
                    socket: socket,
                    status: 401,
                    headers: ["Content-Type": "application/json"],
                    body: errorBody("unauthorized")
                )
                return
            }
        }

        let (status, body) = await routeRequest(request)
        var headers: [String: String] = ["Content-Type": "application/json"]
        for (key, value) in corsHeaders(for: request) {
            headers[key] = value
        }
        writeResponse(socket: socket, status: status, headers: headers, body: body)
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

    // MARK: - HTTP I/O

    private enum HTTPRequestReadError: Error {
        case invalidRequest
        case payloadTooLarge
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String?
    }

    private func readRequest(socket: Int32) throws -> HTTPRequest {
        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var headerRange: Range<Data.Index>?
        var expectedBodyLength = 0

        while true {
            let bytesRead = recv(socket, &buffer, buffer.count, 0)
            if bytesRead == 0 {
                break
            }
            if bytesRead < 0 {
                throw HTTPRequestReadError.invalidRequest
            }

            requestData.append(contentsOf: buffer.prefix(bytesRead))

            if headerRange == nil {
                if requestData.count > Self.maxHeaderBytes {
                    throw HTTPRequestReadError.invalidRequest
                }
                if let discoveredRange = requestData.range(of: Self.headerTerminator) {
                    headerRange = discoveredRange
                    let headerData = requestData.prefix(upTo: discoveredRange.lowerBound)
                    let parsed = try parseRequestHead(headerData)
                    expectedBodyLength = parsed.contentLength
                    if expectedBodyLength > Self.maxBodyBytes {
                        throw HTTPRequestReadError.payloadTooLarge
                    }

                    let currentlyBufferedBody = requestData.count - discoveredRange.upperBound
                    if currentlyBufferedBody >= expectedBodyLength {
                        return try finalizeRequest(parsed: parsed, requestData: requestData, headerRange: discoveredRange)
                    }
                }
                continue
            }

            guard let headerRange else {
                throw HTTPRequestReadError.invalidRequest
            }
            let currentlyBufferedBody = requestData.count - headerRange.upperBound
            if currentlyBufferedBody > Self.maxBodyBytes {
                throw HTTPRequestReadError.payloadTooLarge
            }
            if currentlyBufferedBody >= expectedBodyLength {
                return try finalizeRequest(parsed: parseRequestHead(requestData.prefix(upTo: headerRange.lowerBound)), requestData: requestData, headerRange: headerRange)
            }
        }

        guard let headerRange else {
            throw HTTPRequestReadError.invalidRequest
        }
        return try finalizeRequest(
            parsed: try parseRequestHead(requestData.prefix(upTo: headerRange.lowerBound)),
            requestData: requestData,
            headerRange: headerRange
        )
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
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = String(value)
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

    private func finalizeRequest(
        parsed: ParsedRequestHead,
        requestData: Data,
        headerRange: Range<Data.Index>
    ) throws -> HTTPRequest {
        guard parsed.contentLength <= Self.maxBodyBytes else {
            throw HTTPRequestReadError.payloadTooLarge
        }

        let availableBodyLength = max(0, requestData.count - headerRange.upperBound)
        guard availableBodyLength >= parsed.contentLength else {
            throw HTTPRequestReadError.invalidRequest
        }

        let bodyData = requestData
            .suffix(from: headerRange.upperBound)
            .prefix(parsed.contentLength)
        let body: String?
        if parsed.contentLength == 0 {
            body = nil
        } else if let decoded = String(data: bodyData, encoding: .utf8) {
            body = decoded
        } else {
            throw HTTPRequestReadError.invalidRequest
        }

        return HTTPRequest(
            method: parsed.method,
            path: parsed.path,
            headers: parsed.headers,
            body: body
        )
    }

    private func writeResponse(socket: Int32, status: Int, headers: [String: String], body: String) {
        let statusText: String
        switch status {
        case 204: statusText = "No Content"
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
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
            return
        }
        data.withUnsafeBytes { ptr in
            _ = Darwin.send(socket, ptr.baseAddress, data.count, 0)
        }
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
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case invalidHost(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg):
            return "Gateway configuration error: \(msg)"
        case .socketCreationFailed(let err):
            return "Failed to create gateway socket (errno \(err))."
        case .bindFailed(let err):
            return "Failed to bind gateway socket (errno \(err))."
        case .listenFailed(let err):
            return "Failed to listen on gateway socket (errno \(err))."
        case .invalidHost(let host):
            return "Invalid gateway host address: \(host)"
        }
    }
}
