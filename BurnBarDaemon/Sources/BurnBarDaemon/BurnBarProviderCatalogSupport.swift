import BurnBarCore
import Foundation

public enum BurnBarSupportedProvider: String, CaseIterable, Codable, Hashable, Sendable {
    case zai
    case minimax

    public static var ids: [String] {
        allCases.map(\.rawValue)
    }

    public static func isSupported(providerID: String) -> Bool {
        allCases.contains { $0.rawValue == providerID }
    }
}

public enum BurnBarProviderCatalogSupportError: Error, LocalizedError {
    case missingCatalogProvider(String)

    public var errorDescription: String? {
        switch self {
        case .missingCatalogProvider(let providerID):
            return "BurnBar catalog is missing the required provider '\(providerID)'."
        }
    }
}

public struct BurnBarProviderCatalogSupport: Sendable {
    public let catalog: BurnBarCatalog

    public init(catalog: BurnBarCatalog) {
        self.catalog = catalog
    }

    public var supportedProviders: [BurnBarCatalogProvider] {
        BurnBarSupportedProvider.allCases.compactMap { provider(id: $0.rawValue) }
    }

    public func provider(id: String) -> BurnBarCatalogProvider? {
        guard BurnBarSupportedProvider.isSupported(providerID: id) else {
            return nil
        }
        return catalog.provider(id: id)
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

    public func providerSortRank(providerID: String) -> Int {
        BurnBarSupportedProvider.allCases.firstIndex(where: { $0.rawValue == providerID }) ?? .max
    }
}
