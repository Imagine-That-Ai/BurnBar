import OpenBurnBarCore
import Foundation

public struct BurnBarProviderRoute: Hashable, Sendable {
    public let providerID: String
    public let providerDisplayName: String
    public let credentialSlotID: String?
    public let credentialSlotLabel: String?
    public let baseURL: String
    public let requestedModel: String
    public let resolvedModelID: String
    public let apiKey: String
    public let pricing: BurnBarModelPricing

    public init(
        providerID: String,
        providerDisplayName: String,
        credentialSlotID: String? = nil,
        credentialSlotLabel: String? = nil,
        baseURL: String,
        requestedModel: String,
        resolvedModelID: String,
        apiKey: String,
        pricing: BurnBarModelPricing
    ) {
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.credentialSlotID = credentialSlotID
        self.credentialSlotLabel = credentialSlotLabel
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
            return "OpenBurnBar daemon has no enabled providers to route through."
        case .unsupportedProvider(let providerID):
            return "Provider '\(providerID)' is not supported by OpenBurnBar daemon routing."
        case .providerDisabled(let providerID):
            return "Provider '\(providerID)' is disabled in the daemon config."
        case .missingCredential(let providerID):
            return "Provider '\(providerID)' is missing credentials."
        case .unsupportedModel(let modelName):
            return "Model '\(modelName)' is not supported by the configured OpenBurnBar providers."
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
        preferredProviderID: String? = nil,
        excludedRouteKeys: Set<String> = []
    ) async throws -> BurnBarProviderRoute {
        guard let route = try await candidateRoutes(
            modelName: modelName,
            preferredProviderID: preferredProviderID,
            excludedRouteKeys: excludedRouteKeys
        ).first else {
            throw BurnBarProviderRouterError.unsupportedModel(modelName.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let slotID = route.credentialSlotID {
            try? await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
        }
        return route
    }

    public func candidateRoutes(
        modelName: String,
        preferredProviderID: String? = nil,
        excludedRouteKeys: Set<String> = []
    ) async throws -> [BurnBarProviderRoute] {
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

        let routes = selectRoutes(
            for: trimmedModelName,
            configurations: scopedConfigurations
        ).filter { route in
            !excludedRouteKeys.contains(routeKey(providerID: route.providerID, slotID: route.credentialSlotID))
        }

        if let route = routes.first {
            logger.notice(
                "route_selected",
                metadata: [
                    "provider_id": route.providerID,
                    "slot_id": route.credentialSlotID ?? "legacy",
                    "resolved_model_id": route.resolvedModelID,
                    "requested_model": route.requestedModel
                ]
            )
        }
        if !routes.isEmpty { return routes }

        if let matchingProviderWithoutCredential = scopedConfigurations.first(where: {
            resolveModel(named: trimmedModelName, in: $0) != nil && effectiveAPIKey(for: $0) == nil
        }) {
            throw BurnBarProviderRouterError.missingCredential(matchingProviderWithoutCredential.provider.id)
        }

        return []
    }

    public func markRouteFailure(
        _ route: BurnBarProviderRoute,
        error: Error
    ) async {
        guard let slotID = route.credentialSlotID else { return }
        let now = Date()
        var status: BurnBarProviderCredentialSlotStatus = .coolingDown
        var cooldownUntil = Calendar.current.date(byAdding: .minute, value: 5, to: now)
        if let providerError = error as? BurnBarProviderExecutorError,
           case .upstreamError(let statusCode, let body) = providerError {
            let lowerBody = body.lowercased()
            if statusCode == 401 || statusCode == 403 {
                status = .missingSecret
                cooldownUntil = nil
            } else if statusCode == 402
                || lowerBody.contains("quota")
                || lowerBody.contains("insufficient")
                || lowerBody.contains("exhaust") {
                status = .exhausted
                cooldownUntil = nil
            }
        } else {
            let lowercasedDescription = error.localizedDescription.lowercased()
            if lowercasedDescription.contains("quota")
                || lowercasedDescription.contains("insufficient")
                || lowercasedDescription.contains("exhaust") {
                status = .exhausted
                cooldownUntil = nil
            } else if lowercasedDescription.contains("401")
                || lowercasedDescription.contains("403")
                || lowercasedDescription.contains("invalid api key") {
                status = .missingSecret
                cooldownUntil = nil
            }
        }

        try? await configStore.updateCredentialSlotStatus(
            providerID: route.providerID,
            slotID: slotID,
            status: status,
            cooldownUntil: cooldownUntil,
            message: error.localizedDescription
        )
    }

    public func markRouteSuccess(_ route: BurnBarProviderRoute) async {
        guard let slotID = route.credentialSlotID else { return }
        try? await configStore.updateCredentialSlotStatus(
            providerID: route.providerID,
            slotID: slotID,
            status: .ready,
            cooldownUntil: nil,
            message: nil
        )
    }

    private func selectRoutes(
        for modelName: String,
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> [BurnBarProviderRoute] {
        var routes: [BurnBarProviderRoute] = []

        for configuration in configurations {
            guard let resolvedModel = resolveModel(named: modelName, in: configuration) else {
                continue
            }

            let now = Date()
            let activeSlots = configuration.credentialSlots.filter { resolvedSlot in
                guard resolvedSlot.slot.isEnabled else { return false }
                guard let key = resolvedSlot.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                    return false
                }
                if let cooldown = resolvedSlot.slot.cooldownUntil, cooldown > now {
                    return false
                }
                return resolvedSlot.slot.status != .disabled
                    && resolvedSlot.slot.status != .exhausted
                    && resolvedSlot.slot.status != .missingSecret
            }

            if activeSlots.isEmpty == false {
                let sortedSlots = activeSlots.sorted { lhs, rhs in
                    let lhsPreferred = configuration.settings.preferredCredentialSlotID == lhs.slot.slotID ? 0 : 1
                    let rhsPreferred = configuration.settings.preferredCredentialSlotID == rhs.slot.slotID ? 0 : 1
                    if lhsPreferred != rhsPreferred {
                        return lhsPreferred < rhsPreferred
                    }
                    return (lhs.slot.lastSelectedAt ?? .distantPast) < (rhs.slot.lastSelectedAt ?? .distantPast)
                }

                for slot in sortedSlots {
                    guard let key = slot.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                        continue
                    }
                    routes.append(
                        BurnBarProviderRoute(
                            providerID: configuration.provider.id,
                            providerDisplayName: configuration.provider.displayName,
                            credentialSlotID: slot.slot.slotID,
                            credentialSlotLabel: slot.slot.label,
                            baseURL: configuration.settings.baseURL,
                            requestedModel: modelName,
                            resolvedModelID: resolvedModel.id,
                            apiKey: key,
                            pricing: resolvedModel.pricing
                        )
                    )
                }
                continue
            }

            if let apiKey = effectiveAPIKey(for: configuration) {
                routes.append(
                    BurnBarProviderRoute(
                        providerID: configuration.provider.id,
                        providerDisplayName: configuration.provider.displayName,
                        baseURL: configuration.settings.baseURL,
                        requestedModel: modelName,
                        resolvedModelID: resolvedModel.id,
                        apiKey: apiKey,
                        pricing: resolvedModel.pricing
                    )
                )
            }
        }

        return routes
    }

    public func routeKey(providerID: String, slotID: String?) -> String {
        "\(providerID)#\(slotID ?? "legacy")"
    }

    private func effectiveAPIKey(for configuration: BurnBarResolvedProviderConfiguration) -> String? {
        if let apiKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            return apiKey
        }

        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "openburnbar-fake-provider-key"
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
