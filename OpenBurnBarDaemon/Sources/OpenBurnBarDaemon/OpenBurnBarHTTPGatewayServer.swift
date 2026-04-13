import OpenBurnBarCore
import Foundation

/// HTTP gateway server exposing OpenAI-compatible endpoints for external clients.
/// Binds to configurable host:port (default 127.0.0.1:8317) and routes requests
/// through the daemon's existing provider router and config store.
public actor BurnBarHTTPGatewayServer {
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
                let _ = await self.handleClient(socket: clientSocket)
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
        let host = configuration.host
        let port = configuration.port

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        if host == "0.0.0.0" {
            addr.sin_addr.s_addr = INADDR_ANY
        } else if host == "127.0.0.1" || host == "localhost" {
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
        return "\(host):\(port)"
    }

    private func handleClient(socket: Int32) async {
        let request = readRequest(socket: socket)
        guard let request else {
            writeResponse(socket: socket, status: 400, headers: [:], body: "{\"error\":\"bad request\"}")
            return
        }

        // Auth check
        if let requiredToken = configuration.authToken {
            let provided = request.headers["authorization"]?
                .replacingOccurrences(of: "Bearer ", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard provided == requiredToken else {
                writeResponse(socket: socket, status: 401, headers: [:], body: "{\"error\":\"unauthorized\"}")
                return
            }
        }

        let (status, body) = await routeRequest(request)
        let headers: [String: String] = [
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        ]
        writeResponse(socket: socket, status: status, headers: headers, body: body)
    }

    private func routeRequest(_ request: HTTPRequest) async -> (Int, String) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return (200, "{\"ok\":true,\"version\":\"\(BurnBarDaemonVersion.current)\"}")

        case ("GET", "/v1/models"):
            return await handleModels()

        case ("POST", "/v1/chat/completions"):
            return await handleChatCompletions(body: request.body)

        default:
            return (404, "{\"error\":\"not found\"}")
        }
    }

    // MARK: - /v1/models

    private func handleModels() async -> (Int, String) {
        do {
            let configurations = try await configStore.resolvedConfigurations()
            let enabledConfigs = configurations.filter { $0.settings.isEnabled && $0.hasCredential }
            var models: [[String: String]] = []
            for config in enabledConfigs {
                for model in config.preferredModels {
                    models.append([
                        "id": model.id,
                        "object": "model",
                        "owned_by": config.provider.id
                    ])
                }
            }
            let modelsJSON = models.map { dict in
                "{" + dict.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}"
            }.joined(separator: ",")
            return (200, "{\"object\":\"list\",\"data\":[" + modelsJSON + "]}")
        } catch {
            logger.error("gateway_models_error", metadata: ["error": "\(error)"])
            return (500, "{\"error\":\"internal error\"}")
        }
    }

    // MARK: - /v1/chat/completions

    private func handleChatCompletions(body: String?) async -> (Int, String) {
        guard let body, !body.isEmpty else {
            return (400, "{\"error\":\"request body required\"}")
        }

        // Extract model from body
        guard let modelRange = body.range(of: "\"model\"") else {
            return (400, "{\"error\":\"model field required\"}")
        }

        // Simple JSON extraction: find model value
        let afterModel = body[modelRange.upperBound...]
        guard let colonIdx = afterModel.firstIndex(of: ":") else {
            return (400, "{\"error\":\"invalid model field\"}")
        }
        let afterColon = afterModel[colonIdx...].dropFirst()
        let trimmed = afterColon.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID: String
        if trimmed.hasPrefix("\"") {
            let withoutQuote = trimmed.dropFirst()
            guard let endQuote = withoutQuote.firstIndex(of: "\"") else {
                return (400, "{\"error\":\"invalid model value\"}")
            }
            modelID = String(withoutQuote[..<endQuote])
        } else {
            // Non-quoted value
            let endChars = trimmed.firstIndex(where: { $0 == "," || $0 == "}" || $0.isWhitespace }) ?? trimmed.endIndex
            modelID = String(trimmed[..<endChars])
        }

        // Route through the daemon's router
        do {
            let router = BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "gateway-router")
            )
            let route = try await router.route(modelName: modelID)

            // Build a proxied response indicator — actual proxying requires an HTTP client
            // which the daemon doesn't include yet. For now return the route metadata
            // so external clients know which provider/account to use.
            let response = """
            {"id":"gw-\(UUID().uuidString.prefix(8))","object":"chat.completion","model":"\(route.resolvedModelID)","provider_id":"\(route.providerID)","base_url":"\(route.baseURL)","credential_slot":"\(route.credentialSlotID ?? "default")","created":\(Int(Date().timeIntervalSince1970)),"choices":[]}
            """
            return (200, response)
        } catch {
            logger.error("gateway_route_error", metadata: ["model": modelID, "error": "\(error)"])
            return (502, "{\"error\":\"routing failed: \(error.localizedDescription)\"}")
        }
    }

    // MARK: - HTTP I/O

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String?
    }

    private func readRequest(socket: Int32) -> HTTPRequest? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(socket, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return nil }

        let data = Data(buffer[..<bytesRead])
        guard let rawRequest = String(data: data, encoding: .utf8) else { return nil }

        let lines = rawRequest.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        var bodyStart = -1
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty {
                bodyStart = i + 1
                break
            }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[colonIdx...].dropFirst().trimmingCharacters(in: .whitespaces)
                headers[key] = String(value)
            }
        }

        let body: String? = bodyStart >= 0 && bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\r\n")
            : nil

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func writeResponse(socket: Int32, status: Int, headers: [String: String], body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
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

        let data = response.data(using: .utf8)!
        data.withUnsafeBytes { ptr in
            _ = Darwin.send(socket, ptr.baseAddress, data.count, 0)
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
