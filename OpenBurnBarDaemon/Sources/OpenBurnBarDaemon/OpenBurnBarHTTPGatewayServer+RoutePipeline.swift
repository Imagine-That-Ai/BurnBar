import OpenBurnBarCore
import CryptoKit
import Foundation
import Network

// Unified routing pipeline: parse, attempt, fail-over, usage, degrade.
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-type decomposition) — same module, same isolation, verbatim.

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
    func routeModelRequest(
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

    func appendProxyRouteLog(_ entry: BurnBarProxyRouteLogEntry) async {
        guard let proxyRouteLogStore else { return }
        await proxyRouteLogStore.append(entry)
    }

    func proxyRouteUsage(
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

    func routeAttempt(
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

    func providerLogoKey(for route: BurnBarProviderRoute) -> String {
        configStore.catalogSupport.catalog.provider(id: route.providerID)?.bundledLogoName
            ?? BurnBarCatalogProvider.bundledLogoName(forProviderID: route.providerID)
            ?? "\(route.providerID.capitalized)Logo"
    }

    func routeFinalStatus(
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

    func exactModelInvariant(
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

    func transportKind(for route: BurnBarProviderRoute) -> BurnBarProxyTransportKind {
        if route.providerID.caseInsensitiveCompare("factory") == .orderedSame {
            return .factoryDroid
        }
        if interactiveClaudeExecutor != nil,
           ClaudeInteractiveSessionExecutor.isEligible(route: route) {
            return .claudeInteractive
        }
        return .http
    }

    static func providerReportedModelSlug(from body: Data) -> String? {
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

    static func sanitizedFailureMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let oneLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(oneLine.prefix(260))
    }

    static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
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
    func attemptCrossVendorDegradeForChat(
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
    func attemptCrossVendorDegradeRoute(
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

    func proxyResponses(
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
    func shouldFailOverProviderError(_ error: Error) -> Bool {
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

    func ollamaCloudWireModelID(from modelName: String) -> String? {
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
}
