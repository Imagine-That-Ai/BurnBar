#if os(Linux)
// cov:ignore-start -- reason: Linux-only gateway paths are exercised by the Linux gateway suite, not macOS package coverage.
import Foundation
import Glibc
import OpenBurnBarEngine
import OpenBurnBarKernel

public enum BurnBarHTTPGatewayError: Error, LocalizedError {
    case invalidConfiguration(String)
    case listenerCreationFailed(error: Error)
    case invalidHost(String)
    case malformedRequest(String)
    case requestTooLarge(maxBytes: Int)
    case unsupportedTransferEncoding(String)
    case incompleteRequest

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return detail
        case .listenerCreationFailed(let error):
            return "Failed to create gateway listener: \(error.localizedDescription)"
        case .invalidHost(let host):
            return "Invalid gateway host address: \(host)"
        case .malformedRequest(let detail):
            return "Malformed gateway request: \(detail)"
        case .requestTooLarge(let maxBytes):
            return "Gateway request exceeds the maximum size of \(maxBytes) bytes."
        case .unsupportedTransferEncoding(let encoding):
            return "Gateway does not support transfer encoding '\(encoding)'."
        case .incompleteRequest:
            return "Gateway request ended before the declared body was received."
        }
    }

    fileprivate var httpStatus: Int {
        switch self {
        case .requestTooLarge:
            return 413
        case .unsupportedTransferEncoding:
            return 501
        case .malformedRequest, .incompleteRequest:
            return 400
        case .invalidConfiguration, .listenerCreationFailed, .invalidHost:
            return 500
        }
    }

    fileprivate var responseCode: String {
        switch self {
        case .requestTooLarge: return "request_too_large"
        case .unsupportedTransferEncoding: return "unsupported_transfer_encoding"
        case .incompleteRequest: return "incomplete_request"
        case .malformedRequest: return "malformed_request"
        case .invalidConfiguration, .listenerCreationFailed, .invalidHost:
            return "gateway_error"
        }
    }
}

/// Structured, non-secret failure returned when no healthy route remains.
///
/// This is deliberately separate from an upstream provider error: callers can
/// distinguish a local routing/degraded state from a provider response without
/// receiving credentials, endpoint URLs, or raw upstream payloads.
public enum BurnBarHTTPGatewayDegradedError: Error, LocalizedError, Sendable {
    case noEligibleRoute(modelID: String, endpoint: String)
    case routeCoolingDown(modelID: String, providerID: String, retryAfter: TimeInterval)
    case upstreamUnavailable(modelID: String, providerID: String?, statusCode: Int?)

    public var code: String {
        switch self {
        case .noEligibleRoute: return "no_eligible_route"
        case .routeCoolingDown: return "route_cooling_down"
        case .upstreamUnavailable: return "upstream_unavailable"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noEligibleRoute(let modelID, let endpoint):
            return "No healthy route is available for \(modelID) on \(endpoint)."
        case .routeCoolingDown(let modelID, let providerID, let retryAfter):
            return "Route \(providerID) for \(modelID) is cooling down; retry in \(max(0, Int(ceil(retryAfter)))) seconds."
        case .upstreamUnavailable(let modelID, let providerID, let statusCode):
            let provider = providerID.map { " from \($0)" } ?? ""
            if let statusCode {
                return "Upstream route\(provider) for \(modelID) is unavailable (HTTP \(statusCode))."
            }
            return "Upstream route\(provider) for \(modelID) is unavailable."
        }
    }

    fileprivate var modelID: String {
        switch self {
        case .noEligibleRoute(let modelID, _),
             .routeCoolingDown(let modelID, _, _),
             .upstreamUnavailable(let modelID, _, _):
            return modelID
        }
    }

    fileprivate var retryAfter: TimeInterval? {
        if case .routeCoolingDown(_, _, let retryAfter) = self {
            return retryAfter
        }
        return nil
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
    /// Accommodates one bounded Linux chat attachment plus the prompt while
    /// keeping the loopback HTTP boundary explicitly finite.
    fileprivate static let maxRequestBytes = 16 * 1024 * 1024

    let configuration: BurnBarGatewayConfiguration
    let configStore: BurnBarConfigStore
    let usageRecorder: BurnBarUsageRecorder?
    let proxyRouteLogStore: BurnBarProxyRouteLogStore?
    let quotaSignalStore: BurnBarQuotaSignalStore?
    let providerExecutor: BurnBarOpenAICompatibleProviderExecutor
    let anthropicExecutor: BurnBarAnthropicProviderExecutor
    let factoryExecutor: FactoryDroidProviderExecutor
    let modelHealthStore: BurnBarGatewayModelHealthStore
    let logger: any BurnBarDaemonLogging
    /// Memory Pro egress gate; nil means memory-purpose requests are refused.
    /// Parity with the Darwin gateway: the daemon wires the same enforcer on
    /// both platforms so a `memory-*` purpose never bypasses policy on Linux.
    let memoryEgress: BurnBarMemoryEgressEnforcer?
    let rateLimiter: BurnBarRateLimiter?
    let unauthenticatedLoopbackRateLimiter: BurnBarRateLimiter?

    private let modelCatalogCacheTTL: TimeInterval
    private var modelCatalogCache: LinuxModelCatalogCache?

    private var listenerFileDescriptor: Int32?
    private var acceptLoopTask: Task<Void, Never>?

    public init(
        configuration: BurnBarGatewayConfiguration,
        configStore: BurnBarConfigStore,
        usageRecorder: BurnBarUsageRecorder? = nil,
        proxyRouteLogStore: BurnBarProxyRouteLogStore? = nil,
        quotaSignalStore: BurnBarQuotaSignalStore? = nil,
        providerExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        anthropicExecutor: BurnBarAnthropicProviderExecutor = BurnBarAnthropicProviderExecutor(),
        factoryExecutor: FactoryDroidProviderExecutor = FactoryDroidProviderExecutor(),
        modelHealthStore: BurnBarGatewayModelHealthStore = BurnBarGatewayModelHealthStore(),
        modelCatalogCacheTTL: TimeInterval = 0,
        logger: any BurnBarDaemonLogging = BurnBarDaemonLogger(category: "http-gateway"),
        memoryEgress: BurnBarMemoryEgressEnforcer? = nil,
        rateLimiter: BurnBarRateLimiter? = nil
    ) {
        self.configuration = configuration
        self.configStore = configStore
        self.usageRecorder = usageRecorder
        self.proxyRouteLogStore = proxyRouteLogStore
        self.quotaSignalStore = quotaSignalStore
        self.providerExecutor = providerExecutor
        self.anthropicExecutor = anthropicExecutor
        self.factoryExecutor = factoryExecutor
        self.modelHealthStore = modelHealthStore
        self.modelCatalogCacheTTL = max(0, modelCatalogCacheTTL)
        self.logger = logger
        self.memoryEgress = memoryEgress
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
        let isIPv6Loopback = configuration.normalizedHost == "::1"
        let socketFamily = isIPv6Loopback ? AF_INET6 : AF_INET
        let fileDescriptor = Glibc.socket(socketFamily, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        do {
            var one: Int32 = 1
            setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            configureIOTimeouts(for: fileDescriptor)

            let bindResult: Int32
            if isIPv6Loopback {
                // Keep the IPv6 listener v6-only. The gateway binds a specific
                // loopback address, so accepting IPv4-mapped connections here
                // would make the address-family policy implicit and platform-
                // dependent. IPv4 callers continue using the AF_INET path.
                var v6Only: Int32 = 1
                guard setsockopt(
                    fileDescriptor,
                    Int32(IPPROTO_IPV6),
                    IPV6_V6ONLY,
                    &v6Only,
                    socklen_t(MemoryLayout<Int32>.size)
                ) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }

                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = UInt16(configuration.port).bigEndian
                guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else {
                    throw BurnBarHTTPGatewayError.invalidHost(configuration.normalizedHost)
                }
                bindResult = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                        Glibc.bind(fileDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_in6>.stride))
                    }
                }
            } else {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(configuration.port).bigEndian
                address.sin_addr = loopbackAddress(for: configuration.normalizedHost)
                bindResult = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                        Glibc.bind(fileDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
                    }
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
            let request = try parseRequest(data)
            switch await handleRequest(request, fileDescriptor: fileDescriptor) {
            case .buffered(let response):
                try writeAll(response, to: fileDescriptor)
            case .streamed:
                break
            }
        } catch let error as BurnBarHTTPGatewayError {
            let response = typedGatewayErrorResponse(error)
            try? writeAll(response, to: fileDescriptor)
        } catch {
            let body = #"{"error":{"code":"bad_request","message":"bad request"}}"#
            let response = httpResponse(status: 400, headers: ["Content-Type": "application/json"], body: body)
            try? writeAll(response, to: fileDescriptor)
        }
    }

    /// Keep the Linux gateway's browser-facing loopback contract aligned with
    /// the Network.framework implementation on macOS. Only local origins are
    /// reflected; arbitrary origins never receive an allow-origin header.
    private func corsHeaders(for request: LinuxHTTPRequest) -> [String: String] {
        guard let origin = request.headers["origin"], isAllowedCORSOrigin(origin) else {
            return [:]
        }
        return [
            "Access-Control-Allow-Origin": origin,
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, x-api-key",
            "Vary": "Origin"
        ]
    }

    private func isAllowedCORSOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else {
            return false
        }
        // swift-corelibs-foundation may preserve the brackets around an IPv6
        // URL host even though Darwin Foundation returns the unbracketed form.
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private func addingCORSHeaders(
        to response: LinuxGatewayResponse,
        headers: [String: String]
    ) -> LinuxGatewayResponse {
        guard !headers.isEmpty else { return response }
        switch response {
        case .buffered(let data):
            return .buffered(insertingHeaders(headers, into: data))
        case .streamed:
            // Streaming responses add the headers before writing the first
            // upstream chunk in `relayStream`.
            return .streamed
        }
    }

    private func handleRequest(_ request: LinuxHTTPRequest, fileDescriptor: Int32) async -> LinuxGatewayResponse {
        let cors = corsHeaders(for: request)
        if request.method == "OPTIONS" {
            return .buffered(httpResponse(status: 204, headers: cors, body: Data()))
        }

        let staticToken = configuration.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let purpose = GatewayPurpose(header: request.headers[GatewayPurpose.headerName])
        if let purpose {
            // Memory Pro: a memory-purpose request may present the static token
            // or a scoped token for that purpose, and may only hit the two proxy
            // paths. Everything else is refused before routing — same rule as
            // the Darwin gateway.
            let presented = gatewayAuthToken(from: request.headers)
            var authorized = false
            if let presented, let staticToken, constantTimeTokensEqual(presented, staticToken) {
                authorized = true
            } else if let presented, let memoryEgress {
                authorized = await memoryEgress.validateToken(presented, purpose: purpose)
            }
            guard authorized, BurnBarMemoryEgressEnforcer.allowedPaths.contains(request.path) else {
                logger.warning("gateway_request_unauthorized", metadata: ["path": request.path, "purpose": purpose.rawValue])
                return .buffered(httpResponse(
                    status: 401,
                    headers: ["Content-Type": "application/json"],
                    body: #"{"error":{"message":"unauthorized"}}"#
                ))
            }
        } else if let requiredToken = staticToken {
            guard let provided = gatewayAuthToken(from: request.headers),
                  constantTimeTokensEqual(provided, requiredToken) else {
                logger.warning("gateway_request_unauthorized", metadata: ["path": request.path])
                return .buffered(httpResponse(
                    status: 401,
                    headers: ["Content-Type": "application/json"],
                    body: #"{"error":{"message":"unauthorized"}}"#
                ))
            }
        } else if let unauthenticatedLoopbackRateLimiter {
            let limitResult = await unauthenticatedLoopbackRateLimiter.checkLimit(clientKey: "unauthenticated-loopback")
            if case .throttled(let retryAfter) = limitResult {
                return .buffered(httpResponse(
                    status: 429,
                    headers: [
                        "Content-Type": "application/json",
                        "Retry-After": String(format: "%.1f", retryAfter)
                    ],
                    body: #"{"error":{"message":"rate limit exceeded"}}"#
                ))
            }
        }

        let response: LinuxGatewayResponse
        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            response = .buffered(httpResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"ok":true,"gateway":"openburnbar","platform":"linux"}"#
            ))
        case ("GET", "/metrics"):
            let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: configuration.isEnabled)
            let body = (try? String(data: JSONEncoder().encode(snapshot), encoding: .utf8)) ?? #"{"gatewayEnabled":true}"#
            response = .buffered(httpResponse(status: 200, headers: ["Content-Type": "application/json"], body: body))
        case ("GET", "/v1/models"):
            response = .buffered(await linuxModelsListResponse(catalog: false))
        case ("GET", "/v1/models/catalog"):
            response = .buffered(await linuxModelsListResponse(catalog: true))
        case ("POST", "/v1/chat/completions"):
            response = await handleModelEndpoint(.chatCompletions, request: request, purpose: purpose, fileDescriptor: fileDescriptor, corsHeaders: cors)
        case ("POST", "/v1/embeddings"):
            response = .buffered(jsonResponse(status: 501, message: "embeddings are not available on the Linux gateway yet"))
        case ("POST", "/v1/responses"):
            response = await handleModelEndpoint(.responses, request: request, purpose: purpose, fileDescriptor: fileDescriptor, corsHeaders: cors)
        case ("POST", "/v1/messages"):
            response = await handleModelEndpoint(.anthropicMessages, request: request, purpose: purpose, fileDescriptor: fileDescriptor, corsHeaders: cors)
        default:
            response = .buffered(httpResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":{"message":"not found"}}"#
            ))
        }
        return addingCORSHeaders(to: response, headers: cors)
    }

    private func handleModelEndpoint(
        _ endpoint: LinuxGatewayEndpoint,
        request: LinuxHTTPRequest,
        purpose: GatewayPurpose?,
        fileDescriptor: Int32,
        corsHeaders: [String: String]
    ) async -> LinuxGatewayResponse {
        let startedAt = Date()
        let clientExecutionSource = UsageExecutionSourceResolver.fromClientMarker(
            request.headers["x-openburnbar-client"],
            allowCustom: true
        ) ?? UsageExecutionSourceResolver.fromClientMarker(
            request.headers["user-agent"]
        ) ?? .unknown
        // Memory Pro spend is attributed to its own execution source so the
        // daily cap reads the right ledger rows (Darwin parity).
        let executionSource = purpose == nil ? clientExecutionSource : BurnBarMemoryEgressEnforcer.executionSource
        guard !request.body.isEmpty else {
            return .buffered(jsonResponse(status: 400, message: "request body required"))
        }
        let decoded: LinuxGatewayModelRequest
        do {
            decoded = try JSONDecoder().decode(LinuxGatewayModelRequest.self, from: request.body)
        } catch {
            return .buffered(jsonResponse(status: 400, message: "invalid JSON request body"))
        }
        let clientModelID = (decoded.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientModelID.isEmpty else {
            return .buffered(jsonResponse(status: 400, message: "model field required"))
        }
        let resolvedModel = await resolveLinuxGatewayModel(clientModelID)
        let modelID = resolvedModel.modelID

        let accountingRequestID = UUID().uuidString
        let router = BurnBarProviderRouter(
            configStore: configStore,
            logger: BurnBarDaemonLogger(category: "gateway-router-linux"),
            routingEventStore: BurnBarProviderRoutingDecisionEventStore(),
            allowDynamicOpenAICompatibleModels: true
        )
        let formatFamilies = preferredGatewayFormatFamilies(for: modelID, endpoint: endpoint)
        var lastFailedRoute: BurnBarProviderRoute?
        var attempts: [BurnBarProxyRouteAttempt] = []
        let streamCommit = LinuxGatewayStreamCommit()

        do {
            for formatFamily in formatFamilies {
                let ranking = try await router.scoreAndRankRoutes(
                    modelName: modelID,
                    preferredProviderID: resolvedModel.preferredProviderID,
                    requestedFormatFamily: formatFamily
                )
                await router.persistDecisionIfNeeded(ranking: ranking, modelName: modelID)
                let routes = ranking.rankedRoutes.map(\.route)
                guard !routes.isEmpty else { continue }

                for (index, route) in routes.enumerated() {
                    let attemptStartedAt = Date()
                    if let purpose {
                        // Policy gate runs per route so a fail-over candidate is
                        // judged on its own provider, never the first one's.
                        if let denial = await memoryEgressDenial(purpose: purpose, route: route, requestBytes: request.body.count) {
                            return .buffered(memoryEgressDenialResponse(denial))
                        }
                    }
                    do {
                        // Memory-purpose requests are always buffered: the
                        // egress chain needs the response size, and Darwin
                        // never relays SSE for them either.
                        if purpose == nil,
                           decoded.stream == true,
                           let streamPlan = streamPlan(
                            for: route,
                            formatFamily: formatFamily,
                            endpoint: endpoint,
                            body: request.body
                           ) {
                            do {
                                let proxyStream = try await streamPlan.open(resolvedModel.variant)
                                let relay = try await relayStream(
                                    proxyStream,
                                    usageFormat: streamPlan.usageFormat,
                                    route: route,
                                    accountingRequestID: accountingRequestID,
                                    executionSource: executionSource,
                                    streamCommit: streamCommit,
                                    fileDescriptor: fileDescriptor,
                                    corsHeaders: corsHeaders
                                )
                                await recordQuotaSignalIfAvailable(
                                    headers: proxyStream.headers,
                                    route: route,
                                    requestPath: endpoint.requestPath,
                                    endpoint: endpoint.displayName,
                                    httpStatus: proxyStream.statusCode,
                                    streamed: true
                                )
                                await modelHealthStore.recordSuccess(
                                    modelID: modelID,
                                    formatFamily: formatFamily,
                                    route: route
                                )
                                let streamStatus = BurnBarProxyRouteFinalStatus.streamRelayOutcome(
                                    interrupted: relay.interrupted
                                )
                                attempts.append(routeAttempt(
                                    sequence: attempts.count + 1,
                                    startedAt: attemptStartedAt,
                                    completedAt: Date(),
                                    route: route,
                                    status: streamStatus,
                                    httpStatus: proxyStream.statusCode
                                ))
                                await recordProxyRouteLogEntry(
                                    startedAt: startedAt,
                                    modelID: clientModelID,
                                    endpoint: endpoint,
                                    route: route,
                                    finalStatus: streamStatus,
                                    streamed: true,
                                    httpStatus: proxyStream.statusCode,
                                    attempts: attempts,
                                    usage: relay.usage,
                                    streamInterrupted: relay.interrupted
                                )
                                return .streamed
                            } catch is BurnBarProxyStreamingUnsupported {
                                // Provider can serve the route, just not as SSE.
                                // Fall through to the buffered proxy below.
                            }
                        }

                        let response: BurnBarProviderProxyResponse
                        do {
                            response = try await proxyEndpoint(
                                body: request.body,
                                route: route,
                                endpoint: endpoint,
                                formatFamily: formatFamily,
                                variant: resolvedModel.variant
                            )
                        } catch {
                            // The request left the machine; the content-free
                            // chain records the attempt even when upstream failed.
                            if let purpose, let memoryEgress {
                                await memoryEgress.record(
                                    purpose: purpose, providerID: route.providerID, modelID: route.resolvedModelID,
                                    requestBytes: request.body.count, responseBytes: 0, outcome: "failed",
                                    code: Self.memoryEgressFailureCode(error),
                                    latencyMs: Int(Date().timeIntervalSince(attemptStartedAt) * 1_000)
                                )
                            }
                            throw error
                        }
                        if let purpose, let memoryEgress {
                            await memoryEgress.record(
                                purpose: purpose, providerID: route.providerID, modelID: route.resolvedModelID,
                                requestBytes: request.body.count, responseBytes: response.body.count, outcome: "allowed", code: nil,
                                latencyMs: Int(Date().timeIntervalSince(attemptStartedAt) * 1_000)
                            )
                        }
                        await recordQuotaSignalIfAvailable(
                            headers: response.headers,
                            route: route,
                            requestPath: endpoint.requestPath,
                            endpoint: endpoint.displayName,
                            httpStatus: response.statusCode,
                            streamed: false
                        )
                        await modelHealthStore.recordSuccess(
                            modelID: modelID,
                            formatFamily: formatFamily,
                            route: route
                        )
                        await recordUsageIfAvailable(
                            response.usage,
                            route: route,
                            idempotencyKey: usageIdempotencyKey(accountingRequestID: accountingRequestID, route: route),
                            executionSource: executionSource
                        )
                        attempts.append(routeAttempt(
                            sequence: attempts.count + 1,
                            startedAt: attemptStartedAt,
                            completedAt: Date(),
                            route: route,
                            status: .exact,
                            httpStatus: response.statusCode
                        ))
                        await recordProxyRouteLogEntry(
                            startedAt: startedAt,
                            modelID: clientModelID,
                            endpoint: endpoint,
                            route: route,
                            finalStatus: .exact,
                            streamed: false,
                            httpStatus: response.statusCode,
                            attempts: attempts,
                            usage: response.usage
                        )
                        return .buffered(httpResponse(
                            status: response.statusCode,
                            headers: ["Content-Type": response.contentType],
                            body: response.body
                        ))
                    } catch {
                        lastFailedRoute = route
                        if let providerError = error as? BurnBarProviderExecutorError,
                           !providerError.upstreamHeaders.isEmpty {
                            await recordQuotaSignalIfAvailable(
                                headers: providerError.upstreamHeaders,
                                route: route,
                                requestPath: endpoint.requestPath,
                                endpoint: endpoint.displayName,
                                httpStatus: Self.httpStatus(from: error),
                                streamed: streamCommit.responseStarted
                            )
                        }
                        if streamCommit.responseStarted {
                            // The response head was already committed to the
                            // client when this attempt broke (mid-stream body
                            // errors are absorbed inside `relayStream`; this
                            // path means the client-side write itself failed).
                            // That is an interruption of delivery, not a
                            // provider failure: record first-class
                            // `interrupted` status and leave route health
                            // untouched, matching the macOS gateway.
                            logger.error("gateway_linux_stream_interrupted", metadata: [
                                "model": modelID,
                                "provider_id": route.providerID,
                                "error": "\(error)"
                            ])
                            let interruptedStatus = BurnBarProxyRouteFinalStatus.streamRelayOutcome(
                                interrupted: true
                            )
                            attempts.append(routeAttempt(
                                sequence: attempts.count + 1,
                                startedAt: attemptStartedAt,
                                completedAt: Date(),
                                route: route,
                                status: interruptedStatus,
                                httpStatus: Self.httpStatus(from: error),
                                failureMessage: Self.routeLogFailureMessage(from: error)
                            ))
                            await recordProxyRouteLogEntry(
                                startedAt: startedAt,
                                modelID: clientModelID,
                                endpoint: endpoint,
                                route: route,
                                finalStatus: interruptedStatus,
                                streamed: true,
                                httpStatus: Self.httpStatus(from: error) ?? 502,
                                attempts: attempts,
                                usage: nil,
                                streamInterrupted: true,
                                failureMessage: Self.routeLogFailureMessage(from: error)
                            )
                            return .streamed
                        }
                        attempts.append(routeAttempt(
                            sequence: attempts.count + 1,
                            startedAt: attemptStartedAt,
                            completedAt: Date(),
                            route: route,
                            status: .failed,
                            httpStatus: Self.httpStatus(from: error),
                            failureMessage: Self.routeLogFailureMessage(from: error)
                        ))
                        await modelHealthStore.recordFailure(
                            modelID: modelID,
                            formatFamily: formatFamily,
                            route: route,
                            error: error
                        )
                        await router.markRouteFailure(route, error: error)
                        if index < routes.count - 1, shouldFailOverProviderError(error) {
                            continue
                        }
                        throw error
                    }
                }
            }

            await recordProxyRouteLogEntry(
                startedAt: startedAt,
                modelID: clientModelID,
                endpoint: endpoint,
                route: nil,
                finalStatus: .rejected,
                streamed: false,
                httpStatus: 503,
                attempts: attempts,
                usage: nil,
                failureMessage: "No eligible route for \(modelID) on \(endpoint.requestPath)."
            )
            return .buffered(noEligibleRouteResponse(modelID: modelID, endpoint: endpoint))
        } catch let error as BurnBarProviderRouterError {
            logger.error("gateway_linux_route_error", metadata: ["model": modelID, "error": "\(error)"])
            await recordProxyRouteLogEntry(
                startedAt: startedAt,
                modelID: clientModelID,
                endpoint: endpoint,
                route: nil,
                finalStatus: .rejected,
                streamed: false,
                httpStatus: 503,
                attempts: attempts,
                usage: nil,
                failureMessage: error.localizedDescription
            )
            return .buffered(noEligibleRouteResponse(modelID: modelID, endpoint: endpoint))
        } catch {
            logger.error("gateway_linux_route_error", metadata: ["model": modelID, "error": "\(error)"])
            await recordProxyRouteLogEntry(
                startedAt: startedAt,
                modelID: clientModelID,
                endpoint: endpoint,
                route: lastFailedRoute,
                finalStatus: .failed,
                streamed: false,
                httpStatus: Self.httpStatus(from: error) ?? 502,
                attempts: attempts,
                usage: nil,
                failureMessage: Self.routeLogFailureMessage(from: error)
            )
            return .buffered(typedDegradedResponse(
                BurnBarHTTPGatewayDegradedError.upstreamUnavailable(
                    modelID: modelID,
                    providerID: lastFailedRoute?.providerID,
                    statusCode: Self.httpStatus(from: error)
                )
            ))
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

    private struct LinuxGatewayResolvedModel {
        var modelID: String
        var variant: BurnBarModelVariant?
        var preferredProviderID: String?
    }

    /// Build OpenAI-compatible `/v1/models` (+ catalog) from one bounded,
    /// shared static snapshot. Health is deliberately checked outside the cache
    /// so a cooldown takes effect immediately without rebuilding provider rows.
    private func linuxModelsListResponse(catalog: Bool) async -> Data {
        guard let models = await linuxModelCatalogModels() else {
            return typedDegradedResponse(
                BurnBarHTTPGatewayDegradedError.upstreamUnavailable(
                    modelID: "catalog",
                    providerID: nil,
                    statusCode: nil
                )
            )
        }

        var data: [[String: Any]] = []
        let now = Date()
        for model in models {
            let health = await modelHealth(for: model)
            // A model remains public while at least one account can route it.
            // An active failure is account-scoped; hiding the model here would
            // defeat failover when a sibling credential is still healthy.
            let available = model.isEnabled && model.routeEligible
            guard catalog || available else { continue }

            var row: [String: Any] = [
                "id": model.id,
                "object": "model",
                "owned_by": model.providerID,
                "created": Int(now.timeIntervalSince1970)
            ]
            if catalog {
                row["provider"] = model.providerID
                row["display_name"] = model.displayName
                row["available"] = available
                row["route_eligible"] = model.routeEligible
                row["advertisement_enabled"] = model.advertisementEnabled
                row["account_ids"] = model.accountIDs
                row["format_family"] = model.formatFamily.rawValue
                if let baseModelID = model.baseModelID {
                    row["base_model"] = baseModelID
                }
                if model.isAlias { row["alias"] = true }
                if model.isVariant { row["variant"] = true }
                if let health {
                    row["degraded"] = true
                    row["degraded_until"] = health.blockedUntil.timeIntervalSince1970
                    row["degraded_status"] = health.statusCode
                } else {
                    row["degraded"] = false
                }
            }
            data.append(row)
        }

        let bodyObj: [String: Any] = [
            "object": "list",
            "data": data,
            "platform": "linux",
            "catalog": catalog,
            "generated_at": now.timeIntervalSince1970
        ]
        let body = (try? JSONSerialization.data(withJSONObject: bodyObj, options: []))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"object":"list","data":[],"platform":"linux"}"#
        return httpResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private func linuxModelCatalogModels() async -> [LinuxGatewayCatalogModel]? {
        guard let snapshot = try? await configStore.snapshot(),
              let configurations = try? await configStore.resolvedConfigurations() else {
            return nil
        }
        let configHash = snapshot.hashValue
        if modelCatalogCacheTTL > 0,
           let cache = modelCatalogCache,
           cache.configurationHash == configHash,
           Date().timeIntervalSince(cache.storedAt) < modelCatalogCacheTTL {
            return cache.models
        }

        var models: [LinuxGatewayCatalogModel] = []
        for configuration in configurations {
            let settings = configuration.settings
            let providerID = settings.providerID
            let accountIDs = routeAccountIDs(for: configuration)
            let formatFamily = configuration.provider.formatFamily
            let providerName = configuration.provider.displayName
            let routeEligible = hasEligibleRoute(for: configuration)
            let baseModels = configuration.preferredModels
            let hiddenBaseIDs = Set(settings.modelAliases.filter { alias in
                alias.hidesBaseModel && settings.isModelAdvertisementEnabled(alias.aliasID)
            }.map { $0.baseModelID.lowercased() })
            var seen = Set<String>()

            for model in baseModels {
                let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty,
                      settings.isModelAdvertisementEnabled(id),
                      !hiddenBaseIDs.contains(id.lowercased()),
                      seen.insert(id.lowercased()).inserted else { continue }
                let displayName = settings.modelDisplayOverrides.first {
                    $0.modelID.caseInsensitiveCompare(id) == .orderedSame
                }?.displayName ?? model.displayName
                models.append(LinuxGatewayCatalogModel(
                    id: id,
                    displayName: displayName,
                    providerID: providerID,
                    providerName: providerName,
                    baseModelID: nil,
                    accountIDs: accountIDs,
                    formatFamily: formatFamily,
                    isEnabled: settings.isEnabled,
                    routeEligible: routeEligible,
                    advertisementEnabled: true,
                    isAlias: false,
                    isVariant: false
                ))
            }

            for variant in settings.modelVariants {
                let id = variant.variantID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty,
                      settings.isModelAdvertisementEnabled(id),
                      seen.insert(id.lowercased()).inserted else { continue }
                models.append(LinuxGatewayCatalogModel(
                    id: id,
                    displayName: variant.label.isEmpty ? id : variant.label,
                    providerID: providerID,
                    providerName: providerName,
                    baseModelID: variant.baseModelID,
                    accountIDs: accountIDs,
                    formatFamily: formatFamily,
                    isEnabled: settings.isEnabled,
                    routeEligible: routeEligible,
                    advertisementEnabled: true,
                    isAlias: false,
                    isVariant: true
                ))
            }

            for alias in settings.modelAliases {
                let id = alias.aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty,
                      settings.isModelAdvertisementEnabled(id),
                      seen.insert(id.lowercased()).inserted else { continue }
                models.append(LinuxGatewayCatalogModel(
                    id: id,
                    displayName: alias.displayName.isEmpty ? id : alias.displayName,
                    providerID: providerID,
                    providerName: providerName,
                    baseModelID: alias.baseModelID,
                    accountIDs: accountIDs,
                    formatFamily: formatFamily,
                    isEnabled: settings.isEnabled,
                    routeEligible: routeEligible,
                    advertisementEnabled: true,
                    isAlias: true,
                    isVariant: false
                ))
            }
        }

        models.sort {
            let provider = $0.providerName.localizedCaseInsensitiveCompare($1.providerName)
            if provider != .orderedSame { return provider == .orderedAscending }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
        if modelCatalogCacheTTL > 0 {
            modelCatalogCache = LinuxModelCatalogCache(
                configurationHash: configHash,
                storedAt: Date(),
                models: models
            )
        }
        return models
    }

    private func routeAccountIDs(
        for configuration: BurnBarResolvedProviderConfiguration
    ) -> [String] {
        if !configuration.credentialSlots.isEmpty {
            return configuration.credentialSlots.compactMap { resolved in
                let slot = resolved.slot
                // Keep configured accounts in the diagnostic catalog even
                // while cooling/exhausted; route eligibility is calculated
                // separately so health remains visible during failover.
                guard slot.isEnabled else { return nil }
                if configuration.provider.local {
                    return slot.slotID
                }
                guard let apiKey = resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !apiKey.isEmpty else { return nil }
                return slot.slotID
            }
        }
        if configuration.provider.local || configuration.hasCredential {
            return ["legacy"]
        }
        return []
    }

    private func hasEligibleRoute(
        for configuration: BurnBarResolvedProviderConfiguration
    ) -> Bool {
        guard configuration.provider.capabilities.contains(.routing),
              configuration.settings.isEnabled else {
            return false
        }
        if !configuration.credentialSlots.isEmpty {
            return configuration.credentialSlots.contains { resolved in
                let hasCredential = configuration.provider.local
                    || (resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                guard hasCredential else { return false }
                return BurnBarProviderCredentialSlotRoutingPolicy.canAttemptRoute(
                    slot: resolved.slot,
                    providerID: configuration.provider.id,
                    hasCredential: hasCredential,
                    providerEnabled: configuration.settings.isEnabled
                )
            }
        }
        return configuration.provider.local || configuration.hasCredential
    }

    private func modelHealth(
        for model: LinuxGatewayCatalogModel
    ) async -> BurnBarGatewayModelHealthRecord? {
        let modelIDs = [model.id, model.baseModelID].compactMap { $0 }
        for modelID in modelIDs {
            for accountID in model.accountIDs {
                if let failure = await modelHealthStore.activeFailure(
                    modelID: modelID,
                    providerID: model.providerID,
                    accountID: accountID,
                    formatFamily: model.formatFamily
                ) {
                    return failure
                }
            }
        }
        return nil
    }

    private func resolveLinuxGatewayModel(_ requested: String) async -> LinuxGatewayResolvedModel {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configurations = try? await configStore.resolvedConfigurations() else {
            return LinuxGatewayResolvedModel(modelID: trimmed, variant: nil, preferredProviderID: nil)
        }

        let (providerHint, modelID) = splitProviderQualifiedModelID(trimmed)
        let candidates = configurations.filter { configuration in
            guard let providerHint else { return true }
            return configuration.provider.id.caseInsensitiveCompare(providerHint) == .orderedSame
        }
        for configuration in candidates {
            if let variant = configuration.settings.modelVariants.first(where: {
                $0.variantID.caseInsensitiveCompare(modelID) == .orderedSame
            }) {
                return LinuxGatewayResolvedModel(
                    modelID: variant.baseModelID,
                    variant: variant,
                    preferredProviderID: configuration.provider.id
                )
            }
            if let alias = configuration.settings.modelAliases.first(where: {
                $0.aliasID.caseInsensitiveCompare(modelID) == .orderedSame
            }) {
                return LinuxGatewayResolvedModel(
                    modelID: alias.baseModelID,
                    variant: nil,
                    preferredProviderID: configuration.provider.id
                )
            }
            if configuration.preferredModels.contains(where: {
                $0.id.caseInsensitiveCompare(modelID) == .orderedSame
                    || $0.aliases.contains(where: { $0.caseInsensitiveCompare(modelID) == .orderedSame })
            }) {
                return LinuxGatewayResolvedModel(
                    modelID: modelID,
                    variant: nil,
                    preferredProviderID: configuration.provider.id
                )
            }
            if configuration.settings.customModels.contains(where: {
                $0.modelID.caseInsensitiveCompare(modelID) == .orderedSame
            }) {
                return LinuxGatewayResolvedModel(
                    modelID: modelID,
                    variant: nil,
                    preferredProviderID: configuration.provider.id
                )
            }
        }
        return LinuxGatewayResolvedModel(modelID: modelID, variant: nil, preferredProviderID: providerHint)
    }

    private func splitProviderQualifiedModelID(_ raw: String) -> (String?, String) {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              configStore.catalogSupport.provider(id: parts[0]) != nil,
              !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, raw)
        }
        return (parts[0], parts[1])
    }

    private func preferredGatewayFormatFamilies(
        for modelID: String,
        endpoint: LinuxGatewayEndpoint
    ) -> [BurnBarProviderFormatFamily] {
        if endpoint == .anthropicMessages {
            return [.anthropic, .openaiCompat]
        }
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("claude") || normalized.contains("anthropic")
            ? [.anthropic, .openaiCompat]
            : [.openaiCompat, .anthropic]
    }

    private func proxyEndpoint(
        body: Data,
        route: BurnBarProviderRoute,
        endpoint: LinuxGatewayEndpoint,
        formatFamily: BurnBarProviderFormatFamily,
        variant: BurnBarModelVariant?
    ) async throws -> BurnBarProviderProxyResponse {
        if route.providerID.caseInsensitiveCompare("factory") == .orderedSame {
            guard endpoint == .chatCompletions else {
                throw BurnBarProxyStreamingUnsupported(reason: "factory-\(endpoint.requestPath)")
            }
            return try await factoryExecutor.proxyChatCompletions(body: body, route: route, variant: variant)
        }
        switch (endpoint, formatFamily) {
        case (.chatCompletions, .openaiCompat):
            return try await providerExecutor.proxyChatCompletions(body: body, route: route, variant: variant)
        case (.chatCompletions, .anthropic):
            return try await anthropicExecutor.proxyChatCompletions(body: body, route: route, variant: variant)
        case (.responses, .openaiCompat):
            return try await providerExecutor.proxyResponses(body: body, route: route, variant: variant)
        case (.responses, .anthropic):
            return try await anthropicExecutor.proxyResponses(body: body, route: route, variant: variant)
        case (.anthropicMessages, .anthropic):
            return try await anthropicExecutor.proxyMessages(body: body, route: route, variant: variant)
        case (.anthropicMessages, .openaiCompat):
            return try await providerExecutor.proxyMessages(body: body, route: route, variant: variant)
        }
    }

    private func streamPlan(
        for route: BurnBarProviderRoute,
        formatFamily: BurnBarProviderFormatFamily,
        endpoint: LinuxGatewayEndpoint,
        body: Data
    ) -> LinuxGatewayStreamPlan? {
        guard route.providerID.caseInsensitiveCompare("factory") != .orderedSame else { return nil }
        switch (endpoint, formatFamily) {
        case (.chatCompletions, .openaiCompat):
            return LinuxGatewayStreamPlan(usageFormat: .openAI) {
                try await self.providerExecutor.openChatCompletionsStream(body: body, route: route, variant: $0)
            }
        case (.chatCompletions, .anthropic):
            return LinuxGatewayStreamPlan(usageFormat: .openAI) {
                try await self.anthropicExecutor.openChatCompletionsStream(body: body, route: route, variant: $0)
            }
        case (.anthropicMessages, .anthropic):
            return LinuxGatewayStreamPlan(usageFormat: .anthropic) {
                try await self.anthropicExecutor.openMessagesStream(body: body, route: route, variant: $0)
            }
        case (.responses, _), (.anthropicMessages, .openaiCompat):
            return nil
        }
    }

    /// Relay result once the response head has been committed to the client.
    /// Mirrors the macOS `GatewayStreamRelayResult` semantics: after commit a
    /// mid-stream error is surfaced as `interrupted` (a delivery interruption,
    /// not a route failure) rather than thrown, so the caller can log
    /// first-class `interrupted` status and still record partial usage.
    private struct LinuxGatewayStreamRelay {
        let usage: BurnBarProviderProxyUsage?
        let interrupted: Bool
    }

    private func relayStream(
        _ proxyStream: BurnBarProviderProxyStream,
        usageFormat: GatewayStreamUsageFormat,
        route: BurnBarProviderRoute,
        accountingRequestID: String,
        executionSource: UsageExecutionSource,
        streamCommit: LinuxGatewayStreamCommit,
        fileDescriptor: Int32,
        corsHeaders: [String: String]
    ) async throws -> LinuxGatewayStreamRelay {
        var headers = [
            "Content-Type": proxyStream.contentType,
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no"
        ]
        for (key, value) in corsHeaders {
            headers[key] = value
        }
        streamCommit.responseStarted = true
        try writeAll(httpResponseHead(status: proxyStream.statusCode, headers: headers), to: fileDescriptor)

        let accumulator = GatewayStreamingUsageAccumulator(format: usageFormat)
        var interrupted = false
        do {
            for try await chunk in proxyStream.chunks {
                accumulator.consume(chunk)
                try writeAll(chunk, to: fileDescriptor)
            }
        } catch {
            // Bytes already flowed to the client; we cannot fail over now.
            // Match the macOS relay: emit a terminal SSE error event (best
            // effort — the client socket itself may be the broken side) and
            // classify the request as interrupted, not failed.
            interrupted = true
            logger.warning("gateway_linux_stream_interrupted", metadata: [
                "provider": route.providerID,
                "error": "\(error)"
            ])
            let errorEvent = "event: error\ndata: {\"error\":{\"message\":\"upstream stream interrupted\"}}\n\n"
            try? writeAll(Data(errorEvent.utf8), to: fileDescriptor)
        }
        // Interrupted usage is still real spend: tokens observed before the
        // interruption were consumed upstream and must hit the local ledger.
        let usage = accumulator.finalize()
        await recordUsageIfAvailable(
            usage,
            route: route,
            idempotencyKey: usageIdempotencyKey(accountingRequestID: accountingRequestID, route: route),
            executionSource: executionSource
        )
        return LinuxGatewayStreamRelay(usage: usage, interrupted: interrupted)
    }

    private func shouldFailOverProviderError(_ error: Error) -> Bool {
        if let providerError = error as? BurnBarProviderExecutorError,
           let statusAndBody = providerError.upstreamStatusAndBody {
            let statusCode = statusAndBody.statusCode
            let body = statusAndBody.body
            if BurnBarProviderExecutorError.isTransientCapacityFailure(statusCode: statusCode, body: body) {
                return true
            }
            if statusCode == 429 || statusCode == 401 || statusCode == 403 || statusCode == 402 {
                return true
            }
            let normalizedBody = body.lowercased()
            return normalizedBody.contains("quota")
                || normalizedBody.contains("rate limit")
                || normalizedBody.contains("rate_limit")
                || normalizedBody.contains("insufficient_quota")
                || normalizedBody.contains("insufficient funds")
                || normalizedBody.contains("insufficient balance")
                || normalizedBody.contains("exhaust")
        } else if error is BurnBarProviderExecutorError {
            return false
        }

        if Self.isRetryableProviderTransportError(error) {
            return true
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("quota")
            || description.contains("rate limit")
            || description.contains("429")
    }

    private static func isRetryableProviderTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut,
             .secureConnectionFailed,
             .badServerResponse:
            return true
        default:
            return false
        }
    }

    private func recordUsageIfAvailable(
        _ usage: BurnBarProviderProxyUsage?,
        route: BurnBarProviderRoute,
        idempotencyKey: String,
        executionSource: UsageExecutionSource
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
            cost: try route.pricing.cost(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens
            ),
            recordedAt: Date(),
            projectName: "OpenBurnBar Gateway",
            executionSourceID: executionSource.id == "unknown" ? nil : executionSource.id,
            executionSourceName: executionSource.id == "unknown" ? nil : executionSource.name,
            executionSourceKind: executionSource.kind == .unknown ? nil : executionSource.kind,
            executionSourceConfidence: executionSource.id == "unknown" ? nil : .exact,
            confidence: usage.confidence
        )
        do {
            _ = try await usageRecorder.record(event, idempotencyKey: idempotencyKey)
        } catch {
            logger.silentFailure("gateway_usage_record", error: error)
        }
    }

    private func recordQuotaSignalIfAvailable(
        headers: [String: String],
        route: BurnBarProviderRoute,
        requestPath: String?,
        endpoint: String?,
        httpStatus: Int?,
        streamed: Bool
    ) async {
        guard let quotaSignalStore,
              let signal = BurnBarQuotaSignalStore.signal(
                  from: headers,
                  route: route,
                  requestPath: requestPath,
                  endpoint: endpoint,
                  httpStatus: httpStatus,
                  streamed: streamed
              ) else {
            return
        }
        await quotaSignalStore.append(signal)
    }

    private func recordProxyRouteLogEntry(
        startedAt: Date,
        modelID: String,
        endpoint: LinuxGatewayEndpoint,
        route: BurnBarProviderRoute?,
        finalStatus: BurnBarProxyRouteFinalStatus,
        streamed: Bool,
        httpStatus: Int?,
        attempts: [BurnBarProxyRouteAttempt],
        usage: BurnBarProviderProxyUsage?,
        streamInterrupted: Bool = false,
        failureMessage: String? = nil
    ) async {
        guard let proxyRouteLogStore else { return }
        let completedAt = Date()
        let entry = BurnBarProxyRouteLogEntry(
            occurredAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: Self.elapsedMilliseconds(from: startedAt, to: completedAt),
            requestPath: endpoint.requestPath,
            endpoint: endpoint.displayName,
            clientModelSlug: modelID,
            advertisedModelSlug: modelID,
            routingModelSlug: modelID,
            upstreamModelSlug: route?.resolvedModelID,
            providerReportedModelSlug: nil,
            clientModelDisplayName: modelID,
            routingModelDisplayName: modelID,
            upstreamModelDisplayName: route?.resolvedModelID,
            providerID: route?.providerID,
            providerName: route?.providerDisplayName,
            providerLogoKey: route.map { providerLogoKey(for: $0) },
            accountID: route?.credentialSlotID,
            accountLabel: route?.credentialSlotLabel,
            requestedCanonicalModelID: route?.canonicalModelID,
            servedCanonicalModelID: route?.canonicalModelID,
            formatFamily: route?.formatFamily.rawValue,
            endpointProfileID: route?.endpointProfileID,
            transportKind: route.map(transportKind(for:)),
            rewriteKind: .none,
            exactModelInvariant: route?.canonicalModelID == nil ? .unavailable : .passed,
            finalStatus: finalStatus,
            streamed: streamed,
            streamInterrupted: streamInterrupted,
            httpStatus: httpStatus,
            attempts: attempts,
            usage: route.flatMap { proxyRouteUsage(from: usage, route: $0) },
            failureMessage: Self.sanitizedFailureMessage(failureMessage),
            parentRequestID: nil
        )
        await proxyRouteLogStore.append(entry)
    }

    private func routeAttempt(
        sequence: Int,
        startedAt: Date,
        completedAt: Date,
        route: BurnBarProviderRoute,
        status: BurnBarProxyRouteFinalStatus,
        httpStatus: Int?,
        failureMessage: String? = nil
    ) -> BurnBarProxyRouteAttempt {
        BurnBarProxyRouteAttempt(
            sequence: sequence,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: Self.elapsedMilliseconds(from: startedAt, to: completedAt),
            providerID: route.providerID,
            providerName: route.providerDisplayName,
            providerLogoKey: providerLogoKey(for: route),
            accountID: route.credentialSlotID,
            accountLabel: route.credentialSlotLabel,
            routingModelSlug: route.requestedModel,
            upstreamModelSlug: route.resolvedModelID,
            canonicalModelID: route.canonicalModelID,
            formatFamily: route.formatFamily.rawValue,
            endpointProfileID: route.endpointProfileID,
            transportKind: transportKind(for: route),
            status: status,
            httpStatus: httpStatus,
            failureMessage: Self.sanitizedFailureMessage(failureMessage)
        )
    }

    private func proxyRouteUsage(
        from usage: BurnBarProviderProxyUsage?,
        route: BurnBarProviderRoute
    ) -> BurnBarProxyRouteUsage? {
        guard let usage else { return nil }
        return BurnBarProxyRouteUsage(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens,
            reasoningTokens: usage.reasoningTokens,
            cost: try route.pricing.cost(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens
            ),
            confidence: usage.confidence
        )
    }

    private func providerLogoKey(for route: BurnBarProviderRoute) -> String {
        configStore.catalogSupport.catalog.provider(id: route.providerID)?.bundledLogoName
            ?? BurnBarCatalogProvider.bundledLogoName(forProviderID: route.providerID)
            ?? "\(route.providerID.capitalized)Logo"
    }

    private func transportKind(for route: BurnBarProviderRoute) -> BurnBarProxyTransportKind {
        route.providerID.caseInsensitiveCompare("factory") == .orderedSame ? .factoryDroid : .http
    }

    private func usageIdempotencyKey(accountingRequestID: String, route: BurnBarProviderRoute) -> String {
        let routePart = "\(route.providerID)#\(route.credentialSlotID ?? "legacy")#\(route.resolvedModelID)"
        return "gateway:\(Self.stableDigest("\(accountingRequestID)|\(routePart)"))"
    }

    private func noEligibleRouteResponse(modelID: String, endpoint: LinuxGatewayEndpoint) -> Data {
        typedDegradedResponse(
            BurnBarHTTPGatewayDegradedError.noEligibleRoute(
                modelID: modelID,
                endpoint: endpoint.requestPath
            )
        )
    }

    private func typedDegradedResponse(
        _ error: BurnBarHTTPGatewayDegradedError,
        retryAfter: TimeInterval? = nil
    ) -> Data {
        var payload: [String: Any] = [
            "code": error.code,
            "message": error.localizedDescription,
            "type": "degraded",
            "model": error.modelID
        ]
        if let retryAfter {
            payload["retry_after_seconds"] = max(0, Int(ceil(retryAfter)))
        } else if let retryAfter = error.retryAfter {
            payload["retry_after_seconds"] = max(0, Int(ceil(retryAfter)))
        }
        let bodyObject: [String: Any] = ["error": payload]
        let body = (try? JSONSerialization.data(withJSONObject: bodyObject, options: []))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"error":{"code":"degraded","type":"degraded"}}"#
        var headers = ["Content-Type": "application/json"]
        if let retryAfter {
            headers["Retry-After"] = String(max(1, Int(ceil(retryAfter))))
        } else if let retryAfter = error.retryAfter {
            headers["Retry-After"] = String(max(1, Int(ceil(retryAfter))))
        }
        return httpResponse(status: 503, headers: headers, body: body)
    }

    private func jsonResponse(status: Int, message: String) -> Data {
        httpResponse(status: status, headers: ["Content-Type": "application/json"], body: errorBody(message))
    }

    /// Evaluates the Memory Pro policy for one route. Returns the denial to
    /// send (already logged to the egress chain) or nil when the request may
    /// leave the machine. A daemon without an enforcer refuses every
    /// memory-purpose request rather than silently proxying it.
    private func memoryEgressDenial(
        purpose: GatewayPurpose,
        route: BurnBarProviderRoute,
        requestBytes: Int
    ) async -> BurnBarMemoryEgressDenial? {
        guard let memoryEgress else {
            return BurnBarMemoryEgressDenial(
                code: "CLOUD_CONSENT_REQUIRED",
                message: "Memory egress policy is not configured on this daemon."
            )
        }
        do {
            try await memoryEgress.evaluate(purpose: purpose, providerID: route.providerID)
            return nil
        } catch let denial as BurnBarMemoryEgressDenial {
            await memoryEgress.record(
                purpose: purpose, providerID: route.providerID, modelID: route.resolvedModelID,
                requestBytes: requestBytes, responseBytes: 0, outcome: "denied", code: denial.code, latencyMs: 0
            )
            return denial
        } catch {
            return BurnBarMemoryEgressDenial(
                code: "CLOUD_CONSENT_REQUIRED",
                message: "Memory egress policy unavailable: \(error.localizedDescription)"
            )
        }
    }

    /// Memory Pro denials use the OpenAI-style object error shape so the
    /// Python engine can read a stable `code` (same body as the Darwin gateway).
    private func memoryEgressDenialResponse(_ denial: BurnBarMemoryEgressDenial) -> Data {
        let payload: [String: Any] = ["error": ["code": denial.code, "message": denial.message, "type": "memory_egress_denied"]]
        let body = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"error":{"code":"\#(denial.code)","message":"denied"}}"#
        return httpResponse(status: 403, headers: ["Content-Type": "application/json"], body: body)
    }

    /// A short, content-free code for the egress chain when upstream fails.
    private nonisolated static func memoryEgressFailureCode(_ error: Error) -> String {
        if let status = httpStatus(from: error) {
            return "UPSTREAM_\(status)"
        }
        return "UPSTREAM_ERROR"
    }

    private func errorBody(_ message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return #"{"error":"\#(escaped)"}"#
    }

    private nonisolated static func httpStatus(from error: Error) -> Int? {
        if let providerError = error as? BurnBarProviderExecutorError,
           let statusAndBody = providerError.upstreamStatusAndBody {
            return statusAndBody.statusCode
        }
        return nil
    }

    private nonisolated static func routeLogFailureMessage(from error: Error) -> String {
        if let providerError = error as? BurnBarProviderExecutorError,
           let statusAndBody = providerError.upstreamStatusAndBody {
            return "OpenBurnBar provider request failed with status \(statusAndBody.statusCode)."
        }
        return sanitizedFailureMessage(error.localizedDescription) ?? "OpenBurnBar provider request failed."
    }

    private nonisolated static func sanitizedFailureMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let oneLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(oneLine.prefix(260))
    }

    private nonisolated static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince1970 - start.timeIntervalSince1970) * 1_000))
    }

    private nonisolated static func stableDigest(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
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

private enum LinuxGatewayResponse {
    case buffered(Data)
    case streamed
}

private struct LinuxGatewayStreamPlan {
    let usageFormat: GatewayStreamUsageFormat
    let open: (BurnBarModelVariant?) async throws -> BurnBarProviderProxyStream
}

private final class LinuxGatewayStreamCommit {
    var responseStarted = false
}

private enum LinuxGatewayEndpoint: Equatable {
    case chatCompletions
    case responses
    case anthropicMessages

    var requestPath: String {
        switch self {
        case .chatCompletions:
            return "/v1/chat/completions"
        case .responses:
            return "/v1/responses"
        case .anthropicMessages:
            return "/v1/messages"
        }
    }

    var displayName: String {
        switch self {
        case .chatCompletions:
            return "Chat Completions"
        case .responses:
            return "Responses"
        case .anthropicMessages:
            return "Anthropic Messages"
        }
    }
}

private struct LinuxGatewayModelRequest: Decodable {
    let model: String?
    let stream: Bool?
}

private struct LinuxGatewayCatalogModel: Sendable {
    let id: String
    let displayName: String
    let providerID: String
    let providerName: String
    let baseModelID: String?
    let accountIDs: [String]
    let formatFamily: BurnBarProviderFormatFamily
    let isEnabled: Bool
    let routeEligible: Bool
    let advertisementEnabled: Bool
    let isAlias: Bool
    let isVariant: Bool
}

private struct LinuxModelCatalogCache {
    let configurationHash: Int
    let storedAt: Date
    let models: [LinuxGatewayCatalogModel]
}

private struct LinuxHTTPRequest {
    var method: String = "GET"
    var path: String = "/"
    var headers: [String: String] = [:]
    var body = Data()
}

private func readHTTPRequest(
    from fileDescriptor: Int32,
    maxBytes: Int = BurnBarHTTPGatewayServer.maxRequestBytes,
    maxHeaderBytes: Int = 16 * 1024
) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var expectedTotalBytes: Int?
    while true {
        let count = read(fileDescriptor, &buffer, buffer.count)
        if count == 0 {
            guard let expectedTotalBytes else {
                throw BurnBarHTTPGatewayError.malformedRequest("request headers are incomplete")
            }
            guard data.count >= expectedTotalBytes else {
                throw BurnBarHTTPGatewayError.incompleteRequest
            }
            break
        }
        if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw BurnBarHTTPGatewayError.incompleteRequest
            }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        data.append(contentsOf: buffer.prefix(count))
        if data.count > maxBytes {
            throw BurnBarHTTPGatewayError.requestTooLarge(maxBytes: maxBytes)
        }
        if let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
            guard headerEnd.upperBound <= maxHeaderBytes else {
                throw BurnBarHTTPGatewayError.requestTooLarge(maxBytes: maxHeaderBytes)
            }
            let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
            let contentLength = try parsedContentLength(from: head)
            let bodyStart = headerEnd.upperBound
            guard bodyStart <= maxBytes, contentLength <= maxBytes - bodyStart else {
                throw BurnBarHTTPGatewayError.requestTooLarge(maxBytes: maxBytes)
            }
            let expected = bodyStart + contentLength
            expectedTotalBytes = expected
            if data.count == expected {
                break
            }
            if data.count > expected {
                throw BurnBarHTTPGatewayError.malformedRequest("multiple HTTP frames are not supported")
            }
        }
    }
    return data
}

private func parsedContentLength(from head: String) throws -> Int {
    let lines = head.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
        throw BurnBarHTTPGatewayError.malformedRequest("request line is missing")
    }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3,
          requestParts[0].isEmpty == false,
          requestParts[1].hasPrefix("/"),
          requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
        throw BurnBarHTTPGatewayError.malformedRequest("invalid request line")
    }

    var contentLength: Int?
    for line in lines.dropFirst() {
        guard !line.isEmpty else { continue }
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw BurnBarHTTPGatewayError.malformedRequest("invalid header line")
        }
        let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw BurnBarHTTPGatewayError.malformedRequest("invalid header name")
        }
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "transfer-encoding" {
            throw BurnBarHTTPGatewayError.unsupportedTransferEncoding(value)
        }
        if name == "content-length" {
            guard !value.isEmpty, value.allSatisfy({ $0.isNumber }), let parsed = Int(value), parsed >= 0 else {
                throw BurnBarHTTPGatewayError.malformedRequest("invalid content length")
            }
            if let contentLength, contentLength != parsed {
                throw BurnBarHTTPGatewayError.malformedRequest("conflicting content lengths")
            }
            contentLength = parsed
        }
    }
    return contentLength ?? 0
}

private func parseRequest(_ data: Data) throws -> LinuxHTTPRequest {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
        throw BurnBarHTTPGatewayError.malformedRequest("request headers are incomplete")
    }
    let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
    _ = try parsedContentLength(from: head)
    var lines = head.components(separatedBy: "\r\n")
    let start = lines.isEmpty ? "" : lines.removeFirst()
    let startParts = start.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var request = LinuxHTTPRequest()
    guard startParts.count == 3 else {
        throw BurnBarHTTPGatewayError.malformedRequest("invalid request line")
    }
    request.method = startParts[0].uppercased()
    request.path = startParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    for line in lines {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw BurnBarHTTPGatewayError.malformedRequest("invalid header line")
        }
        request.headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    request.body = data[headerEnd.upperBound...]
    return request
}

private func httpResponse(status: Int, headers: [String: String], body: String) -> Data {
    httpResponse(status: status, headers: headers, body: Data(body.utf8))
}

private func httpResponse(status: Int, headers: [String: String], body: Data) -> Data {
    httpResponseHead(status: status, headers: headers, contentLength: body.count) + body
}

private func insertingHeaders(_ headers: [String: String], into response: Data) -> Data {
    guard !headers.isEmpty,
          let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
        return response
    }
    let additions = headers.keys.sorted().compactMap { key in
        headers[key].map { "\(key): \($0)\r\n" }
    }.joined()
    var result = Data(response[..<separator.lowerBound])
    result.append(Data("\r\n".utf8))
    result.append(contentsOf: additions.utf8)
    result.append(Data("\r\n\r\n".utf8))
    result.append(response[separator.upperBound...])
    return result
}

private func httpResponseHead(status: Int, headers: [String: String], contentLength: Int? = nil) -> Data {
    var responseHeaders = headers
    if let contentLength {
        responseHeaders["Content-Length"] = "\(contentLength)"
    }
    responseHeaders["Connection"] = "close"
    let head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        + responseHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        + "\r\n\r\n"
    return Data(head.utf8)
}

private func typedGatewayErrorResponse(_ error: BurnBarHTTPGatewayError) -> Data {
    let message = error.localizedDescription
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    let body = #"{"error":{"code":"\#(error.responseCode)","message":"\#(message)"}}"#
    return httpResponse(status: error.httpStatus, headers: ["Content-Type": "application/json"], body: body)
}

private func statusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 413: return "Payload Too Large"
    case 404: return "Not Found"
    case 429: return "Too Many Requests"
    case 501: return "Not Implemented"
    case 502: return "Bad Gateway"
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
// cov:ignore-end
#endif
