import OpenBurnBarEngine
import CryptoKit
import Foundation
import Network

// Opt-in cross-vendor degrade fallback and the model-identity helpers it shares with routing.
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-file decomposition);
// an extension on the same actor — behavior- and isolation-identical.

extension BurnBarHTTPGatewayServer {

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
        accountingRequestID: String,
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
                accountingRequestID: accountingRequestID,
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
        accountingRequestID: String,
        logContext: GatewayRequestContext,
        priorAttempts: [BurnBarProxyRouteAttempt],
        attempts: inout [BurnBarProxyRouteAttempt]
    ) async -> GatewayDegradeAttemptResult? {
        let idempotencyKey = usageIdempotencyKey(accountingRequestID: accountingRequestID, route: route)
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
        switch formatFamily {
        case .openaiCompat:
            return try await providerExecutor.proxyResponses(body: body, route: route, variant: variant)
        case .anthropic:
            return try await anthropicExecutor.proxyResponses(body: body, route: route, variant: variant)
        }
    }

    func proxyMessages(
        body: Data,
        route: BurnBarProviderRoute,
        formatFamily: BurnBarProviderFormatFamily,
        variant: BurnBarModelVariant?
    ) async throws -> BurnBarProviderProxyResponse {
        switch formatFamily {
        case .openaiCompat:
            if route.providerID.caseInsensitiveCompare("factory") == .orderedSame {
                let (chatBody, streamRequested) = try BurnBarOpenAICompatibleProviderExecutor
                    .chatCompletionsBodyFromAnthropicMessagesRequest(body, modelID: route.resolvedModelID)
                let chatResponse = try await factoryExecutor.proxyChatCompletions(
                    body: chatBody,
                    route: route,
                    variant: variant
                )
                return try BurnBarOpenAICompatibleProviderExecutor.anthropicMessagesProxyResponse(
                    from: chatResponse,
                    modelID: route.resolvedModelID,
                    streamRequested: streamRequested
                )
            }
            return try await providerExecutor.proxyMessages(body: body, route: route, variant: variant)
        case .anthropic:
            return try await anthropicExecutor.proxyMessages(body: body, route: route, variant: variant)
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
