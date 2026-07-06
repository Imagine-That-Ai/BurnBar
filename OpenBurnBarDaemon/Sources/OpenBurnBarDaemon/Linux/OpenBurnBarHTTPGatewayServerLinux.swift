#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore

public enum BurnBarHTTPGatewayError: Error, LocalizedError {
    case invalidConfiguration(String)
    case listenerCreationFailed(error: Error)
    case invalidHost(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return detail
        case .listenerCreationFailed(let error):
            return "Failed to create gateway listener: \(error.localizedDescription)"
        case .invalidHost(let host):
            return "Invalid gateway host address: \(host)"
        }
    }
}

/// Linux loopback HTTP gateway for the daemon package.
///
/// This intentionally keeps the public daemon-facing surface of the
/// Network.framework gateway while using POSIX sockets on Linux. Provider
/// routing remains daemon-owned; unauthenticated or non-loopback exposure fails
/// before the socket is bound.
public actor BurnBarHTTPGatewayServer {
    public static let defaultModelCatalogCacheTTL: TimeInterval = 45

    let configuration: BurnBarGatewayConfiguration
    let configStore: BurnBarConfigStore
    let logger: any BurnBarDaemonLogging
    let rateLimiter: BurnBarRateLimiter?
    let unauthenticatedLoopbackRateLimiter: BurnBarRateLimiter?

    private var listenerFileDescriptor: Int32?
    private var acceptLoopTask: Task<Void, Never>?

    public init(
        configuration: BurnBarGatewayConfiguration,
        configStore: BurnBarConfigStore,
        usageRecorder: BurnBarUsageRecorder? = nil,
        proxyRouteLogStore: BurnBarProxyRouteLogStore? = nil,
        modelCatalogCacheTTL: TimeInterval = 0,
        logger: any BurnBarDaemonLogging = BurnBarDaemonLogger(category: "http-gateway"),
        rateLimiter: BurnBarRateLimiter? = nil
    ) {
        _ = usageRecorder
        _ = proxyRouteLogStore
        _ = modelCatalogCacheTTL
        self.configuration = configuration
        self.configStore = configStore
        self.logger = logger
        self.rateLimiter = rateLimiter ?? configuration.rateLimit.map {
            BurnBarRateLimiter(configuration: $0)
        }
        self.unauthenticatedLoopbackRateLimiter = configuration
            .effectiveUnauthenticatedLoopbackRateLimit
            .map { BurnBarRateLimiter(configuration: $0) }
    }

    public func start() throws {
        guard listenerFileDescriptor == nil else { return }
        guard configuration.isEnabled else {
            logger.debug("gateway_disabled", metadata: [:])
            return
        }
        if let error = configuration.validationError {
            logger.error("gateway_config_invalid", metadata: ["error": error])
            throw BurnBarHTTPGatewayError.invalidConfiguration(error)
        }
        guard configuration.isLoopback else {
            let detail = "Linux gateway refuses non-loopback bind address '\(configuration.host)'."
            logger.error("gateway_config_invalid", metadata: ["error": detail])
            throw BurnBarHTTPGatewayError.invalidConfiguration(detail)
        }
        guard configuration.normalizedHost != "::1" else {
            let detail = "Linux gateway currently supports IPv4 loopback binds only; use 127.0.0.1 or localhost."
            logger.error("gateway_config_invalid", metadata: ["error": detail])
            throw BurnBarHTTPGatewayError.invalidConfiguration(detail)
        }

        let fileDescriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        do {
            var one: Int32 = 1
            setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            configureIOTimeouts(for: fileDescriptor)

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(configuration.port).bigEndian
            address.sin_addr = loopbackAddress(for: configuration.normalizedHost)

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Glibc.bind(fileDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
            guard bindResult == 0 else {
                let code = errno
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            guard Glibc.listen(fileDescriptor, SOMAXCONN) == 0 else {
                let code = errno
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }

            listenerFileDescriptor = fileDescriptor
            let logger = self.logger
            acceptLoopTask = Task.detached(priority: .utility) { [weak self, logger] in
                guard let server = self else { return }
                await Self.runAcceptLoop(
                    listenerFileDescriptor: fileDescriptor,
                    logger: logger
                ) { client in
                    Task.detached(priority: .utility) { [server] in
                        await server.handleClient(fileDescriptor: client)
                    }
                }
            }

            BurnBarDaemonMetricsCounters.recordGatewayListenerReady()
            let authEnforced = configuration.isAuthEnforced
            logger.notice("gateway_started", metadata: [
                "host": configuration.normalizedHost,
                "port": "\(configuration.port)",
                "auth_required": "\(authEnforced)"
            ])
            if !authEnforced {
                logger.warning("gateway_auth_disabled_loopback", metadata: [
                    "host": configuration.normalizedHost,
                    "port": "\(configuration.port)",
                    "is_loopback": "\(configuration.isLoopback)",
                    "allow_unauthenticated_loopback": "\(configuration.allowUnauthenticatedLoopback)"
                ])
            }
        } catch {
            close(fileDescriptor)
            let reason = "gateway listener on \(configuration.normalizedHost):\(configuration.port) failed: \(error.localizedDescription)"
            BurnBarDaemonMetricsCounters.recordGatewayListenerFailure(reason)
            logger.error("gateway_listener_failed", metadata: [
                "host": configuration.normalizedHost,
                "port": "\(configuration.port)",
                "reason": reason,
                "error": "\(error)"
            ])
            throw BurnBarHTTPGatewayError.listenerCreationFailed(error: error)
        }
    }

    public func stop() {
        guard let listenerFileDescriptor else {
            return
        }
        self.listenerFileDescriptor = nil
        acceptLoopTask?.cancel()
        acceptLoopTask = nil
        _ = Glibc.shutdown(listenerFileDescriptor, Int32(SHUT_RDWR))
        close(listenerFileDescriptor)
        logger.notice("gateway_stopped", metadata: [:])
    }

    private nonisolated static func runAcceptLoop(
        listenerFileDescriptor: Int32,
        logger: any BurnBarDaemonLogging,
        handleClient: @escaping @Sendable (Int32) -> Void
    ) async {
        while !Task.isCancelled {
            let client = accept(listenerFileDescriptor, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                if errno == EBADF || errno == EINVAL || Task.isCancelled {
                    break
                }
                logger.error("gateway_accept_failed", metadata: ["errno": "\(errno)"])
                continue
            }

            handleClient(client)
        }
    }

    private func handleClient(fileDescriptor: Int32) async {
        defer { close(fileDescriptor) }
        configureIOTimeouts(for: fileDescriptor)

        do {
            let data = try readHTTPRequest(from: fileDescriptor)
            let request = parseRequest(data)
            let response = await handleRequest(request)
            try writeAll(response, to: fileDescriptor)
        } catch {
            let body = #"{"error":{"message":"bad request"}}"#
            let response = httpResponse(status: 400, headers: ["Content-Type": "application/json"], body: body)
            try? writeAll(response, to: fileDescriptor)
        }
    }

    private func handleRequest(_ request: LinuxHTTPRequest) async -> Data {
        if let requiredToken = configuration.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            guard let provided = gatewayAuthToken(from: request.headers),
                  constantTimeTokensEqual(provided, requiredToken) else {
                logger.warning("gateway_request_unauthorized", metadata: ["path": request.path])
                return httpResponse(
                    status: 401,
                    headers: ["Content-Type": "application/json"],
                    body: #"{"error":{"message":"unauthorized"}}"#
                )
            }
        } else if let unauthenticatedLoopbackRateLimiter {
            let limitResult = await unauthenticatedLoopbackRateLimiter.checkLimit(clientKey: "unauthenticated-loopback")
            if case .throttled(let retryAfter) = limitResult {
                return httpResponse(
                    status: 429,
                    headers: [
                        "Content-Type": "application/json",
                        "Retry-After": String(format: "%.1f", retryAfter)
                    ],
                    body: #"{"error":{"message":"rate limit exceeded"}}"#
                )
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            return httpResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"ok":true,"gateway":"openburnbar","platform":"linux"}"#
            )
        case ("GET", "/metrics"):
            let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: configuration.isEnabled)
            let body = (try? String(data: JSONEncoder().encode(snapshot), encoding: .utf8)) ?? #"{"gatewayEnabled":true}"#
            return httpResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
        case ("GET", "/v1/models"):
            return httpResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"object":"list","data":[]}"#
            )
        case ("POST", "/v1/chat/completions"), ("POST", "/v1/responses"), ("POST", "/v1/messages"):
            return httpResponse(
                status: 503,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":{"message":"No Linux gateway provider route is configured for this request.","type":"openburnbar_no_route"}}"#
            )
        default:
            return httpResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":{"message":"not found"}}"#
            )
        }
    }

    private func gatewayAuthToken(from headers: [String: String]) -> String? {
        if let authorization = headers["authorization"] {
            let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }
        }
        return headers["x-api-key"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private nonisolated func loopbackAddress(for host: String) -> in_addr {
        var address = in_addr()
        if host == "localhost" {
            inet_pton(AF_INET, "127.0.0.1", &address)
        } else {
            let parsed = inet_pton(AF_INET, host, &address)
            precondition(parsed == 1, "Linux gateway only binds IPv4 loopback hosts")
        }
        return address
    }

    private nonisolated func configureIOTimeouts(for fileDescriptor: Int32, seconds: Int = 30) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

private struct LinuxHTTPRequest {
    var method: String = "GET"
    var path: String = "/"
    var headers: [String: String] = [:]
    var body: Data = Data()
}

private func readHTTPRequest(from fileDescriptor: Int32, maxBytes: Int = 1_048_576) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < maxBytes {
        let count = read(fileDescriptor, &buffer, buffer.count)
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        data.append(contentsOf: buffer.prefix(count))
        if let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
            let contentLength = parsedContentLength(from: head)
            let bodyStart = headerEnd.upperBound
            if data.count >= bodyStart + contentLength {
                break
            }
        }
    }
    return data
}

private func parsedContentLength(from head: String) -> Int {
    for line in head.components(separatedBy: "\r\n").dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].lowercased() == "content-length" {
            return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
    }
    return 0
}

private func parseRequest(_ data: Data) -> LinuxHTTPRequest {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
        return LinuxHTTPRequest()
    }
    let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let start = lines.isEmpty ? "" : lines.removeFirst()
    let startParts = start.split(separator: " ").map(String.init)
    var request = LinuxHTTPRequest()
    if startParts.count >= 2 {
        request.method = startParts[0].uppercased()
        request.path = startParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    }
    for line in lines {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        request.headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    request.body = data[headerEnd.upperBound...]
    return request
}

private func httpResponse(status: Int, headers: [String: String], body: String) -> Data {
    let bodyData = Data(body.utf8)
    var responseHeaders = headers
    responseHeaders["Content-Length"] = "\(bodyData.count)"
    responseHeaders["Connection"] = "close"
    let head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        + responseHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        + "\r\n\r\n"
    return Data(head.utf8) + bodyData
}

private func statusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 429: return "Too Many Requests"
    case 503: return "Service Unavailable"
    default: return "OK"
    }
}

private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        var offset = 0
        while remaining > 0 {
            let wrote = send(fileDescriptor, baseAddress.advanced(by: offset), remaining, Int32(MSG_NOSIGNAL))
            if wrote < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard wrote > 0 else { throw POSIXError(.EIO) }
            remaining -= wrote
            offset += wrote
        }
    }
}
#endif
