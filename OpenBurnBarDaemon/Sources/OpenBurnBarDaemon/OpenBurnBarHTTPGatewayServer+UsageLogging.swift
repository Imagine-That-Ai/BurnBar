import OpenBurnBarCore
import CryptoKit
import Foundation
import Network

// Usage recording and proxy route-log emission (one route-log per request, idempotent usage per attempt).
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-file decomposition);
// an extension on the same actor — behavior- and isolation-identical.

extension BurnBarHTTPGatewayServer {

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
}
