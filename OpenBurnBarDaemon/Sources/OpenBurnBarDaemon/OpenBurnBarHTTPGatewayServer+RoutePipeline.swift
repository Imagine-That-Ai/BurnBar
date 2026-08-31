import OpenBurnBarEngine
import OpenBurnBarKernel
import CryptoKit
import Foundation
import Network

// The unified model-routing pipeline: parse, attempt, fail-over, and terminal response selection.
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-file decomposition);
// an extension on the same actor — behavior- and isolation-identical.

extension BurnBarHTTPGatewayServer {

    // remediation(gateway split): mechanically-extracted sub-steps of
    // `routeModelRequest`. Each helper is a contiguous block lifted verbatim
    // from the former ~412-line method onto the SAME actor — no routing, auth,
    // rate-limit, or degrade semantics change. The locals the block consumed are
    // now parameters; the values it produced are returned (or mutated `inout`).

    /// remediation(gateway split): request parsing + model-override resolution
    /// step (formerly the head of `routeModelRequest`). Preserves the exact 400
    /// rejections and the alias/thinking-variant rewrite bookkeeping.
    func parseModelRequest(
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
    func attemptSingleRoute(
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
        let idempotencyKey = usageIdempotencyKey(accountingRequestID: pipeline.accountingRequestID, route: route)
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
                        executionSource: pipeline.executionSource,
                        openStream: streamPlan.openStream
                    )
                    await router.markRouteSuccess(route)
                    await modelHealthStore.recordSuccess(
                        modelID: requestedModel.originalID,
                        formatFamily: formatFamily,
                        route: route
                    )
                    await recordQuotaSignalIfAvailable(
                        headers: relay.headers,
                        route: route,
                        requestPath: logContext.requestPath,
                        endpoint: logContext.endpoint,
                        httpStatus: relay.httpStatus,
                        streamed: true
                    )
                    let attemptStatus = BurnBarProxyRouteFinalStatus.streamRelayOutcome(interrupted: relay.interrupted)
                    routeLogAttempts.append(routeAttempt(
                        sequence: routeLogAttempts.nextSequence,
                        startedAt: attemptStartedAt,
                        completedAt: Date(),
                        route: route,
                        status: attemptStatus,
                        httpStatus: relay.httpStatus
                    ))
                    let finalStatus = relay.interrupted
                        ? BurnBarProxyRouteFinalStatus.streamRelayOutcome(interrupted: true)
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
            await recordQuotaSignalIfAvailable(
                headers: response.headers,
                route: route,
                requestPath: logContext.requestPath,
                endpoint: logContext.endpoint,
                httpStatus: response.statusCode,
                streamed: false
            )
            await recordUsageIfAvailable(
                response.usage,
                route: route,
                idempotencyKey: idempotencyKey,
                executionSource: pipeline.executionSource
            )
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
            if let providerError = error as? BurnBarProviderExecutorError,
               !providerError.upstreamHeaders.isEmpty {
                await recordQuotaSignalIfAvailable(
                    headers: providerError.upstreamHeaders,
                    route: route,
                    requestPath: logContext.requestPath,
                    endpoint: logContext.endpoint,
                    httpStatus: Self.httpStatus(from: error),
                    streamed: false
                )
            }
            routeLogAttempts.append(routeAttempt(
                sequence: routeLogAttempts.nextSequence,
                startedAt: attemptStartedAt,
                completedAt: Date(),
                route: route,
                status: .failed,
                httpStatus: Self.httpStatus(from: error),
                failureMessage: Self.routeLogFailureMessage(from: error)
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
    func routeModelRequest(
        body: String?,
        connection: NWConnection?,
        corsHeaders: [String: String],
        executionSource: UsageExecutionSource,
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
        let accountingRequestID = UUID().uuidString
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
                accountingRequestID: accountingRequestID,
                executionSource: executionSource,
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
                if let rejection = await configuredRouteUnavailableRejection(
                    clientModelID: modelID,
                    requestedModel: advertisedRequestedModel,
                    requestPath: descriptor.requestPath
                ) {
                    await recordProxyRouteLogEntry(
                        context: logContext,
                        requestedCanonicalModelID: nil,
                        route: nil,
                        finalStatus: .rejected,
                        httpStatus: rejection.response.status,
                        attempts: routeLogAttempts.attempts,
                        failureMessage: rejection.failureMessage
                    )
                    return .buffered(rejection.response)
                }
                if let rejection = descriptor.emptyRankedRoutesRejection {
                    let (failureMessage, response) = rejection(modelID)
                    await recordProxyRouteLogEntry(
                        context: logContext,
                        requestedCanonicalModelID: nil,
                        route: nil,
                        finalStatus: .rejected,
                        httpStatus: 503,
                        attempts: routeLogAttempts.attempts,
                        failureMessage: failureMessage
                    )
                    return .buffered(response)
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
                            accountingRequestID: accountingRequestID,
                            executionSource: executionSource,
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
                    let returnProviderFailure = shouldReturnFinalProviderFailure(
                        lastError,
                        requestedModel: requestedModel
                    )
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
                        failureMessage: returnProviderFailure
                            ? Self.routeLogFailureMessage(from: lastError)
                            : "Exact model fail-closed after provider failure."
                    )
                    if returnProviderFailure {
                        return .buffered(providerFailureResponse(lastError, modelID: modelID, route: lastFailedRoute))
                    }
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
                        failureMessage: Self.routeLogFailureMessage(from: lastError)
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
                    failureMessage: Self.routeLogFailureMessage(from: lastError)
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
           let statusAndBody = providerError.upstreamStatusAndBody {
            let statusCode = statusAndBody.statusCode
            let body = statusAndBody.body
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

    func shouldReturnFinalProviderFailure(_ error: Error, requestedModel: GatewayRequestedModel) -> Bool {
        guard requestedModel.accountID != nil else { return false }
        guard let providerError = error as? BurnBarProviderExecutorError else { return false }
        return providerError.upstreamStatusAndBody != nil
    }

    func shouldPreferContextualProviderError(body: String, statusCode: Int) -> Bool {
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

    func noEligibleRouteResponse(modelID: String) -> GatewayHTTPResponse {
        jsonResponse(
            status: 503,
            body: errorBody("No eligible route for \(modelID). Add or enable an account/provider that serves this model.")
        )
    }

    func exactModelIdentityUnavailableResponse(modelID: String) -> GatewayHTTPResponse {
        jsonResponse(
            status: 503,
            body: errorBody(
                "No exact canonical model identity is available for \(modelID). Add or enable a direct model entry that proves the route serves this exact model."
            )
        )
    }

    func exactModelFailClosedResponse(canonicalModelID: String) -> GatewayHTTPResponse {
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
}
