import OpenBurnBarEngine
import Foundation

extension BurnBarProviderRouter {
    public func candidateRoutes(
        modelName: String,
        preferredProviderID: String? = nil,
        excludedRouteKeys: Set<String> = [],
        requestedFormatFamily: BurnBarProviderFormatFamily? = nil,
        requiredCapabilityClassID: String? = nil,
        requiredCanonicalModelID: String? = nil,
        routerMode: ProviderRouterMode? = nil
    ) async throws -> [BurnBarProviderRoute] {
        let configurations = try await configStore.resolvedConfigurations()
        let effectiveRouterMode = try await resolvedRouterMode(routerMode)
        let derivedPreferredProviderID = preferredProviderID == nil
            ? preferredProviderForProviderFamilyMode(
                modelName: modelName,
                routerMode: effectiveRouterMode,
                requestedFormatFamily: requestedFormatFamily,
                configurations: configurations
            )
            : nil
        let effectivePreferredProviderID = preferredProviderID ?? derivedPreferredProviderID
        let resolvedRequiredCanonicalModelID = resolveRequiredCanonicalModelID(
            explicitCanonicalModelID: requiredCanonicalModelID,
            modelName: modelName,
            preferredProviderID: effectivePreferredProviderID,
            requestedFormatFamily: requestedFormatFamily,
            configurations: configurations,
            allowForeignCatalogModelForPinnedLocalProvider: preferredProviderID != nil
        )
        let resolvedRequiredCapabilityClassID = resolveRequiredCapabilityClassID(
            explicitCapabilityClassID: requiredCapabilityClassID,
            modelName: modelName,
            preferredProviderID: effectivePreferredProviderID,
            requestedFormatFamily: requestedFormatFamily,
            requiredCanonicalModelID: resolvedRequiredCanonicalModelID,
            routerMode: effectiveRouterMode
        )
        return try candidateRoutes(
            modelName: modelName,
            preferredProviderID: effectivePreferredProviderID,
            excludedRouteKeys: excludedRouteKeys,
            requestedFormatFamily: requestedFormatFamily,
            requiredCapabilityClassID: resolvedRequiredCapabilityClassID,
            requiredCanonicalModelID: resolvedRequiredCanonicalModelID,
            configurations: configurations,
            routerMode: effectiveRouterMode,
            strictPreferredProvider: preferredProviderID != nil
        )
    }

    func candidateRoutes(
        modelName: String,
        preferredProviderID: String?,
        excludedRouteKeys: Set<String>,
        requestedFormatFamily: BurnBarProviderFormatFamily?,
        requiredCapabilityClassID: String?,
        requiredCanonicalModelID: String?,
        configurations: [BurnBarResolvedProviderConfiguration],
        routerMode: ProviderRouterMode = .providerFamilyFailover,
        enforceExactModelInvariant: Bool = true,
        strictPreferredProvider: Bool = true
    ) throws -> [BurnBarProviderRoute] {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            throw BurnBarProviderRouterError.unsupportedModel(modelName)
        }

        if let preferredProviderID, !configStore.catalogSupport.isSupported(providerID: preferredProviderID) {
            throw BurnBarProviderRouterError.unsupportedProvider(preferredProviderID)
        }

        let enabledConfigurations = configurations.filter { $0.settings.isEnabled }
        guard !enabledConfigurations.isEmpty else {
            throw BurnBarProviderRouterError.noEnabledProviders
        }

        let scopedConfigurations: [BurnBarResolvedProviderConfiguration]
        if let preferredProviderID {
            guard let preferredConfiguration = configurations.first(where: { $0.provider.id == preferredProviderID }) else {
                if strictPreferredProvider == false {
                    return []
                }
                throw BurnBarProviderRouterError.unsupportedProvider(preferredProviderID)
            }
            guard preferredConfiguration.settings.isEnabled else {
                if strictPreferredProvider == false {
                    return []
                }
                throw BurnBarProviderRouterError.providerDisabled(preferredProviderID)
            }
            scopedConfigurations = [preferredConfiguration]
        } else {
            scopedConfigurations = enabledConfigurations
        }

        let allRoutes = selectRoutes(
            for: trimmedModelName,
            configurations: scopedConfigurations,
            allowForeignCatalogModelForPinnedLocalProvider: preferredProviderID != nil
        ).filter { route in
            !excludedRouteKeys.contains(routeKey(providerID: route.providerID, slotID: route.credentialSlotID))
        }

        // Format-family isolation: when the gateway request comes from an
        // Anthropic-shape endpoint (/v1/messages) we only consider Anthropic
        // family upstreams, and vice versa. This is the heart of "two
        // highways" routing — same-format failover, never cross-format.
        let formatScopedRoutes: [BurnBarProviderRoute]
        if let requestedFormatFamily {
            formatScopedRoutes = allRoutes.filter { $0.formatFamily == requestedFormatFamily }
        } else {
            formatScopedRoutes = allRoutes
        }

        let routes: [BurnBarProviderRoute]
        let capabilityScopedRoutes: [BurnBarProviderRoute]
        if let requiredCapabilityClassID {
            let normalizedClassID = requiredCapabilityClassID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            capabilityScopedRoutes = formatScopedRoutes.filter { $0.modelCapabilityClassID == normalizedClassID }
        } else {
            capabilityScopedRoutes = formatScopedRoutes
        }

        let shouldEnforceExactModel = enforceExactModelInvariant
            && (requiredCanonicalModelID != nil || routerMode.usesExactSameModelInvariant)
        if shouldEnforceExactModel {
            guard let requiredCanonicalModelID else {
                return []
            }
            routes = capabilityScopedRoutes.filter { route in
                route.canonicalModelID == requiredCanonicalModelID
            }
        } else {
            routes = capabilityScopedRoutes
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

        if let unavailable = credentialUnavailableError(
            for: trimmedModelName,
            configurations: scopedConfigurations
        ) {
            throw unavailable
        }

        return []
    }

    private func credentialUnavailableError(
        for modelName: String,
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> BurnBarProviderRouterError? {
        let now = Date()
        for configuration in configurations where resolveModel(named: modelName, in: configuration) != nil {
            if configuration.credentialSlots.isEmpty {
                if effectiveAPIKey(for: configuration) == nil {
                    return .missingCredential(configuration.provider.id)
                }
                if !BurnBarProviderAuthRegistry.authMethodAllowsProxyRouting(
                    providerID: configuration.provider.id,
                    authMethodID: nil
                ) {
                    return .credentialsUnavailable(
                        providerID: configuration.provider.id,
                        reason: "no configured credential slot is allowed for proxy routing."
                    )
                }
                continue
            }

            let enabledSlots = configuration.credentialSlots.filter { $0.slot.isEnabled }
            if enabledSlots.isEmpty {
                return .credentialsUnavailable(
                    providerID: configuration.provider.id,
                    reason: "all configured credential slots are disabled."
                )
            }

            let slotsWithSecret = enabledSlots.filter { resolvedSlot in
                OpenBurnBarProviderCredentialNormalizer.routingAPIKey(
                    providerID: configuration.provider.id,
                    rawSecret: resolvedSlot.apiKey
                ) != nil
            }
            if slotsWithSecret.isEmpty {
                return .missingCredential(configuration.provider.id)
            }

            let routeEligibleSlots = slotsWithSecret.filter {
                BurnBarProviderAuthRegistry.authMethodAllowsProxyRouting(providerID: configuration.provider.id, authMethodID: $0.slot.authMethodID)
            }
            if routeEligibleSlots.isEmpty {
                return .credentialsUnavailable(providerID: configuration.provider.id, reason: "no configured credential slot is allowed for proxy routing.")
            }

            if routeEligibleSlots.allSatisfy({ BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: $0.slot, now: now) == .exhausted }) {
                return .credentialsUnavailable(
                    providerID: configuration.provider.id,
                    reason: unavailableCredentialReason(prefix: "all configured credential slots are exhausted", slots: routeEligibleSlots)
                )
            }

            let coolingSlots = routeEligibleSlots.filter { BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: $0.slot, now: now) == .coolingDown }
            if coolingSlots.count == routeEligibleSlots.count {
                let nextRetry = coolingSlots
                    .compactMap { slot in
                        slot.slot.cooldownUntil
                            ?? slot.slot.lastQuotaResetsAt
                            ?? BurnBarProviderCredentialSlotRoutingPolicy.resetDate(from: slot.slot.lastStatusMessage)
                    }
                    .min()
                let suffix = nextRetry.map { " Retry after \($0.formatted(date: .abbreviated, time: .standard))." } ?? ""
                return .credentialsUnavailable(
                    providerID: configuration.provider.id,
                    reason: "all configured credential slots are cooling down.\(suffix)"
                )
            }

            if routeEligibleSlots.allSatisfy({ BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: $0.slot, now: now) == .missingSecret }) {
                return .missingCredential(configuration.provider.id)
            }

            return .credentialsUnavailable(
                providerID: configuration.provider.id,
                reason: unavailableCredentialReason(
                    prefix: "configured credential slots are not ready",
                    slots: routeEligibleSlots
                )
            )
        }
        return nil
    }

    private func unavailableCredentialReason(
        prefix: String,
        slots: [BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot]
    ) -> String {
        let message = slots
            .compactMap { $0.slot.lastStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let message {
            return "\(prefix). Last error: \(message)"
        }
        return "\(prefix)."
    }

    func selectRoutes(
        for modelName: String,
        configurations: [BurnBarResolvedProviderConfiguration],
        allowForeignCatalogModelForPinnedLocalProvider: Bool = false
    ) -> [BurnBarProviderRoute] {
        var routes: [BurnBarProviderRoute] = []

        for configuration in configurations {
            guard let resolvedModel = resolveModel(
                named: modelName,
                in: configuration,
                allowForeignCatalogModelForPinnedLocalProvider: allowForeignCatalogModelForPinnedLocalProvider
            ) else {
                continue
            }

            let formatFamily = configuration.provider.formatFamily

            let now = Date()
            let activeSlots = configuration.credentialSlots.filter { resolvedSlot in
                guard let key = resolvedSlot.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                    return false
                }
                return BurnBarProviderCredentialSlotRoutingPolicy.canAttemptRoute(
                    slot: resolvedSlot.slot,
                    providerID: configuration.provider.id,
                    hasCredential: true,
                    providerEnabled: configuration.settings.isEnabled,
                    now: now
                )
            }

            if activeSlots.isEmpty == false {
                let sortedSlots = activeSlots.sorted { lhs, rhs in
                    let lhsEndpointProfileID = resolvedEndpointProfileID(for: lhs, configuration: configuration)
                    let rhsEndpointProfileID = resolvedEndpointProfileID(for: rhs, configuration: configuration)
                    if lhsEndpointProfileID == rhsEndpointProfileID,
                       let quotaOrder = Self.compareQuotaDrain(
                        lhsReset: lhs.slot.lastQuotaResetsAt,
                        lhsRemainingPercent: lhs.slot.lastQuotaRemainingPercent,
                        rhsReset: rhs.slot.lastQuotaResetsAt,
                        rhsRemainingPercent: rhs.slot.lastQuotaRemainingPercent,
                        now: now
                    ) {
                        return quotaOrder.ordered
                    }
                    let lhsPreferred = configuration.settings.preferredCredentialSlotID == lhs.slot.slotID ? 0 : 1
                    let rhsPreferred = configuration.settings.preferredCredentialSlotID == rhs.slot.slotID ? 0 : 1
                    if lhsPreferred != rhsPreferred {
                        return lhsPreferred < rhsPreferred
                    }
                    return (lhs.slot.lastSelectedAt ?? .distantPast) < (rhs.slot.lastSelectedAt ?? .distantPast)
                }

                for slot in sortedSlots {
                    guard let key = OpenBurnBarProviderCredentialNormalizer.routingAPIKey(
                        providerID: configuration.provider.id,
                        rawSecret: slot.apiKey
                    ) else {
                        continue
                    }
                    let resolvedEndpoint = ProviderRouteEndpointResolver.resolve(
                        providerID: configuration.provider.id,
                        apiKey: key,
                        defaultBaseURL: configuration.settings.baseURL,
                        slot: ProviderRouteEndpointResolver.SlotContext(
                            endpointProfileID: slot.slot.endpointProfileID,
                            region: slot.slot.region,
                            authMethodID: slot.slot.authMethodID
                        )
                    )
                    routes.append(
                        BurnBarProviderRoute(
                            providerID: configuration.provider.id,
                            providerDisplayName: configuration.provider.displayName,
                            credentialSlotID: slot.slot.slotID,
                            credentialSlotLabel: slot.slot.label,
                            baseURL: resolvedEndpoint.baseURL,
                            requestedModel: modelName,
                            resolvedModelID: resolvedModel.id,
                            canonicalModelID: resolvedModel.canonicalModelID,
                            apiKey: key,
                            pricing: resolvedModel.pricing,
                            modelCapabilityClassID: resolvedModel.capabilityClassID,
                            formatFamily: formatFamily,
                            endpointProfileID: resolvedEndpoint.endpointProfileID
                        )
                    )
                }
                continue
            }

            if configuration.credentialSlots.isEmpty == false {
                continue
            }

            if configuration.provider.local, configuration.ollamaEndpoints.isEmpty == false {
                let endpointRoutes = configuration.ollamaEndpoints
                    .filter { endpoint in
                        BurnBarProviderCredentialSlotRoutingPolicy.canAttemptRoute(
                            slot: endpoint.slot,
                            providerID: configuration.provider.id,
                            hasCredential: true,
                            providerEnabled: configuration.settings.isEnabled,
                            now: now
                        )
                    }
                    .sorted { lhs, rhs in
                        if lhs.endpoint.priority != rhs.endpoint.priority {
                            return lhs.endpoint.priority < rhs.endpoint.priority
                        }
                        return lhs.endpoint.id < rhs.endpoint.id
                    }

                for endpointRoute in endpointRoutes {
                    routes.append(
                        BurnBarProviderRoute(
                            providerID: configuration.provider.id,
                            providerDisplayName: configuration.provider.displayName,
                            credentialSlotID: endpointRoute.slot.slotID,
                            credentialSlotLabel: endpointRoute.slot.label,
                            baseURL: endpointRoute.endpoint.baseURL,
                            requestedModel: modelName,
                            resolvedModelID: resolvedModel.id,
                            canonicalModelID: resolvedModel.canonicalModelID,
                            apiKey: endpointRoute.apiKey ?? "",
                            pricing: resolvedModel.pricing,
                            modelCapabilityClassID: resolvedModel.capabilityClassID,
                            formatFamily: formatFamily,
                            endpointProfileID: endpointRoute.slot.endpointProfileID
                        )
                    )
                }
                continue
            }

            if let apiKey = effectiveAPIKey(for: configuration),
               BurnBarProviderAuthRegistry.authMethodAllowsProxyRouting(
                providerID: configuration.provider.id,
                authMethodID: nil
               ) {
                let resolvedEndpoint = ProviderRouteEndpointResolver.resolve(
                    providerID: configuration.provider.id,
                    apiKey: apiKey,
                    defaultBaseURL: configuration.settings.baseURL,
                    slot: ProviderRouteEndpointResolver.SlotContext()
                )
                routes.append(
                    BurnBarProviderRoute(
                        providerID: configuration.provider.id,
                        providerDisplayName: configuration.provider.displayName,
                        baseURL: resolvedEndpoint.baseURL,
                        requestedModel: modelName,
                        resolvedModelID: resolvedModel.id,
                        canonicalModelID: resolvedModel.canonicalModelID,
                        apiKey: apiKey,
                        pricing: resolvedModel.pricing,
                        modelCapabilityClassID: resolvedModel.capabilityClassID,
                        formatFamily: formatFamily,
                        endpointProfileID: resolvedEndpoint.endpointProfileID
                    )
                )
            } else if configuration.provider.local {
                // Local, credential-less providers (e.g. a local Ollama daemon)
                // route straight to the machine with an empty key; the local
                // server ignores the Authorization header.
                let resolvedEndpoint = ProviderRouteEndpointResolver.resolve(
                    providerID: configuration.provider.id,
                    apiKey: "",
                    defaultBaseURL: configuration.settings.baseURL,
                    slot: ProviderRouteEndpointResolver.SlotContext()
                )
                routes.append(
                    BurnBarProviderRoute(
                        providerID: configuration.provider.id,
                        providerDisplayName: configuration.provider.displayName,
                        baseURL: resolvedEndpoint.baseURL,
                        requestedModel: modelName,
                        resolvedModelID: resolvedModel.id,
                        canonicalModelID: resolvedModel.canonicalModelID,
                        apiKey: "",
                        pricing: resolvedModel.pricing,
                        modelCapabilityClassID: resolvedModel.capabilityClassID,
                        formatFamily: formatFamily,
                        endpointProfileID: resolvedEndpoint.endpointProfileID
                    )
                )
            }
        }

        return routes
    }

    private func resolvedEndpointProfileID(
        for slot: BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot,
        configuration: BurnBarResolvedProviderConfiguration
    ) -> String? {
        guard let key = OpenBurnBarProviderCredentialNormalizer.routingAPIKey(
            providerID: configuration.provider.id,
            rawSecret: slot.apiKey
        ) else {
            return nil
        }
        return ProviderRouteEndpointResolver.resolve(
            providerID: configuration.provider.id,
            apiKey: key,
            defaultBaseURL: configuration.settings.baseURL,
            slot: ProviderRouteEndpointResolver.SlotContext(
                endpointProfileID: slot.slot.endpointProfileID,
                region: slot.slot.region,
                authMethodID: slot.slot.authMethodID
            )
        ).endpointProfileID
    }

    public func routeKey(providerID: String, slotID: String?) -> String {
        "\(providerID)#\(slotID ?? "legacy")"
    }

    private func effectiveAPIKey(for configuration: BurnBarResolvedProviderConfiguration) -> String? {
        if let apiKey = OpenBurnBarProviderCredentialNormalizer.routingAPIKey(
            providerID: configuration.provider.id,
            rawSecret: configuration.apiKey
        ) {
            return apiKey
        }

        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "openburnbar-fake-provider-key"
        }

        return nil
    }

    func resolveModel(
        named modelName: String,
        in configuration: BurnBarResolvedProviderConfiguration,
        allowForeignCatalogModelForPinnedLocalProvider: Bool = false
    ) -> BurnBarCatalogModel? {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, configStore.catalogSupport.modelID(normalized, isNamespaceSafeFor: configuration.provider.id) else { return nil }

        if configuration.provider.id.lowercased() == "ollama",
           isOllamaCloudBaseURL(configuration.settings.baseURL),
           OllamaCloudModelRoutingPolicy.cloudAliasBaseModelID(from: modelName) == nil {
            return nil
        }

        if configuration.provider.id.lowercased() == "ollama",
           let cloudModel = OllamaCloudModelRoutingPolicy.routeModel(
            named: modelName,
            in: configuration,
            catalog: configStore.catalogSupport.catalog,
            allowDynamicModel: allowDynamicOpenAICompatibleModels
           ) {
            return cloudModel
        }
        if configuration.provider.id.lowercased() == "ollama",
           OllamaCloudModelRoutingPolicy.cloudAliasBaseModelID(from: modelName) != nil {
            return nil
        }

        if let exactMatch = configuration.preferredModels.first(where: {
            $0.id.lowercased() == normalized || $0.aliases.contains(where: { $0.lowercased() == normalized })
        }) {
            return wireModel(for: exactMatch, requestedModel: modelName)
        }

        if let dynamicModel = dynamicDiscoveredProviderModel(
            named: modelName,
            in: configuration,
            allowForeignCatalogModelForPinnedLocalProvider: allowForeignCatalogModelForPinnedLocalProvider
        ) {
            return dynamicModel
        }

        guard let matchedModel = configuration.preferredModels.first(where: { $0.matches(modelName: normalized) }) else {
            return nil
        }

        return wireModel(for: matchedModel, requestedModel: modelName)
    }

    /// Whether a (local) provider's base URL is a queryable HTTP(S) endpoint.
    /// Subprocess-backed local providers use a non-HTTP sentinel scheme (e.g.
    /// `codex-cli://local`) and serve only their static catalog models.
    static func isHTTPLocalEndpoint(_ baseURL: String) -> Bool {
        guard let scheme = URL(string: baseURL)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func dynamicDiscoveredProviderModel(
        named modelName: String,
        in configuration: BurnBarResolvedProviderConfiguration,
        allowForeignCatalogModelForPinnedLocalProvider: Bool
    ) -> BurnBarCatalogModel? {
        guard allowDynamicOpenAICompatibleModels,
              [.openaiCompat, .anthropic].contains(configuration.provider.formatFamily),
              configuration.provider.capabilities.contains(.routing) else {
            return nil
        }

        let template = configuration.preferredModels.first
            ?? configuration.provider.models.first(where: { $0.visibility == .public })

        // Local HTTP providers can route installed models as free passthroughs.
        // Subprocess-backed local providers serve only their static catalog rows.
        if configuration.provider.local,
           !Self.isHTTPLocalEndpoint(configuration.settings.baseURL) {
            return nil
        }

        guard template != nil || configuration.provider.local else {
            return nil
        }

        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()

        // A credential-less local provider is always enabled and would otherwise
        // resolve ANY model name, shadowing real providers: a request for a
        // foreign catalog model whose vendor isn't configured (e.g. "gpt-5.5",
        // "claude-opus-4-8") would route to localhost and 404 instead of
        // surfacing a clean missing-credential error. Block only models a
        // different-family vendor owns. Ollama-family catalog models (e.g.
        // "gpt-oss:120b", "qwen3.6:27b-coding-nvfp4") stay routable locally,
        // since the user may well have pulled them, so advertised local models stay callable.
        if configuration.provider.local,
           !allowForeignCatalogModelForPinnedLocalProvider,
           let vendor = configStore.catalogSupport.catalog.vendorForModel(named: trimmed),
           !vendor.local,
           vendor.id.caseInsensitiveCompare("ollama") != .orderedSame {
            return nil
        }

        let capabilityTemplate = configuration.provider.models.first(where: { $0.matches(modelName: normalized) }) ?? template
        let pricing = capabilityTemplate?.pricing
            ?? BurnBarModelPricing(inputPerMToken: 0, outputPerMToken: 0, cacheReadPerMToken: 0)

        return BurnBarCatalogModel(
            id: trimmed,
            displayName: trimmed,
            visibility: .hidden,
            aliases: [trimmed],
            matchers: [],
            pricing: pricing,
            canonicalModelID: trimmed,
            capabilityClassID: trimmed,
            capabilityClassRank: capabilityTemplate?.capabilityClassRank
        )
    }

    private func isOllamaCloudBaseURL(_ rawURL: String) -> Bool {
        guard let host = URL(string: rawURL)?.host?.lowercased() else {
            return false
        }
        return host == "ollama.com" || host.hasSuffix(".ollama.com")
    }

    private func wireModel(
        for model: BurnBarCatalogModel,
        requestedModel: String
    ) -> BurnBarCatalogModel {
        let aliases = model.aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let canonicalModelID = model.exactCanonicalModelID(forRequestedModelID: requestedModel)
        guard aliases.isEmpty == false else {
            guard model.canonicalModelID != canonicalModelID else {
                return model
            }
            return BurnBarCatalogModel(
                id: model.id,
                displayName: model.displayName,
                visibility: model.visibility,
                aliases: model.aliases,
                matchers: model.matchers,
                pricing: model.pricing,
                canonicalModelID: canonicalModelID,
                capabilityClassID: model.capabilityClassID,
                capabilityClassRank: model.capabilityClassRank
            )
        }

        let normalizedRequestedModel = requestedModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let matchedAlias = aliases.first(where: { $0.lowercased() == normalizedRequestedModel })
        let isVirtualFamily = model.id.lowercased().hasSuffix("-family")

        let wireModelID: String
        if isVirtualFamily {
            wireModelID = matchedAlias ?? aliases.first ?? model.id
        } else if let matchedAlias {
            wireModelID = matchedAlias
        } else {
            guard model.canonicalModelID != canonicalModelID else {
                return model
            }
            return BurnBarCatalogModel(
                id: model.id,
                displayName: model.displayName,
                visibility: model.visibility,
                aliases: aliases,
                matchers: model.matchers,
                pricing: model.pricing,
                canonicalModelID: canonicalModelID,
                capabilityClassID: model.capabilityClassID,
                capabilityClassRank: model.capabilityClassRank
            )
        }

        guard wireModelID.isEmpty == false,
              wireModelID.lowercased() != model.id.lowercased() else {
            guard model.canonicalModelID != canonicalModelID else {
                return model
            }
            return BurnBarCatalogModel(
                id: model.id,
                displayName: model.displayName,
                visibility: model.visibility,
                aliases: aliases,
                matchers: model.matchers,
                pricing: model.pricing,
                canonicalModelID: canonicalModelID,
                capabilityClassID: model.capabilityClassID,
                capabilityClassRank: model.capabilityClassRank
            )
        }

        let capabilityClassID = model.capabilityClassID ?? (isVirtualFamily ? nil : wireModelID)
        return BurnBarCatalogModel(
            id: wireModelID,
            displayName: model.displayName,
            visibility: model.visibility,
            aliases: aliases,
            matchers: model.matchers,
            pricing: model.pricing,
            canonicalModelID: canonicalModelID,
            capabilityClassID: capabilityClassID,
            capabilityClassRank: model.capabilityClassRank
        )
    }

    func resolveRequiredCanonicalModelID(
        explicitCanonicalModelID: String?,
        modelName: String,
        preferredProviderID: String?,
        requestedFormatFamily: BurnBarProviderFormatFamily?,
        configurations: [BurnBarResolvedProviderConfiguration],
        allowForeignCatalogModelForPinnedLocalProvider: Bool
    ) -> String? {
        if let normalized = BurnBarCatalogModel.normalizedCanonicalModelID(explicitCanonicalModelID) {
            return normalized
        }

        let matchingConfigurations = configurations.filter { configuration in
            configuration.settings.isEnabled
                && (preferredProviderID == nil || configuration.provider.id == preferredProviderID)
                && (requestedFormatFamily == nil || configuration.provider.formatFamily == requestedFormatFamily)
        }

        let canonicalIDs = matchingConfigurations.compactMap { configuration -> String? in
            resolveModel(
                named: modelName,
                in: configuration,
                allowForeignCatalogModelForPinnedLocalProvider: allowForeignCatalogModelForPinnedLocalProvider
            )?.canonicalModelID
        }
        let uniqueCanonicalIDs = Set(canonicalIDs)
        return uniqueCanonicalIDs.count == 1 ? uniqueCanonicalIDs.first : nil
    }

    func resolveRequiredCapabilityClassID(
        explicitCapabilityClassID: String?,
        modelName: String,
        preferredProviderID: String?,
        requestedFormatFamily: BurnBarProviderFormatFamily?,
        requiredCanonicalModelID: String?,
        routerMode: ProviderRouterMode
    ) -> String? {
        if let explicit = explicitCapabilityClassID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !explicit.isEmpty {
            return explicit
        }
        guard requiredCanonicalModelID != nil || routerMode.usesExactSameModelInvariant else {
            return nil
        }
        guard preferredProviderID == nil else {
            return nil
        }
        if OllamaCloudModelRoutingPolicy.cloudAliasBaseModelID(from: modelName) != nil {
            return nil
        }
        let catalog = configStore.catalogSupport.catalog
        if let capability = catalog.capabilityClassID(forModelName: modelName) {
            return capability
        }
        guard requestedFormatFamily != nil else { return nil }
        let matchingCapabilities = catalog.providers.compactMap { provider -> String? in
            guard provider.formatFamily == requestedFormatFamily else { return nil }
            return catalog.capabilityClassID(forModelName: modelName, providerID: provider.id)
        }
        let uniqueCapabilities = Set(matchingCapabilities)
        return uniqueCapabilities.count == 1 ? uniqueCapabilities.first : nil
    }

    func resolvedRouterMode(_ requested: ProviderRouterMode?) async throws -> ProviderRouterMode {
        if let requested { return requested.effectiveMode }
        return try await configStore.snapshot().routerMode.effectiveMode
    }

    func preferredProviderForProviderFamilyMode(
        modelName: String,
        routerMode: ProviderRouterMode,
        requestedFormatFamily: BurnBarProviderFormatFamily?,
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> String? {
        guard routerMode == .providerFamilyFailover else { return nil }
        if OllamaCloudModelRoutingPolicy.cloudAliasBaseModelID(from: modelName) != nil {
            let ollamaMatches = configurations.filter { configuration in
                configuration.provider.id.lowercased() == "ollama"
                    && configuration.settings.isEnabled
                    && (requestedFormatFamily == nil || configuration.provider.formatFamily == requestedFormatFamily)
                    && resolveModel(named: modelName, in: configuration) != nil
            }
            if ollamaMatches.contains(where: { !selectRoutes(for: modelName, configurations: [$0]).isEmpty }) {
                return "ollama"
            }
            if ollamaMatches.count == 1 {
                return "ollama"
            }
        }
        if let catalogProviderID = configStore.catalogSupport.catalog.vendorForModel(named: modelName)?.id {
            let catalogMatches = configurations.filter { configuration in
                configuration.provider.id == catalogProviderID
                    && configuration.settings.isEnabled
                    && (requestedFormatFamily == nil || configuration.provider.formatFamily == requestedFormatFamily)
                    && resolveModel(named: modelName, in: configuration) != nil
            }
            if catalogMatches.contains(where: { !selectRoutes(for: modelName, configurations: [$0]).isEmpty }) {
                return catalogProviderID
            }
        }

        let matchingConfigurations = configurations.filter { configuration in
            configuration.settings.isEnabled
                && (requestedFormatFamily == nil || configuration.provider.formatFamily == requestedFormatFamily)
                && resolveModel(named: modelName, in: configuration) != nil
        }

        let routableMatches = matchingConfigurations.filter { configuration in
            !selectRoutes(for: modelName, configurations: [configuration]).isEmpty
        }
        if routableMatches.count == 1 {
            return routableMatches[0].provider.id
        }
        if routableMatches.count > 1 {
            return nil
        }
        if matchingConfigurations.count == 1 {
            return matchingConfigurations[0].provider.id
        }

        return nil
    }
}
