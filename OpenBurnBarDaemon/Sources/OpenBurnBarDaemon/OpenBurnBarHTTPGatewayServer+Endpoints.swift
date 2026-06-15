import OpenBurnBarCore
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
                hostedSearch: ElderWandHostedSearchConfig.resolve(headers: headers)
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

    func handleResponses(body: String?) async -> GatewayRouteOutcome {
        await routeModelRequest(
            body: body,
            connection: nil,
            corsHeaders: [:],
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
    var anthropicMessagesEndpointDescriptor: GatewayEndpointDescriptor {
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
}
