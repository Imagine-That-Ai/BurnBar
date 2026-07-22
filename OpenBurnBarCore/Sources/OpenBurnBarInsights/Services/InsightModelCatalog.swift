import Foundation

/// Aggregates every reachable `InsightModelGateway` into a single picker.
///
/// The catalog is the source of truth for "which models can I use" — both
/// the macOS shell and the iOS shell read from the same catalog.
public actor InsightModelCatalog {
    private var gateways: [String: InsightModelGateway] = [:]
    private var cache: [String: (date: Date, models: [InsightCatalogModel])] = [:]
    private let cacheTTL: TimeInterval = 60

    public init() {}

    public func register(_ gateway: InsightModelGateway) {
        gateways[gateway.providerKey] = gateway
    }

    public func unregister(providerKey: String) {
        gateways.removeValue(forKey: providerKey)
        cache.removeValue(forKey: providerKey)
    }

    public func registeredKeys() -> [String] { Array(gateways.keys).sorted() }

    public func gateway(for providerKey: String) -> InsightModelGateway? {
        gateways[providerKey]
    }

    /// All available models across all registered adapters, sorted with
    /// `localOnly` first, then by display name.
    public func allModels(refresh: Bool = false) async -> [InsightCatalogModel] {
        let now = Date()
        var out: [InsightCatalogModel] = []
        for (key, gateway) in gateways {
            if !refresh, let cached = cache[key], now.timeIntervalSince(cached.date) < cacheTTL {
                out.append(contentsOf: cached.models)
                continue
            }
            do {
                let models = try await gateway.availableModels()
                cache[key] = (now, models)
                out.append(contentsOf: models)
            } catch {
                // Skip unreachable gateways but keep the rest of the catalog.
                continue
            }
        }
        return out.sorted { lhs, rhs in
            if lhs.egressTier != rhs.egressTier {
                return egressOrder(lhs.egressTier) < egressOrder(rhs.egressTier)
            }
            return lhs.displayName < rhs.displayName
        }
    }

    private func egressOrder(_ tier: InsightEgressTier) -> Int {
        switch tier {
        case .localOnly: return 0
        case .userRelay: return 1
        case .userKey: return 2
        case .hosted: return 3
        }
    }
}
