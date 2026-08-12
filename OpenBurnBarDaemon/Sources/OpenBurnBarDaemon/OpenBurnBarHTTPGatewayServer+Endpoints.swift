import OpenBurnBarEngine
import OpenBurnBarKernel
import CryptoKit
import Foundation
import Network

// OpenAI/Anthropic endpoint handlers (/v1/chat/completions, /v1/responses, /v1/messages) and their route descriptors.
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-file decomposition);
// an extension on the same actor — behavior- and isolation-identical.

extension BurnBarHTTPGatewayServer {

    private struct ResolvedGatewayClientContext {
        let executionSource: UsageExecutionSource
        let attribution: GatewayRequestAttribution
    }

    private static let safariAttributionRejectionBody =
        #"{"error":{"message":"Safari attribution capability is invalid or expired.","code":"gateway_attribution_rejected"}}"#

    func handleChatCompletions(
        body: String?,
        headers: [String: String],
        connection: NWConnection,
        corsHeaders: [String: String]
    ) async -> GatewayRouteOutcome {
        let clientContext: ResolvedGatewayClientContext
        switch await resolvedClientContext(from: headers) {
        case .success(let resolved):
            clientContext = resolved
        case .failure:
            return safariAttributionRejection()
        }
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
                corsHeaders: corsHeaders,
                hostedSearch: ElderWandHostedSearchConfig.resolve(headers: headers),
                executionSource: clientContext.executionSource,
                attribution: clientContext.attribution
            )
        }

        return await routeModelRequest(
            body: body,
            connection: connection,
            corsHeaders: corsHeaders,
            executionSource: clientContext.executionSource,
            attribution: clientContext.attribution,
            descriptor: chatCompletionsEndpointDescriptor
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
                    priorAttempts: request.priorAttempts,
                    attribution: request.attribution
                )
            }
        )
    }

    func handleResponses(body: String?, headers: [String: String]) async -> GatewayRouteOutcome {
        let clientContext: ResolvedGatewayClientContext
        switch await resolvedClientContext(from: headers) {
        case .success(let resolved):
            clientContext = resolved
        case .failure:
            return safariAttributionRejection()
        }
        return await routeModelRequest(
            body: body,
            connection: nil,
            corsHeaders: [:],
            executionSource: clientContext.executionSource,
            attribution: clientContext.attribution,
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
        let clientContext: ResolvedGatewayClientContext
        switch await resolvedClientContext(from: headers) {
        case .success(let resolved):
            clientContext = resolved
        case .failure:
            return safariAttributionRejection()
        }
        return await routeModelRequest(
            body: body,
            connection: connection,
            corsHeaders: corsHeaders,
            executionSource: clientContext.executionSource,
            attribution: clientContext.attribution,
            descriptor: anthropicMessagesEndpointDescriptor
        )
    }

    private func resolvedClientContext(
        from headers: [String: String]
    ) async -> Result<ResolvedGatewayClientContext, SafariAttributionRejection> {
        let safariMarker = headers["x-openburnbar-client"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(GatewayRequestAttribution.safariClientSource)
            == .orderedSame
        let resolution: GatewayRequestAttributionResolution
        if let safariAttributionAuthority {
            resolution = await safariAttributionAuthority.resolve(
                headers: headers
            )
        } else {
            resolution = safariMarker ? .rejected : .absent
        }

        let executionSource: UsageExecutionSource
        switch resolution {
        case .accepted(let attribution):
            executionSource = UsageExecutionSourceResolver.fromClientMarker(
                attribution.clientSource
            ) ?? .unknown
        case .absent:
            executionSource = nonSafariExecutionSource(
                clientMarker: headers["x-openburnbar-client"],
                userAgent: headers["user-agent"]
            )
        case .rejected:
            return .failure(SafariAttributionRejection())
        }
        return .success(
            ResolvedGatewayClientContext(
                executionSource: executionSource,
                attribution: resolution.attribution
            )
        )
    }

    private struct SafariAttributionRejection: Error {}

    func rejectInvalidSafariAttribution(
        headers: [String: String]
    ) async -> GatewayHTTPResponse? {
        switch await resolvedClientContext(from: headers) {
        case .success:
            return nil
        case .failure:
            return safariAttributionRejectionResponse()
        }
    }

    private func safariAttributionRejection() -> GatewayRouteOutcome {
        .buffered(safariAttributionRejectionResponse())
    }

    private func safariAttributionRejectionResponse() -> GatewayHTTPResponse {
        jsonResponse(
            status: 401,
            body: Self.safariAttributionRejectionBody
        )
    }

    private func nonSafariExecutionSource(
        clientMarker: String?,
        userAgent: String?
    ) -> UsageExecutionSource {
        let resolved = UsageExecutionSourceResolver.fromClientMarker(
            clientMarker,
            allowCustom: true
        ) ?? UsageExecutionSourceResolver.fromClientMarker(userAgent)
        guard resolved?.id
                != GatewayRequestAttribution.safariClientSource else {
            return .unknown
        }
        return resolved ?? .unknown
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
