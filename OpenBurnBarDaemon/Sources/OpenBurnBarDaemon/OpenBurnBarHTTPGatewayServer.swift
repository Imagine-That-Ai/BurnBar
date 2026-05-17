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
    private static let maxBodyBytes = 64 * 1024 * 1024

    private let configuration: BurnBarGatewayConfiguration
    private let configStore: BurnBarConfigStore
    private let usageRecorder: BurnBarUsageRecorder?
    private let providerExecutor: BurnBarOpenAICompatibleProviderExecutor
    private let anthropicExecutor: BurnBarAnthropicProviderExecutor
    private let modelHealthStore: BurnBarGatewayModelHealthStore
    private let modelCatalogSession: URLSession
    private let logger: BurnBarDaemonLogger
    private let rateLimiter: BurnBarRateLimiter?
    private var listener: NWListener?

    public init(
        configuration: BurnBarGatewayConfiguration,
        configStore: BurnBarConfigStore,
        usageRecorder: BurnBarUsageRecorder? = nil,
        providerExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        anthropicExecutor: BurnBarAnthropicProviderExecutor = BurnBarAnthropicProviderExecutor(),
        modelHealthStore: BurnBarGatewayModelHealthStore = BurnBarGatewayModelHealthStore(),
        modelCatalogSession: URLSession = .shared,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "http-gateway"),
        rateLimiter: BurnBarRateLimiter? = nil
    ) {
        self.configuration = configuration
        self.configStore = configStore
        self.usageRecorder = usageRecorder
        self.providerExecutor = providerExecutor
        self.anthropicExecutor = anthropicExecutor
        self.modelHealthStore = modelHealthStore
        self.modelCatalogSession = modelCatalogSession
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

        case ("POST", "/v1/responses"):
            return await handleResponses(body: request.body)

        case ("POST", "/v1/messages"):
            return await handleAnthropicMessages(body: request.body)

        default:
            return jsonResponse(status: 404, body: errorBody("not found"))
        }
    }

    // MARK: - /v1/models

    private func handleModels() async -> GatewayHTTPResponse {
        do {
            let catalog = configStore.catalogSupport.catalog
            let router = BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "gateway-router"),
                allowDynamicOpenAICompatibleModels: true
            )
            let snapshot = try await BurnBarLiveModelCatalog(
                configStore: configStore,
                session: modelCatalogSession
            ).snapshot()
            var models: [ModelDescriptor] = []
            for model in snapshot.models where model.routeEligible {
                if await canRouteAdvertisedModel(model, router: router, catalog: catalog) {
                    models.append(ModelDescriptor(model: model))
                }
            }
            return jsonResponse(status: 200, body: encodeBody(ModelsResponse(data: models)))
        } catch {
            logger.error("gateway_models_error", metadata: ["error": "\(error)"])
            return jsonResponse(status: 500, body: errorBody("internal error"))
        }
    }

    private func canRouteAdvertisedModel(
        _ model: BurnBarLiveAdvertisedModel,
        router: BurnBarProviderRouter,
        catalog: BurnBarCatalog
    ) async -> Bool {
        do {
            let requiredCapabilityClassID = capabilityClassID(forModelName: model.id, catalog: catalog)
            let formatFamily = advertisedFormatFamily(for: model, catalog: catalog)
            if let failure = await modelHealthStore.activeFailure(
                modelID: model.id,
                providerID: model.providerID,
                accountID: model.accountID,
                formatFamily: formatFamily
            ) {
                logger.warning(
                    "gateway_models_route_recently_failed",
                    metadata: [
                        "model": model.id,
                        "provider": model.providerID,
                        "account": model.accountID,
                        "status": "\(failure.statusCode)",
                        "blocked_until": "\(failure.blockedUntil)"
                    ]
                )
                return false
            }
            let routes = try await router.candidateRoutes(
                modelName: model.id,
                requestedFormatFamily: formatFamily,
                requiredCapabilityClassID: requiredCapabilityClassID
            )
            return routes.contains { route in
                route.providerID == model.providerID
                    && (route.credentialSlotID ?? "legacy") == model.accountID
            }
        } catch {
            logger.warning(
                "gateway_models_route_verification_failed",
                metadata: [
                    "model": model.id,
                    "provider": model.providerID,
                    "account": model.accountID,
                    "error": "\(error)"
                ]
            )
            return false
        }
    }

    private func advertisedRouteKeysByFamily(for modelID: String) async throws -> [BurnBarProviderFormatFamily: Set<String>] {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedModelID.isEmpty == false else { return [:] }

        let catalog = configStore.catalogSupport.catalog
        let router = BurnBarProviderRouter(
            configStore: configStore,
            logger: BurnBarDaemonLogger(category: "gateway-router"),
            allowDynamicOpenAICompatibleModels: true
        )
        let snapshot = try await BurnBarLiveModelCatalog(
            configStore: configStore,
            session: modelCatalogSession
        ).snapshot()

        var routeKeysByFamily: [BurnBarProviderFormatFamily: Set<String>] = [:]
        for model in snapshot.models where model.routeEligible {
            guard advertisedModel(model.id, matchesRequestedModelID: normalizedModelID, providerID: model.providerID, catalog: catalog) else {
                continue
            }
            guard await canRouteAdvertisedModel(model, router: router, catalog: catalog) else {
                continue
            }
            let family = advertisedFormatFamily(for: model, catalog: catalog)
            routeKeysByFamily[family, default: []].insert(
                routeKey(providerID: model.providerID, slotID: model.accountID == "legacy" ? nil : model.accountID)
            )
        }
        return routeKeysByFamily
    }

    private func advertisedFormatFamily(
        for model: BurnBarLiveAdvertisedModel,
        catalog: BurnBarCatalog
    ) -> BurnBarProviderFormatFamily {
        if model.capabilities.contains(BurnBarProviderFormatFamily.anthropic.rawValue) {
            return .anthropic
        }
        if model.capabilities.contains(BurnBarProviderFormatFamily.openaiCompat.rawValue) {
            return .openaiCompat
        }
        return catalog.provider(id: model.providerID)?.formatFamily ?? .openaiCompat
    }

    private func preferredGatewayFormatFamilies(
        for modelID: String,
        advertised: [BurnBarProviderFormatFamily: Set<String>]
    ) -> [BurnBarProviderFormatFamily] {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseOrder: [BurnBarProviderFormatFamily] = normalized.contains("claude") || normalized.contains("anthropic")
            ? [.anthropic, .openaiCompat]
            : [.openaiCompat, .anthropic]
        return baseOrder.filter { advertised[$0]?.isEmpty == false }
    }

    private func advertisedModel(
        _ advertisedModelID: String,
        matchesRequestedModelID normalizedRequestedModelID: String,
        providerID: String,
        catalog: BurnBarCatalog
    ) -> Bool {
        let normalizedAdvertisedModelID = advertisedModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedAdvertisedModelID.isEmpty else { return false }
        if normalizedAdvertisedModelID == normalizedRequestedModelID {
            return true
        }

        return catalog.models(forProviderID: providerID).contains { model in
            model.matches(modelName: normalizedRequestedModelID)
                && model.matches(modelName: normalizedAdvertisedModelID)
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
            let advertisedRouteKeysByFamily = try await advertisedRouteKeysByFamily(for: modelID)
            guard advertisedRouteKeysByFamily.values.contains(where: { !$0.isEmpty }) else {
                return noEligibleRouteResponse(modelID: modelID)
            }

            let router = BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "gateway-router"),
                routingEventStore: BurnBarProviderRoutingDecisionEventStore(),
                allowDynamicOpenAICompatibleModels: true
            )
            let catalog = configStore.catalogSupport.catalog
            let resolvedCapabilityClassID = capabilityClassID(
                forModelName: modelID,
                catalog: catalog
            )
            var lastError: Error?
            var lastFailedRoute: BurnBarProviderRoute?
            for formatFamily in preferredGatewayFormatFamilies(for: modelID, advertised: advertisedRouteKeysByFamily) {
                guard let advertisedRouteKeys = advertisedRouteKeysByFamily[formatFamily], !advertisedRouteKeys.isEmpty else {
                    continue
                }

                let ranking = try await router.scoreAndRankRoutes(
                    modelName: modelID,
                    requestedFormatFamily: formatFamily,
                    requiredCapabilityClassID: resolvedCapabilityClassID
                )
                await router.persistDecisionIfNeeded(ranking: ranking, modelName: modelID)
                let rankedRoutes = ranking.rankedRoutes
                    .map(\.route)
                    .filter { advertisedRouteKeys.contains(routeKey(providerID: $0.providerID, slotID: $0.credentialSlotID)) }
                guard rankedRoutes.isEmpty == false else {
                    continue
                }

                // When the router pre-filtered by capability class, use its reported
                // blocked routes. Otherwise, discover the class from the top-ranked
                // route and compute blocked alternatives post-hoc.
                let selectedCapabilityClassID = resolvedCapabilityClassID ?? rankedRoutes.first?.modelCapabilityClassID
                let routes: [BurnBarProviderRoute]
                let blockedCapabilityAlternatives: [BurnBarProviderRoute]
                if let classID = selectedCapabilityClassID {
                    routes = rankedRoutes.filter { $0.modelCapabilityClassID == classID }
                    if !ranking.blockedCapabilityClassRoutes.isEmpty {
                        blockedCapabilityAlternatives = ranking.blockedCapabilityClassRoutes
                    } else {
                        blockedCapabilityAlternatives = rankedRoutes.filter { $0.modelCapabilityClassID != classID }
                    }
                } else {
                    routes = rankedRoutes
                    blockedCapabilityAlternatives = []
                }

                for (index, route) in routes.enumerated() {
                    if let slotID = route.credentialSlotID {
                        try? await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
                    }

                    do {
                        let response: BurnBarProviderProxyResponse
                        switch formatFamily {
                        case .openaiCompat:
                            response = try await providerExecutor.proxyChatCompletions(
                                body: bodyData,
                                route: route
                            )
                        case .anthropic:
                            response = try await anthropicExecutor.proxyChatCompletions(
                                body: bodyData,
                                route: route
                            )
                        }
                        await router.markRouteSuccess(route)
                        await modelHealthStore.recordSuccess(
                            modelID: modelID,
                            formatFamily: formatFamily,
                            route: route
                        )
                        await recordUsageIfAvailable(response.usage, route: route)
                        return GatewayHTTPResponse(
                            status: response.statusCode,
                            headers: ["Content-Type": response.contentType],
                            body: response.body
                        )
                    } catch {
                        lastError = error
                        lastFailedRoute = route
                        await modelHealthStore.recordFailure(
                            modelID: modelID,
                            formatFamily: formatFamily,
                            route: route,
                            error: error
                        )
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

                if let lastError {
                    return providerFailureResponse(lastError, modelID: modelID, route: lastFailedRoute)
                }
            }

            if let lastError {
                return providerFailureResponse(lastError, modelID: modelID, route: lastFailedRoute)
            }
            return noEligibleRouteResponse(modelID: modelID)
        } catch let error as BurnBarProviderRouterError {
            logger.error("gateway_route_error", metadata: ["model": modelID, "error": "\(error)"])
            return noEligibleRouteResponse(modelID: modelID)
        } catch {
            logger.error("gateway_route_error", metadata: ["model": modelID, "error": "\(error)"])
            return jsonResponse(status: 502, body: errorBody("routing failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - /v1/responses

    private func handleResponses(body: String?) async -> GatewayHTTPResponse {
        guard let body, !body.isEmpty else {
            return jsonResponse(status: 400, body: errorBody("request body required"))
        }

        guard let bodyData = body.data(using: .utf8) else {
            return jsonResponse(status: 400, body: errorBody("request body must be valid UTF-8"))
        }

        let responsesRequest: ResponsesRequest
        do {
            responsesRequest = try JSONDecoder().decode(ResponsesRequest.self, from: bodyData)
        } catch {
            return jsonResponse(status: 400, body: errorBody("invalid JSON request body"))
        }

        let modelID = responsesRequest.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelID.isEmpty == false else {
            return jsonResponse(status: 400, body: errorBody("model field required"))
        }

        do {
            let advertisedRouteKeysByFamily = try await advertisedRouteKeysByFamily(for: modelID)
            guard advertisedRouteKeysByFamily.values.contains(where: { !$0.isEmpty }) else {
                return noEligibleRouteResponse(modelID: modelID)
            }

            let router = BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "gateway-router-responses"),
                routingEventStore: BurnBarProviderRoutingDecisionEventStore(),
                allowDynamicOpenAICompatibleModels: true
            )
            let catalog = configStore.catalogSupport.catalog
            let resolvedCapabilityClassID = capabilityClassID(
                forModelName: modelID,
                catalog: catalog
            )
            var lastError: Error?
            var lastFailedRoute: BurnBarProviderRoute?
            for formatFamily in preferredGatewayFormatFamilies(for: modelID, advertised: advertisedRouteKeysByFamily) {
                guard let advertisedRouteKeys = advertisedRouteKeysByFamily[formatFamily], !advertisedRouteKeys.isEmpty else {
                    continue
                }

                let ranking = try await router.scoreAndRankRoutes(
                    modelName: modelID,
                    requestedFormatFamily: formatFamily,
                    requiredCapabilityClassID: resolvedCapabilityClassID
                )
                await router.persistDecisionIfNeeded(ranking: ranking, modelName: modelID)
                let rankedRoutes = ranking.rankedRoutes
                    .map(\.route)
                    .filter { advertisedRouteKeys.contains(routeKey(providerID: $0.providerID, slotID: $0.credentialSlotID)) }
                guard rankedRoutes.isEmpty == false else {
                    continue
                }

                let selectedCapabilityClassID = resolvedCapabilityClassID ?? rankedRoutes.first?.modelCapabilityClassID
                let routes: [BurnBarProviderRoute]
                let blockedCapabilityAlternatives: [BurnBarProviderRoute]
                if let classID = selectedCapabilityClassID {
                    routes = rankedRoutes.filter { $0.modelCapabilityClassID == classID }
                    if !ranking.blockedCapabilityClassRoutes.isEmpty {
                        blockedCapabilityAlternatives = ranking.blockedCapabilityClassRoutes
                    } else {
                        blockedCapabilityAlternatives = rankedRoutes.filter { $0.modelCapabilityClassID != classID }
                    }
                } else {
                    routes = rankedRoutes
                    blockedCapabilityAlternatives = []
                }

                for (index, route) in routes.enumerated() {
                    if let slotID = route.credentialSlotID {
                        try? await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
                    }

                    do {
                        let response: BurnBarProviderProxyResponse
                        switch formatFamily {
                        case .openaiCompat:
                            response = try await providerExecutor.proxyResponses(
                                body: bodyData,
                                route: route
                            )
                        case .anthropic:
                            response = try await anthropicExecutor.proxyResponses(
                                body: bodyData,
                                route: route
                            )
                        }
                        await router.markRouteSuccess(route)
                        await modelHealthStore.recordSuccess(
                            modelID: modelID,
                            formatFamily: formatFamily,
                            route: route
                        )
                        await recordUsageIfAvailable(response.usage, route: route)
                        return GatewayHTTPResponse(
                            status: response.statusCode,
                            headers: ["Content-Type": response.contentType],
                            body: response.body
                        )
                    } catch {
                        lastError = error
                        lastFailedRoute = route
                        await modelHealthStore.recordFailure(
                            modelID: modelID,
                            formatFamily: formatFamily,
                            route: route,
                            error: error
                        )
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

                if let lastError {
                    return providerFailureResponse(lastError, modelID: modelID, route: lastFailedRoute)
                }
            }

            if let lastError {
                return providerFailureResponse(lastError, modelID: modelID, route: lastFailedRoute)
            }
            return noEligibleRouteResponse(modelID: modelID)
        } catch let error as BurnBarProviderRouterError {
            logger.error("gateway_responses_route_error", metadata: ["model": modelID, "error": "\(error)"])
            return noEligibleRouteResponse(modelID: modelID)
        } catch {
            logger.error("gateway_responses_route_error", metadata: ["model": modelID, "error": "\(error)"])
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
            let catalog = configStore.catalogSupport.catalog
            let resolvedCapabilityClassID = capabilityClassID(
                forModelName: modelID,
                catalog: catalog
            )
            let ranking = try await router.scoreAndRankRoutes(
                modelName: modelID,
                requestedFormatFamily: .anthropic,
                requiredCapabilityClassID: resolvedCapabilityClassID
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

            let anthropicSelectedCapabilityClassID = resolvedCapabilityClassID ?? rankedRoutes.first?.modelCapabilityClassID
            let anthropicRoutes: [BurnBarProviderRoute]
            let anthropicBlockedAlternatives: [BurnBarProviderRoute]
            if let classID = anthropicSelectedCapabilityClassID {
                anthropicRoutes = rankedRoutes.filter { $0.modelCapabilityClassID == classID }
                if !ranking.blockedCapabilityClassRoutes.isEmpty {
                    anthropicBlockedAlternatives = ranking.blockedCapabilityClassRoutes
                } else {
                    anthropicBlockedAlternatives = rankedRoutes.filter { $0.modelCapabilityClassID != classID }
                }
            } else {
                anthropicRoutes = rankedRoutes
                anthropicBlockedAlternatives = []
            }

            var lastError: Error?
            var lastFailedRoute: BurnBarProviderRoute?
            for (index, route) in anthropicRoutes.enumerated() {
                if let slotID = route.credentialSlotID {
                    try? await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
                }

                do {
                    let response = try await anthropicExecutor.proxyMessages(
                        body: bodyData,
                        route: route
                    )
                    await router.markRouteSuccess(route)
                    await modelHealthStore.recordSuccess(
                        modelID: modelID,
                        formatFamily: .anthropic,
                        route: route
                    )
                    await recordUsageIfAvailable(response.usage, route: route)
                    return GatewayHTTPResponse(
                        status: response.statusCode,
                        headers: ["Content-Type": response.contentType],
                        body: response.body
                    )
                } catch {
                    lastError = error
                    lastFailedRoute = route
                    await modelHealthStore.recordFailure(
                        modelID: modelID,
                        formatFamily: .anthropic,
                        route: route,
                        error: error
                    )
                    await router.markRouteFailure(route, error: error)
                    let hasMoreCandidates = index < anthropicRoutes.count - 1
                    if shouldFailOverProviderError(error), hasMoreCandidates {
                        continue
                    }
                    break
                }
            }

            if !anthropicBlockedAlternatives.isEmpty,
               let lastError,
               shouldFailOverProviderError(lastError) {
                let classLabel = anthropicSelectedCapabilityClassID ?? modelID
                return jsonResponse(
                    status: 503,
                    body: errorBody(
                        "all routed accounts in capability class \(classLabel) failed; no same-tier fallback remained and downgrade is disabled."
                    )
                )
            }

            if let lastError {
                return providerFailureResponse(lastError, modelID: modelID, route: lastFailedRoute)
            }
            return noEligibleRouteResponse(modelID: modelID)
        } catch {
            logger.error("gateway_anthropic_route_error", metadata: ["model": modelID, "error": "\(error)"])
            return jsonResponse(status: 502, body: errorBody("routing failed: \(error.localizedDescription)"))
        }
    }

    private func providerFailureResponse(
        _ error: Error,
        modelID: String,
        route: BurnBarProviderRoute?
    ) -> GatewayHTTPResponse {
        if let providerError = error as? BurnBarProviderExecutorError,
           case .upstreamError(let statusCode, let body) = providerError {
            if let route {
                let contextualMessage = BurnBarGatewayModelHealthStore.routeFailureMessage(
                    modelID: modelID,
                    statusCode: statusCode,
                    body: body,
                    route: route
                )
                if shouldPreferContextualProviderError(body: body, statusCode: statusCode) {
                    return jsonResponse(status: statusCode, body: errorBody(contextualMessage))
                }
            }
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBody.isEmpty {
                return GatewayHTTPResponse(
                    status: statusCode,
                    headers: ["Content-Type": "application/json"],
                    body: Data(trimmedBody.utf8)
                )
            }
            return jsonResponse(
                status: statusCode,
                body: errorBody("upstream provider returned HTTP \(statusCode)")
            )
        }
        return jsonResponse(status: 502, body: errorBody("routing failed: \(error.localizedDescription)"))
    }

    private func shouldPreferContextualProviderError(body: String, statusCode: Int) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return false
        }
        let message = ((dictionary["error"] as? [String: Any])?["message"] as? String)
            ?? (dictionary["message"] as? String)
            ?? (dictionary["error"] as? String)
            ?? ""
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return statusCode == 429 && (normalizedMessage.isEmpty || normalizedMessage == "error")
    }

    private func noEligibleRouteResponse(modelID: String) -> GatewayHTTPResponse {
        jsonResponse(
            status: 503,
            body: errorBody("No eligible route for \(modelID). Add or enable an account/provider that serves this model.")
        )
    }

    private func routeKey(providerID: String, slotID: String?) -> String {
        "\(providerID)#\(slotID ?? "legacy")"
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

    private func capabilityClassID(
        forModelName modelName: String,
        catalog: BurnBarCatalog
    ) -> String? {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let providerID = normalized.contains(":cloud") || normalized.contains("-cloud") ? "ollama" : nil
        return catalog.capabilityClassID(forModelName: modelName, providerID: providerID)
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
        let models: [CodexModelDescriptor]

        init(data: [ModelDescriptor]) {
            self.data = data
            self.models = data.map(CodexModelDescriptor.init(model:))
        }
    }

    private struct ModelDescriptor: Encodable {
        let id: String
        let object = "model"
        let ownedBy: String
        let providerID: String
        let providerName: String
        let accountID: String
        let accountLabel: String
        let sourceID: String
        let sourceKind: String
        let displayName: String
        let capabilities: [String]
        let formatFamily: String
        let servedEndpoints: [String]
        let quotaState: String
        let enabled: Bool
        let routeEligible: Bool
        let lastRefreshAt: Date?
        let lastError: String?

        init(model: BurnBarLiveAdvertisedModel) {
            self.id = model.id
            self.ownedBy = model.providerID
            self.providerID = model.providerID
            self.providerName = model.providerName
            self.accountID = model.accountID
            self.accountLabel = model.accountLabel
            self.sourceID = model.sourceID
            self.sourceKind = model.sourceKind
            self.displayName = model.displayName
            self.capabilities = model.capabilities
            self.formatFamily = Self.formatFamily(from: model.capabilities).rawValue
            self.servedEndpoints = Self.servedEndpoints(for: Self.formatFamily(from: model.capabilities))
            self.quotaState = model.quotaState.rawValue
            self.enabled = model.enabled
            self.routeEligible = model.routeEligible
            self.lastRefreshAt = model.lastRefreshAt
            self.lastError = model.lastError
        }

        private static func formatFamily(from capabilities: [String]) -> BurnBarProviderFormatFamily {
            if capabilities.contains(BurnBarProviderFormatFamily.anthropic.rawValue) {
                return .anthropic
            }
            return .openaiCompat
        }

        private static func servedEndpoints(for formatFamily: BurnBarProviderFormatFamily) -> [String] {
            switch formatFamily {
            case .openaiCompat:
                return ["/v1/models", "/v1/chat/completions", "/v1/responses"]
            case .anthropic:
                return ["/v1/models", "/v1/messages", "/v1/chat/completions", "/v1/responses"]
            }
        }

        enum CodingKeys: String, CodingKey {
            case id
            case object
            case ownedBy = "owned_by"
            case providerID = "provider_id"
            case providerName = "provider_name"
            case accountID = "account_id"
            case accountLabel = "account_label"
            case sourceID = "source_id"
            case sourceKind = "source_kind"
            case displayName = "display_name"
            case capabilities
            case formatFamily = "format_family"
            case servedEndpoints = "served_endpoints"
            case quotaState = "quota_state"
            case enabled
            case routeEligible = "route_eligible"
            case lastRefreshAt = "last_refresh_at"
            case lastError = "last_error"
        }
    }

    private struct CodexModelDescriptor: Encodable {
        let slug: String
        let displayName: String
        let description: String?
        let defaultReasoningLevel: String?
        let supportedReasoningLevels: [ReasoningLevel]
        let shellType: String
        let visibility: String
        let supportedInAPI: Bool
        let priority: Int
        let additionalSpeedTiers: [String]
        let serviceTiers: [String]
        let availabilityNux: String?
        let upgrade: String?
        let baseInstructions: String
        let modelMessages: String?
        let supportsReasoningSummaries: Bool
        let defaultReasoningSummary: String
        let supportVerbosity: Bool
        let defaultVerbosity: String?
        let applyPatchToolType: String?
        let webSearchToolType: String
        let truncationPolicy: TruncationPolicy
        let supportsParallelToolCalls: Bool
        let supportsImageDetailOriginal: Bool
        let contextWindow: Int
        let maxContextWindow: Int?
        let autoCompactTokenLimit: Int?
        let effectiveContextWindowPercent: Int
        let experimentalSupportedTools: [String]
        let inputModalities: [String]
        let supportsSearchTool: Bool

        init(model: ModelDescriptor) {
            self.slug = model.id
            self.displayName = model.displayName
            self.description = "\(model.providerName) via OpenBurnBar (\(model.accountLabel))"
            self.defaultReasoningLevel = nil
            self.supportedReasoningLevels = []
            self.shellType = "shell_command"
            self.visibility = "list"
            self.supportedInAPI = true
            self.priority = 10_000
            self.additionalSpeedTiers = []
            self.serviceTiers = []
            self.availabilityNux = nil
            self.upgrade = nil
            self.baseInstructions = "You are Codex, a coding agent."
            self.modelMessages = nil
            self.supportsReasoningSummaries = false
            self.defaultReasoningSummary = "auto"
            self.supportVerbosity = false
            self.defaultVerbosity = nil
            self.applyPatchToolType = nil
            self.webSearchToolType = "text"
            self.truncationPolicy = TruncationPolicy(mode: "tokens", limit: 65_536)
            self.supportsParallelToolCalls = false
            self.supportsImageDetailOriginal = false
            self.contextWindow = Self.contextWindow(for: model)
            self.maxContextWindow = Self.contextWindow(for: model)
            self.autoCompactTokenLimit = nil
            self.effectiveContextWindowPercent = 95
            self.experimentalSupportedTools = []
            self.inputModalities = ["text"]
            self.supportsSearchTool = false
        }

        private static func contextWindow(for model: ModelDescriptor) -> Int {
            let id = model.id.lowercased()
            if model.formatFamily == BurnBarProviderFormatFamily.anthropic.rawValue,
               id.contains("opus") {
                return 1_000_000
            }
            if model.formatFamily == BurnBarProviderFormatFamily.anthropic.rawValue {
                return 200_000
            }
            return 65_536
        }

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case description
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case shellType = "shell_type"
            case visibility
            case supportedInAPI = "supported_in_api"
            case priority
            case additionalSpeedTiers = "additional_speed_tiers"
            case serviceTiers = "service_tiers"
            case availabilityNux = "availability_nux"
            case upgrade
            case baseInstructions = "base_instructions"
            case modelMessages = "model_messages"
            case supportsReasoningSummaries = "supports_reasoning_summaries"
            case defaultReasoningSummary = "default_reasoning_summary"
            case supportVerbosity = "support_verbosity"
            case defaultVerbosity = "default_verbosity"
            case applyPatchToolType = "apply_patch_tool_type"
            case webSearchToolType = "web_search_tool_type"
            case truncationPolicy = "truncation_policy"
            case supportsParallelToolCalls = "supports_parallel_tool_calls"
            case supportsImageDetailOriginal = "supports_image_detail_original"
            case contextWindow = "context_window"
            case maxContextWindow = "max_context_window"
            case autoCompactTokenLimit = "auto_compact_token_limit"
            case effectiveContextWindowPercent = "effective_context_window_percent"
            case experimentalSupportedTools = "experimental_supported_tools"
            case inputModalities = "input_modalities"
            case supportsSearchTool = "supports_search_tool"
        }

        struct ReasoningLevel: Encodable {
            let effort: String
            let description: String
        }

        struct TruncationPolicy: Encodable {
            let mode: String
            let limit: Int
        }
    }

    private struct ChatCompletionsRequest: Decodable {
        let model: String
    }

    private struct ResponsesRequest: Decodable {
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
