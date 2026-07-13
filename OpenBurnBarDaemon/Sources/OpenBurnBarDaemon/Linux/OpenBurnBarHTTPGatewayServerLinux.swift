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
    let usageRecorder: BurnBarUsageRecorder?
    let proxyRouteLogStore: BurnBarProxyRouteLogStore?
    let quotaSignalStore: BurnBarQuotaSignalStore?
    let providerExecutor: BurnBarOpenAICompatibleProviderExecutor
    let anthropicExecutor: BurnBarAnthropicProviderExecutor
    let factoryExecutor: FactoryDroidProviderExecutor
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
        quotaSignalStore: BurnBarQuotaSignalStore? = nil,
        providerExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        anthropicExecutor: BurnBarAnthropicProviderExecutor = BurnBarAnthropicProviderExecutor(),
        factoryExecutor: FactoryDroidProviderExecutor = FactoryDroidProviderExecutor(),
        modelCatalogCacheTTL: TimeInterval = 0,
        logger: any BurnBarDaemonLogging = BurnBarDaemonLogger(category: "http-gateway"),
        rateLimiter: BurnBarRateLimiter? = nil
    ) {
        _ = modelCatalogCacheTTL
        self.configuration = configuration
        self.configStore = configStore
        self.usageRecorder = usageRecorder
        self.proxyRouteLogStore = proxyRouteLogStore
        self.quotaSignalStore = quotaSignalStore
        self.providerExecutor = providerExecutor
        self.anthropicExecutor = anthropicExecutor
        self.factoryExecutor = factoryExecutor
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
            switch await handleRequest(request, fileDescriptor: fileDescriptor) {
            case .buffered(let response):
                try writeAll(response, to: fileDescriptor)
            case .streamed:
                break
            }
        } catch {
            let body = #"{"error":{"message":"bad request"}}"#
            let response = httpResponse(status: 400, headers: ["Content-Type": "application/json"], body: body)
            try? writeAll(response, to: fileDescriptor)
        }
    }

    private func handleRequest(_ request: LinuxHTTPRequest, fileDescriptor: Int32) async -> LinuxGatewayResponse {
        if request.method == "OPTIONS" {
            return .buffered(httpResponse(status: 204, headers: [:], body: Data()))
        }

        if let requiredToken = configuration.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
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

        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            return .buffered(httpResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"ok":true,"gateway":"openburnbar","platform":"linux"}"#
            ))
        case ("GET", "/metrics"):
            let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: configuration.isEnabled)
            let body = (try? String(data: JSONEncoder().encode(snapshot), encoding: .utf8)) ?? #"{"gatewayEnabled":true}"#
            return .buffered(httpResponse(status: 200, headers: ["Content-Type": "application/json"], body: body))
        case ("GET", "/v1/models"):
            return .buffered(await linuxModelsListResponse(catalog: false))
        case ("GET", "/v1/models/catalog"):
            return .buffered(await linuxModelsListResponse(catalog: true))
        case ("POST", "/v1/chat/completions"):
            return await handleModelEndpoint(.chatCompletions, request: request, fileDescriptor: fileDescriptor)
        case ("POST", "/v1/responses"):
            return await handleModelEndpoint(.responses, request: request, fileDescriptor: fileDescriptor)
        case ("POST", "/v1/messages"):
            return await handleModelEndpoint(.anthropicMessages, request: request, fileDescriptor: fileDescriptor)
        default:
            return .buffered(httpResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":{"message":"not found"}}"#
            ))
        }
    }

    private func handleModelEndpoint(
        _ endpoint: LinuxGatewayEndpoint,
        request: LinuxHTTPRequest,
        fileDescriptor: Int32
    ) async -> LinuxGatewayResponse {
        let startedAt = Date()
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
                    requestedFormatFamily: formatFamily
                )
                await router.persistDecisionIfNeeded(ranking: ranking, modelName: modelID)
                let routes = ranking.rankedRoutes.map(\.route)
                guard !routes.isEmpty else { continue }

                for (index, route) in routes.enumerated() {
                    let attemptStartedAt = Date()
                    do {
                        if decoded.stream == true,
                           let streamPlan = streamPlan(
                            for: route,
                            formatFamily: formatFamily,
                            endpoint: endpoint,
                            body: request.body
                           ) {
                            do {
                                let proxyStream = try await streamPlan.open(resolvedModel.variant)
                                let usage = try await relayStream(
                                    proxyStream,
                                    usageFormat: streamPlan.usageFormat,
                                    route: route,
                                    accountingRequestID: accountingRequestID,
                                    streamCommit: streamCommit,
                                    fileDescriptor: fileDescriptor
                                )
                                await recordQuotaSignalIfAvailable(
                                    headers: proxyStream.headers,
                                    route: route,
                                    requestPath: endpoint.requestPath,
                                    endpoint: endpoint.displayName,
                                    httpStatus: proxyStream.statusCode,
                                    streamed: true
                                )
                                attempts.append(routeAttempt(
                                    sequence: attempts.count + 1,
                                    startedAt: attemptStartedAt,
                                    completedAt: Date(),
                                    route: route,
                                    status: .exact,
                                    httpStatus: proxyStream.statusCode
                                ))
                                await recordProxyRouteLogEntry(
                                    startedAt: startedAt,
                                    modelID: clientModelID,
                                    endpoint: endpoint,
                                    route: route,
                                    finalStatus: .exact,
                                    streamed: true,
                                    httpStatus: proxyStream.statusCode,
                                    attempts: attempts,
                                    usage: usage
                                )
                                return .streamed
                            } catch is BurnBarProxyStreamingUnsupported {
                                // Provider can serve the route, just not as SSE.
                                // Fall through to the buffered proxy below.
                            }
                        }

                        let response = try await proxyEndpoint(
                            body: request.body,
                            route: route,
                            endpoint: endpoint,
                            formatFamily: formatFamily,
                            variant: resolvedModel.variant
                        )
                        await recordQuotaSignalIfAvailable(
                            headers: response.headers,
                            route: route,
                            requestPath: endpoint.requestPath,
                            endpoint: endpoint.displayName,
                            httpStatus: response.statusCode,
                            streamed: false
                        )
                        await recordUsageIfAvailable(
                            response.usage,
                            route: route,
                            idempotencyKey: usageIdempotencyKey(accountingRequestID: accountingRequestID, route: route)
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
                        attempts.append(routeAttempt(
                            sequence: attempts.count + 1,
                            startedAt: attemptStartedAt,
                            completedAt: Date(),
                            route: route,
                            status: .failed,
                            httpStatus: Self.httpStatus(from: error),
                            failureMessage: Self.routeLogFailureMessage(from: error)
                        ))
                        await router.markRouteFailure(route, error: error)
                        if streamCommit.responseStarted {
                            logger.error("gateway_linux_stream_interrupted", metadata: [
                                "model": modelID,
                                "provider_id": route.providerID,
                                "error": "\(error)"
                            ])
                            await recordProxyRouteLogEntry(
                                startedAt: startedAt,
                                modelID: clientModelID,
                                endpoint: endpoint,
                                route: route,
                                finalStatus: .failed,
                                streamed: true,
                                httpStatus: Self.httpStatus(from: error) ?? 502,
                                attempts: attempts,
                                usage: nil,
                                streamInterrupted: true,
                                failureMessage: Self.routeLogFailureMessage(from: error)
                            )
                            return .streamed
                        }
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
            return .buffered(providerFailureResponse(error, modelID: modelID))
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
    }

    /// Build OpenAI-compatible `/v1/models` (+ catalog) from configured providers (VAL-DAEMON-002).
    private func linuxModelsListResponse(catalog: Bool) async -> Data {
        var data: [[String: Any]] = []
        if let configurations = try? await configStore.resolvedConfigurations() {
            var seen = Set<String>()
            for configuration in configurations {
                let owner = configuration.settings.providerID
                for variant in configuration.settings.modelVariants {
                    let id = variant.variantID
                    guard seen.insert(id).inserted else { continue }
                    var row: [String: Any] = [
                        "id": id,
                        "object": "model",
                        "owned_by": owner,
                        "created": Int(Date().timeIntervalSince1970)
                    ]
                    if catalog {
                        row["base_model"] = variant.baseModelID
                        row["provider"] = owner
                    }
                    data.append(row)
                }
                for alias in configuration.settings.modelAliases {
                    let id = alias.aliasID
                    guard seen.insert(id).inserted else { continue }
                    var row: [String: Any] = [
                        "id": id,
                        "object": "model",
                        "owned_by": owner,
                        "created": Int(Date().timeIntervalSince1970)
                    ]
                    if catalog {
                        row["base_model"] = alias.baseModelID
                        row["provider"] = owner
                        row["alias"] = true
                    }
                    data.append(row)
                }
                // Prefer advertised catalog models when variants empty.
                if configuration.settings.modelVariants.isEmpty {
                    for model in configuration.preferredModels {
                        let id = model.id
                        guard seen.insert(id).inserted else { continue }
                        data.append([
                            "id": id,
                            "object": "model",
                            "owned_by": owner,
                            "created": Int(Date().timeIntervalSince1970)
                        ])
                    }
                }
            }
        }
        let bodyObj: [String: Any] = [
            "object": "list",
            "data": data,
            "platform": "linux",
            "catalog": catalog
        ]
        let body = (try? JSONSerialization.data(withJSONObject: bodyObj, options: []))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"object":"list","data":[]}"#
        return httpResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private func resolveLinuxGatewayModel(_ requested: String) async -> LinuxGatewayResolvedModel {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configurations = try? await configStore.resolvedConfigurations() else {
            return LinuxGatewayResolvedModel(modelID: trimmed, variant: nil)
        }
        for configuration in configurations {
            if let variant = configuration.settings.modelVariants.first(where: {
                $0.variantID.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return LinuxGatewayResolvedModel(modelID: variant.baseModelID, variant: variant)
            }
            if let alias = configuration.settings.modelAliases.first(where: {
                $0.aliasID.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return LinuxGatewayResolvedModel(modelID: alias.baseModelID, variant: nil)
            }
        }
        return LinuxGatewayResolvedModel(modelID: trimmed, variant: nil)
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

    private func relayStream(
        _ proxyStream: BurnBarProviderProxyStream,
        usageFormat: GatewayStreamUsageFormat,
        route: BurnBarProviderRoute,
        accountingRequestID: String,
        streamCommit: LinuxGatewayStreamCommit,
        fileDescriptor: Int32
    ) async throws -> BurnBarProviderProxyUsage? {
        let headers = [
            "Content-Type": proxyStream.contentType,
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no"
        ]
        streamCommit.responseStarted = true
        try writeAll(httpResponseHead(status: proxyStream.statusCode, headers: headers), to: fileDescriptor)

        let accumulator = GatewayStreamingUsageAccumulator(format: usageFormat)
        for try await chunk in proxyStream.chunks {
            accumulator.consume(chunk)
            try writeAll(chunk, to: fileDescriptor)
        }
        let usage = accumulator.finalize()
        await recordUsageIfAvailable(
            usage,
            route: route,
            idempotencyKey: usageIdempotencyKey(accountingRequestID: accountingRequestID, route: route)
        )
        return usage
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
        idempotencyKey: String
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
        jsonResponse(
            status: 503,
            message: "No eligible route for \(modelID) on \(endpoint.requestPath). Add or enable an account/provider that serves this model."
        )
    }

    private func providerFailureResponse(_ error: Error, modelID: String) -> Data {
        if let providerError = error as? BurnBarProviderExecutorError,
           let statusAndBody = providerError.upstreamStatusAndBody {
            let statusCode = statusAndBody.statusCode
            let body = statusAndBody.body
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBody.isEmpty {
                return httpResponse(status: statusCode, headers: ["Content-Type": "application/json"], body: trimmedBody)
            }
            return jsonResponse(status: statusCode, message: "upstream provider returned HTTP \(statusCode)")
        }
        return jsonResponse(status: 502, message: "routing failed: \(error.localizedDescription)")
    }

    private func jsonResponse(status: Int, message: String) -> Data {
        httpResponse(status: status, headers: ["Content-Type": "application/json"], body: errorBody(message))
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

private struct LinuxHTTPRequest {
    var method: String = "GET"
    var path: String = "/"
    var headers: [String: String] = [:]
    var body = Data()
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
    httpResponse(status: status, headers: headers, body: Data(body.utf8))
}

private func httpResponse(status: Int, headers: [String: String], body: Data) -> Data {
    httpResponseHead(status: status, headers: headers, contentLength: body.count) + body
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

private func statusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
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
#endif
