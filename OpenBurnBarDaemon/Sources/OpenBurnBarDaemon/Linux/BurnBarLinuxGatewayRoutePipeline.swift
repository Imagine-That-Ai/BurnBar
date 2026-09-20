#if os(Linux)
// cov:ignore-start -- reason: Linux-only gateway paths are exercised by the Linux gateway suite, not macOS package coverage.
import Foundation
import OpenBurnBarEngine
import OpenBurnBarKernel

/// One ranked Linux gateway route the server will attempt, plus failover context.
///
/// Pure routing state: no sockets, no executors, no actor isolation. The HTTP
/// gateway walks these choices in order, records a `BurnBarProxyRouteAttempt`
/// for each, and fails over only when `hasMoreCandidates` is true and the
/// error is a quota, auth, capacity, or retryable-transport failure.
struct BurnBarLinuxGatewayRouteChoice: Sendable, Hashable {
    let route: BurnBarProviderRoute
    let formatFamily: BurnBarProviderFormatFamily
    /// Zero-based index in the ranked list for this format family.
    let attemptIndex: Int
    /// How many later candidates remain if this attempt fails over.
    let remainingCandidates: Int

    var hasMoreCandidates: Bool { remainingCandidates > 0 }
}

/// Catalog diagnostics for one resolved provider: which account IDs to show,
/// and whether any of them can currently be attempted.
struct BurnBarLinuxGatewayRouteCatalogFacts: Sendable, Equatable {
    let accountIDs: [String]
    let isEligible: Bool
}

/// Stateless Linux gateway routing pipeline.
///
/// Extracted from `OpenBurnBarHTTPGatewayServerLinux` so eligibility, account
/// listing, format-family preference, failover, and route-attempt records can
/// be unit-tested without binding a POSIX socket. The server still owns I/O
/// (executors, stream relay, usage writes).
struct BurnBarLinuxGatewayRoutePipeline: Sendable {
    private let catalog: BurnBarCatalog?

    init(catalog: BurnBarCatalog? = nil) {
        self.catalog = catalog
    }

    func catalogFacts(
        for configuration: BurnBarResolvedProviderConfiguration,
        now: Date = Date()
    ) -> BurnBarLinuxGatewayRouteCatalogFacts {
        BurnBarLinuxGatewayRouteCatalogFacts(
            accountIDs: routeAccountIDs(for: configuration),
            isEligible: hasEligibleRoute(for: configuration, now: now)
        )
    }

    func routeAccountIDs(
        for configuration: BurnBarResolvedProviderConfiguration
    ) -> [String] {
        if !configuration.credentialSlots.isEmpty {
            return configuration.credentialSlots.compactMap { resolved in
                let slot = resolved.slot
                // Keep configured accounts in the diagnostic catalog even
                // while cooling/exhausted; route eligibility is calculated
                // separately so health remains visible during failover.
                guard slot.isEnabled else { return nil }
                if configuration.provider.local {
                    return slot.slotID
                }
                guard let apiKey = resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !apiKey.isEmpty else { return nil }
                return slot.slotID
            }
        }
        if configuration.provider.local || configuration.hasCredential {
            return ["legacy"]
        }
        return []
    }

    func hasEligibleRoute(
        for configuration: BurnBarResolvedProviderConfiguration,
        now: Date = Date()
    ) -> Bool {
        guard configuration.provider.capabilities.contains(.routing),
              configuration.settings.isEnabled else {
            return false
        }
        if !configuration.credentialSlots.isEmpty {
            return configuration.credentialSlots.contains { resolved in
                let hasCredential = configuration.provider.local
                    || (resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                guard hasCredential else { return false }
                return BurnBarProviderCredentialSlotRoutingPolicy.canAttemptRoute(
                    slot: resolved.slot,
                    providerID: configuration.provider.id,
                    hasCredential: hasCredential,
                    providerEnabled: configuration.settings.isEnabled,
                    now: now
                )
            }
        }
        return configuration.provider.local || configuration.hasCredential
    }

    /// Ranked-route walk order for one format family. Empty input yields no
    /// choices; the server then continues to the next family (or rejects).
    func choices(
        rankedRoutes: [BurnBarProviderRoute],
        formatFamily: BurnBarProviderFormatFamily
    ) -> [BurnBarLinuxGatewayRouteChoice] {
        rankedRoutes.enumerated().map { index, route in
            BurnBarLinuxGatewayRouteChoice(
                route: route,
                formatFamily: formatFamily,
                attemptIndex: index,
                remainingCandidates: rankedRoutes.count - index - 1
            )
        }
    }

    /// OpenAI-compat first unless the request is Anthropic-shaped or the model
    /// slug itself names Claude/Anthropic.
    func preferredFormatFamilies(
        modelID: String,
        prefersAnthropicFirst: Bool
    ) -> [BurnBarProviderFormatFamily] {
        if prefersAnthropicFirst {
            return [.anthropic, .openaiCompat]
        }
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("claude") || normalized.contains("anthropic")
            ? [.anthropic, .openaiCompat]
            : [.openaiCompat, .anthropic]
    }

    func shouldTryNextCandidate(
        _ choice: BurnBarLinuxGatewayRouteChoice,
        after error: Error
    ) -> Bool {
        choice.hasMoreCandidates && shouldFailOver(error)
    }

    func shouldFailOver(_ error: Error) -> Bool {
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

        if isRetryableProviderTransportError(error) {
            return true
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("quota")
            || description.contains("rate limit")
            || description.contains("429")
    }

    func isRetryableProviderTransportError(_ error: Error) -> Bool {
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
            durationMilliseconds: elapsedMilliseconds(from: startedAt, to: completedAt),
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
            failureMessage: sanitizedFailureMessage(failureMessage)
        )
    }

    func providerLogoKey(for route: BurnBarProviderRoute) -> String {
        catalog?.provider(id: route.providerID)?.bundledLogoName
            ?? BurnBarCatalogProvider.bundledLogoName(forProviderID: route.providerID)
            ?? "\(route.providerID.capitalized)Logo"
    }

    func transportKind(for route: BurnBarProviderRoute) -> BurnBarProxyTransportKind {
        route.providerID.caseInsensitiveCompare("factory") == .orderedSame ? .factoryDroid : .http
    }

    func usageIdempotencyKey(accountingRequestID: String, route: BurnBarProviderRoute) -> String {
        let routePart = "\(route.providerID)#\(route.credentialSlotID ?? "legacy")#\(route.resolvedModelID)"
        return "gateway:\(stableDigest("\(accountingRequestID)|\(routePart)"))"
    }

    func splitProviderQualifiedModelID(_ raw: String) -> (String?, String) {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              catalog?.provider(id: parts[0]) != nil,
              !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, raw)
        }
        return (parts[0], parts[1])
    }

    func httpStatus(from error: Error) -> Int? {
        if let providerError = error as? BurnBarProviderExecutorError,
           let statusAndBody = providerError.upstreamStatusAndBody {
            return statusAndBody.statusCode
        }
        return nil
    }

    func routeLogFailureMessage(from error: Error) -> String {
        if let providerError = error as? BurnBarProviderExecutorError,
           let statusAndBody = providerError.upstreamStatusAndBody {
            return "OpenBurnBar provider request failed with status \(statusAndBody.statusCode)."
        }
        return sanitizedFailureMessage(error.localizedDescription) ?? "OpenBurnBar provider request failed."
    }

    func sanitizedFailureMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let oneLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(oneLine.prefix(260))
    }

    func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        // Round, don't truncate: Date subtraction carries sub-ULP error (e.g.
        // a 10.0 -> 10.4 interval lands at 0.39999999...), which would shave
        // a real 400 ms route duration down to 399 in the route log.
        max(0, Int(((end.timeIntervalSince1970 - start.timeIntervalSince1970) * 1_000).rounded()))
    }

    private func stableDigest(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
// cov:ignore-end
#endif
