import OpenBurnBarCore
import CryptoKit
import Foundation
import Network

/// HTTP gateway server exposing OpenAI-compatible endpoints through the daemon
/// provider router. Built on `Network.framework`, not raw sockets.
public actor BurnBarHTTPGatewayServer {
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 64 * 1024 * 1024

    /// Short TTL for production live-model catalog snapshots; collapses repeated
    /// provider fan-out while keeping `/v1/models` fresh.
    public static let defaultModelCatalogCacheTTL: TimeInterval = 45

    private let configuration: BurnBarGatewayConfiguration
    let configStore: BurnBarConfigStore
    private let usageRecorder: BurnBarUsageRecorder?
    private let proxyRouteLogStore: BurnBarProxyRouteLogStore?
    let providerExecutor: BurnBarOpenAICompatibleProviderExecutor
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
    /// Owns the expensive live model-catalog snapshot (+ optional TTL cache) and
    /// the advertisement-eligibility predicate, consumed by `/v1/models` and the
    /// routing path through one narrow interface. Replaces the inline catalog
    /// session / droid runner / cache-TTL / cached-snapshot fields.
    private let catalogSource: GatewayModelCatalogSource
    let logger: any BurnBarDaemonLogging
    private let rateLimiter: BurnBarRateLimiter?
    /// Dedicated limiter for the unauthenticated-loopback escape hatch; never
    /// applies to authenticated callers.
    private let unauthenticatedLoopbackRateLimiter: BurnBarRateLimiter?
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
        modelCatalogCacheTTL: TimeInterval = 0,
        logger: any BurnBarDaemonLogging = BurnBarDaemonLogger(category: "http-gateway"),
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
        self.catalogSource = GatewayModelCatalogSource(
            configStore: configStore,
            session: modelCatalogSession,
            droidProcessRunner: modelCatalogDroidProcessRunner,
            modelHealthStore: modelHealthStore,
            cacheTTL: modelCatalogCacheTTL,
            logger: logger
        )
        self.logger = logger
        self.rateLimiter = rateLimiter ?? configuration.rateLimit.map {
            BurnBarRateLimiter(configuration: $0)
        }
        // Bound the tokenless-loopback escape hatch independently of the
        // optional general limiter.
        self.unauthenticatedLoopbackRateLimiter = configuration
            .effectiveUnauthenticatedLoopbackRateLimit
            .map { BurnBarRateLimiter(configuration: $0) }
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
                // Match the request-path enforcement: a whitespace-only token is
                // treated as no token at all (see `handleRequest`), so auth is
                // only "on" when a non-empty token is present.
                let authEnforced = self.configuration.authToken?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
                self.logger.notice("gateway_started", metadata: [
                    "host": host,
                    "port": "\(boundPort)",
                    "auth_required": "\(authEnforced)"
                ])
                // remediation(loopback hardening): when the gateway is reachable
                // with NO bearer check, any same-host process can drive the
                // credential-spending proxy. The bind is already constrained to
                // loopback (validationError rejects non-loopback + wildcard
                // binds without a token), but this state must never be silent —
                // emit a loud, explicit startup WARNING so an operator can see
                // that the unauthenticated escape hatch is live.
                if !authEnforced {
                    self.logger.warning("gateway_auth_disabled_loopback", metadata: [
                        "host": host,
                        "port": "\(boundPort)",
                        "is_loopback": "\(self.configuration.isLoopback)",
                        "allow_unauthenticated_loopback": "\(self.configuration.allowUnauthenticatedLoopback)",
                        "reason": "Gateway is serving the credential-spending proxy with NO auth token; any local "
                            + "process can spend the user's provider credits. Set an auth token to fail closed."
                    ])
                }
                if !self.configuration.isLoopback {
                    self.logger.warning("gateway_non_loopback_bind", metadata: [
                        "host": host,
                        "port": "\(boundPort)"
                    ])
                }
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
                await writeRateLimitResponse(on: connection, retryAfter: retryAfter, request: request)
                return
            }
        }

        // remediation(loopback-c): apply the stricter tokenless-loopback ceiling
        // on top of (and after) any general limit. This limiter is non-nil only
        // while the unauthenticated-loopback escape hatch is live, so it bounds
        // an abusive same-host process from spending unlimited provider credits
        // without touching the authenticated path.
        if let unauthenticatedLoopbackRateLimiter {
            // remediation(loopback-c): collapse ALL callers into one constant bucket
            // for this limiter. `rateLimitClientKey` derives a per-credential bucket
            // from a presented bearer token, but in unauthenticated-loopback mode
            // tokens are NOT validated — so keying on them would let a local caller
            // mint fresh buckets with arbitrary tokens and evade the ceiling. A single
            // shared bucket makes the tokenless provider-credit-spend cap actually bind.
            let clientKey = "unauthenticated-loopback"
            let limitResult = await unauthenticatedLoopbackRateLimiter.checkLimit(clientKey: clientKey)
            if case .throttled(let retryAfter) = limitResult {
                logger.warning(
                    "gateway_unauthenticated_loopback_rate_limit_exceeded",
                    metadata: [
                        "client_key": clientKey,
                        "retry_after": "\(retryAfter)",
                        "reason": "tokenless-loopback escape hatch ceiling bounds provider-credit spend"
                    ]
                )
                await writeRateLimitResponse(on: connection, retryAfter: retryAfter, request: request)
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
            let snapshot = try await catalogSource.snapshot()
            var entries: [GatewayModelCatalogEntry] = []
            for model in snapshot.models {
                if !includeUnadvertised,
                   isSuppressedBaseModelRow(model, suppressedBaseIDs: suppressedBaseIDs) {
                    continue
                }
                let canAdvertise = await catalogSource.canAdvertise(model, catalog: catalog)
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
        // remediation(B1): route through the shared, optionally-cached accessor
        // instead of building a throwaway catalog per call. Now also passes the
        // injected droid process runner (was previously defaulted here), which
        // matches `/v1/models` and is a no-op in production.
        let snapshot = try await catalogSource.snapshot()

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
            guard await catalogSource.canAdvertise(model, catalog: catalog) else {
                continue
            }
            let family = GatewayModelCatalogSource.formatFamily(for: model, catalog: catalog)
            routeKeysByFamily[family, default: []].insert(
                routeKey(providerID: model.providerID, slotID: model.accountID == "legacy" ? nil : model.accountID)
            )
        }
        return routeKeysByFamily
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


    func preferredGatewayFormatFamilies(
        for modelID: String,
        advertised: [BurnBarProviderFormatFamily: Set<String>]
    ) -> [BurnBarProviderFormatFamily] {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseOrder: [BurnBarProviderFormatFamily] = normalized.contains("claude") || normalized.contains("anthropic")
            ? [.anthropic, .openaiCompat]
            : [.openaiCompat, .anthropic]
        return baseOrder.filter { advertised[$0]?.isEmpty == false }
    }

    func singleAdvertisedProviderID(
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
        // The Elder Wand: short-circuit to the model-fusion orchestrator when an
        // active `fusion` plugin is present AND the recursion marker is absent.
        // Inner panel/judge/synthesis sub-calls carry the marker so they fall
        // through to the normal single-route pipeline (no re-trigger).
        if let body, let bodyData = body.data(using: .utf8),
           !Self.bodyCarriesFusionRecursionMarker(bodyData),
           let request = try? JSONDecoder().decode(ChatCompletionsRequest.self, from: bodyData),
           let plugin = request.activeFusionPlugin {
            return await runElderWandFusion(
                bodyData: bodyData,
                plugin: plugin,
                originatingModel: request.model,
                wantsStream: request.stream == true,
                connection: connection,
                corsHeaders: corsHeaders
            )
        }

        return await routeModelRequest(
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

    // remediation(gateway split): mechanically-extracted sub-steps of
    // `routeModelRequest`. Each helper is a contiguous block lifted verbatim
    // from the former ~412-line method onto the SAME actor — no routing, auth,
    // rate-limit, or degrade semantics change. The locals the block consumed are
    // now parameters; the values it produced are returned (or mutated `inout`).

    /// remediation(gateway split): request parsing + model-override resolution
    /// step (formerly the head of `routeModelRequest`). Preserves the exact 400
    /// rejections and the alias/thinking-variant rewrite bookkeeping.
    private func parseModelRequest(
        body: String?,
        descriptor: GatewayEndpointDescriptor,
        routeLogStartedAt: Date
    ) async -> GatewayModelRequestParse {
        guard let body, !body.isEmpty else {
            return .rejected(.buffered(jsonResponse(status: 400, body: errorBody("request body required"))))
        }

        guard let bodyData = body.data(using: .utf8) else {
            return .rejected(.buffered(jsonResponse(status: 400, body: errorBody("request body must be valid UTF-8"))))
        }

        let decoded: GatewayDecodedModelRequest
        do {
            decoded = try descriptor.decodeRequest(bodyData)
        } catch {
            return .rejected(.buffered(jsonResponse(status: 400, body: errorBody("invalid JSON request body"))))
        }

        let modelID = decoded.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelID.isEmpty == false else {
            return .rejected(.buffered(jsonResponse(status: 400, body: errorBody("model field required"))))
        }
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

        return .resolved(GatewayResolvedModelRequest(
            bodyData: bodyData,
            modelID: modelID,
            wantsStream: wantsStream,
            requestSignature: requestSignature,
            requestedModel: requestedModel,
            advertisedRequestedModel: advertisedRequestedModel,
            resolvedVariant: resolvedVariant,
            logContext: logContext
        ))
    }

    /// remediation(gateway split): one ranked-route attempt (formerly the inner
    /// `do/catch` of the route loop). Tries the verbatim SSE relay when the
    /// endpoint's stream plan allows it, otherwise the buffered proxy; records
    /// health, usage, the per-attempt log line, and the single proxy route-log
    /// entry on success. On failure it records the failed attempt, updates
    /// `lastError`/`lastFailedRoute`, and signals whether the loop should try the
    /// next candidate — identical to the original inline logic.
    private func attemptSingleRoute(
        route: BurnBarProviderRoute,
        hasMoreCandidates: Bool,
        formatFamily: BurnBarProviderFormatFamily,
        requiredCanonicalModelID: String,
        router: BurnBarProviderRouter,
        pipeline: GatewayRoutePipeline,
        routeLogAttempts: inout RouteAttemptRecorder,
        lastError: inout Error?,
        lastFailedRoute: inout BurnBarProviderRoute?
    ) async -> GatewaySingleRouteOutcome {
        let descriptor = pipeline.descriptor
        let connection = pipeline.connection
        let corsHeaders = pipeline.corsHeaders
        let requestedModel = pipeline.requestedModel
        let logContext = pipeline.logContext
        if let slotID = route.credentialSlotID {
            try? await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
        }
        let idempotencyKey = usageIdempotencyKey(requestSignature: pipeline.requestSignature, route: route)
        let attemptStartedAt = Date()
        let attemptContext = GatewayRouteAttemptContext(
            bodyData: pipeline.bodyData,
            route: route,
            formatFamily: formatFamily,
            wantsStream: pipeline.wantsStream,
            variant: pipeline.resolvedVariant
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
                    return .completed(relay.outcome)
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
            return .completed(.buffered(GatewayHTTPResponse(
                status: response.statusCode,
                headers: ["Content-Type": response.contentType],
                body: response.body
            )))
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
            if shouldFailOverProviderError(error), hasMoreCandidates {
                return .failedTryNext
            }
            return .failedStop
        }
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
        // remediation(gateway split): body validation + model-override resolution
        // moved to `parseModelRequest`; it returns the exact early-return
        // rejections the inline guards produced, or the initial routing state.
        let routeLogStartedAt = Date()
        let resolved: GatewayResolvedModelRequest
        switch await parseModelRequest(
            body: body,
            descriptor: descriptor,
            routeLogStartedAt: routeLogStartedAt
        ) {
        case .rejected(let outcome):
            return outcome
        case .resolved(let value):
            resolved = value
        }

        let bodyData = resolved.bodyData
        let modelID = resolved.modelID
        let wantsStream = resolved.wantsStream
        let requestSignature = resolved.requestSignature
        var routeLogAttempts = RouteAttemptRecorder()
        var requestedModel = resolved.requestedModel
        var advertisedRequestedModel = resolved.advertisedRequestedModel
        let resolvedVariant = resolved.resolvedVariant
        var logContext = resolved.logContext

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

                // remediation(gateway split): labeled loop so a `.failedStop`
                // signal breaks the ROUTE loop (matching the original bare
                // `break`), not just the `switch`.
                routeLoop: for (index, route) in routes.enumerated() {
                    // remediation(gateway split): one ranked-route attempt lifted
                    // into `attemptSingleRoute`; the returned signal reproduces
                    // the original return / continue / break control flow.
                    let attemptOutcome = await attemptSingleRoute(
                        route: route,
                        hasMoreCandidates: index < routes.count - 1,
                        formatFamily: formatFamily,
                        requiredCanonicalModelID: requiredCanonicalModelID,
                        router: router,
                        pipeline: GatewayRoutePipeline(
                            descriptor: descriptor,
                            connection: connection,
                            corsHeaders: corsHeaders,
                            bodyData: bodyData,
                            wantsStream: wantsStream,
                            resolvedVariant: resolvedVariant,
                            requestSignature: requestSignature,
                            requestedModel: requestedModel,
                            logContext: logContext
                        ),
                        routeLogAttempts: &routeLogAttempts,
                        lastError: &lastError,
                        lastFailedRoute: &lastFailedRoute
                    )
                    switch attemptOutcome {
                    case .completed(let outcome):
                        return outcome
                    case .failedTryNext:
                        continue routeLoop
                    case .failedStop:
                        break routeLoop
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

    func providerFailureResponse(
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

    func routeKey(providerID: String, slotID: String?) -> String {
        "\(providerID)#\(slotID ?? "legacy")"
    }

    func recordUsageIfAvailable(
        _ usage: BurnBarProviderProxyUsage?,
        route: BurnBarProviderRoute,
        idempotencyKey: String,
        parentRequestID: String? = nil
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
            confidence: usage.confidence,
            parentRequestID: parentRequestID
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

    static func httpStatus(from error: Error) -> Int? {
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

    func recordProxyRouteLogEntry(
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
        failureMessage: String? = nil,
        parentRequestID: String? = nil
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
            failureMessage: Self.sanitizedFailureMessage(failureMessage),
            parentRequestID: parentRequestID
        )
        await appendProxyRouteLog(entry)
    }

    /// Build a stable idempotency key from the request content and the route
    /// it was served on. Identical retries of the same completion on the same
    /// account collapse to one recorded usage event (see A2).
    func usageIdempotencyKey(requestSignature: String, route: BurnBarProviderRoute) -> String {
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
            // remediation(gateway split): one degrade-route attempt lifted into
            // `attemptCrossVendorDegradeRoute`; a non-nil result is the served
            // fallback response, nil means try the next degrade candidate —
            // identical to the original inline return/continue logic.
            if let served = await attemptCrossVendorDegradeRoute(
                route: ranked.route,
                router: router,
                requestedModelID: requestedModelID,
                requestedCanonicalModelID: requestedCanonicalModelID,
                bodyData: bodyData,
                requestSignature: requestSignature,
                logContext: logContext,
                priorAttempts: priorAttempts,
                attempts: &attempts
            ) {
                return served
            }
        }
        return GatewayDegradeAttemptResult(outcome: nil, attempts: attempts)
    }

    /// remediation(gateway split): one cross-vendor degrade attempt (formerly the
    /// inner body of the `for ranked in degradeRoutes` loop). Returns the served
    /// `GatewayDegradeAttemptResult` on success, or nil on failure after
    /// recording the failed attempt and marking the route — letting the caller
    /// fall through to the next degrade candidate exactly as before.
    private func attemptCrossVendorDegradeRoute(
        route: BurnBarProviderRoute,
        router: BurnBarProviderRouter,
        requestedModelID: String,
        requestedCanonicalModelID: String?,
        bodyData: Data,
        requestSignature: String,
        logContext: GatewayRequestContext,
        priorAttempts: [BurnBarProxyRouteAttempt],
        attempts: inout [BurnBarProxyRouteAttempt]
    ) async -> GatewayDegradeAttemptResult? {
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
            return nil
        }
    }

    func proxyChatCompletions(
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

    func canonicalModelID(
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
    func relayProxyStream(
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

    /// remediation(loopback-c): shared 429 writer so the general limiter and the
    /// stricter tokenless-loopback ceiling emit byte-identical throttle responses
    /// (CORS headers + `Retry-After`), then close the connection.
    private func writeRateLimitResponse(
        on connection: NWConnection,
        retryAfter: Double,
        request: HTTPRequest
    ) async {
        var rateLimitHeaders: [String: String] = [
            "Content-Type": "application/json",
            "Retry-After": "\(Int(ceil(retryAfter)))"
        ]
        for (key, value) in corsHeaders(for: request) {
            rateLimitHeaders[key] = value
        }
        await writeResponse(on: connection, status: 429, headers: rateLimitHeaders, body: errorBody("rate limit exceeded"))
        connection.cancel()
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

    func errorBody(_ message: String) -> String {
        encodeBody(GatewayErrorResponse(error: message))
    }

    func jsonResponse(status: Int, body: String) -> GatewayHTTPResponse {
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

    // remediation(gateway decomposition): `GatewayStreamUsageFormat` and
    // `GatewayStreamingUsageAccumulator` moved verbatim to
    // GatewayStreamingUsageAccumulator.swift (same directory, module-internal).
    // No behavior change.

}

// remediation(gateway decomposition): `BurnBarHTTPGatewayError` moved verbatim
// to OpenBurnBarHTTPGatewayError.swift (same directory, auto-included by the
// XcodeGen/SwiftPM source glob). No behavior change.
