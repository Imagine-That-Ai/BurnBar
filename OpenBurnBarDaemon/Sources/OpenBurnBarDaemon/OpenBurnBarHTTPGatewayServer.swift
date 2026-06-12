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
    private let proxyRouteLogStore: BurnBarProxyRouteLogStore?
    private let providerExecutor: BurnBarOpenAICompatibleProviderExecutor
    private let anthropicExecutor: BurnBarAnthropicProviderExecutor
    private let factoryExecutor: FactoryDroidProviderExecutor
    /// Experimental, off-by-default interactive-Claude path (Part B2). Non-nil
    /// only when `OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE` opts in. When
    /// present, eligible Anthropic OAuth routes are served by driving a genuine
    /// interactive `claude` TUI instead of the metered programmatic API.
    private let interactiveClaudeExecutor: ClaudeInteractiveSessionExecutor?
    /// Opt-in, off-by-default cross-vendor degrade safety net (Part B3). When
    /// enabled, an OpenAI-chat request whose requested model is unavailable can
    /// fall back to an allow-listed OpenAI-compatible vendor on the user's own
    /// key instead of hard-failing.
    private let crossVendorDegradePolicy: BurnBarCrossVendorDegradePolicy
    private let modelHealthStore: BurnBarGatewayModelHealthStore
    private let modelCatalogSession: URLSession
    private let modelCatalogDroidProcessRunner: any FactoryDroidProcessRunning
    private let logger: BurnBarDaemonLogger
    private let rateLimiter: BurnBarRateLimiter?
    private var listener: NWListener?

    public init(
        configuration: BurnBarGatewayConfiguration,
        configStore: BurnBarConfigStore,
        usageRecorder: BurnBarUsageRecorder? = nil,
        proxyRouteLogStore: BurnBarProxyRouteLogStore? = nil,
        providerExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        anthropicExecutor: BurnBarAnthropicProviderExecutor = BurnBarAnthropicProviderExecutor(),
        factoryExecutor: FactoryDroidProviderExecutor = FactoryDroidProviderExecutor(),
        interactiveClaudeExecutor: ClaudeInteractiveSessionExecutor? = ClaudeInteractiveSessionExecutor.makeIfEnabled(),
        crossVendorDegradePolicy: BurnBarCrossVendorDegradePolicy = .fromEnvironment(),
        modelHealthStore: BurnBarGatewayModelHealthStore = BurnBarGatewayModelHealthStore(),
        modelCatalogSession: URLSession = .shared,
        modelCatalogDroidProcessRunner: any FactoryDroidProcessRunning = FactoryDroidSystemProcessRunner(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "http-gateway"),
        rateLimiter: BurnBarRateLimiter? = nil
    ) {
        self.configuration = configuration
        self.configStore = configStore
        self.usageRecorder = usageRecorder
        self.proxyRouteLogStore = proxyRouteLogStore
        self.providerExecutor = providerExecutor
        self.anthropicExecutor = anthropicExecutor
        self.factoryExecutor = factoryExecutor
        self.interactiveClaudeExecutor = interactiveClaudeExecutor
        self.crossVendorDegradePolicy = crossVendorDegradePolicy
        self.modelHealthStore = modelHealthStore
        self.modelCatalogSession = modelCatalogSession
        self.modelCatalogDroidProcessRunner = modelCatalogDroidProcessRunner
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

        let boundPort = self.configuration.port
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                BurnBarDaemonMetricsCounters.recordGatewayListenerReady()
                self.logger.notice("gateway_started", metadata: [
                    "host": host,
                    "port": "\(boundPort)",
                    "auth_required": "\(self.configuration.authToken != nil)"
                ])
            case .failed(let error):
                let reason = Self.listenerFailureReason(error, host: host, port: boundPort)
                BurnBarDaemonMetricsCounters.recordGatewayListenerFailure(reason)
                self.logger.error("gateway_listener_failed", metadata: [
                    "host": host,
                    "port": "\(boundPort)",
                    "reason": reason,
                    "error": "\(error)"
                ])
                // Tear the failed listener down so it is not left as a silent
                // zombie (a non-nil `listener` makes future `start()` calls
                // no-op). Clearing it lets a daemon restart rebind cleanly once
                // the conflicting process releases the port.
                Task { await self.handleListenerFailure() }
            default:
                break
            }
        }

        self.listener = nwListener
        nwListener.start(queue: .global(qos: .utility))
    }

    /// Tears down a listener that transitioned to `.failed` so the gateway does
    /// not sit bound-but-not-serving with a stale `listener` reference.
    private func handleListenerFailure() {
        listener?.cancel()
        listener = nil
    }

    /// Builds an operator-facing reason string for a listener bind failure,
    /// special-casing address-in-use (the common "port 8317 already taken"
    /// case) so the remediation is obvious in logs and on `GET /metrics`.
    nonisolated static func listenerFailureReason(_ error: NWError, host: String, port: Int) -> String {
        if case let .posix(code) = error, code == .EADDRINUSE {
            return "gateway port \(port) on \(host) is already in use by another process — the gateway is not serving"
        }
        if case let .posix(code) = error, code == .EACCES {
            return "permission denied binding gateway port \(port) on \(host)"
        }
        return "gateway listener on \(host):\(port) failed: \(error.localizedDescription)"
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
            let presented = clientAuthToken(from: request)
            guard let presented, constantTimeTokensEqual(presented, requiredToken) else {
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

        let cors = corsHeaders(for: request)
        let outcome = await routeRequest(request, connection: connection, corsHeaders: cors)
        switch outcome {
        case .buffered(let routedResponse):
            var headers = routedResponse.headers
            for (key, value) in cors {
                headers[key] = value
            }
            await writeResponse(on: connection, response: routedResponse.withHeaders(headers))
            connection.cancel()
        case .streamed:
            // The streaming relay has already written the full response
            // (head + chunks) directly to the connection; just close it.
            connection.cancel()
        }
    }

    private func routeRequest(
        _ request: HTTPRequest,
        connection: NWConnection,
        corsHeaders: [String: String]
    ) async -> GatewayRouteOutcome {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .buffered(jsonResponse(status: 200, body: encodeBody(HealthResponse(ok: true, version: BurnBarDaemonVersion.current))))

        case ("GET", "/metrics"):
            return .buffered(handleMetrics())

        case ("GET", "/v1/models"):
            return .buffered(await handleModels())

        case ("GET", "/v1/models/catalog"):
            return .buffered(await handleModels(includeUnadvertised: true))

        case ("POST", "/v1/chat/completions"):
            return await handleChatCompletions(body: request.body, connection: connection, corsHeaders: corsHeaders)

        case ("POST", "/v1/responses"):
            return await handleResponses(body: request.body)

        case ("POST", "/v1/messages"):
            return await handleAnthropicMessages(body: request.body, connection: connection, corsHeaders: corsHeaders)

        default:
            return .buffered(jsonResponse(status: 404, body: errorBody("not found")))
        }
    }

    private func handleMetrics() -> GatewayHTTPResponse {
        let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: configuration.isEnabled)
        return jsonResponse(status: 200, body: encodeBody(snapshot))
    }

    // MARK: - /v1/models

    private func handleModels(includeUnadvertised: Bool = false) async -> GatewayHTTPResponse {
        do {
            let catalog = configStore.catalogSupport.catalog
            let configSnapshot = try await configStore.snapshot()
            let suppressedBaseIDs = includeUnadvertised
                ? Set<String>()
                : suppressedBaseModelIDs(from: configSnapshot)
            let snapshot = try await BurnBarLiveModelCatalog(
                configStore: configStore,
                session: modelCatalogSession,
                droidProcessRunner: modelCatalogDroidProcessRunner
            ).snapshot()
            var entries: [GatewayModelCatalogEntry] = []
            for model in snapshot.models {
                if !includeUnadvertised,
                   isSuppressedBaseModelRow(model, suppressedBaseIDs: suppressedBaseIDs) {
                    continue
                }
                let canAdvertise = await canAdvertiseModel(model, catalog: catalog)
                let advertised = model.routeEligible && model.advertisementEnabled && canAdvertise
                if advertised || (includeUnadvertised && model.enabled) {
                    entries.append(GatewayModelCatalogEntry(model: model, advertised: advertised))
                }
            }
            let groups = groupedModelCatalogEntries(entries)
            let duplicateModelIDs = duplicateAdvertisedModelIDs(in: groups)
            let models = groups.map { group in
                ModelDescriptor(
                    group: group,
                    advertisedID: gatewayRouteModelID(for: group, duplicateModelIDs: duplicateModelIDs)
                )
            }
            return jsonResponse(status: 200, body: encodeBody(ModelsResponse(data: models)))
        } catch {
            logger.error("gateway_models_error", metadata: ["error": "\(error)"])
            return jsonResponse(status: 500, body: errorBody("internal error"))
        }
    }

    private func canAdvertiseModel(
        _ model: BurnBarLiveAdvertisedModel,
        catalog: BurnBarCatalog
    ) async -> Bool {
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
        return true
    }

    private func canRouteAdvertisedModel(
        _ model: BurnBarLiveAdvertisedModel,
        router: BurnBarProviderRouter,
        catalog: BurnBarCatalog
    ) async -> Bool {
        guard await canAdvertiseModel(model, catalog: catalog) else { return false }

        let formatFamily = advertisedFormatFamily(for: model, catalog: catalog)
        let expectedRouteKey = routeKey(
            providerID: model.providerID,
            slotID: model.accountID == "legacy" ? nil : model.accountID
        )
        do {
            let ranking = try await router.scoreAndRankRoutes(
                modelName: model.id,
                requestedFormatFamily: formatFamily,
                requiredCanonicalModelID: canonicalModelID(
                    forModelName: model.id,
                    providerID: model.providerID,
                    catalog: catalog
                )
            )
            return ranking.rankedRoutes.contains { rankedRoute in
                routeKey(
                    providerID: rankedRoute.route.providerID,
                    slotID: rankedRoute.route.credentialSlotID
                ) == expectedRouteKey
            }
        } catch {
            logger.warning(
                "gateway_models_route_unavailable",
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

    /// Detect when the inbound wire id refers to a thinking-level variant
    /// (e.g. `claude-opus-4-7-xhigh`) or a user-defined alias (`my-coder`) and
    /// resolve it back to the base model the router knows how to score.
    private struct GatewayProxyModelOverride {
        let requestedModel: GatewayRequestedModel
        let advertisedRequestedModel: GatewayRequestedModel
        let variant: BurnBarModelVariant?
        let alias: BurnBarModelAlias?
    }

    private func resolveProxyModelOverride(
        forRequestedModel requestedModel: GatewayRequestedModel
    ) async -> GatewayProxyModelOverride? {
        guard let snapshot = try? await configStore.snapshot() else { return nil }
        let requested = requestedModel.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return nil }

        let providersToScan: [BurnBarProviderSettings]
        if let providerID = requestedModel.providerID {
            providersToScan = snapshot.providers.filter {
                $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
            }
        } else {
            providersToScan = snapshot.providers
        }

        for provider in providersToScan {
            if let variant = provider.modelVariants.first(where: {
                $0.variantID.caseInsensitiveCompare(requested) == .orderedSame
            }) {
                let rewritten = GatewayRequestedModel(
                    originalID: requestedModel.originalID,
                    modelID: variant.baseModelID,
                    providerID: requestedModel.providerID ?? provider.providerID,
                    accountID: requestedModel.accountID
                )
                return GatewayProxyModelOverride(
                    requestedModel: rewritten,
                    advertisedRequestedModel: requestedModel,
                    variant: variant,
                    alias: nil
                )
            }
        }

        for provider in providersToScan {
            if let alias = provider.modelAliases.first(where: {
                $0.aliasID.caseInsensitiveCompare(requested) == .orderedSame
            }) {
                let rewritten = GatewayRequestedModel(
                    originalID: requestedModel.originalID,
                    modelID: alias.baseModelID,
                    providerID: requestedModel.providerID ?? provider.providerID,
                    accountID: requestedModel.accountID
                )
                return GatewayProxyModelOverride(
                    requestedModel: rewritten,
                    advertisedRequestedModel: requestedModel,
                    variant: nil,
                    alias: alias
                )
            }
        }
        return nil
    }

    private func suppressedBaseModelIDs(from snapshot: BurnBarProviderConfigurationSnapshot) -> Set<String> {
        var suppressed = Set<String>()
        for provider in snapshot.providers {
            for alias in provider.modelAliases where alias.hidesBaseModel {
                guard provider.isModelAdvertisementEnabled(alias.aliasID) else { continue }
                let normalizedBase = alias.baseModelID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !normalizedBase.isEmpty else { continue }
                suppressed.insert(normalizedBase)
            }
        }
        return suppressed
    }

    private func isSuppressedBaseModelRow(
        _ model: BurnBarLiveAdvertisedModel,
        suppressedBaseIDs: Set<String>
    ) -> Bool {
        guard model.baseModelID == nil, model.thinkingLevel == nil else { return false }
        guard model.sourceKind != "user_model_alias" else { return false }
        let normalizedID = model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return suppressedBaseIDs.contains(normalizedID)
    }

    private func advertisedRouteKeysByFamily(for requestedModel: GatewayRequestedModel) async throws -> [BurnBarProviderFormatFamily: Set<String>] {
        let normalizedModelID = requestedModel.modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedModelID.isEmpty == false else { return [:] }

        let catalog = configStore.catalogSupport.catalog
        let snapshot = try await BurnBarLiveModelCatalog(
            configStore: configStore,
            session: modelCatalogSession
        ).snapshot()

        var routeKeysByFamily: [BurnBarProviderFormatFamily: Set<String>] = [:]
        for model in snapshot.models where model.routeEligible && model.advertisementEnabled {
            if let providerID = requestedModel.providerID,
               model.providerID.caseInsensitiveCompare(providerID) != .orderedSame {
                continue
            }
            if let accountID = requestedModel.accountID,
               model.accountID.caseInsensitiveCompare(accountID) != .orderedSame {
                continue
            }
            guard modelMatchesRequested(
                model,
                normalizedRequestedModelID: normalizedModelID,
                providerID: model.providerID,
                catalog: catalog
            ) else {
                continue
            }
            guard await canAdvertiseModel(model, catalog: catalog) else {
                continue
            }
            let family = advertisedFormatFamily(for: model, catalog: catalog)
            routeKeysByFamily[family, default: []].insert(
                routeKey(providerID: model.providerID, slotID: model.accountID == "legacy" ? nil : model.accountID)
            )
        }
        return routeKeysByFamily
    }

    private struct GatewayAdvertisedRouteResolution {
        let requestedModel: GatewayRequestedModel
        let advertisedRequestedModel: GatewayRequestedModel
        let routeKeysByFamily: [BurnBarProviderFormatFamily: Set<String>]
    }

    private func resolveAdvertisedRouteKeys(
        requestedModel: GatewayRequestedModel,
        advertisedRequestedModel: GatewayRequestedModel
    ) async throws -> GatewayAdvertisedRouteResolution {
        let primaryKeys = try await advertisedRouteKeysByFamily(for: advertisedRequestedModel)
        if primaryKeys.values.contains(where: { !$0.isEmpty }) {
            return GatewayAdvertisedRouteResolution(
                requestedModel: requestedModel,
                advertisedRequestedModel: advertisedRequestedModel,
                routeKeysByFamily: primaryKeys
            )
        }

        guard let cloudCandidate = legacyOllamaCloudCandidate(for: requestedModel) else {
            return GatewayAdvertisedRouteResolution(
                requestedModel: requestedModel,
                advertisedRequestedModel: advertisedRequestedModel,
                routeKeysByFamily: primaryKeys
            )
        }

        let cloudKeys = try await advertisedRouteKeysByFamily(for: cloudCandidate)
        guard cloudKeys.values.contains(where: { !$0.isEmpty }) else {
            return GatewayAdvertisedRouteResolution(
                requestedModel: requestedModel,
                advertisedRequestedModel: advertisedRequestedModel,
                routeKeysByFamily: primaryKeys
            )
        }
        return GatewayAdvertisedRouteResolution(
            requestedModel: cloudCandidate,
            advertisedRequestedModel: cloudCandidate,
            routeKeysByFamily: cloudKeys
        )
    }

    private func legacyOllamaCloudCandidate(for requestedModel: GatewayRequestedModel) -> GatewayRequestedModel? {
        let requested = requestedModel.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return nil }
        let lowercased = requested.lowercased()
        guard !lowercased.hasSuffix(":cloud"), !lowercased.hasSuffix("-cloud") else {
            return nil
        }

        let accountID: String?
        if requestedModel.providerID?.caseInsensitiveCompare("ollama") == .orderedSame {
            accountID = requestedModel.accountID
        } else {
            accountID = nil
        }
        return GatewayRequestedModel(
            originalID: requestedModel.originalID,
            modelID: "\(requested):cloud",
            providerID: "ollama",
            accountID: accountID
        )
    }

    private struct GatewayModelCatalogEntry {
        let model: BurnBarLiveAdvertisedModel
        let advertised: Bool
    }

    private struct GatewayModelCatalogGroup {
        let providerID: String
        let normalizedModelID: String
        var entries: [GatewayModelCatalogEntry]

        var representative: BurnBarLiveAdvertisedModel {
            entries.first(where: { $0.advertised })?.model ?? entries[0].model
        }

        var advertised: Bool {
            entries.contains { $0.advertised }
        }
    }

    private func groupedModelCatalogEntries(_ entries: [GatewayModelCatalogEntry]) -> [GatewayModelCatalogGroup] {
        var groupsByKey: [String: GatewayModelCatalogGroup] = [:]
        for entry in entries {
            let providerID = entry.model.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedModelID = entry.model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !providerID.isEmpty, !normalizedModelID.isEmpty else { continue }
            let key = "\(providerID.lowercased())|\(normalizedModelID)"
            if var group = groupsByKey[key] {
                group.entries.append(entry)
                groupsByKey[key] = group
            } else {
                groupsByKey[key] = GatewayModelCatalogGroup(
                    providerID: providerID,
                    normalizedModelID: normalizedModelID,
                    entries: [entry]
                )
            }
        }
        return groupsByKey.values.sorted { lhs, rhs in
            let lhsModel = lhs.representative
            let rhsModel = rhs.representative
            let providerOrder = lhsModel.providerName.localizedCaseInsensitiveCompare(rhsModel.providerName)
            if providerOrder != .orderedSame {
                return providerOrder == .orderedAscending
            }
            let displayOrder = lhsModel.displayName.localizedCaseInsensitiveCompare(rhsModel.displayName)
            if displayOrder != .orderedSame {
                return displayOrder == .orderedAscending
            }
            return lhsModel.id.localizedCaseInsensitiveCompare(rhsModel.id) == .orderedAscending
        }
    }

    private func duplicateAdvertisedModelIDs(in groups: [GatewayModelCatalogGroup]) -> Set<String> {
        let counts = Dictionary(grouping: groups) {
            $0.representative.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return Set(counts.compactMap { key, rows in
            key.isEmpty || rows.count < 2 ? nil : key
        })
    }

    private func gatewayRouteModelID(
        for group: GatewayModelCatalogGroup,
        duplicateModelIDs: Set<String>
    ) -> String {
        let rawID = group.representative.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard duplicateModelIDs.contains(rawID.lowercased()) else {
            return rawID
        }
        return "\(group.providerID)/\(rawID)"
    }

    private struct GatewayRequestedModel {
        let originalID: String
        let modelID: String
        let providerID: String?
        let accountID: String?
    }

    private func gatewayRequestedModel(from rawID: String) -> GatewayRequestedModel {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2,
              configStore.catalogSupport.provider(id: parts[0]) != nil else {
            return GatewayRequestedModel(originalID: trimmed, modelID: trimmed, providerID: nil, accountID: nil)
        }

        if parts.count >= 3 {
            let modelID = parts.dropFirst(2).joined(separator: "/")
            if !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return GatewayRequestedModel(
                    originalID: trimmed,
                    modelID: modelID,
                    providerID: parts[0],
                    accountID: parts[1]
                )
            }
        }

        let modelID = parts.dropFirst().joined(separator: "/")
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GatewayRequestedModel(originalID: trimmed, modelID: trimmed, providerID: nil, accountID: nil)
        }
        return GatewayRequestedModel(originalID: trimmed, modelID: modelID, providerID: parts[0], accountID: nil)
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

    private func singleAdvertisedProviderID(
        in advertised: [BurnBarProviderFormatFamily: Set<String>]
    ) -> String? {
        var providerIDs: Set<String> = []
        for routeKeys in advertised.values {
            for routeKey in routeKeys {
                let providerID = routeKey
                    .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let providerID, !providerID.isEmpty {
                    providerIDs.insert(providerID)
                }
            }
        }
        return providerIDs.count == 1 ? providerIDs.first : nil
    }

    private func modelMatchesRequested(
        _ model: BurnBarLiveAdvertisedModel,
        normalizedRequestedModelID: String,
        providerID: String,
        catalog: BurnBarCatalog
    ) -> Bool {
        if advertisedModel(
            model.id,
            matchesRequestedModelID: normalizedRequestedModelID,
            providerID: providerID,
            catalog: catalog
        ) {
            return true
        }
        if let baseModelID = model.baseModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !baseModelID.isEmpty,
           baseModelID == normalizedRequestedModelID {
            return true
        }
        return false
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

        if normalizedAdvertisedModelID.hasSuffix(":cloud") != normalizedRequestedModelID.hasSuffix(":cloud") {
            return false
        }

        return catalog.models(forProviderID: providerID).contains { model in
            let explicitModelIDs = Set(([model.id] + model.aliases).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            return explicitModelIDs.contains(normalizedRequestedModelID)
                && explicitModelIDs.contains(normalizedAdvertisedModelID)
        }
    }

    // MARK: - /v1/chat/completions

    private func handleChatCompletions(
        body: String?,
        connection: NWConnection,
        corsHeaders: [String: String]
    ) async -> GatewayRouteOutcome {
        await routeModelRequest(
            body: body,
            connection: connection,
            corsHeaders: corsHeaders,
            descriptor: chatCompletionsEndpointDescriptor
        )
    }

    /// Per-endpoint pipeline parameterization for `/v1/chat/completions`.
    private var chatCompletionsEndpointDescriptor: GatewayEndpointDescriptor {
        GatewayEndpointDescriptor(
            requestPath: "/v1/chat/completions",
            endpoint: "Chat Completions",
            routeErrorLogEvent: "gateway_route_error",
            routerLoggerCategory: "gateway-router",
            allowDynamicOpenAICompatibleModels: true,
            treatsRouterErrorAsNoEligibleRoute: true,
            finalRejectUsesRankingCanonicalModelID: false,
            decodeRequest: { data in
                let request = try JSONDecoder().decode(ChatCompletionsRequest.self, from: data)
                return GatewayDecodedModelRequest(model: request.model, wantsStream: request.stream == true)
            },
            selectFormatFamilies: { advertised, requestedModel, _ in
                .families(self.preferredGatewayFormatFamilies(for: requestedModel.modelID, advertised: advertised))
            },
            filterRankedRoutes: { routes, _ in routes },
            emptyRankedRoutesRejection: nil,
            streamAttempt: { context in
                // Verbatim SSE passthrough only when the client wire
                // format (OpenAI chat) matches the upstream family.
                // Mixed families (e.g. Anthropic serving chat) require
                // translation and stay on the buffered path.
                guard context.wantsStream,
                      context.formatFamily == .openaiCompat,
                      context.route.providerID.caseInsensitiveCompare("factory") != .orderedSame else {
                    return nil
                }
                return GatewayStreamAttemptPlan(usageFormat: .openAI) {
                    try await self.providerExecutor.openChatCompletionsStream(
                        body: context.bodyData,
                        route: context.route,
                        variant: context.variant
                    )
                }
            },
            proxyBuffered: { context in
                try await self.proxyChatCompletions(
                    body: context.bodyData,
                    route: context.route,
                    formatFamily: context.formatFamily,
                    variant: context.variant
                )
            },
            attemptDegrade: { request in
                await self.attemptCrossVendorDegradeForChat(
                    bodyData: request.bodyData,
                    requestSignature: request.requestSignature,
                    requestedModelID: request.modelID,
                    routeLogStartedAt: request.startedAt,
                    requestPath: request.requestPath,
                    endpoint: request.endpoint,
                    advertisedModelSlug: request.advertisedModelSlug,
                    routingModelSlug: request.routingModelSlug,
                    requestedCanonicalModelID: request.requestedCanonicalModelID,
                    priorAttempts: request.priorAttempts
                )
            }
        )
    }

    // MARK: - /v1/responses

    private func handleResponses(body: String?) async -> GatewayRouteOutcome {
        await routeModelRequest(
            body: body,
            connection: nil,
            corsHeaders: [:],
            descriptor: responsesEndpointDescriptor
        )
    }

    /// Per-endpoint pipeline parameterization for `/v1/responses`.
    private var responsesEndpointDescriptor: GatewayEndpointDescriptor {
        GatewayEndpointDescriptor(
            requestPath: "/v1/responses",
            endpoint: "Responses",
            routeErrorLogEvent: "gateway_responses_route_error",
            routerLoggerCategory: "gateway-router-responses",
            allowDynamicOpenAICompatibleModels: true,
            treatsRouterErrorAsNoEligibleRoute: true,
            finalRejectUsesRankingCanonicalModelID: false,
            decodeRequest: { data in
                let request = try JSONDecoder().decode(ResponsesRequest.self, from: data)
                return GatewayDecodedModelRequest(model: request.model, wantsStream: request.stream == true)
            },
            selectFormatFamilies: { advertised, requestedModel, _ in
                .families(self.preferredGatewayFormatFamilies(for: requestedModel.modelID, advertised: advertised))
            },
            filterRankedRoutes: { routes, _ in routes },
            emptyRankedRoutesRejection: nil,
            // /v1/responses is served buffered-only; no verbatim relay.
            streamAttempt: { _ in nil },
            proxyBuffered: { context in
                try await self.proxyResponses(
                    body: context.bodyData,
                    route: context.route,
                    formatFamily: context.formatFamily,
                    variant: context.variant
                )
            },
            attemptDegrade: nil
        )
    }

    // MARK: - /v1/messages (Anthropic Messages format)

    private func handleAnthropicMessages(
        body: String?,
        connection: NWConnection,
        corsHeaders: [String: String]
    ) async -> GatewayRouteOutcome {
        await routeModelRequest(
            body: body,
            connection: connection,
            corsHeaders: corsHeaders,
            descriptor: anthropicMessagesEndpointDescriptor
        )
    }

    /// Per-endpoint pipeline parameterization for `/v1/messages`.
    private var anthropicMessagesEndpointDescriptor: GatewayEndpointDescriptor {
        GatewayEndpointDescriptor(
            requestPath: "/v1/messages",
            endpoint: "Anthropic Messages",
            routeErrorLogEvent: "gateway_anthropic_route_error",
            routerLoggerCategory: "gateway-router-anthropic",
            allowDynamicOpenAICompatibleModels: false,
            treatsRouterErrorAsNoEligibleRoute: false,
            finalRejectUsesRankingCanonicalModelID: true,
            decodeRequest: { data in
                let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)
                return GatewayDecodedModelRequest(model: request.model, wantsStream: request.stream == true)
            },
            selectFormatFamilies: { advertised, _, clientModelID in
                guard advertised[.anthropic]?.isEmpty == false else {
                    return .reject(failureMessage: "No eligible Anthropic-family route for \(clientModelID).")
                }
                return .families([.anthropic])
            },
            filterRankedRoutes: { routes, requestedModel in
                routes.filter {
                    guard let accountID = requestedModel.accountID else { return true }
                    return $0.credentialSlotID?.caseInsensitiveCompare(accountID) == .orderedSame
                }
            },
            emptyRankedRoutesRejection: { clientModelID in
                let detail = "no eligible Anthropic-family route for \(clientModelID). "
                    + "Add an Anthropic Console API key or an Anthropic Pro/Team plan to serve /v1/messages."
                return (
                    failureMessage: "No eligible Anthropic-family route for \(clientModelID).",
                    response: self.jsonResponse(status: 503, body: self.errorBody(detail))
                )
            },
            streamAttempt: { context in
                // B2: when the experimental interactive path is enabled and
                // this OAuth subscription route is eligible, a real
                // interactive `claude` TUI serves the request. It produces
                // a single buffered answer, so verbatim streaming is
                // skipped for these routes. Otherwise the client wire
                // format (Anthropic messages) matches the upstream route
                // family, so chunks relay unchanged.
                let useInteractiveClaude = self.interactiveClaudeExecutor != nil
                    && ClaudeInteractiveSessionExecutor.isEligible(route: context.route)
                guard context.wantsStream, !useInteractiveClaude else { return nil }
                return GatewayStreamAttemptPlan(usageFormat: .anthropic) {
                    try await self.anthropicExecutor.openMessagesStream(
                        body: context.bodyData,
                        route: context.route,
                        variant: context.variant
                    )
                }
            },
            proxyBuffered: { context in
                if let interactiveClaudeExecutor = self.interactiveClaudeExecutor,
                   ClaudeInteractiveSessionExecutor.isEligible(route: context.route) {
                    return try await interactiveClaudeExecutor.proxyMessages(
                        body: context.bodyData,
                        route: context.route,
                        variant: context.variant
                    )
                }
                return try await self.anthropicExecutor.proxyMessages(
                    body: context.bodyData,
                    route: context.route,
                    variant: context.variant
                )
            },
            attemptDegrade: nil
        )
    }

    // MARK: - Unified model-endpoint route pipeline

    /// Everything that differs between the three model-serving endpoints
    /// (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`), so
    /// `routeModelRequest` can drive the shared route-resolve → attempt-loop →
    /// fail-over → usage-record sequence for all of them (finding-16/63).
    private struct GatewayEndpointDescriptor {
        /// Request path as served (e.g. "/v1/chat/completions").
        let requestPath: String
        /// Human-readable endpoint name for route-log entries.
        let endpoint: String
        /// Logger event name when routing throws.
        let routeErrorLogEvent: String
        /// Category for the per-request provider-router logger.
        let routerLoggerCategory: String
        /// Forwarded to `BurnBarProviderRouter.init`.
        let allowDynamicOpenAICompatibleModels: Bool
        /// `true` maps a thrown `BurnBarProviderRouterError` to the 503
        /// no-eligible-route response (chat/responses); `false` lets it fall
        /// through to the generic 502 routing-failure response (Anthropic).
        let treatsRouterErrorAsNoEligibleRoute: Bool
        /// `true` stamps the final no-eligible-route record with the ranking's
        /// required canonical model ID (Anthropic); `false` uses the
        /// catalog-derived requested canonical ID (chat/responses).
        let finalRejectUsesRankingCanonicalModelID: Bool
        /// Decodes the endpoint's wire request far enough for routing: the
        /// model slug and whether the client asked for a streamed response.
        let decodeRequest: (Data) throws -> GatewayDecodedModelRequest
        /// Chooses the format families to attempt (in order), or rejects the
        /// request up front (Anthropic without an Anthropic-family route).
        /// Receives the advertised route keys by family, the (post-resolution)
        /// requested model, and the client's model slug for error copy.
        let selectFormatFamilies: (
            [BurnBarProviderFormatFamily: Set<String>],
            GatewayRequestedModel,
            String
        ) -> GatewayFormatFamilySelection
        /// Endpoint-specific narrowing of the ranked routes (e.g. Anthropic
        /// account pinning), applied before the advertised-route-key filter.
        let filterRankedRoutes: ([BurnBarProviderRoute], GatewayRequestedModel) -> [BurnBarProviderRoute]
        /// When non-nil, an empty ranked-route set rejects the request with
        /// the returned log message and response instead of moving on to the
        /// next format family.
        let emptyRankedRoutesRejection: ((String) -> (failureMessage: String, response: GatewayHTTPResponse))?
        /// Verbatim SSE passthrough plan for one attempt, or nil to serve the
        /// attempt on the buffered path.
        let streamAttempt: (GatewayRouteAttemptContext) -> GatewayStreamAttemptPlan?
        /// Buffered (non-streaming) proxy call for one attempt.
        let proxyBuffered: (GatewayRouteAttemptContext) async throws -> BurnBarProviderProxyResponse
        /// Cross-vendor degrade safety net (chat only, Part B3).
        let attemptDegrade: ((GatewayDegradeRequest) async -> GatewayDegradeAttemptResult?)?
    }

    /// The routing-relevant fields of a decoded model-endpoint request.
    private struct GatewayDecodedModelRequest {
        let model: String
        let wantsStream: Bool
    }

    private enum GatewayFormatFamilySelection {
        case families([BurnBarProviderFormatFamily])
        case reject(failureMessage: String)
    }

    /// Inputs available to one route attempt inside the shared pipeline.
    private struct GatewayRouteAttemptContext {
        let bodyData: Data
        let route: BurnBarProviderRoute
        let formatFamily: BurnBarProviderFormatFamily
        let wantsStream: Bool
        let variant: BurnBarModelVariant?
    }

    /// How to relay one attempt as a verbatim SSE stream.
    private struct GatewayStreamAttemptPlan {
        let usageFormat: GatewayStreamUsageFormat
        let openStream: () async throws -> BurnBarProviderProxyStream
    }

    /// Pipeline state handed to the cross-vendor degrade hook.
    private struct GatewayDegradeRequest {
        let bodyData: Data
        let requestSignature: String
        let modelID: String
        let startedAt: Date
        let requestPath: String
        let endpoint: String
        let advertisedModelSlug: String?
        let routingModelSlug: String?
        let requestedCanonicalModelID: String?
        let priorAttempts: [BurnBarProxyRouteAttempt]
    }

    /// Shared routing pipeline behind the three model-serving endpoints:
    /// validate and decode the body, resolve model overrides and advertised
    /// routes, then walk format families and ranked routes attempting the
    /// request (verbatim-stream first when eligible, buffered otherwise),
    /// failing over between accounts on quota/credential errors, recording
    /// usage, and writing exactly one proxy route-log entry per request.
    private func routeModelRequest(
        body: String?,
        connection: NWConnection?,
        corsHeaders: [String: String],
        descriptor: GatewayEndpointDescriptor
    ) async -> GatewayRouteOutcome {
        guard let body, !body.isEmpty else {
            return .buffered(jsonResponse(status: 400, body: errorBody("request body required")))
        }

        guard let bodyData = body.data(using: .utf8) else {
            return .buffered(jsonResponse(status: 400, body: errorBody("request body must be valid UTF-8")))
        }

        let decoded: GatewayDecodedModelRequest
        do {
            decoded = try descriptor.decodeRequest(bodyData)
        } catch {
            return .buffered(jsonResponse(status: 400, body: errorBody("invalid JSON request body")))
        }

        let modelID = decoded.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelID.isEmpty == false else {
            return .buffered(jsonResponse(status: 400, body: errorBody("model field required")))
        }
        let routeLogStartedAt = Date()
        var routeLogAttempts = RouteAttemptRecorder()
        let wantsStream = decoded.wantsStream
        let requestSignature = Self.stableDigest(body)
        var requestedModel = gatewayRequestedModel(from: modelID)
        var advertisedRequestedModel = requestedModel
        var resolvedVariant: BurnBarModelVariant?
        var logContext = GatewayRequestContext(
            startedAt: routeLogStartedAt,
            requestPath: descriptor.requestPath,
            endpoint: descriptor.endpoint,
            clientModelSlug: modelID,
            advertisedModelSlug: advertisedRequestedModel.originalID,
            routingModelSlug: requestedModel.modelID,
            clientModelDisplayName: modelID,
            routingModelDisplayName: requestedModel.modelID,
            rewriteKind: .none
        )
        if let override = await resolveProxyModelOverride(forRequestedModel: requestedModel) {
            requestedModel = override.requestedModel
            advertisedRequestedModel = override.advertisedRequestedModel
            resolvedVariant = override.variant
            logContext.rewriteKind = override.variant != nil ? .thinkingVariant : .modelAlias
            logContext.advertisedModelSlug = advertisedRequestedModel.originalID
            logContext.routingModelSlug = requestedModel.modelID
            logContext.routingModelDisplayName = requestedModel.modelID
        }

        // Snapshot of the pipeline state for the cross-vendor degrade hook.
        // Reads the routing locals at call time, after any reassignment.
        func degradeRequest(requestedCanonicalModelID: String?) -> GatewayDegradeRequest {
            GatewayDegradeRequest(
                bodyData: bodyData,
                requestSignature: requestSignature,
                modelID: modelID,
                startedAt: routeLogStartedAt,
                requestPath: descriptor.requestPath,
                endpoint: descriptor.endpoint,
                advertisedModelSlug: advertisedRequestedModel.originalID,
                routingModelSlug: requestedModel.modelID,
                requestedCanonicalModelID: requestedCanonicalModelID,
                priorAttempts: routeLogAttempts.attempts
            )
        }

        do {
            let routingModelBeforeAdvertisedResolution = requestedModel.modelID
            let routeResolution = try await resolveAdvertisedRouteKeys(
                requestedModel: requestedModel,
                advertisedRequestedModel: advertisedRequestedModel
            )
            requestedModel = routeResolution.requestedModel
            advertisedRequestedModel = routeResolution.advertisedRequestedModel
            logContext.advertisedModelSlug = advertisedRequestedModel.originalID
            logContext.routingModelSlug = requestedModel.modelID
            logContext.routingModelDisplayName = requestedModel.modelID
            if requestedModel.modelID.caseInsensitiveCompare(routingModelBeforeAdvertisedResolution) != .orderedSame {
                logContext.rewriteKind = .legacyOllamaCloud
            }
            let advertisedRouteKeysByFamily = routeResolution.routeKeysByFamily
            guard advertisedRouteKeysByFamily.values.contains(where: { !$0.isEmpty }) else {
                if let attemptDegrade = descriptor.attemptDegrade,
                   let degraded = await attemptDegrade(degradeRequest(requestedCanonicalModelID: nil)) {
                    routeLogAttempts.append(contentsOf: degraded.attempts)
                    if let outcome = degraded.outcome {
                        return outcome
                    }
                }
                await recordProxyRouteLogEntry(
                    context: logContext,
                    requestedCanonicalModelID: nil,
                    route: nil,
                    finalStatus: .rejected,
                    httpStatus: 503,
                    attempts: routeLogAttempts.attempts,
                    failureMessage: "No eligible route for \(modelID)."
                )
                return .buffered(noEligibleRouteResponse(modelID: modelID))
            }

            let formatFamilies: [BurnBarProviderFormatFamily]
            switch descriptor.selectFormatFamilies(advertisedRouteKeysByFamily, requestedModel, modelID) {
            case .families(let families):
                formatFamilies = families
            case .reject(let failureMessage):
                await recordProxyRouteLogEntry(
                    context: logContext,
                    requestedCanonicalModelID: nil,
                    route: nil,
                    finalStatus: .rejected,
                    httpStatus: 503,
                    attempts: routeLogAttempts.attempts,
                    failureMessage: failureMessage
                )
                return .buffered(noEligibleRouteResponse(modelID: modelID))
            }

            let router = BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: descriptor.routerLoggerCategory),
                routingEventStore: BurnBarProviderRoutingDecisionEventStore(),
                allowDynamicOpenAICompatibleModels: descriptor.allowDynamicOpenAICompatibleModels
            )
            let catalog = configStore.catalogSupport.catalog
            let effectiveProviderID = requestedModel.providerID
                ?? singleAdvertisedProviderID(in: advertisedRouteKeysByFamily)
            let requestedCanonicalModelID = canonicalModelID(
                forModelName: requestedModel.modelID,
                providerID: effectiveProviderID,
                catalog: catalog
            )
            var lastError: Error?
            var lastFailedRoute: BurnBarProviderRoute?
            var lastRankingRequiredCanonicalModelID: String?
            for formatFamily in formatFamilies {
                guard let advertisedRouteKeys = advertisedRouteKeysByFamily[formatFamily], !advertisedRouteKeys.isEmpty else {
                    continue
                }

                let ranking = try await router.scoreAndRankRoutes(
                    modelName: requestedModel.modelID,
                    preferredProviderID: effectiveProviderID,
                    requestedFormatFamily: formatFamily,
                    requiredCanonicalModelID: requestedCanonicalModelID
                )
                await router.persistDecisionIfNeeded(ranking: ranking, modelName: requestedModel.modelID)
                guard let requiredCanonicalModelID = ranking.requiredCanonicalModelID else {
                    await recordProxyRouteLogEntry(
                        context: logContext,
                        requestedCanonicalModelID: nil,
                        route: nil,
                        finalStatus: .rejected,
                        httpStatus: 503,
                        attempts: routeLogAttempts.attempts,
                        failureMessage: "Exact model identity unavailable for \(modelID)."
                    )
                    return .buffered(exactModelIdentityUnavailableResponse(modelID: modelID))
                }
                lastRankingRequiredCanonicalModelID = requiredCanonicalModelID
                let rankedRoutes = descriptor
                    .filterRankedRoutes(ranking.rankedRoutes.map(\.route), requestedModel)
                    .filter { advertisedRouteKeys.contains(routeKey(providerID: $0.providerID, slotID: $0.credentialSlotID)) }
                guard rankedRoutes.isEmpty == false else {
                    if let rejection = descriptor.emptyRankedRoutesRejection {
                        let (failureMessage, response) = rejection(modelID)
                        await recordProxyRouteLogEntry(
                            context: logContext,
                            requestedCanonicalModelID: requiredCanonicalModelID,
                            route: nil,
                            finalStatus: .rejected,
                            httpStatus: 503,
                            attempts: routeLogAttempts.attempts,
                            failureMessage: failureMessage
                        )
                        return .buffered(response)
                    }
                    continue
                }

                let routes = rankedRoutes.filter { $0.canonicalModelID == requiredCanonicalModelID }

                for (index, route) in routes.enumerated() {
                    if let slotID = route.credentialSlotID {
                        try? await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
                    }
                    let idempotencyKey = usageIdempotencyKey(requestSignature: requestSignature, route: route)
                    let attemptStartedAt = Date()
                    let attemptContext = GatewayRouteAttemptContext(
                        bodyData: bodyData,
                        route: route,
                        formatFamily: formatFamily,
                        wantsStream: wantsStream,
                        variant: resolvedVariant
                    )

                    do {
                        // Verbatim SSE passthrough when the endpoint's stream
                        // plan allows it for this attempt. Falls back to the
                        // buffered path when the upstream cannot stream.
                        if let connection, let streamPlan = descriptor.streamAttempt(attemptContext) {
                            do {
                                let relay = try await relayProxyStream(
                                    on: connection,
                                    corsHeaders: corsHeaders,
                                    usageFormat: streamPlan.usageFormat,
                                    route: route,
                                    idempotencyKey: idempotencyKey,
                                    openStream: streamPlan.openStream
                                )
                                await router.markRouteSuccess(route)
                                await modelHealthStore.recordSuccess(
                                    modelID: requestedModel.originalID,
                                    formatFamily: formatFamily,
                                    route: route
                                )
                                let attemptStatus: BurnBarProxyRouteFinalStatus = relay.interrupted ? .interrupted : .exact
                                routeLogAttempts.append(routeAttempt(
                                    sequence: routeLogAttempts.nextSequence,
                                    startedAt: attemptStartedAt,
                                    completedAt: Date(),
                                    route: route,
                                    status: attemptStatus,
                                    httpStatus: relay.httpStatus
                                ))
                                let finalStatus = relay.interrupted
                                    ? BurnBarProxyRouteFinalStatus.interrupted
                                    : routeFinalStatus(
                                        route: route,
                                        requestedCanonicalModelID: requiredCanonicalModelID,
                                        attempts: routeLogAttempts.attempts
                                    )
                                await recordProxyRouteLogEntry(
                                    context: logContext,
                                    requestedCanonicalModelID: requiredCanonicalModelID,
                                    route: route,
                                    finalStatus: finalStatus,
                                    streamed: true,
                                    streamInterrupted: relay.interrupted,
                                    httpStatus: relay.httpStatus,
                                    attempts: routeLogAttempts.attempts,
                                    usage: relay.usage
                                )
                                return relay.outcome
                            } catch is BurnBarProxyStreamingUnsupported {
                                // Upstream cannot stream verbatim (e.g. Ollama
                                // native API) — fall back to buffered below.
                            }
                        }

                        let response = try await descriptor.proxyBuffered(attemptContext)
                        await router.markRouteSuccess(route)
                        await modelHealthStore.recordSuccess(
                            modelID: requestedModel.originalID,
                            formatFamily: formatFamily,
                            route: route
                        )
                        await recordUsageIfAvailable(response.usage, route: route, idempotencyKey: idempotencyKey)
                        routeLogAttempts.append(routeAttempt(
                            sequence: routeLogAttempts.nextSequence,
                            startedAt: attemptStartedAt,
                            completedAt: Date(),
                            route: route,
                            status: .exact,
                            httpStatus: response.statusCode
                        ))
                        await recordProxyRouteLogEntry(
                            context: logContext,
                            requestedCanonicalModelID: requiredCanonicalModelID,
                            route: route,
                            providerReportedModelSlug: Self.providerReportedModelSlug(from: response.body),
                            finalStatus: routeFinalStatus(
                                route: route,
                                requestedCanonicalModelID: requiredCanonicalModelID,
                                attempts: routeLogAttempts.attempts
                            ),
                            httpStatus: response.statusCode,
                            attempts: routeLogAttempts.attempts,
                            usage: response.usage
                        )
                        return .buffered(GatewayHTTPResponse(
                            status: response.statusCode,
                            headers: ["Content-Type": response.contentType],
                            body: response.body
                        ))
                    } catch {
                        lastError = error
                        lastFailedRoute = route
                        routeLogAttempts.append(routeAttempt(
                            sequence: routeLogAttempts.nextSequence,
                            startedAt: attemptStartedAt,
                            completedAt: Date(),
                            route: route,
                            status: .failed,
                            httpStatus: Self.httpStatus(from: error),
                            failureMessage: error.localizedDescription
                        ))
                        await modelHealthStore.recordFailure(
                            modelID: requestedModel.originalID,
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

                if let lastError,
                   shouldFailOverProviderError(lastError) {
                    if let attemptDegrade = descriptor.attemptDegrade,
                       let degraded = await attemptDegrade(
                           degradeRequest(requestedCanonicalModelID: requiredCanonicalModelID)
                       ) {
                        routeLogAttempts.append(contentsOf: degraded.attempts)
                        if let outcome = degraded.outcome {
                            return outcome
                        }
                    }
                    await recordProxyRouteLogEntry(
                        context: logContext,
                        requestedCanonicalModelID: requiredCanonicalModelID,
                        route: lastFailedRoute,
                        finalStatus: .failed,
                        httpStatus: Self.httpStatus(from: lastError),
                        attempts: routeLogAttempts.attempts,
                        failureMessage: "Exact model fail-closed after provider failure."
                    )
                    return .buffered(exactModelFailClosedResponse(canonicalModelID: requiredCanonicalModelID))
                }

                if let lastError {
                    await recordProxyRouteLogEntry(
                        context: logContext,
                        requestedCanonicalModelID: requiredCanonicalModelID,
                        route: lastFailedRoute,
                        finalStatus: .failed,
                        httpStatus: Self.httpStatus(from: lastError),
                        attempts: routeLogAttempts.attempts,
                        failureMessage: lastError.localizedDescription
                    )
                    return .buffered(providerFailureResponse(lastError, modelID: modelID, route: lastFailedRoute))
                }
            }

            if let lastError {
                await recordProxyRouteLogEntry(
                    context: logContext,
                    requestedCanonicalModelID: requestedCanonicalModelID,
                    route: lastFailedRoute,
                    finalStatus: .failed,
                    httpStatus: Self.httpStatus(from: lastError),
                    attempts: routeLogAttempts.attempts,
                    failureMessage: lastError.localizedDescription
                )
                return .buffered(providerFailureResponse(lastError, modelID: modelID, route: lastFailedRoute))
            }
            if let attemptDegrade = descriptor.attemptDegrade,
               let degraded = await attemptDegrade(
                   degradeRequest(requestedCanonicalModelID: requestedCanonicalModelID)
               ) {
                routeLogAttempts.append(contentsOf: degraded.attempts)
                if let outcome = degraded.outcome {
                    return outcome
                }
            }
            await recordProxyRouteLogEntry(
                context: logContext,
                requestedCanonicalModelID: descriptor.finalRejectUsesRankingCanonicalModelID
                    ? lastRankingRequiredCanonicalModelID
                    : requestedCanonicalModelID,
                route: nil,
                finalStatus: .rejected,
                httpStatus: 503,
                attempts: routeLogAttempts.attempts,
                failureMessage: "No eligible route for \(modelID)."
            )
            return .buffered(noEligibleRouteResponse(modelID: modelID))
        } catch let error as BurnBarProviderRouterError where descriptor.treatsRouterErrorAsNoEligibleRoute {
            logger.error(descriptor.routeErrorLogEvent, metadata: ["model": modelID, "error": "\(error)"])
            await recordProxyRouteLogEntry(
                context: logContext,
                requestedCanonicalModelID: nil,
                route: nil,
                finalStatus: .rejected,
                httpStatus: 503,
                attempts: routeLogAttempts.attempts,
                failureMessage: error.localizedDescription
            )
            return .buffered(noEligibleRouteResponse(modelID: modelID))
        } catch {
            logger.error(descriptor.routeErrorLogEvent, metadata: ["model": modelID, "error": "\(error)"])
            await recordProxyRouteLogEntry(
                context: logContext,
                requestedCanonicalModelID: nil,
                route: nil,
                finalStatus: .failed,
                httpStatus: 502,
                attempts: routeLogAttempts.attempts,
                failureMessage: error.localizedDescription
            )
            return .buffered(jsonResponse(status: 502, body: errorBody("routing failed: \(error.localizedDescription)")))
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

    private func exactModelIdentityUnavailableResponse(modelID: String) -> GatewayHTTPResponse {
        jsonResponse(
            status: 503,
            body: errorBody(
                "No exact canonical model identity is available for \(modelID). Add or enable a direct model entry that proves the route serves this exact model."
            )
        )
    }

    private func exactModelFailClosedResponse(canonicalModelID: String) -> GatewayHTTPResponse {
        jsonResponse(
            status: 503,
            body: errorBody(
                "All routed accounts serving exact model \(canonicalModelID) failed; no exact same-model fallback remained."
            )
        )
    }

    private func routeKey(providerID: String, slotID: String?) -> String {
        "\(providerID)#\(slotID ?? "legacy")"
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
            // A stable, content-derived key means a client that retries the
            // same completion (or our own retry on the same route) records the
            // usage exactly once instead of double-billing the local ledger.
            _ = try await usageRecorder.record(
                event,
                idempotencyKey: idempotencyKey
            )
        } catch {
            logger.silentFailure("gateway_usage_record", error: error)
        }

        if route.providerID.caseInsensitiveCompare("xai") == .orderedSame {
            XAISuperGrokPacingLog.recordPromptDispatched(
                model: route.resolvedModelID,
                source: "http-gateway"
            )
        }
    }

    private func appendProxyRouteLog(_ entry: BurnBarProxyRouteLogEntry) async {
        guard let proxyRouteLogStore else { return }
        await proxyRouteLogStore.append(entry)
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
            cost: route.pricing.cost(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens
            ),
            confidence: usage.confidence
        )
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

    private func providerLogoKey(for route: BurnBarProviderRoute) -> String {
        configStore.catalogSupport.catalog.provider(id: route.providerID)?.bundledLogoName
            ?? BurnBarCatalogProvider.bundledLogoName(forProviderID: route.providerID)
            ?? "\(route.providerID.capitalized)Logo"
    }

    private func routeFinalStatus(
        route: BurnBarProviderRoute,
        requestedCanonicalModelID: String?,
        attempts: [BurnBarProxyRouteAttempt],
        fallback: BurnBarProxyRouteFinalStatus = .exact
    ) -> BurnBarProxyRouteFinalStatus {
        guard fallback == .exact else { return fallback }
        guard let requestedCanonicalModelID else {
            return attempts.contains(where: { $0.status == .failed }) ? .failed : .exact
        }
        guard route.canonicalModelID == requestedCanonicalModelID else {
            return .failed
        }
        return attempts.contains(where: { $0.status == .failed }) ? .sameModelFailover : .exact
    }

    private func exactModelInvariant(
        route: BurnBarProviderRoute?,
        requestedCanonicalModelID: String?,
        finalStatus: BurnBarProxyRouteFinalStatus
    ) -> BurnBarProxyExactModelInvariant {
        if finalStatus == .crossVendorFallback {
            return .notApplicable
        }
        guard let requestedCanonicalModelID else {
            return .unavailable
        }
        guard let route else {
            return .failed
        }
        return route.canonicalModelID == requestedCanonicalModelID ? .passed : .failed
    }

    private func transportKind(for route: BurnBarProviderRoute) -> BurnBarProxyTransportKind {
        if route.providerID.caseInsensitiveCompare("factory") == .orderedSame {
            return .factoryDroid
        }
        if interactiveClaudeExecutor != nil,
           ClaudeInteractiveSessionExecutor.isEligible(route: route) {
            return .claudeInteractive
        }
        return .http
    }

    private static func providerReportedModelSlug(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        if let model = object["model"] as? String {
            return normalizedNonEmpty(model)
        }
        if let response = object["response"] as? [String: Any],
           let model = response["model"] as? String {
            return normalizedNonEmpty(model)
        }
        return nil
    }

    private static func httpStatus(from error: Error) -> Int? {
        if case let BurnBarProviderExecutorError.upstreamError(status, _) = error {
            return status
        }
        return nil
    }

    private static func sanitizedFailureMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let oneLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(oneLine.prefix(260))
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince1970 - start.timeIntervalSince1970) * 1_000))
    }

    private func recordProxyRouteLogEntry(
        context: GatewayRequestContext,
        requestedCanonicalModelID: String?,
        route: BurnBarProviderRoute?,
        providerReportedModelSlug: String? = nil,
        finalStatus: BurnBarProxyRouteFinalStatus,
        streamed: Bool = false,
        streamInterrupted: Bool = false,
        httpStatus: Int? = nil,
        attempts: [BurnBarProxyRouteAttempt],
        usage: BurnBarProviderProxyUsage? = nil,
        failureMessage: String? = nil
    ) async {
        let completedAt = Date()
        let routeUsage = route.flatMap { proxyRouteUsage(from: usage, route: $0) }
        let entry = BurnBarProxyRouteLogEntry(
            occurredAt: context.startedAt,
            completedAt: completedAt,
            durationMilliseconds: Self.elapsedMilliseconds(from: context.startedAt, to: completedAt),
            requestPath: context.requestPath,
            endpoint: context.endpoint,
            clientModelSlug: context.clientModelSlug,
            advertisedModelSlug: context.advertisedModelSlug,
            routingModelSlug: context.routingModelSlug,
            upstreamModelSlug: route?.resolvedModelID,
            providerReportedModelSlug: Self.normalizedNonEmpty(providerReportedModelSlug),
            clientModelDisplayName: Self.normalizedNonEmpty(context.clientModelDisplayName) ?? context.clientModelSlug,
            routingModelDisplayName: Self.normalizedNonEmpty(context.routingModelDisplayName) ?? context.routingModelSlug,
            upstreamModelDisplayName: route?.resolvedModelID,
            providerID: route?.providerID,
            providerName: route?.providerDisplayName,
            providerLogoKey: route.map { providerLogoKey(for: $0) },
            accountID: route?.credentialSlotID,
            accountLabel: route?.credentialSlotLabel,
            requestedCanonicalModelID: requestedCanonicalModelID,
            servedCanonicalModelID: route?.canonicalModelID,
            formatFamily: route?.formatFamily.rawValue,
            endpointProfileID: route?.endpointProfileID,
            transportKind: route.map(transportKind(for:)),
            rewriteKind: context.rewriteKind,
            exactModelInvariant: exactModelInvariant(
                route: route,
                requestedCanonicalModelID: requestedCanonicalModelID,
                finalStatus: finalStatus
            ),
            finalStatus: finalStatus,
            streamed: streamed,
            streamInterrupted: streamInterrupted,
            httpStatus: httpStatus,
            attempts: attempts,
            usage: routeUsage,
            failureMessage: Self.sanitizedFailureMessage(failureMessage)
        )
        await appendProxyRouteLog(entry)
    }

    /// Build a stable idempotency key from the request content and the route
    /// it was served on. Identical retries of the same completion on the same
    /// account collapse to one recorded usage event (see A2).
    private func usageIdempotencyKey(requestSignature: String, route: BurnBarProviderRoute) -> String {
        let routePart = "\(route.providerID)#\(route.credentialSlotID ?? "legacy")#\(route.resolvedModelID)"
        return "gateway:\(Self.stableDigest("\(requestSignature)|\(routePart)"))"
    }

    /// Last-resort cross-vendor degrade for the OpenAI chat endpoint (Part B3).
    ///
    /// Returns `nil` when the policy is disabled, no allow-listed vendor is
    /// configured, or every degrade candidate fails — in which case the caller
    /// falls back to its normal failure response. The OpenAI-compatible
    /// executor rewrites the body's `model` field to the degrade model, and the
    /// degrade target is always OpenAI-compatible, so the response wire format
    /// already matches the client. Usage is recorded against the degrade model's
    /// own pricing so the local ledger reflects the true (cheaper) cost.
    private func attemptCrossVendorDegradeForChat(
        bodyData: Data,
        requestSignature: String,
        requestedModelID: String,
        routeLogStartedAt: Date,
        requestPath: String,
        endpoint: String,
        advertisedModelSlug: String?,
        routingModelSlug: String?,
        requestedCanonicalModelID: String?,
        priorAttempts: [BurnBarProxyRouteAttempt]
    ) async -> GatewayDegradeAttemptResult? {
        guard crossVendorDegradePolicy.isEnabled else { return nil }

        let router = BurnBarProviderRouter(
            configStore: configStore,
            logger: BurnBarDaemonLogger(category: "gateway-router"),
            routingEventStore: BurnBarProviderRoutingDecisionEventStore(),
            allowDynamicOpenAICompatibleModels: true
        )

        let degradeRoutes: [BurnBarRankedRoute]
        do {
            degradeRoutes = try await router.crossVendorDegradeRoutes(
                policy: crossVendorDegradePolicy,
                taskCategory: .unknown
            )
        } catch {
            logger.error("cross_vendor_degrade_lookup_failed", metadata: ["error": "\(error)"])
            return nil
        }
        guard !degradeRoutes.isEmpty else { return nil }

        let logContext = GatewayRequestContext(
            startedAt: routeLogStartedAt,
            requestPath: requestPath,
            endpoint: endpoint,
            clientModelSlug: requestedModelID,
            advertisedModelSlug: advertisedModelSlug,
            routingModelSlug: routingModelSlug,
            clientModelDisplayName: requestedModelID,
            routingModelDisplayName: routingModelSlug,
            rewriteKind: .crossVendorFallback
        )
        var attempts: [BurnBarProxyRouteAttempt] = []
        for ranked in degradeRoutes {
            let route = ranked.route
            let idempotencyKey = usageIdempotencyKey(requestSignature: requestSignature, route: route)
            let attemptStartedAt = Date()
            do {
                logger.notice(
                    "cross_vendor_degrade",
                    metadata: [
                        "requested_model": requestedModelID,
                        "degrade_provider_id": route.providerID,
                        "degrade_model_id": route.resolvedModelID
                    ]
                )
                let response = try await proxyChatCompletions(
                    body: bodyData,
                    route: route,
                    formatFamily: .openaiCompat,
                    variant: nil
                )
                await router.markRouteSuccess(route)
                await recordUsageIfAvailable(response.usage, route: route, idempotencyKey: idempotencyKey)
                attempts.append(routeAttempt(
                    sequence: priorAttempts.count + attempts.count + 1,
                    startedAt: attemptStartedAt,
                    completedAt: Date(),
                    route: route,
                    status: .crossVendorFallback,
                    httpStatus: response.statusCode
                ))
                await recordProxyRouteLogEntry(
                    context: logContext,
                    requestedCanonicalModelID: requestedCanonicalModelID,
                    route: route,
                    providerReportedModelSlug: Self.providerReportedModelSlug(from: response.body),
                    finalStatus: .crossVendorFallback,
                    httpStatus: response.statusCode,
                    attempts: priorAttempts + attempts,
                    usage: response.usage
                )
                return GatewayDegradeAttemptResult(outcome: .buffered(GatewayHTTPResponse(
                    status: response.statusCode,
                    headers: ["Content-Type": response.contentType],
                    body: response.body
                )), attempts: attempts)
            } catch {
                attempts.append(routeAttempt(
                    sequence: priorAttempts.count + attempts.count + 1,
                    startedAt: attemptStartedAt,
                    completedAt: Date(),
                    route: route,
                    status: .failed,
                    httpStatus: Self.httpStatus(from: error),
                    failureMessage: error.localizedDescription
                ))
                await router.markRouteFailure(route, error: error)
                continue
            }
        }
        return GatewayDegradeAttemptResult(outcome: nil, attempts: attempts)
    }

    private func proxyChatCompletions(
        body: Data,
        route: BurnBarProviderRoute,
        formatFamily: BurnBarProviderFormatFamily,
        variant: BurnBarModelVariant?
    ) async throws -> BurnBarProviderProxyResponse {
        if route.providerID.caseInsensitiveCompare("factory") == .orderedSame {
            return try await factoryExecutor.proxyChatCompletions(body: body, route: route, variant: variant)
        }
        if let interactiveClaudeExecutor, ClaudeInteractiveSessionExecutor.isEligible(route: route) {
            return try await interactiveClaudeExecutor.proxyChatCompletions(body: body, route: route, variant: variant)
        }
        switch formatFamily {
        case .openaiCompat:
            return try await providerExecutor.proxyChatCompletions(body: body, route: route, variant: variant)
        case .anthropic:
            return try await anthropicExecutor.proxyChatCompletions(body: body, route: route, variant: variant)
        }
    }

    private func proxyResponses(
        body: Data,
        route: BurnBarProviderRoute,
        formatFamily: BurnBarProviderFormatFamily,
        variant: BurnBarModelVariant?
    ) async throws -> BurnBarProviderProxyResponse {
        if route.providerID.caseInsensitiveCompare("factory") == .orderedSame {
            return try await factoryExecutor.proxyResponses(body: body, route: route, variant: variant)
        }
        if let interactiveClaudeExecutor, ClaudeInteractiveSessionExecutor.isEligible(route: route) {
            return try await interactiveClaudeExecutor.proxyResponses(body: body, route: route, variant: variant)
        }
        switch formatFamily {
        case .openaiCompat:
            return try await providerExecutor.proxyResponses(body: body, route: route, variant: variant)
        case .anthropic:
            return try await anthropicExecutor.proxyResponses(body: body, route: route, variant: variant)
        }
    }

    /// Decide whether a route failure should trigger trying the next account.
    ///
    /// Narrowed (A2) to genuine capacity/quota/credential exhaustion. We only
    /// fail over on the unambiguous quota status codes (402 payment required,
    /// 429 too many requests) and credential errors (401/403), plus specific
    /// quota phrases. The previous broad `contains("rate")` substring matched
    /// innocuous bodies (e.g. "generate rate", "accurate") and re-sent the
    /// whole prompt to another paid account, multiplying token burn.
    private func shouldFailOverProviderError(_ error: Error) -> Bool {
        if let providerError = error as? BurnBarProviderExecutorError {
            switch providerError {
            case .upstreamError(let statusCode, let body):
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
            case .invalidBaseURL, .invalidResponse:
                return false
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("quota")
            || description.contains("rate limit")
            || description.contains("429")
    }

    private func canonicalModelID(
        forModelName modelName: String,
        providerID requestedProviderID: String?,
        catalog: BurnBarCatalog
    ) -> String? {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let providerID = requestedProviderID ?? (normalized.contains(":cloud") || normalized.contains("-cloud") ? "ollama" : nil)
        if providerID?.caseInsensitiveCompare("ollama") == .orderedSame,
           let cloudModelID = ollamaCloudWireModelID(from: modelName) {
            return cloudModelID.lowercased()
        }
        return catalog.canonicalModelID(forModelName: modelName, providerID: providerID)
    }

    private func ollamaCloudWireModelID(from modelName: String) -> String? {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasSuffix(":cloud") {
            let candidate = String(trimmed.dropLast(":cloud".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }
        if lowercased.hasSuffix("-cloud") {
            let candidate = String(trimmed.dropLast("-cloud".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }
        return nil
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

    // MARK: - Streaming relay

    /// Relay an upstream SSE stream to the client chunk-by-chunk (A1).
    ///
    /// `openStream` performs the upstream request and resolves once response
    /// headers arrive. If it throws before any client bytes are written (e.g.
    /// an upstream 429), the error propagates so the caller can still fail
    /// over to another account. Once the head is written we are committed to
    /// this connection: a mid-stream failure is surfaced as a terminal SSE
    /// error event rather than a fail-over, because the client has already
    /// begun consuming the response.
    private func relayProxyStream(
        on connection: NWConnection,
        corsHeaders: [String: String],
        usageFormat: GatewayStreamUsageFormat,
        route: BurnBarProviderRoute,
        idempotencyKey: String,
        openStream: () async throws -> BurnBarProviderProxyStream
    ) async throws -> GatewayStreamRelayResult {
        let stream = try await openStream()

        await writeStreamingHead(
            on: connection,
            status: stream.statusCode,
            contentType: stream.contentType,
            corsHeaders: corsHeaders
        )

        let accumulator = GatewayStreamingUsageAccumulator(format: usageFormat)
        var interrupted = false
        do {
            for try await chunk in stream.chunks {
                accumulator.consume(chunk)
                await sendRaw(chunk, on: connection)
            }
        } catch {
            interrupted = true
            // Bytes already flowed to the client; we cannot fail over now.
            // Emit a terminal SSE error event so the client sees a clean end.
            logger.warning(
                "gateway_stream_interrupted",
                metadata: ["provider": route.providerID, "error": "\(error)"]
            )
            let errorEvent = "event: error\ndata: {\"error\":{\"message\":\"upstream stream interrupted\"}}\n\n"
            await sendRaw(Data(errorEvent.utf8), on: connection)
        }

        let usage = accumulator.finalize()
        await recordUsageIfAvailable(usage, route: route, idempotencyKey: idempotencyKey)
        return GatewayStreamRelayResult(
            outcome: .streamed,
            usage: usage,
            interrupted: interrupted,
            httpStatus: stream.statusCode
        )
    }

    private func writeStreamingHead(
        on connection: NWConnection,
        status: Int,
        contentType: String,
        corsHeaders: [String: String]
    ) async {
        var head = "HTTP/1.1 \(status) \(Self.statusText(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "X-Accel-Buffering: no\r\n"
        for (key, value) in corsHeaders {
            head += "\(key): \(value)\r\n"
        }
        // No Content-Length: the body length is unknown up front. We signal
        // end-of-response by closing the connection (Connection: close), which
        // is the standard HTTP/1.1 way to stream a body of indeterminate size.
        head += "Connection: close\r\n"
        head += "\r\n"
        await sendRaw(Data(head.utf8), on: connection)
    }

    private func sendRaw(_ data: Data, on connection: NWConnection) async {
        guard !data.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private static func statusText(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "OK"
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

    /// Gateway auth token presented by routed CLI clients. Droid's Anthropic BYOK
    /// adapter sends `x-api-key`; OpenAI-style clients use `Authorization: Bearer`.
    private func clientAuthToken(from request: HTTPRequest) -> String? {
        if let bearer = bearerToken(from: request.headers["authorization"]) {
            return bearer
        }
        if let apiKey = request.headers["x-api-key"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return apiKey
        }
        return nil
    }

    private func rateLimitClientKey(for request: HTTPRequest) -> String {
        if let token = clientAuthToken(from: request) {
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

    /// The result of routing a request: either a fully-buffered response the
    /// caller should write, or a stream the relay has already written directly
    /// to the connection (so the caller only needs to close it).
    private enum GatewayRouteOutcome {
        case buffered(GatewayHTTPResponse)
        case streamed
    }

    private struct GatewayStreamRelayResult {
        let outcome: GatewayRouteOutcome
        let usage: BurnBarProviderProxyUsage?
        let interrupted: Bool
        let httpStatus: Int
    }

    private struct GatewayDegradeAttemptResult {
        let outcome: GatewayRouteOutcome?
        let attempts: [BurnBarProxyRouteAttempt]
    }

    /// Selects how the streaming usage accumulator parses SSE events.
    private enum GatewayStreamUsageFormat {
        case openAI
        case anthropic
    }

    /// Parses token usage out of an SSE stream as it is relayed, so streamed
    /// responses record real usage instead of `nil` (A4). Used entirely within
    /// the gateway actor's isolation, so a plain reference type is safe.
    private final class GatewayStreamingUsageAccumulator {
        private let format: GatewayStreamUsageFormat
        private var inputTokens = 0
        private var outputTokens = 0
        private var cacheCreationTokens = 0
        private var cacheReadTokens = 0
        private var reasoningTokens = 0
        private var sawUsage = false

        init(format: GatewayStreamUsageFormat) {
            self.format = format
        }

        func consume(_ chunk: Data) {
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                switch format {
                case .openAI:
                    consumeOpenAI(object)
                case .anthropic:
                    consumeAnthropic(object)
                }
            }
        }

        func finalize() -> BurnBarProviderProxyUsage? {
            guard sawUsage else { return nil }
            return BurnBarProviderProxyUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens,
                reasoningTokens: reasoningTokens,
                confidence: .exact
            )
        }

        private func consumeOpenAI(_ object: [String: Any]) {
            guard let usage = object["usage"] as? [String: Any] else { return }
            let prompt = Self.intValue(usage["prompt_tokens"])
            let completion = Self.intValue(usage["completion_tokens"])
            guard prompt != nil || completion != nil else { return }
            sawUsage = true
            let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
            let cached = Self.intValue(promptDetails?["cached_tokens"]) ?? 0
            let completionDetails = usage["completion_tokens_details"] as? [String: Any]
            let reasoning = Self.intValue(completionDetails?["reasoning_tokens"]) ?? 0
            // The final usage chunk is authoritative — overwrite rather than sum.
            inputTokens = max((prompt ?? 0) - cached, 0)
            outputTokens = completion ?? 0
            cacheReadTokens = cached
            reasoningTokens = reasoning
        }

        private func consumeAnthropic(_ object: [String: Any]) {
            let type = object["type"] as? String
            if type == "message_start",
               let message = object["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                sawUsage = true
                inputTokens = Self.intValue(usage["input_tokens"]) ?? inputTokens
                cacheCreationTokens = Self.intValue(usage["cache_creation_input_tokens"]) ?? cacheCreationTokens
                cacheReadTokens = Self.intValue(usage["cache_read_input_tokens"]) ?? cacheReadTokens
                outputTokens = Self.intValue(usage["output_tokens"]) ?? outputTokens
            } else if type == "message_delta",
                      let usage = object["usage"] as? [String: Any] {
                sawUsage = true
                // output_tokens in message_delta is cumulative for the message.
                outputTokens = Self.intValue(usage["output_tokens"]) ?? outputTokens
                if let input = Self.intValue(usage["input_tokens"]) {
                    inputTokens = input
                }
            }
        }

        private static func intValue(_ value: Any?) -> Int? {
            if let int = value as? Int { return int }
            if let double = value as? Double { return Int(double) }
            if let string = value as? String { return Int(string) }
            return nil
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
        let servedBy: String
        let usageLane: String?
        let nativeStreaming: Bool
        let displayName: String
        /// `true` when `displayName` is a verbatim user rename emitted as-is
        /// (no provider/route/reasoning suffixes). Lets clients badge it.
        let displayNameIsCustom: Bool
        let capabilities: [String]
        let modelCapabilities: ModelIOCapabilities?
        let formatFamily: String
        let servedEndpoints: [String]
        let quotaState: String
        let accountCount: Int
        let enabled: Bool
        let advertisementEnabled: Bool
        let advertised: Bool
        let routeEligible: Bool
        let lastRefreshAt: Date?
        let lastError: String?
        let baseModelID: String?
        let thinkingLevel: String?
        let hidesBaseModel: Bool?

        init(group: GatewayModelCatalogGroup, advertisedID: String, advertised: Bool? = nil) {
            let representative = group.representative
            let entries = group.entries
            let models = entries.map(\.model)
            let accountIDs = Self.uniqueNonEmpty(models.map(\.accountID))
            let accountLabels = Self.uniqueNonEmpty(models.map(\.accountLabel))
            let accountCount = max(1, accountIDs.count)
            let capabilities = Self.mergedCapabilities(from: models)
            let modelCapabilities = Self.mergedModelCapabilities(from: models)
            let formatFamily = Self.formatFamily(from: capabilities)
            let rawDisplayName = Self.displayName(
                representative: representative,
                accountLabels: accountLabels
            )
            let thinkingLevel = models.compactMap(\.thinkingLevel).first

            self.id = advertisedID
            self.ownedBy = representative.providerID
            self.providerID = representative.providerID
            self.providerName = representative.providerName
            self.accountID = accountCount > 1 ? "auto" : representative.accountID
            self.accountLabel = Self.accountLabel(
                representative: representative,
                accountLabels: accountLabels,
                accountCount: accountCount
            )
            self.sourceID = accountCount > 1
                ? "\(representative.providerID)#auto"
                : representative.sourceID
            self.sourceKind = Self.sourceKind(from: models)
            self.servedBy = Self.servedBy(from: models)
            self.usageLane = Self.usageLane(from: models)
            self.nativeStreaming = !models.allSatisfy { Self.isFactoryModel($0) }
            let isCustomDisplayName = models.contains(where: { $0.displayNameIsCustom == true })
            self.displayNameIsCustom = isCustomDisplayName
            self.displayName = isCustomDisplayName
                ? rawDisplayName
                : OpenBurnBarModelDisplayName.compose(
                    modelName: rawDisplayName,
                    providerName: representative.providerName,
                    providerID: representative.providerID,
                    reasoningLevel: thinkingLevel
                )
            self.capabilities = capabilities
            self.modelCapabilities = modelCapabilities
            self.formatFamily = formatFamily.rawValue
            self.servedEndpoints = Self.servedEndpoints(for: formatFamily)
            self.quotaState = Self.quotaState(from: entries).rawValue
            self.accountCount = accountCount
            self.enabled = models.contains { $0.enabled }
            self.advertisementEnabled = models.contains { $0.advertisementEnabled }
            self.advertised = advertised ?? group.advertised
            self.routeEligible = models.contains { $0.routeEligible }
            self.lastRefreshAt = models.compactMap(\.lastRefreshAt).max()
            self.lastError = models.compactMap(\.lastError).first
            self.baseModelID = models.compactMap(\.baseModelID).first
            self.thinkingLevel = thinkingLevel
            self.hidesBaseModel = models.compactMap(\.hidesBaseModel).first
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

        private static func mergedCapabilities(from models: [BurnBarLiveAdvertisedModel]) -> [String] {
            var seen: Set<String> = []
            var merged: [String] = []
            for capability in models.flatMap(\.capabilities) {
                let normalized = capability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                merged.append(capability)
            }
            return merged
        }

        private static func mergedModelCapabilities(from models: [BurnBarLiveAdvertisedModel]) -> ModelIOCapabilities? {
            let values = models.compactMap(\.modelCapabilities)
            guard let first = values.first else { return nil }
            guard values.count > 1 else { return first }

            return ModelIOCapabilities(
                schemaVersion: first.schemaVersion,
                inputModalities: intersection(values.map(\.inputModalities), fallback: first.inputModalities),
                outputModalities: intersection(values.map(\.outputModalities), fallback: first.outputModalities),
                supportedParameters: union(values.map(\.supportedParameters)),
                contextWindowTokens: values.compactMap(\.contextWindowTokens).min(),
                maxOutputTokens: values.compactMap(\.maxOutputTokens).min(),
                acceptedInputMimeTypes: intersection(
                    values.map(\.acceptedInputMimeTypes).filter { !$0.isEmpty },
                    fallback: first.acceptedInputMimeTypes
                ),
                imageMaxBytes: values.compactMap(\.imageMaxBytes).min(),
                audioMaxBytes: values.compactMap(\.audioMaxBytes).min(),
                videoMaxBytes: values.compactMap(\.videoMaxBytes).min(),
                sourceRefs: first.sourceRefs
            )
        }

        private static func intersection(_ lists: [[String]], fallback: [String]) -> [String] {
            guard let first = lists.first, !first.isEmpty else { return fallback }
            let remaining = lists.dropFirst().map { Set($0.map { $0.lowercased() }) }
            let result = first.filter { value in
                remaining.allSatisfy { $0.contains(value.lowercased()) }
            }
            return result.isEmpty ? fallback : result
        }

        private static func union(_ lists: [[String]]) -> [String] {
            var seen: Set<String> = []
            var result: [String] = []
            for value in lists.flatMap({ $0 }) {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                result.append(value)
            }
            return result
        }

        private static func quotaState(from entries: [GatewayModelCatalogEntry]) -> BurnBarLiveModelQuotaState {
            if let advertised = entries.first(where: { $0.advertised })?.model.quotaState {
                return advertised
            }
            if let eligible = entries.first(where: { $0.model.routeEligible })?.model.quotaState {
                return eligible
            }
            return entries.first?.model.quotaState ?? .unknown
        }

        private static func sourceKind(from models: [BurnBarLiveAdvertisedModel]) -> String {
            let sourceKinds = uniqueNonEmpty(models.map(\.sourceKind))
            return sourceKinds.count == 1 ? sourceKinds[0] : "gateway_failover_pool"
        }

        private static func servedBy(from models: [BurnBarLiveAdvertisedModel]) -> String {
            if models.allSatisfy({ isFactoryModel($0) }) {
                return "Factory Droid CLI"
            }
            let providerNames = uniqueNonEmpty(models.map(\.providerName))
            return providerNames.count == 1 ? providerNames[0] : "OpenBurnBar failover pool"
        }

        private static func usageLane(from models: [BurnBarLiveAdvertisedModel]) -> String? {
            guard models.allSatisfy({ isFactoryModel($0) }) else { return nil }
            let lanes = uniqueNonEmpty(models.map { model in
                FactoryDroidProviderExecutor.isStandardModel(model.baseModelID ?? model.id)
                    ? "standard"
                    : "droid_core"
            })
            return lanes.count == 1 ? lanes[0] : "mixed"
        }

        private static func isFactoryModel(_ model: BurnBarLiveAdvertisedModel) -> Bool {
            model.providerID.caseInsensitiveCompare("factory") == .orderedSame
        }

        private static func accountLabel(
            representative: BurnBarLiveAdvertisedModel,
            accountLabels: [String],
            accountCount: Int
        ) -> String {
            guard accountCount > 1 else {
                return representative.accountLabel
            }
            return "Auto failover (\(accountCount) accounts)"
        }

        private static func displayName(
            representative: BurnBarLiveAdvertisedModel,
            accountLabels: [String]
        ) -> String {
            var displayName = representative.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if displayName.isEmpty {
                displayName = representative.id
            }
            for label in accountLabels where !label.isEmpty {
                let suffix = " (\(label))"
                if displayName.hasSuffix(suffix) {
                    displayName.removeLast(suffix.count)
                    displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return displayName
        }

        private static func uniqueNonEmpty(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            var unique: [String] = []
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = trimmed.lowercased()
                guard !trimmed.isEmpty, seen.insert(normalized).inserted else { continue }
                unique.append(trimmed)
            }
            return unique
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
            case servedBy = "served_by"
            case usageLane = "usage_lane"
            case nativeStreaming = "native_streaming"
            case displayName = "display_name"
            case displayNameIsCustom = "display_name_is_custom"
            case capabilities
            case modelCapabilities = "model_capabilities"
            case formatFamily = "format_family"
            case servedEndpoints = "served_endpoints"
            case quotaState = "quota_state"
            case accountCount = "account_count"
            case enabled
            case advertisementEnabled = "advertisement_enabled"
            case advertised
            case routeEligible = "route_eligible"
            case lastRefreshAt = "last_refresh_at"
            case lastError = "last_error"
            case baseModelID = "base_model_id"
            case thinkingLevel = "thinking_level"
            case hidesBaseModel = "hides_base_model"
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
            let contextWindow = Self.contextWindow(for: model)
            self.slug = model.id
            self.displayName = model.displayName
            if model.accountCount > 1 {
                self.description = "\(model.providerName) via OpenBurnBar auto failover across \(model.accountCount) accounts"
            } else {
                self.description = "\(model.providerName) via OpenBurnBar"
            }
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
            self.truncationPolicy = TruncationPolicy(mode: "tokens", limit: contextWindow)
            self.supportsParallelToolCalls = false
            self.supportsImageDetailOriginal = model.modelCapabilities?.supportsImageInput ?? false
            self.contextWindow = contextWindow
            self.maxContextWindow = contextWindow
            self.autoCompactTokenLimit = nil
            self.effectiveContextWindowPercent = 95
            self.experimentalSupportedTools = []
            self.inputModalities = model.modelCapabilities?.inputModalities ?? ["text"]
            self.supportsSearchTool = false
        }

        private static func contextWindow(for model: ModelDescriptor) -> Int {
            if let contextWindowTokens = model.modelCapabilities?.contextWindowTokens {
                return contextWindowTokens
            }
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
        let stream: Bool?
    }

    private struct ResponsesRequest: Decodable {
        let model: String
        let stream: Bool?
    }

    private struct AnthropicMessagesRequest: Decodable {
        let model: String
        let stream: Bool?
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
