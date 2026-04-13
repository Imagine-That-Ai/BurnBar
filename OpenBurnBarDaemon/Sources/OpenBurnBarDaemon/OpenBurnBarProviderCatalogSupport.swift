import OpenBurnBarCore
import Foundation

/// Supported providers are now derived from the catalog — any provider present in catalog.json
/// is eligible for account management and (if it has the `routing` capability) for API routing.
/// The old hardcoded enum is preserved only for migration ordering priority.
public enum BurnBarLegacyProviderRank: String, CaseIterable, Codable, Hashable, Sendable {
    case zai
    case minimax
}

public enum BurnBarProviderCatalogSupportError: Error, LocalizedError {
    case missingCatalogProvider(String)

    public var errorDescription: String? {
        switch self {
        case .missingCatalogProvider(let providerID):
            return "OpenBurnBar catalog is missing the required provider '\(providerID)'."
        }
    }
}

public struct BurnBarProviderCatalogSupport: Sendable {
    public let catalog: BurnBarCatalog

    /// Ordered provider IDs from the catalog (all providers, not just routing-capable).
    public let supportedProviderIDs: [String]

    public init(catalog: BurnBarCatalog) {
        self.catalog = catalog
        // Derive supported providers from catalog — all providers are eligible for accounts.
        self.supportedProviderIDs = catalog.providers.map(\.id)
    }

    /// Whether a provider ID is present in the catalog (eligible for account management).
    public func isSupported(providerID: String) -> Bool {
        supportedProviderIDs.contains(providerID)
    }

    /// Whether a provider supports API routing (has `routing` capability).
    public func supportsRouting(providerID: String) -> Bool {
        guard let provider = catalog.provider(id: providerID) else { return false }
        return provider.capabilities.contains(.routing)
    }

    /// All catalog providers eligible for account management.
    public var supportedProviders: [BurnBarCatalogProvider] {
        catalog.providers
    }

    public func provider(id: String) -> BurnBarCatalogProvider? {
        catalog.provider(id: id)
    }

    public func requiredProvider(id: String) throws -> BurnBarCatalogProvider {
        guard let provider = provider(id: id) else {
            throw BurnBarProviderCatalogSupportError.missingCatalogProvider(id)
        }
        return provider
    }

    public func defaultModelIDs(forProviderID providerID: String) -> [String] {
        catalog.suggestedModels(forProviderID: providerID).map(\.id)
    }

    public func supportsModelID(_ modelID: String, providerID: String) -> Bool {
        provider(id: providerID)?.models.contains(where: { $0.id == modelID }) ?? false
    }

    public func model(id: String, providerID: String) -> BurnBarCatalogModel? {
        provider(id: providerID)?.models.first(where: { $0.id == id })
    }

    public func preferredModels(
        providerID: String,
        preferredModelIDs: [String]
    ) -> [BurnBarCatalogModel] {
        guard let provider = provider(id: providerID) else {
            return []
        }

        let requestedIDs = Set(preferredModelIDs)
        let scopedModels = provider.models.filter { requestedIDs.contains($0.id) }
        if !scopedModels.isEmpty {
            return scopedModels
        }

        let fallbackIDs = Set(defaultModelIDs(forProviderID: providerID))
        let fallbackModels = provider.models.filter { fallbackIDs.contains($0.id) }
        if !fallbackModels.isEmpty {
            return fallbackModels
        }

        return provider.models.filter { $0.visibility == .public }
    }

    /// Sort rank for a provider ID. Legacy providers (zai, minimax) come first,
    /// then remaining catalog providers in catalog order.
    public func providerSortRank(providerID: String) -> Int {
        // Legacy providers get priority
        if let legacyRank = BurnBarLegacyProviderRank.allCases.firstIndex(where: { $0.rawValue == providerID }) {
            return legacyRank
        }
        // Other catalog providers come after, in catalog order
        if let catalogRank = catalog.providers.firstIndex(where: { $0.id == providerID }) {
            return BurnBarLegacyProviderRank.allCases.count + catalogRank
        }
        return .max
    }
}
