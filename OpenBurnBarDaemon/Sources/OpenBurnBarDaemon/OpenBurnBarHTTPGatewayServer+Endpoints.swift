import OpenBurnBarEngine
import OpenBurnBarKernel
import CryptoKit
import Foundation
import Network

// OpenAI/Anthropic endpoint handlers (/v1/chat/completions, /v1/responses, /v1/messages) and their route descriptors.
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-file decomposition);
// an extension on the same actor — behavior- and isolation-identical.

extension BurnBarHTTPGatewayServer {

    func handleChatCompletions(
        body: String?,
        headers: [String: String],
        connection: NWConnection,
        corsHeaders: [String: String]
    ) async -> GatewayRouteOutcome {
        // The Elder Wand: short-circuit to the model-fusion orchestrator when an
        // active `fusion` plugin is present AND the recursion marker is absent.
        // Inner panel/judge/synthesis sub-calls carry the marker so they fall
        // through to the normal single-route pipeline (no re-trigger).
        // Memory-purpose calls (scoped bearers) always take the single-route
        // pipeline so `BurnBarMemoryEgressEnforcer` sees them; fusion would
        // spend provider credentials outside the consent, retention and cap gates.
        let purpose = GatewayPurpose(header: headers[GatewayPurpose.headerName])
        if purpose == nil,
           let body, let bodyData = body.data(using: .utf8),
           !Self.bodyCarriesFusionRecursionMarker(bodyData),
           let request = try? JSONDecoder().decode(ChatCompletionsRequest.self, from: bodyData),
           let plugin = request.activeFusionPlugin {
            return await runElderWandFusion(
                bodyData: bodyData,
                plugin: plugin,
                originatingModel: request.model,
                wantsStream: request.stream == true,
                connection: connection,
                corsHeaders: corsHeaders,
                hostedSearch: ElderWandHostedSearchConfig.resolve(headers: headers),
                executionSource: executionSource(from: headers)
            )
        }

        return await routeModelRequest(
            body: body,
            connection: connection,
            corsHeaders: corsHeaders,
            executionSource: executionSource(from: headers),
            descriptor: chatCompletionsEndpointDescriptor,
            purpose: purpose
        )
    }

    func handleEmbeddings(body: String?, headers: [String: String]) async -> GatewayRouteOutcome {
        await routeModelRequest(
            body: body,
            connection: nil,
            corsHeaders: [:],
            executionSource: executionSource(from: headers),
            descriptor: embeddingsEndpointDescriptor,
            purpose: GatewayPurpose(header: headers[GatewayPurpose.headerName])
        )
    }

    /// `POST /v1/embeddings`: OpenAI-shaped, buffered only, OpenAI-compatible
    /// providers only. Memory Pro's embedding purpose rides on it.
    var embeddingsEndpointDescriptor: GatewayEndpointDescriptor {
        GatewayEndpointDescriptor(
            requestPath: "/v1/embeddings",
            endpoint: "Embeddings",
            routeErrorLogEvent: "gateway_embeddings_route_error",
            routerLoggerCategory: "gateway-router-embeddings",
            allowDynamicOpenAICompatibleModels: true,
            treatsRouterErrorAsNoEligibleRoute: true,
            finalRejectUsesRankingCanonicalModelID: false,
            decodeRequest: { data in
                let request = try JSONDecoder().decode(EmbeddingsRequest.self, from: data)
                return GatewayDecodedModelRequest(model: request.model, wantsStream: false)
            },
            selectFormatFamilies: { _, _, _ in .families([.openaiCompat]) },
            filterRankedRoutes: { routes, _ in routes },
            emptyRankedRoutesRejection: nil,
            streamAttempt: { _ in nil },
            proxyBuffered: { context in
                try await self.providerExecutor.proxyEmbeddings(body: context.bodyData, route: context.route)
            },
            attemptDegrade: nil
        )
    }

    /// Per-endpoint pipeline parameterization for `/v1/chat/completions`.
    var chatCompletionsEndpointDescriptor: GatewayEndpointDescriptor {
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
                    accountingRequestID: request.accountingRequestID,
                    executionSource: request.executionSource,
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

    func handleResponses(body: String?, headers: [String: String]) async -> GatewayRouteOutcome {
        await routeModelRequest(
            body: body,
            connection: nil,
            corsHeaders: [:],
            executionSource: executionSource(from: headers),
            descriptor: responsesEndpointDescriptor
        )
    }

    /// Per-endpoint pipeline parameterization for `/v1/responses`.
    var responsesEndpointDescriptor: GatewayEndpointDescriptor {
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

    func handleAnthropicMessages(
        body: String?,
        headers: [String: String],
        connection: NWConnection,
        corsHeaders: [String: String]
    ) async -> GatewayRouteOutcome {
        await routeModelRequest(
            body: body,
            connection: connection,
            corsHeaders: corsHeaders,
            executionSource: executionSource(from: headers),
            descriptor: anthropicMessagesEndpointDescriptor
        )
    }

    private func executionSource(from headers: [String: String]) -> UsageExecutionSource {
        UsageExecutionSourceResolver.fromClientMarker(
            headers["x-openburnbar-client"],
            allowCustom: true
        )
            ?? UsageExecutionSourceResolver.fromClientMarker(headers["user-agent"])
            ?? .unknown
    }

    /// Per-endpoint pipeline parameterization for `/v1/messages`.
    var anthropicMessagesEndpointDescriptor: GatewayEndpointDescriptor {
        GatewayEndpointDescriptor(
            requestPath: "/v1/messages",
            endpoint: "Anthropic Messages",
            routeErrorLogEvent: "gateway_anthropic_route_error",
            routerLoggerCategory: "gateway-router-anthropic",
            allowDynamicOpenAICompatibleModels: true,
            treatsRouterErrorAsNoEligibleRoute: false,
            finalRejectUsesRankingCanonicalModelID: true,
            decodeRequest: { data in
                let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)
                return GatewayDecodedModelRequest(model: request.model, wantsStream: request.stream == true)
            },
            selectFormatFamilies: { advertised, requestedModel, clientModelID in
                let families = self.preferredGatewayFormatFamilies(
                    for: requestedModel.modelID,
                    advertised: advertised
                )
                guard !families.isEmpty else {
                    return .reject(failureMessage: "No eligible route for \(clientModelID) on /v1/messages.")
                }
                return .families(families)
            },
            filterRankedRoutes: { routes, requestedModel in
                routes.filter {
                    guard let accountID = requestedModel.accountID else { return true }
                    return $0.credentialSlotID?.caseInsensitiveCompare(accountID) == .orderedSame
                }
            },
            emptyRankedRoutesRejection: { clientModelID in
                let detail = "No eligible route for \(clientModelID). "
                    + "Add or enable an advertised OpenBurnBar provider that can serve /v1/messages."
                return (
                    failureMessage: "No eligible route for \(clientModelID).",
                    response: self.jsonResponse(status: 503, body: self.errorBody(detail))
                )
            },
            streamAttempt: { context in
                // Anthropic routes stream verbatim in the client wire format;
                // OpenAI-compatible routes are translated back to Anthropic SSE
                // on the buffered path (below), so they skip streaming here to
                // keep failover/accounting intact before any bytes leave.
                guard context.formatFamily == .anthropic else { return nil }
                guard context.wantsStream else { return nil }
                return GatewayStreamAttemptPlan(usageFormat: .anthropic) {
                    try await self.anthropicExecutor.openMessagesStream(
                        body: context.bodyData,
                        route: context.route,
                        variant: context.variant
                    )
                }
            },
            proxyBuffered: { context in
                return try await self.proxyMessages(
                    body: context.bodyData,
                    route: context.route,
                    formatFamily: context.formatFamily,
                    variant: context.variant
                )
            },
            attemptDegrade: nil
        )
    }
}
