import OpenBurnBarEngine
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

        let normalizedRequested = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedBase = directCloudModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCanonical = canonicalCloudModelID(modelName)?.lowercased()
        let configuredCloudModel = configuration.preferredModels.first { model in
            isExplicitlyConfiguredCloudModel(
                model,
                normalizedRequested: normalizedRequested,
                normalizedBase: normalizedBase,
                normalizedCanonical: normalizedCanonical
            )
        }
        guard let configuredCloudModel else { return nil }

        let resolvedModelID = cloudAliasBaseModelID(from: configuredCloudModel.id) ?? configuredCloudModel.id
        let canonicalModelID: String
        if configuredCloudModel.id.caseInsensitiveCompare(directCloudModelID) != .orderedSame {
            canonicalModelID = configuredCloudModel.exactCanonicalModelID(forRequestedModelID: modelName)
                ?? configuredCloudModel.exactCanonicalModelID(forRequestedModelID: directCloudModelID)
                ?? configuredCloudModel.canonicalModelID
                ?? normalizedCanonical
                ?? configuredCloudModel.id
        } else {
            canonicalModelID = normalizedBase
        }
        let capabilityClassID = configuredCloudModel.capabilityClassID ?? configuredCloudModel.id

        return BurnBarCatalogModel(
            id: resolvedModelID,
            displayName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            visibility: .hidden,
            aliases: [modelName],
            matchers: [],
            pricing: configuredCloudModel.pricing,
            canonicalModelID: canonicalModelID,
            capabilityClassID: capabilityClassID,
            capabilityClassRank: configuredCloudModel.capabilityClassRank
        )
    }

    private static func isExplicitlyConfiguredCloudModel(
        _ model: BurnBarCatalogModel,
        normalizedRequested: String,
        normalizedBase: String,
        normalizedCanonical: String?
    ) -> Bool {
        if isCloudFamilyModelID(model.id) {
            return false
        }

        let configuredIDs = [model.id, model.canonicalModelID].compactMap(\.self) + model.aliases
        let exactModelIDs = configuredIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let requestedIDs = [normalizedRequested, normalizedBase, normalizedCanonical]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return requestedIDs.contains { exactModelIDs.contains($0) }
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
