import BurnBarCore
import Foundation

public struct BurnBarProviderRoute: Hashable, Sendable {
    public let providerID: String
    public let providerDisplayName: String
    public let baseURL: String
    public let requestedModel: String
    public let resolvedModelID: String
    public let apiKey: String
    public let pricing: BurnBarModelPricing

    public init(
        providerID: String,
        providerDisplayName: String,
        baseURL: String,
        requestedModel: String,
        resolvedModelID: String,
        apiKey: String,
        pricing: BurnBarModelPricing
    ) {
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.baseURL = baseURL
        self.requestedModel = requestedModel
        self.resolvedModelID = resolvedModelID
        self.apiKey = apiKey
        self.pricing = pricing
    }
}

public enum BurnBarProviderRouterError: Error, LocalizedError {
    case noEnabledProviders
    case unsupportedProvider(String)
    case providerDisabled(String)
    case missingCredential(String)
    case unsupportedModel(String)

    public var errorDescription: String? {
        switch self {
        case .noEnabledProviders:
            return "BurnBar daemon has no enabled providers to route through."
        case .unsupportedProvider(let providerID):
            return "Provider '\(providerID)' is not supported by BurnBar daemon routing."
        case .providerDisabled(let providerID):
            return "Provider '\(providerID)' is disabled in the daemon config."
        case .missingCredential(let providerID):
            return "Provider '\(providerID)' is missing credentials."
        case .unsupportedModel(let modelName):
            return "Model '\(modelName)' is not supported by the configured BurnBar providers."
        }
    }
}

public struct BurnBarProviderRouter: Sendable {
    private let configStore: BurnBarConfigStore
    private let logger: BurnBarDaemonLogger

    public init(
        configStore: BurnBarConfigStore,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "provider-router")
    ) {
        self.configStore = configStore
        self.logger = logger
    }

    public func route(
        modelName: String,
        preferredProviderID: String? = nil
    ) async throws -> BurnBarProviderRoute {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            throw BurnBarProviderRouterError.unsupportedModel(modelName)
        }

        if let preferredProviderID, !BurnBarSupportedProvider.isSupported(providerID: preferredProviderID) {
            throw BurnBarProviderRouterError.unsupportedProvider(preferredProviderID)
        }

        let configurations = try await configStore.resolvedConfigurations()
        let enabledConfigurations = configurations.filter { $0.settings.isEnabled }
        guard !enabledConfigurations.isEmpty else {
            throw BurnBarProviderRouterError.noEnabledProviders
        }

        let scopedConfigurations: [BurnBarResolvedProviderConfiguration]
        if let preferredProviderID {
            guard let preferredConfiguration = configurations.first(where: { $0.provider.id == preferredProviderID }) else {
                throw BurnBarProviderRouterError.unsupportedProvider(preferredProviderID)
            }
            guard preferredConfiguration.settings.isEnabled else {
                throw BurnBarProviderRouterError.providerDisabled(preferredProviderID)
            }
            scopedConfigurations = [preferredConfiguration]
        } else {
            scopedConfigurations = enabledConfigurations
        }

        if let route = selectRoute(for: trimmedModelName, configurations: scopedConfigurations) {
            logger.notice(
                "route_selected",
                metadata: [
                    "provider_id": route.providerID,
                    "resolved_model_id": route.resolvedModelID,
                    "requested_model": route.requestedModel
                ]
            )
            return route
        }

        if let matchingProviderWithoutCredential = scopedConfigurations.first(where: {
            resolveModel(named: trimmedModelName, in: $0) != nil && effectiveAPIKey(for: $0) == nil
        }) {
            throw BurnBarProviderRouterError.missingCredential(matchingProviderWithoutCredential.provider.id)
        }

        throw BurnBarProviderRouterError.unsupportedModel(trimmedModelName)
    }

    private func selectRoute(
        for modelName: String,
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> BurnBarProviderRoute? {
        for configuration in configurations {
            guard let resolvedModel = resolveModel(named: modelName, in: configuration),
                  let apiKey = effectiveAPIKey(for: configuration) else {
                continue
            }

            return BurnBarProviderRoute(
                providerID: configuration.provider.id,
                providerDisplayName: configuration.provider.displayName,
                baseURL: configuration.settings.baseURL,
                requestedModel: modelName,
                resolvedModelID: resolvedModel.id,
                apiKey: apiKey,
                pricing: resolvedModel.pricing
            )
        }

        return nil
    }

    private func effectiveAPIKey(for configuration: BurnBarResolvedProviderConfiguration) -> String? {
        if let apiKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            return apiKey
        }

        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "burnbar-fake-provider-key"
        }

        return nil
    }

    private func resolveModel(
        named modelName: String,
        in configuration: BurnBarResolvedProviderConfiguration
    ) -> BurnBarCatalogModel? {
        let normalized = modelName.lowercased()

        if let exactMatch = configuration.preferredModels.first(where: {
            $0.id.lowercased() == normalized || $0.aliases.contains(where: { $0.lowercased() == normalized })
        }) {
            return exactMatch
        }

        return configuration.preferredModels.first(where: { $0.matches(modelName: normalized) })
    }
}
