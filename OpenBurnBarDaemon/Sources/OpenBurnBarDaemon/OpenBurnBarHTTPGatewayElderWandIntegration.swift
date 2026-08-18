import Foundation
import Network
import OpenBurnBarEngine
import OpenBurnBarKernel

// MARK: - The Elder Wand — model-fusion integration

extension BurnBarHTTPGatewayServer {
    /// Top-level body key carrying the fusion recursion marker. An inner sub-call
    /// stamps this so `handleChatCompletions` treats the body as a normal,
    /// non-fusion request and never re-triggers the orchestrator.
    static let fusionRecursionMarkerKey = "x_burnbar_fusion_depth"
    static let fusionRecursionMarkerValue = "1"

    /// `true` when a request body already carries the recursion marker (either as
    /// the top-level body key or the equivalent header-style key), so fusion is
    /// not re-entered on inner panel/judge/synthesis calls.
    static func bodyCarriesFusionRecursionMarker(_ bodyData: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return false
        }
        return object[fusionRecursionMarkerKey] != nil
    }

    /// Build the orchestrator from the server's stored deps and run the fusion
    /// pipeline, mapping its result onto a `GatewayRouteOutcome`.
    func runElderWandFusion(
        bodyData: Data,
        plugin: FusionPluginConfig,
        originatingModel: String,
        wantsStream: Bool,
        connection: NWConnection,
        corsHeaders: [String: String],
        hostedSearch: ElderWandHostedSearchConfig?,
        executionSource: UsageExecutionSource
    ) async -> GatewayRouteOutcome {
        let startedAt = Date()
        let orchestrator = makeElderWandOrchestrator(
            hostedSearch: hostedSearch,
            executionSource: executionSource
        )
        let result = await orchestrator.run(
            bodyData: bodyData,
            plugin: plugin,
            originatingModel: originatingModel,
            wantsStream: wantsStream
        )

        switch result {
        case .buffered(let buffered):
            return .buffered(GatewayHTTPResponse(
                status: buffered.status,
                headers: ["Content-Type": buffered.contentType].merging(corsHeaders) { _, new in new },
                body: buffered.body
            ))

        case .failed(let failure):
            return .buffered(jsonResponse(status: failure.status, body: errorBody(failure.message)))

        case .streaming(let streaming):
            // Relay the synthesis answer over the live connection using the
            // server's existing SSE relay. A pre-stream upstream error falls back
            // to a buffered error response (no bytes have been written yet).
            let idempotencyKey = elderWandIdempotencyKey(
                requestSignature: streaming.requestSignature,
                route: streaming.route.route
            )
            do {
                let relay = try await relayProxyStream(
                    on: connection,
                    corsHeaders: corsHeaders,
                    usageFormat: .openAI,
                    route: streaming.route.route,
                    idempotencyKey: idempotencyKey,
                    parentRequestID: streaming.parentRequestID,
                    executionSource: executionSource,
                    openStream: {
                        try await self.providerExecutor.openChatCompletionsStream(
                            body: streaming.requestBody,
                            route: streaming.route.route,
                            variant: nil
                        )
                    }
                )
                await recordElderWandRouteSuccess(streaming.route)
                await recordElderWandRouteLog(
                    stageLabel: "synthesis",
                    route: streaming.route.route,
                    parentRequestID: streaming.parentRequestID,
                    startedAt: startedAt,
                    httpStatus: relay.httpStatus,
                    streamed: true,
                    streamInterrupted: relay.interrupted,
                    usage: relay.usage,
                    succeeded: !relay.interrupted,
                    failureMessage: relay.interrupted ? "synthesis stream interrupted" : nil
                )
                // Emit the full itemized fusion session as a final SSE frame so
                // clients with no local ledger (iOS over the relay) render the
                // receipt. The connection is still open after the relay's `[DONE]`;
                // the frame is additive and ignored by clients that don't read it.
                if !relay.interrupted {
                    let synthesisItem = ElderWandFusionOrchestrator.lineItem(
                        stage: .synthesis,
                        route: streaming.route,
                        requestSignature: streaming.requestSignature,
                        usage: relay.usage
                    )
                    let session = FusionSessionSpend(
                        parentRequestID: streaming.parentRequestID,
                        lineItems: streaming.priorLineItems + [synthesisItem].compactMap { $0 },
                        completedAt: Date()
                    )
                    await emitFusionSpendFrame(session, on: connection)
                }
                return relay.outcome
            } catch is BurnBarProxyStreamingUnsupported {
                // The originating route cannot stream verbatim (e.g. Ollama
                // native API). Fall back to a buffered synthesis completion.
                return await runElderWandBufferedSynthesisFallback(
                    streaming: streaming,
                    startedAt: startedAt,
                    corsHeaders: corsHeaders,
                    executionSource: executionSource
                )
            } catch {
                await recordElderWandRouteFailure(streaming.route, error: error)
                logger.error("elder_wand_synthesis_stream_failed", metadata: ["error": "\(error)"])
                await recordElderWandRouteLog(
                    stageLabel: "synthesis",
                    route: streaming.route.route,
                    parentRequestID: streaming.parentRequestID,
                    startedAt: startedAt,
                    httpStatus: Self.httpStatus(from: error),
                    streamed: false,
                    streamInterrupted: false,
                    usage: nil,
                    succeeded: false,
                    failureMessage: error.localizedDescription
                )
                return .buffered(providerFailureResponse(error, modelID: originatingModel, route: streaming.route.route))
            }
        }
    }

    /// Buffered fallback used when the originating route cannot stream verbatim.
    private func runElderWandBufferedSynthesisFallback(
        streaming: ElderWandFusionResult.Streaming,
        startedAt: Date,
        corsHeaders: [String: String],
        executionSource: UsageExecutionSource
    ) async -> GatewayRouteOutcome {
        // Re-encode the synthesis body with stream:false.
        var bufferedBody = streaming.requestBody
        if var object = try? JSONSerialization.jsonObject(with: streaming.requestBody) as? [String: Any] {
            object["stream"] = false
            if let reencoded = try? JSONSerialization.data(withJSONObject: object, options: []) {
                bufferedBody = reencoded
            }
        }
        do {
            let response = try await executeElderWandBufferedCompletion(
                body: bufferedBody,
                resolved: streaming.route
            )
            let idempotencyKey = elderWandIdempotencyKey(
                requestSignature: streaming.requestSignature,
                route: streaming.route.route
            )
            await recordUsageIfAvailable(
                response.usage,
                route: streaming.route.route,
                idempotencyKey: idempotencyKey,
                parentRequestID: streaming.parentRequestID,
                executionSource: executionSource
            )
            await recordElderWandRouteLog(
                stageLabel: "synthesis",
                route: streaming.route.route,
                parentRequestID: streaming.parentRequestID,
                startedAt: startedAt,
                httpStatus: response.statusCode,
                streamed: false,
                streamInterrupted: false,
                usage: response.usage,
                succeeded: true,
                failureMessage: nil
            )
            return .buffered(GatewayHTTPResponse(
                status: response.statusCode,
                headers: ["Content-Type": response.contentType].merging(corsHeaders) { _, new in new },
                body: response.body
            ))
        } catch {
            return .buffered(providerFailureResponse(error, modelID: streaming.route.wireModelSlug, route: streaming.route.route))
        }
    }

    /// Construct an orchestrator over the server's stored deps.
    private func makeElderWandOrchestrator(
        hostedSearch: ElderWandHostedSearchConfig?,
        executionSource: UsageExecutionSource
    ) -> ElderWandFusionOrchestrator {
        let tools = ElderWandWebTools(hostedSearch: hostedSearch).makeTools()
        return ElderWandFusionOrchestrator(
            resolveRoute: { [self] modelSlug in
                await self.resolveElderWandRoute(modelSlug: modelSlug)
            },
            bufferedCompletion: { [self] body, resolved in
                try await self.executeElderWandBufferedCompletion(body: body, resolved: resolved)
            },
            recordSubCall: { [self] record in
                await self.recordElderWandSubCall(record, executionSource: executionSource)
            },
            tools: tools,
            recursionMarkerKey: Self.fusionRecursionMarkerKey,
            recursionMarkerValue: Self.fusionRecursionMarkerValue,
            panelExecutionGate: elderWandPanelExecutionGate
        )
    }

    /// Elder Wand calls execute below the normal endpoint route pipeline, so
    /// mirror that pipeline's route/model health bookkeeping around every
    /// buffered panel, judge, and synthesis attempt.
    private func executeElderWandBufferedCompletion(
        body: Data,
        resolved: ElderWandResolvedRoute
    ) async throws -> BurnBarProviderProxyResponse {
        do {
            let response = try await proxyChatCompletions(
                body: body,
                route: resolved.route,
                formatFamily: resolved.formatFamily,
                variant: nil
            )
            await recordElderWandRouteSuccess(resolved)
            return response
        } catch {
            await recordElderWandRouteFailure(resolved, error: error)
            guard shouldRetryRotatedCurrentClaudeCredential(error, route: resolved),
                  let refreshed = await refreshedCurrentClaudeElderWandRoute(replacing: resolved) else {
                throw error
            }

            do {
                let response = try await proxyChatCompletions(
                    body: body,
                    route: refreshed.route,
                    formatFamily: refreshed.formatFamily,
                    variant: nil
                )
                await recordElderWandRouteSuccess(refreshed)
                return response
            } catch {
                await recordElderWandRouteFailure(refreshed, error: error)
                throw error
            }
        }
    }

    private func shouldRetryRotatedCurrentClaudeCredential(
        _ error: Error,
        route: ElderWandResolvedRoute
    ) -> Bool {
        guard route.route.providerID.caseInsensitiveCompare("anthropic") == .orderedSame,
              route.route.credentialSlotID?
                .caseInsensitiveCompare("current-claude-code-login") == .orderedSame,
              let providerError = error as? BurnBarProviderExecutorError,
              let statusCode = providerError.upstreamStatusAndBody?.statusCode else {
            return false
        }
        return statusCode == 401 || statusCode == 403
    }

    private func refreshedCurrentClaudeElderWandRoute(
        replacing stale: ElderWandResolvedRoute
    ) async -> ElderWandResolvedRoute? {
        await configStore.invalidateExternallyManagedCredentialMaterial()
        guard let refreshed = await resolveElderWandRoute(modelSlug: stale.wireModelSlug),
              refreshed.formatFamily == stale.formatFamily,
              refreshed.route.providerID.caseInsensitiveCompare(stale.route.providerID) == .orderedSame,
              refreshed.route.credentialSlotID?
                .caseInsensitiveCompare(stale.route.credentialSlotID ?? "") == .orderedSame,
              refreshed.route.canonicalModelID == stale.route.canonicalModelID,
              refreshed.route.resolvedModelID == stale.route.resolvedModelID,
              refreshed.route.apiKey != stale.route.apiKey else {
            return nil
        }
        return refreshed
    }

    private func recordElderWandRouteSuccess(_ resolved: ElderWandResolvedRoute) async {
        await modelHealthStore.recordSuccess(
            modelID: resolved.route.requestedModel,
            formatFamily: resolved.formatFamily,
            route: resolved.route
        )
        await elderWandHealthRouter().markRouteSuccess(resolved.route)
    }

    private func recordElderWandRouteFailure(
        _ resolved: ElderWandResolvedRoute,
        error: Error
    ) async {
        await modelHealthStore.recordFailure(
            modelID: resolved.route.requestedModel,
            formatFamily: resolved.formatFamily,
            route: resolved.route,
            error: error
        )
        await elderWandHealthRouter().markRouteFailure(resolved.route, error: error)
    }

    private func elderWandHealthRouter() -> BurnBarProviderRouter {
        BurnBarProviderRouter(
            configStore: configStore,
            logger: BurnBarDaemonLogger(category: "elder-wand-health-router")
        )
    }

    /// Resolve the winning route for a model slug, mirroring `routeModelRequest`'s
    /// resolution but returning only the top-ranked exact-model route.
    private func resolveElderWandRoute(modelSlug: String) async -> ElderWandResolvedRoute? {
        let requested = gatewayRequestedModel(from: modelSlug)
        let advertisedRequested = requested
        let routeResolution: GatewayAdvertisedRouteResolution
        do {
            routeResolution = try await resolveAdvertisedRouteKeys(
                requestedModel: requested,
                advertisedRequestedModel: advertisedRequested
            )
        } catch {
            logger.warning("elder_wand_resolve_failed", metadata: ["model": modelSlug, "error": "\(error)"])
            return nil
        }
        let routeKeysByFamily = routeResolution.routeKeysByFamily
        guard routeKeysByFamily.values.contains(where: { !$0.isEmpty }) else { return nil }

        let resolvedModel = routeResolution.requestedModel
        let families = preferredGatewayFormatFamilies(for: resolvedModel.modelID, advertised: routeKeysByFamily)
        let router = BurnBarProviderRouter(
            configStore: configStore,
            logger: BurnBarDaemonLogger(category: "elder-wand-router"),
            routingEventStore: BurnBarProviderRoutingDecisionEventStore(),
            allowDynamicOpenAICompatibleModels: true
        )
        let catalog = configStore.catalogSupport.catalog
        let effectiveProviderID = resolvedModel.providerID ?? singleAdvertisedProviderID(in: routeKeysByFamily)
        let requiredCanonicalModelID = canonicalModelID(
            forModelName: resolvedModel.modelID,
            providerID: effectiveProviderID,
            catalog: catalog
        )

        for family in families {
            guard let advertisedRouteKeys = routeKeysByFamily[family], !advertisedRouteKeys.isEmpty else { continue }
            do {
                let ranking = try await router.scoreAndRankRoutes(
                    modelName: resolvedModel.modelID,
                    preferredProviderID: effectiveProviderID,
                    requestedFormatFamily: family,
                    requiredCanonicalModelID: requiredCanonicalModelID
                )
                guard let requiredCanonical = ranking.requiredCanonicalModelID else { continue }
                let candidate = ranking.rankedRoutes
                    .map(\.route)
                    .first { route in
                        route.canonicalModelID == requiredCanonical
                            && advertisedRouteKeys.contains(routeKey(providerID: route.providerID, slotID: route.credentialSlotID))
                    }
                if let candidate {
                    return ElderWandResolvedRoute(route: candidate, formatFamily: family)
                }
            } catch {
                logger.warning("elder_wand_rank_failed", metadata: ["model": modelSlug, "error": "\(error)"])
                continue
            }
        }
        return nil
    }

    // MARK: - Sub-call accounting

    /// Distinct-per-sub-call idempotency key: the per-sub-call request signature
    /// already embeds the parent id + stage + model + index, so identical sub
    /// models never collide (unlike the shared single-route key).
    private func elderWandIdempotencyKey(
        requestSignature: String,
        route: BurnBarProviderRoute
    ) -> String {
        usageIdempotencyKey(accountingRequestID: requestSignature, route: route)
    }

    /// Record one usage event + one route-log row for a panel/judge sub-call,
    /// stamping the shared `parentRequestID` and a distinct idempotency key.
    private func recordElderWandSubCall(
        _ record: ElderWandSubCallRecord,
        executionSource: UsageExecutionSource
    ) async {
        let startedAt = Date()
        guard let route = record.route else {
            // No-route failure: still record a rejected route-log row so the
            // fusion request's ledger reflects the dropped member.
            await recordElderWandRejection(
                stageLabel: record.stage.label,
                modelSlug: record.modelSlug,
                parentRequestID: record.parentRequestID,
                startedAt: startedAt,
                failureMessage: record.failureMessage
            )
            return
        }

        if record.succeeded {
            let idempotencyKey = elderWandIdempotencyKey(
                requestSignature: record.requestSignature,
                route: route
            )
            await recordUsageIfAvailable(
                record.usage,
                route: route,
                idempotencyKey: idempotencyKey,
                parentRequestID: record.parentRequestID,
                executionSource: executionSource
            )
        }

        await recordElderWandRouteLog(
            stageLabel: record.stage.label,
            route: route,
            parentRequestID: record.parentRequestID,
            startedAt: startedAt,
            httpStatus: record.succeeded ? 200 : nil,
            streamed: false,
            streamInterrupted: false,
            usage: record.usage,
            succeeded: record.succeeded,
            failureMessage: record.failureMessage
        )
    }

    private func recordElderWandRejection(
        stageLabel: String,
        modelSlug: String,
        parentRequestID: String,
        startedAt: Date,
        failureMessage: String?
    ) async {
        let context = GatewayRequestContext(
            startedAt: startedAt,
            requestPath: "/v1/chat/completions",
            endpoint: "Elder Wand Fusion (\(stageLabel))",
            clientModelSlug: modelSlug,
            advertisedModelSlug: modelSlug,
            routingModelSlug: modelSlug,
            clientModelDisplayName: modelSlug,
            routingModelDisplayName: modelSlug,
            rewriteKind: .none
        )
        await recordProxyRouteLogEntry(
            context: context,
            requestedCanonicalModelID: nil,
            route: nil,
            finalStatus: .rejected,
            httpStatus: 503,
            attempts: [],
            failureMessage: failureMessage,
            parentRequestID: parentRequestID
        )
    }

    private func recordElderWandRouteLog(
        stageLabel: String,
        route: BurnBarProviderRoute,
        parentRequestID: String,
        startedAt: Date,
        httpStatus: Int?,
        streamed: Bool,
        streamInterrupted: Bool,
        usage: BurnBarProviderProxyUsage?,
        succeeded: Bool,
        failureMessage: String?
    ) async {
        let context = GatewayRequestContext(
            startedAt: startedAt,
            requestPath: "/v1/chat/completions",
            endpoint: "Elder Wand Fusion (\(stageLabel))",
            clientModelSlug: route.requestedModel,
            advertisedModelSlug: route.requestedModel,
            routingModelSlug: route.resolvedModelID,
            clientModelDisplayName: route.requestedModel,
            routingModelDisplayName: route.resolvedModelID,
            rewriteKind: .none
        )
        let finalStatus: BurnBarProxyRouteFinalStatus = {
            if streamInterrupted { return .streamRelayOutcome(interrupted: true) }
            return succeeded ? .exact : .failed
        }()
        await recordProxyRouteLogEntry(
            context: context,
            requestedCanonicalModelID: route.canonicalModelID,
            route: route,
            finalStatus: finalStatus,
            streamed: streamed,
            streamInterrupted: streamInterrupted,
            httpStatus: httpStatus,
            attempts: [],
            usage: usage,
            failureMessage: failureMessage,
            parentRequestID: parentRequestID
        )
    }
}
