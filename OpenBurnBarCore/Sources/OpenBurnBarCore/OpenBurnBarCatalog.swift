import Foundation

public struct BurnBarModelPricing: Codable, Hashable, Sendable {
    public let inputPerMToken: Double
    public let outputPerMToken: Double
    public let cacheReadPerMToken: Double

    public init(inputPerMToken: Double, outputPerMToken: Double, cacheReadPerMToken: Double) {
        self.inputPerMToken = inputPerMToken
        self.outputPerMToken = outputPerMToken
        self.cacheReadPerMToken = cacheReadPerMToken
    }

    public func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) -> Double {
        Double(inputTokens) / 1_000_000 * inputPerMToken
            + Double(outputTokens) / 1_000_000 * outputPerMToken
            + Double(cacheCreationTokens) / 1_000_000 * inputPerMToken
            + Double(cacheReadTokens) / 1_000_000 * cacheReadPerMToken
    }

    public static let defaultFallback = BurnBarModelPricing(
        inputPerMToken: 2.5,
        outputPerMToken: 10,
        cacheReadPerMToken: 1.25
    )
}

public enum BurnBarCatalogVisibility: String, Codable, Hashable, Sendable {
    case `public`
    case hidden
    case `internal`
}

public enum BurnBarProviderCapability: String, Codable, Hashable, Sendable {
    case routing
    case accounting
    case cursorConnector = "cursor_connector"
}

public struct BurnBarModelMatcher: Codable, Hashable, Sendable {
    public let all: [String]
    public let any: [String]
    public let none: [String]

    public init(all: [String] = [], any: [String] = [], none: [String] = []) {
        self.all = all
        self.any = any
        self.none = none
    }

    public func matches(_ normalizedModelName: String) -> Bool {
        let containsAll = all.allSatisfy(normalizedModelName.contains)
        let containsAny = any.isEmpty || any.contains(where: normalizedModelName.contains)
        let containsNone = none.allSatisfy { !normalizedModelName.contains($0) }
        return containsAll && containsAny && containsNone
    }
}

public struct BurnBarCatalogModel: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let visibility: BurnBarCatalogVisibility
    public let aliases: [String]
    public let matchers: [BurnBarModelMatcher]
    public let pricing: BurnBarModelPricing

    public init(
        id: String,
        displayName: String,
        visibility: BurnBarCatalogVisibility,
        aliases: [String] = [],
        matchers: [BurnBarModelMatcher] = [],
        pricing: BurnBarModelPricing
    ) {
        self.id = id
        self.displayName = displayName
        self.visibility = visibility
        self.aliases = aliases
        self.matchers = matchers
        self.pricing = pricing
    }

    public func matches(modelName: String) -> Bool {
        let normalized = modelName.lowercased()
        if id.lowercased() == normalized {
            return true
        }
        if aliases.contains(where: { $0.lowercased() == normalized }) {
            return true
        }
        return matchers.contains { $0.matches(normalized) }
    }
}

public struct BurnBarCatalogProvider: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let baseURL: String
    public let visibility: BurnBarCatalogVisibility
    public let capabilities: [BurnBarProviderCapability]
    public let logoKey: String?
    public let models: [BurnBarCatalogModel]

    public init(
        id: String,
        displayName: String,
        baseURL: String,
        visibility: BurnBarCatalogVisibility,
        capabilities: [BurnBarProviderCapability],
        logoKey: String? = nil,
        models: [BurnBarCatalogModel]
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.visibility = visibility
        self.capabilities = capabilities
        self.logoKey = logoKey
        self.models = models
    }

    /// Asset catalog image name for this provider's bundled logo.
    /// Falls back to a convention-based name ("{id}Logo") if not explicitly set.
    public var bundledLogoName: String {
        logoKey ?? "\(id.capitalized)Logo"
    }
}

public struct BurnBarCatalog: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let providers: [BurnBarCatalogProvider]

    public init(schemaVersion: Int, providers: [BurnBarCatalogProvider]) {
        self.schemaVersion = schemaVersion
        self.providers = providers
    }

    public func provider(id: String) -> BurnBarCatalogProvider? {
        providers.first { $0.id == id }
    }

    public func models(forProviderID providerID: String, includeHidden: Bool = true) -> [BurnBarCatalogModel] {
        let models = provider(id: providerID)?.models ?? []
        if includeHidden {
            return models
        }
        return models.filter { $0.visibility == .public }
    }

    public func suggestedModels(forProviderID providerID: String) -> [BurnBarCatalogModel] {
        models(forProviderID: providerID, includeHidden: false)
    }

    public func pricing(forModelName modelName: String) -> BurnBarModelPricing? {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        for provider in providers {
            for model in provider.models where model.matches(modelName: normalized) {
                return model.pricing
            }
        }

        return nil
    }

    /// Returns the catalog provider (vendor) that owns a given model name, if any.
    public func vendorForModel(named modelName: String) -> BurnBarCatalogProvider? {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        for provider in providers {
            for model in provider.models where model.matches(modelName: normalized) {
                return provider
            }
        }
        return nil
    }

    public func supportsModel(named modelName: String, providerID: String? = nil, includeHidden: Bool = true) -> Bool {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let providersToSearch: [BurnBarCatalogProvider]
        if let providerID, let provider = provider(id: providerID) {
            providersToSearch = [provider]
        } else {
            providersToSearch = providers
        }

        return providersToSearch.contains { provider in
            provider.models.contains { model in
                (includeHidden || model.visibility == .public) && model.matches(modelName: normalized)
            }
        }
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw BurnBarCatalogError.unsupportedSchemaVersion(schemaVersion)
        }

        var providerIDs = Set<String>()
        var modelIDs = Set<String>()

        for provider in providers {
            guard providerIDs.insert(provider.id).inserted else {
                throw BurnBarCatalogError.duplicateProviderID(provider.id)
            }

            if provider.capabilities.contains(.routing) && provider.models.filter({ $0.visibility == .public }).isEmpty {
                throw BurnBarCatalogError.providerMissingVisibleModels(provider.id)
            }

            for model in provider.models {
                guard modelIDs.insert(model.id).inserted else {
                    throw BurnBarCatalogError.duplicateModelID(model.id)
                }
            }
        }
    }
}

public enum BurnBarCatalogError: Error, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case duplicateProviderID(String)
    case duplicateModelID(String)
    case providerMissingVisibleModels(String)
    case missingBundledCatalog

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported OpenBurnBar catalog schema version \(version)."
        case .duplicateProviderID(let providerID):
            return "Duplicate provider ID '\(providerID)' in OpenBurnBar catalog."
        case .duplicateModelID(let modelID):
            return "Duplicate model ID '\(modelID)' in OpenBurnBar catalog."
        case .providerMissingVisibleModels(let providerID):
            return "Provider '\(providerID)' has routing capability but no visible models."
        case .missingBundledCatalog:
            return "Bundled OpenBurnBar catalog resource is missing."
        }
    }
}

public enum BurnBarCatalogLoader {
    public static let bundledCatalog: BurnBarCatalog = {
        do {
            return try loadBundledCatalog()
        } catch {
            fatalError("Failed to load bundled OpenBurnBar catalog: \(error)")
        }
    }()

    public static func loadBundledCatalog() throws -> BurnBarCatalog {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json") else {
            throw BurnBarCatalogError.missingBundledCatalog
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> BurnBarCatalog {
        let decoder = JSONDecoder()
        let catalog = try decoder.decode(BurnBarCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }
}
