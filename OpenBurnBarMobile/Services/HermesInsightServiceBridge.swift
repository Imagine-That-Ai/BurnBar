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
/// Two registration paths:
/// - Local LAN session: hits `http://127.0.0.1:8642` (or whatever the
///   user re-routed `HermesService.insightsBaseURL` to). No auth header.
/// - Relay session: hits the relay URL with the user's relay credential
///   surfaced via the existing `HermesService.insightsAuthorizationHeader`
///   accessor. The Insights call goes through the same plumbing as the
///   chat surface — there's only one Hermes wire.
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

@MainActor
extension HermesService {
    /// Build a Hermes Insights provider closure for
    /// `InsightProviderGatewayRegistry.registerDefaultSwiftGateways`.
    ///
    /// The closure is `@Sendable` so it can run off-actor when the
    /// registry refreshes the catalog. It captures only the current
    /// connection's URL + auth, not a live `HermesService` reference,
    /// to keep cross-actor lifecycle clean.
    func makeInsightProvider() -> InsightProviderGatewayRegistry.HermesProvider {
        let url = insightsBaseURL
        let auth = insightsAuthorizationHeader
        let reachable = isReachable
        return { @Sendable in
            guard reachable else { return nil }
            return HermesInsightServiceBridge(
                baseURL: url,
                authorizationHeader: auth
            ).makeAdapter()
        }
    }
}
