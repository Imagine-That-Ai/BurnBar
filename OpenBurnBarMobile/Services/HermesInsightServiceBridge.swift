import Foundation
import OpenBurnBarCore

/// Bridges the mobile shell's `HermesService` into the OpenBurnBarCore
/// Insights gateway machinery.
///
/// `HermesInsightAdapter` (in core) doesn't know what a `HermesService`
/// is — it just speaks `HermesInsightTransport`. This thin actor wraps
/// the service into the protocol so `InsightsStore` can register a
/// Hermes adapter conditionally on `service.isReachable`.
///
/// Registration is intentionally limited to the direct HTTP path until
/// mobile has a relay-native Insights transport. Relay chat can be
/// reachable while `HermesService.baseURL` still points at an old direct
/// endpoint; registering that stale URL would send Insights traffic to
/// the wrong unauthenticated target.
///
/// The bridge is intentionally a simple struct. Lifecycle is owned by
/// `InsightsStore.registerAvailableAnalysisGateways(via:)` which builds
/// it on demand inside the `hermesProvider` closure.
public struct HermesInsightServiceBridge {
    private let baseURL: URL
    private let authorizationHeader: String?

    public init(baseURL: URL, authorizationHeader: String? = nil) {
        self.baseURL = baseURL
        self.authorizationHeader = authorizationHeader
    }

    /// Build a `HermesInsightAdapter` ready to plug into
    /// `InsightModelCatalog`. Callers should already have verified
    /// connectivity (e.g. `HermesService.isReachable`) — the bridge
    /// itself doesn't ping the relay.
    public func makeAdapter() -> HermesInsightAdapter {
        let transport = HermesInsightHTTPTransport(
            baseURL: baseURL,
            authorizationHeader: authorizationHeader,
            advertisedModels: HermesInsightAdapter.defaultModels
        )
        return HermesInsightAdapter(
            transport: transport,
            availableModels: HermesInsightAdapter.defaultModels
        )
    }
}

struct HermesInsightHTTPConfiguration {
    let baseURL: URL
    let authorizationHeader: String?
}

@MainActor
extension HermesService {
    /// Build a Hermes Insights provider closure for
    /// `InsightProviderGatewayRegistry.registerDefaultSwiftGateways`.
    ///
    /// The closure is `@Sendable` so it can run off-actor when the
    /// registry refreshes the catalog. It captures only the current
    /// direct HTTP connection's URL + auth, not a live `HermesService` reference,
    /// to keep cross-actor lifecycle clean.
    func makeInsightProvider() -> InsightProviderGatewayRegistry.HermesProvider {
        let configuration = insightsHTTPConfiguration
        let reachable = isReachable
        return { @Sendable in
            guard reachable, let configuration else { return nil }
            return HermesInsightServiceBridge(
                baseURL: configuration.baseURL,
                authorizationHeader: configuration.authorizationHeader
            ).makeAdapter()
        }
    }

    var insightsHTTPConfiguration: HermesInsightHTTPConfiguration? {
        guard selectedConnection.mode == .directURL,
              let endpointURL = selectedConnection.endpointURL,
              let selectedEndpoint = HermesService.validatedEndpointURL(endpointURL),
              HermesService.sameInsightEndpoint(baseURL, selectedEndpoint) else {
            return nil
        }
        return HermesInsightHTTPConfiguration(
            baseURL: selectedEndpoint,
            authorizationHeader: insightsAuthorizationHeader(for: selectedEndpoint)
        )
    }

    private func insightsAuthorizationHeader(for endpoint: URL) -> String? {
        guard Self.canSendAuthorizationHeader(to: endpoint),
              let rawToken = try? secretStore.load(connectionID: selectedConnection.id) else {
            return nil
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return nil
        }
        return "Bearer \(token)"
    }

    private static func canSendAuthorizationHeader(to endpoint: URL) -> Bool {
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return false
        }
        if scheme == "https" {
            return true
        }
        if scheme == "http" {
            return isLoopbackHost(host)
        }
        return false
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1"
            || normalized == "::1" || normalized == "0:0:0:0:0:0:0:1"
    }

    private static func sameInsightEndpoint(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedInsightEndpoint(lhs) == normalizedInsightEndpoint(rhs)
    }

    private static func normalizedInsightEndpoint(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [scheme, host, components.port.map(String.init) ?? "", path].joined(separator: "|")
    }
}
