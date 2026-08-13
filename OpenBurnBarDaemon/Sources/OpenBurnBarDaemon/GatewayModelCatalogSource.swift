import OpenBurnBarEngine
import Foundation

/// The gateway's model-catalog source of truth: expensive provider discovery
/// (with its optional TTL cache), fresh catalog projection, and per-model advertisement
/// eligibility predicate. Both the `/v1/models` responder and the routing path
/// consume it through this narrow interface, so the server no longer carries the
/// catalog session / droid runner / cache-TTL / cached-snapshot fields inline —
/// it holds one typed collaborator instead of five scattered dependencies.
///
/// An `actor` because it owns the mutable `cachedDiscovery`: the check-then-refresh
/// in `snapshot()` is race-free only under a single isolation domain (the same
/// guarantee the gateway actor gave it before extraction). With `cacheTTL == 0`
/// (the default) it performs a fresh fan-out per call, byte-for-byte identical to
/// the pre-cache behavior.
actor GatewayModelCatalogSource {
    private struct CachedDiscovery {
        let configRevision: UInt64
        let storedAt: Date
        let snapshot: BurnBarLiveModelCatalogDiscoverySnapshot
    }

    private let configStore: BurnBarConfigStore
    private let session: URLSession
    private let droidProcessRunner: any FactoryDroidProcessRunning
    private let modelHealthStore: BurnBarGatewayModelHealthStore
    private let cacheTTL: TimeInterval
    private let logger: any BurnBarDaemonLogging
    private var cachedDiscovery: CachedDiscovery?

    init(
        configStore: BurnBarConfigStore,
        session: URLSession,
        droidProcessRunner: any FactoryDroidProcessRunning,
        modelHealthStore: BurnBarGatewayModelHealthStore,
        cacheTTL: TimeInterval,
        logger: any BurnBarDaemonLogging
    ) {
        self.configStore = configStore
        self.session = session
        self.droidProcessRunner = droidProcessRunner
        self.modelHealthStore = modelHealthStore
        self.cacheTTL = max(0, cacheTTL)
        self.logger = logger
    }

    /// remediation(B1): single, shared accessor for the expensive live
    /// model-catalog projection used by BOTH `/v1/models` and the routing path.
    /// When `cacheTTL` is positive, only provider discovery is reused while it is
    /// fresh and discovery-relevant configuration is unchanged. Credential health,
    /// quota, metadata, and route eligibility are projected from the latest config
    /// on every call. Runs inside actor isolation, so cache refresh is race-free.
    func snapshot() async throws -> BurnBarLiveModelCatalogSnapshot {
        let initialConfigRevision = await configStore.modelCatalogConfigurationRevision()
        let catalog = BurnBarLiveModelCatalog(
            configStore: configStore,
            session: session,
            droidProcessRunner: droidProcessRunner
        )
        let discovery: BurnBarLiveModelCatalogDiscoverySnapshot
        if cacheTTL > 0,
           let cached = cachedDiscovery,
           cached.configRevision == initialConfigRevision,
           Date().timeIntervalSince(cached.storedAt) < cacheTTL {
            discovery = cached.snapshot
        } else {
            discovery = try await catalog.discoverySnapshot()
        }

        let snapshot = try await catalog.snapshot(using: discovery)
        let projectedConfigRevision = await configStore.modelCatalogConfigurationRevision()
        if projectedConfigRevision != initialConfigRevision {
            let refreshedDiscovery = try await catalog.discoverySnapshot()
            if cacheTTL > 0 {
                cachedDiscovery = CachedDiscovery(
                    configRevision: projectedConfigRevision,
                    storedAt: Date(),
                    snapshot: refreshedDiscovery
                )
            }
            return try await catalog.snapshot(using: refreshedDiscovery)
        }

        if cacheTTL > 0 {
            cachedDiscovery = CachedDiscovery(
                configRevision: projectedConfigRevision,
                storedAt: Date(),
                snapshot: discovery
            )
        }
        return snapshot
    }

    /// Whether a model may be advertised right now: true unless the model-health
    /// store has an active recent-failure block for its (model, provider, account,
    /// format-family) route.
    func canAdvertise(
        _ model: BurnBarLiveAdvertisedModel,
        catalog: BurnBarCatalog
    ) async -> Bool {
        let formatFamily = Self.formatFamily(for: model, catalog: catalog)
        if let failure = await modelHealthStore.activeFailure(
            modelID: model.id,
            providerID: model.providerID,
            accountID: model.accountID,
            formatFamily: formatFamily
        ) {
            logger.warning(
                "gateway_models_route_recently_failed",
                metadata: [
                    "model": model.id,
                    "provider": model.providerID,
                    "account": model.accountID,
                    "status": "\(failure.statusCode)",
                    "blocked_until": "\(failure.blockedUntil)"
                ]
            )
            return false
        }
        return true
    }

    /// The advertised wire format family for a model. Pure (model + catalog only),
    /// so `nonisolated static` — the routing path calls it with no actor hop.
    nonisolated static func formatFamily(
        for model: BurnBarLiveAdvertisedModel,
        catalog: BurnBarCatalog
    ) -> BurnBarProviderFormatFamily {
        if model.capabilities.contains(BurnBarProviderFormatFamily.anthropic.rawValue) {
            return .anthropic
        }
        if model.capabilities.contains(BurnBarProviderFormatFamily.openaiCompat.rawValue) {
            return .openaiCompat
        }
        return catalog.provider(id: model.providerID)?.formatFamily ?? .openaiCompat
    }
}
