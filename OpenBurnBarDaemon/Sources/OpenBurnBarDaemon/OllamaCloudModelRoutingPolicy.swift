import OpenBurnBarCore
import Foundation

enum OllamaCloudModelRoutingPolicy {
    static func cloudAliasBaseModelID(from rawID: String) -> String? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func canonicalCloudModelID(_ rawID: String) -> String? {
        guard let baseID = cloudAliasBaseModelID(from: rawID) else { return nil }
        let normalizedBaseID = baseID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedBaseID.isEmpty ? nil : "\(normalizedBaseID):cloud"
    }

    static func isCloudFamilyModelID(_ rawID: String) -> Bool {
        rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("ollama-cloud-family") == .orderedSame
    }

    static func routeModel(
        named modelName: String,
        in configuration: BurnBarResolvedProviderConfiguration,
        catalog: BurnBarCatalog
    ) -> BurnBarCatalogModel? {
        guard let directCloudModelID = cloudAliasBaseModelID(from: modelName),
              mayClaimModelID(directCloudModelID, catalog: catalog) else {
            return nil
        }

        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exactCloudModel = configuration.preferredModels.first {
            $0.id.lowercased() == normalized || $0.aliases.contains { $0.lowercased() == normalized }
        }
        let concreteCloudModel: BurnBarCatalogModel? = exactCloudModel.flatMap {
            if isCloudFamilyModelID($0.id) || cloudAliasBaseModelID(from: $0.id) != nil {
                return nil
            }
            return $0
        }
        let cloudFamily = configuration.provider.models.first { $0.id == "ollama-cloud-family" }
        let modelTemplate = concreteCloudModel ?? cloudFamily
        guard let modelTemplate else { return nil }

        let resolvedModelID = concreteCloudModel?.id ?? directCloudModelID
        let canonicalModelID: String
        if let concreteCloudModel,
           concreteCloudModel.id.caseInsensitiveCompare(directCloudModelID) != .orderedSame {
            canonicalModelID = concreteCloudModel.exactCanonicalModelID(forRequestedModelID: modelName)
                ?? concreteCloudModel.canonicalModelID
                ?? concreteCloudModel.id
        } else {
            canonicalModelID = directCloudModelID
        }
        let capabilityClassID = concreteCloudModel?.capabilityClassID
            ?? concreteCloudModel?.id
            ?? directCloudModelID

        return BurnBarCatalogModel(
            id: resolvedModelID,
            displayName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            visibility: .hidden,
            aliases: [modelName],
            matchers: [],
            pricing: modelTemplate.pricing,
            canonicalModelID: canonicalModelID,
            capabilityClassID: capabilityClassID,
            capabilityClassRank: concreteCloudModel?.capabilityClassRank
                ?? cloudFamily?.capabilityClassRank
                ?? modelTemplate.capabilityClassRank
        )
    }

    static func mayClaimModelID(_ rawID: String, catalog: BurnBarCatalog) -> Bool {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let unsuffixed = cloudAliasBaseModelID(from: trimmed) ?? trimmed
        let lastPathComponent = unsuffixed
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
        let baseCandidates = ([lastPathComponent, Optional(unsuffixed)] as [String?])
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidates = baseCandidates.flatMap { candidate -> [String] in
            var values = [candidate]
            for level in BurnBarThinkingLevel.allCases {
                let suffix = "-\(level.slug)"
                if candidate.lowercased().hasSuffix(suffix) {
                    let base = String(candidate.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !base.isEmpty {
                        values.append(base)
                    }
                }
            }
            return values
        }

        for candidate in candidates {
            if candidate.lowercased().contains("claude") {
                return false
            }
            guard let vendor = catalog.vendorForModel(named: candidate) else {
                continue
            }
            if vendor.id.caseInsensitiveCompare("ollama") == .orderedSame {
                return true
            }
            if vendor.id.caseInsensitiveCompare("anthropic") == .orderedSame
                || vendor.formatFamily == .anthropic {
                return false
            }
        }
        return true
    }
}
