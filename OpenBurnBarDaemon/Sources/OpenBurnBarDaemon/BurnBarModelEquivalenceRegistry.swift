import Foundation
import OpenBurnBarCore

public enum BurnBarModelEquivalenceTier: String, Codable, Hashable, Sendable {
    case exactCanonical = "exact_canonical"
    case curatedCapabilityClass = "curated_capability_class"
    case benchmarkBand = "benchmark_band"
}

public struct BurnBarModelEquivalenceRegistry: Sendable {
    public struct Resolution: Hashable, Sendable {
        public let tier: BurnBarModelEquivalenceTier
        public let identifier: String
        public let formatFamily: BurnBarProviderFormatFamily
    }

    private struct ModelMatch {
        let provider: BurnBarCatalogProvider
        let model: BurnBarCatalogModel
    }

    private let catalog: BurnBarCatalog

    public init(catalog: BurnBarCatalog) {
        self.catalog = catalog
    }

    public func exactCanonicalModelID(
        for modelName: String,
        providerID: String? = nil,
        requestedFormatFamily: BurnBarProviderFormatFamily? = nil
    ) -> String? {
        let matches = matchingModels(
            named: modelName,
            providerID: providerID,
            requestedFormatFamily: requestedFormatFamily
        )
        let canonicalIDs = Set(matches.compactMap { match in
            BurnBarCatalogModel.normalizedCanonicalModelID(match.model.canonicalModelID)
        })
        return canonicalIDs.count == 1 ? canonicalIDs.first : nil
    }

    public func curatedCapabilityClassID(
        for modelName: String,
        providerID: String? = nil,
        requestedFormatFamily: BurnBarProviderFormatFamily? = nil
    ) -> String? {
        let matches = matchingModels(
            named: modelName,
            providerID: providerID,
            requestedFormatFamily: requestedFormatFamily
        )
        let classIDs = Set(matches.compactMap { match in
            normalized(match.model.capabilityClassID) ?? match.model.id.lowercased()
        })
        return classIDs.count == 1 ? classIDs.first : nil
    }

    public func benchmarkBandID(
        for modelName: String,
        providerID: String? = nil,
        requestedFormatFamily: BurnBarProviderFormatFamily? = nil
    ) -> String? {
        let matches = matchingModels(
            named: modelName,
            providerID: providerID,
            requestedFormatFamily: requestedFormatFamily
        )
        let bands = Set(matches.compactMap { match in
            benchmarkBand(forRank: match.model.capabilityClassRank)
        })
        return bands.count == 1 ? bands.first : nil
    }

    public func resolution(
        for modelName: String,
        providerID: String? = nil,
        requestedFormatFamily: BurnBarProviderFormatFamily
    ) -> Resolution? {
        if let canonical = exactCanonicalModelID(
            for: modelName,
            providerID: providerID,
            requestedFormatFamily: requestedFormatFamily
        ) {
            return Resolution(tier: .exactCanonical, identifier: canonical, formatFamily: requestedFormatFamily)
        }
        if let capability = curatedCapabilityClassID(
            for: modelName,
            providerID: providerID,
            requestedFormatFamily: requestedFormatFamily
        ) {
            return Resolution(tier: .curatedCapabilityClass, identifier: capability, formatFamily: requestedFormatFamily)
        }
        if let band = benchmarkBandID(
            for: modelName,
            providerID: providerID,
            requestedFormatFamily: requestedFormatFamily
        ) {
            return Resolution(tier: .benchmarkBand, identifier: band, formatFamily: requestedFormatFamily)
        }
        return nil
    }

    private func matchingModels(
        named modelName: String,
        providerID: String?,
        requestedFormatFamily: BurnBarProviderFormatFamily?
    ) -> [ModelMatch] {
        let normalizedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedModelName.isEmpty else { return [] }

        return catalog.providers
            .filter { provider in
                (providerID == nil || provider.id == providerID)
                    && (requestedFormatFamily == nil || provider.formatFamily == requestedFormatFamily)
            }
            .flatMap { provider in
                provider.models.compactMap { model in
                    model.matches(modelName: normalizedModelName)
                        ? ModelMatch(provider: provider, model: model)
                        : nil
                }
            }
    }

    private func benchmarkBand(forRank rank: Int?) -> String? {
        guard let rank else { return nil }
        switch rank {
        case ...10:
            return "frontier"
        case 11...30:
            return "advanced"
        case 31...60:
            return "standard"
        default:
            return "economy"
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
