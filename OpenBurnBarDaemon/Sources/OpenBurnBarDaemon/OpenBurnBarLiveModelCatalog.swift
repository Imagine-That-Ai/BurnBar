import OpenBurnBarCore
import Foundation

public enum BurnBarLiveModelQuotaState: String, Codable, Hashable, Sendable {
    case healthy
    case unknown
    case exhausted
    case coolingDown = "cooling_down"
    case authFailed = "auth_failed"
    case disabled
    case missingCredential = "missing_credential"
}

public struct BurnBarLiveModelAccountDescriptor: Codable, Hashable, Sendable {
    public let providerID: String
    public let providerName: String
    public let accountID: String
    public let accountLabel: String
    public let enabled: Bool
    public let hasCredential: Bool
    public let quotaState: BurnBarLiveModelQuotaState
    public let quotaRemainingPercent: Double?
    public let quotaResetsAt: Date?
    public let lastRefreshAt: Date?
    public let lastError: String?

    public init(
        providerID: String,
        providerName: String,
        accountID: String,
        accountLabel: String,
        enabled: Bool,
        hasCredential: Bool,
        quotaState: BurnBarLiveModelQuotaState,
        quotaRemainingPercent: Double? = nil,
        quotaResetsAt: Date? = nil,
        lastRefreshAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.enabled = enabled
        self.hasCredential = hasCredential
        self.quotaState = quotaState
        self.quotaRemainingPercent = quotaRemainingPercent
        self.quotaResetsAt = quotaResetsAt
        self.lastRefreshAt = lastRefreshAt
        self.lastError = lastError
    }
}

public struct BurnBarLiveAdvertisedModel: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let providerID: String
    public let providerName: String
    public let accountID: String
    public let accountLabel: String
    public let displayNameIsCustom: Bool?
    public let sourceID: String
    public let sourceKind: String
    public let capabilities: [String]
    public let modelCapabilities: ModelIOCapabilities?
    public let quotaState: BurnBarLiveModelQuotaState
    public let enabled: Bool
    public let advertisementEnabled: Bool
    public let routeEligible: Bool
    public let lastRefreshAt: Date?
    public let lastError: String?
    /// When this row is a thinking-level variant, the base model id the
    /// gateway should route through. `nil` for non-variant rows.
    public let baseModelID: String?
    /// `BurnBarThinkingLevel.rawValue` when this row is a variant. `nil`
    /// otherwise. Stored as a string so older clients that haven't been
    /// upgraded ignore the field instead of failing to decode.
    public let thinkingLevel: String?
    /// When this row is a user-defined alias, whether the base model should
    /// be hidden from public `/v1/models`. Omitted for non-alias rows.
    public let hidesBaseModel: Bool?

    public init(
        id: String,
        displayName: String,
        providerID: String,
        providerName: String,
        accountID: String,
        accountLabel: String,
        displayNameIsCustom: Bool = false,
        sourceID: String,
        sourceKind: String,
        capabilities: [String],
        modelCapabilities: ModelIOCapabilities? = nil,
        quotaState: BurnBarLiveModelQuotaState,
        enabled: Bool,
        advertisementEnabled: Bool = true,
        routeEligible: Bool,
        lastRefreshAt: Date? = nil,
        lastError: String? = nil,
        baseModelID: String? = nil,
        thinkingLevel: String? = nil,
        hidesBaseModel: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.displayNameIsCustom = displayNameIsCustom
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.capabilities = capabilities
        self.modelCapabilities = modelCapabilities
        self.quotaState = quotaState
        self.enabled = enabled
        self.advertisementEnabled = advertisementEnabled
        self.routeEligible = routeEligible
        self.lastRefreshAt = lastRefreshAt
        self.lastError = lastError
        self.baseModelID = baseModelID
        self.thinkingLevel = thinkingLevel
        self.hidesBaseModel = hidesBaseModel
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, providerID, providerName, accountID, accountLabel
        case displayNameIsCustom
        case sourceID, sourceKind, capabilities, modelCapabilities, quotaState, enabled
        case advertisementEnabled, routeEligible, lastRefreshAt, lastError
        case baseModelID, thinkingLevel, hidesBaseModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        providerID = try container.decode(String.self, forKey: .providerID)
        providerName = try container.decode(String.self, forKey: .providerName)
        accountID = try container.decode(String.self, forKey: .accountID)
        accountLabel = try container.decode(String.self, forKey: .accountLabel)
        displayNameIsCustom = try container.decodeIfPresent(Bool.self, forKey: .displayNameIsCustom)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        sourceKind = try container.decode(String.self, forKey: .sourceKind)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        modelCapabilities = try container.decodeIfPresent(ModelIOCapabilities.self, forKey: .modelCapabilities)
        quotaState = try container.decode(BurnBarLiveModelQuotaState.self, forKey: .quotaState)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        advertisementEnabled = try container.decodeIfPresent(Bool.self, forKey: .advertisementEnabled) ?? true
        routeEligible = try container.decode(Bool.self, forKey: .routeEligible)
        lastRefreshAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        baseModelID = try container.decodeIfPresent(String.self, forKey: .baseModelID)
        thinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        hidesBaseModel = try container.decodeIfPresent(Bool.self, forKey: .hidesBaseModel)
    }
}

public struct BurnBarLiveModelCatalogSnapshot: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let models: [BurnBarLiveAdvertisedModel]
    public let accounts: [BurnBarLiveModelAccountDescriptor]

    public init(
        generatedAt: Date,
        models: [BurnBarLiveAdvertisedModel],
        accounts: [BurnBarLiveModelAccountDescriptor]
    ) {
        self.generatedAt = generatedAt
        self.models = models
        self.accounts = accounts
    }
}

public struct BurnBarLiveModelCatalog: Sendable {
    private static let ollamaCloudCatalogURL = URL(string: "https://ollama.com/search?c=cloud")!

    /// Anthropic's API version header value for the Messages models endpoint.
    private static let anthropicVersion = "2023-06-01"

    private let configStore: BurnBarConfigStore
    private let session: URLSession
    private let droidProcessRunner: any FactoryDroidProcessRunning
    private let refreshTimeoutSeconds: TimeInterval

    public init(
        configStore: BurnBarConfigStore,
        session: URLSession = .shared,
        droidProcessRunner: any FactoryDroidProcessRunning = FactoryDroidSystemProcessRunner(),
        refreshTimeoutSeconds: TimeInterval = 1.5
    ) {
        self.configStore = configStore
        self.session = session
        self.droidProcessRunner = droidProcessRunner
        self.refreshTimeoutSeconds = refreshTimeoutSeconds
    }

    public func snapshot(now: Date = Date()) async throws -> BurnBarLiveModelCatalogSnapshot {
        let configurations = try await configStore.resolvedConfigurations()
        var contexts: [AccountRefreshContext] = []

        for configuration in configurations {
            let providerID = configuration.provider.id
            let providerName = configuration.provider.displayName
            let providerEnabled = configuration.settings.isEnabled
            let providerCanRoute = configuration.provider.capabilities.contains(.routing)
            let capabilities = modelCapabilities(for: configuration.provider)

            if configuration.credentialSlots.isEmpty {
                let apiKey = OpenBurnBarProviderCredentialNormalizer.routingAPIKey(
                    providerID: providerID,
                    rawSecret: configuration.apiKey
                )
                // Local, credential-less providers (e.g. a local Ollama daemon)
                // route without an API key, so treat their credential as
                // satisfied and their quota as unknown-but-eligible.
                let hasCredential = configuration.provider.local ? true : hasUsableSecret(apiKey)
                let quotaState: BurnBarLiveModelQuotaState = configuration.provider.local
                    ? (providerEnabled ? .unknown : .disabled)
                    : (providerEnabled ? (hasCredential ? .unknown : .missingCredential) : .disabled)
                let account = BurnBarLiveModelAccountDescriptor(
                    providerID: providerID,
                    providerName: providerName,
                    accountID: "legacy",
                    accountLabel: providerName,
                    enabled: providerEnabled,
                    hasCredential: hasCredential,
                    quotaState: quotaState
                )
                contexts.append(AccountRefreshContext(
                    index: contexts.count,
                    configuration: configuration,
                    account: account,
                    apiKey: apiKey,
                    providerCanRoute: providerCanRoute,
                    capabilities: capabilities
                ))
                continue
            }

            for resolvedSlot in configuration.credentialSlots {
                let slot = resolvedSlot.slot
                let apiKey = OpenBurnBarProviderCredentialNormalizer.routingAPIKey(
                    providerID: providerID,
                    rawSecret: resolvedSlot.apiKey
                )
                let hasCredential = hasUsableSecret(apiKey)
                let account = BurnBarLiveModelAccountDescriptor(
                    providerID: providerID,
                    providerName: providerName,
                    accountID: slot.slotID,
                    accountLabel: slot.label,
                    enabled: providerEnabled && slot.isEnabled,
                    hasCredential: hasCredential,
                    quotaState: quotaState(for: slot, providerEnabled: providerEnabled, hasCredential: hasCredential, now: now),
                    quotaRemainingPercent: slot.lastQuotaRemainingPercent,
                    quotaResetsAt: slot.lastQuotaResetsAt,
                    lastRefreshAt: slot.updatedAt,
                    lastError: slot.lastStatusMessage
                )
                contexts.append(AccountRefreshContext(
                    index: contexts.count,
                    configuration: configuration,
                    account: account,
                    apiKey: apiKey,
                    providerCanRoute: providerCanRoute,
                    capabilities: capabilities
                ))
            }
        }

        let liveRefreshes = await liveRefreshes(for: contexts)
        var models: [BurnBarLiveAdvertisedModel] = []
        var accounts: [BurnBarLiveModelAccountDescriptor] = []
        for context in contexts.sorted(by: { $0.index < $1.index }) {
            let liveRefresh = liveRefreshes[context.index]
            accounts.append(context.account)
            models.append(contentsOf: advertisedModels(
                configuration: context.configuration,
                account: context.account,
                providerCanRoute: context.providerCanRoute,
                capabilities: context.capabilities,
                liveRefresh: liveRefresh
            ))
        }

        return BurnBarLiveModelCatalogSnapshot(
            generatedAt: now,
            models: models.sorted(by: modelSort),
            accounts: accounts.sorted(by: accountSort)
        )
    }

    public func hasEligibleRoute(
        for modelID: String,
        formatFamily: BurnBarProviderFormatFamily
    ) async throws -> Bool {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedModelID.isEmpty else { return false }
        let snapshot = try await snapshot()
        return snapshot.models.contains { model in
            model.routeEligible
                && model.id.lowercased() == normalizedModelID
                && model.capabilities.contains(formatFamily.rawValue)
        }
    }

    private func advertisedModels(
        configuration: BurnBarResolvedProviderConfiguration,
        account: BurnBarLiveModelAccountDescriptor,
        providerCanRoute: Bool,
        capabilities: [String],
        liveRefresh: LiveRefreshResult?
    ) -> [BurnBarLiveAdvertisedModel] {
        let liveIDSet = liveRefresh?.isAuthoritative == true
            ? Set(liveRefresh?.advertisedModels.map { $0.id.lowercased() } ?? [])
            : nil

        var rows: [BurnBarLiveAdvertisedModel] = []
        for model in configuration.preferredModels {
            for wireModelID in advertisedWireModelIDs(
                for: model,
                providerID: configuration.provider.id,
                formatFamily: configuration.provider.formatFamily
            ) {
                let liveCompatibleIDs = compatibleLiveModelIDs(for: wireModelID, model: model)
                let liveModel = liveRefresh?.advertisedModels.first { liveModel in
                    liveCompatibleIDs.contains { compatibleID in
                        compatibleID.caseInsensitiveCompare(liveModel.id) == .orderedSame
                    }
                }
                let liveConfirmed = liveIDSet.map { advertisedIDs in
                    liveCompatibleIDs.contains { compatibleID in
                        advertisedIDs.contains(compatibleID.lowercased())
                    }
                }
                let liveBlocksRouting = liveRefresh?.blocksRouting == true
                let advertisementEnabled = configuration.settings.isModelAdvertisementEnabled(wireModelID)
                let liveError: String? = {
                    if let error = liveRefresh?.error {
                        return error
                    }
                    if liveConfirmed == false {
                        return "Configured model '\(wireModelID)' was not advertised by \(configuration.provider.displayName)'s live /models endpoint."
                    }
                    return account.lastError
                }()
                let displayOverride = configuration.settings.displayOverride(forModelID: wireModelID)
                let hasCustomDisplayName = displayOverride != nil
                let resolvedDisplayName = displayOverride?.displayName ?? liveModel?.displayName ?? model.displayName

                let baseRow = BurnBarLiveAdvertisedModel(
                    id: wireModelID,
                    displayName: resolvedDisplayName,
                    providerID: configuration.provider.id,
                    providerName: configuration.provider.displayName,
                    accountID: account.accountID,
                    accountLabel: account.accountLabel,
                    displayNameIsCustom: hasCustomDisplayName,
                    sourceID: "\(configuration.provider.id)#\(account.accountID)",
                    sourceKind: liveRefresh?.sourceKind ?? configuredModelSourceKind(for: configuration.provider.id),
                    capabilities: capabilities,
                    modelCapabilities: model.modelCapabilities,
                    quotaState: account.quotaState,
                    enabled: account.enabled,
                    advertisementEnabled: advertisementEnabled,
                    routeEligible: providerCanRoute
                        && account.enabled
                        && account.hasCredential
                        && isEligibleQuotaState(account.quotaState)
                        && !liveBlocksRouting
                        && (liveConfirmed ?? true),
                    lastRefreshAt: liveRefresh?.refreshedAt ?? account.lastRefreshAt,
                    lastError: liveError
                )
                rows.append(baseRow)
                rows.append(contentsOf: variantRows(
                    from: baseRow,
                    configuration: configuration,
                    account: account
                ))
                rows.append(contentsOf: aliasRows(
                    from: baseRow,
                    configuration: configuration
                ))
            }
        }

        guard liveRefresh?.isAuthoritative == true else {
            return rows
        }

        var seenIDs = Set(rows.map { $0.id.lowercased() })
        for liveModel in liveRefresh?.advertisedModels ?? [] {
            guard seenIDs.insert(liveModel.id.lowercased()).inserted else { continue }
            let advertisementEnabled = configuration.settings.isModelAdvertisementEnabled(liveModel.id)
            let displayOverride = configuration.settings.displayOverride(forModelID: liveModel.id)
            let hasCustomDisplayName = displayOverride != nil
            let resolvedDisplayName = displayOverride?.displayName ?? liveModel.displayName

            let liveRow = BurnBarLiveAdvertisedModel(
                id: liveModel.id,
                displayName: resolvedDisplayName,
                providerID: configuration.provider.id,
                providerName: configuration.provider.displayName,
                accountID: account.accountID,
                accountLabel: account.accountLabel,
                displayNameIsCustom: hasCustomDisplayName,
                sourceID: "\(configuration.provider.id)#\(account.accountID)",
                sourceKind: liveRefresh?.sourceKind ?? "upstream_models_endpoint",
                capabilities: capabilities,
                modelCapabilities: configuredModelCapabilities(
                    for: liveModel.id,
                    in: configuration.preferredModels
                ),
                quotaState: account.quotaState,
                enabled: account.enabled,
                advertisementEnabled: advertisementEnabled,
                routeEligible: providerCanRoute
                    && account.enabled
                    && account.hasCredential
                    && isEligibleQuotaState(account.quotaState)
                    && liveRefresh?.blocksRouting != true,
                lastRefreshAt: liveRefresh?.refreshedAt ?? account.lastRefreshAt,
                lastError: account.lastError
            )
            rows.append(liveRow)
            rows.append(contentsOf: variantRows(
                from: liveRow,
                configuration: configuration,
                account: account
            ))
            rows.append(contentsOf: aliasRows(
                from: liveRow,
                configuration: configuration
            ))
            seenIDs.formUnion(rows.suffix(rows.count - seenIDs.count).map { $0.id.lowercased() })
        }

        return rows
    }

    /// Emit one synthetic advertised row per `BurnBarModelVariant` whose
    /// `baseModelID` matches the supplied base row. Variants inherit the
    /// route-eligibility/quota state of the base row but ship distinct wire
    /// ids so they appear as separate models in `/v1/models` and every
    /// wired CLI's model picker.
    private func variantRows(
        from baseRow: BurnBarLiveAdvertisedModel,
        configuration: BurnBarResolvedProviderConfiguration,
        account: BurnBarLiveModelAccountDescriptor
    ) -> [BurnBarLiveAdvertisedModel] {
        let variants = configuration.settings.variants(forBaseModelID: baseRow.id)
        guard !variants.isEmpty else { return [] }
        return variants.map { variant in
            let variantID = variant.variantID
            let advertisementEnabled = configuration.settings.isModelAdvertisementEnabled(variantID)
            return BurnBarLiveAdvertisedModel(
                id: variantID,
                displayName: "\(baseRow.displayName) (\(variant.label))",
                providerID: baseRow.providerID,
                providerName: baseRow.providerName,
                accountID: baseRow.accountID,
                accountLabel: baseRow.accountLabel,
                displayNameIsCustom: baseRow.displayNameIsCustom ?? false,
                sourceID: "\(baseRow.sourceID)::variant::\(variantID)",
                sourceKind: "thinking_level_variant",
                capabilities: baseRow.capabilities,
                modelCapabilities: baseRow.modelCapabilities,
                quotaState: baseRow.quotaState,
                enabled: baseRow.enabled,
                advertisementEnabled: advertisementEnabled,
                routeEligible: baseRow.routeEligible,
                lastRefreshAt: baseRow.lastRefreshAt,
                lastError: baseRow.lastError,
                baseModelID: baseRow.id,
                thinkingLevel: variant.thinkingLevel.rawValue
            )
        }
    }

    /// Emit one synthetic advertised row per user-defined alias whose
    /// `baseModelID` matches the supplied base row.
    private func aliasRows(
        from baseRow: BurnBarLiveAdvertisedModel,
        configuration: BurnBarResolvedProviderConfiguration
    ) -> [BurnBarLiveAdvertisedModel] {
        let aliases = configuration.settings.aliases(forBaseModelID: baseRow.id)
        guard !aliases.isEmpty else { return [] }
        return aliases.map { alias in
            let advertisementEnabled = configuration.settings.isModelAdvertisementEnabled(alias.aliasID)
            return BurnBarLiveAdvertisedModel(
                id: alias.aliasID,
                displayName: alias.displayName,
                providerID: baseRow.providerID,
                providerName: baseRow.providerName,
                accountID: baseRow.accountID,
                accountLabel: baseRow.accountLabel,
                displayNameIsCustom: false,
                sourceID: "\(baseRow.sourceID)::alias::\(alias.aliasID)",
                sourceKind: "user_model_alias",
                capabilities: baseRow.capabilities,
                modelCapabilities: baseRow.modelCapabilities,
                quotaState: baseRow.quotaState,
                enabled: baseRow.enabled,
                advertisementEnabled: advertisementEnabled,
                routeEligible: baseRow.routeEligible,
                lastRefreshAt: baseRow.lastRefreshAt,
                lastError: baseRow.lastError,
                baseModelID: baseRow.id,
                thinkingLevel: nil,
                hidesBaseModel: alias.hidesBaseModel
            )
        }
    }

    private func advertisedWireModelIDs(
        for model: BurnBarCatalogModel,
        providerID: String,
        formatFamily: BurnBarProviderFormatFamily
    ) -> [String] {
        if providerID.lowercased() == "ollama" {
            return [advertisedModelID(for: model, providerID: providerID)]
        }

        if formatFamily == .anthropic,
           model.id.lowercased().hasSuffix("-family") {
            let aliases = model.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !aliases.isEmpty {
                return aliases
            }
        }

        return [advertisedModelID(for: model, providerID: providerID)]
    }

    private func compatibleLiveModelIDs(for wireModelID: String, model: BurnBarCatalogModel) -> [String] {
        var seen = Set<String>()
        return ([wireModelID] + model.aliases).compactMap { rawID in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            guard seen.insert(id.lowercased()).inserted else { return nil }
            return id
        }
    }

    private func advertisedModelID(for model: BurnBarCatalogModel, providerID: String) -> String {
        guard model.id.lowercased().hasSuffix("-family"),
              let alias = model.aliases.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alias.isEmpty else {
            return providerID.lowercased() == "ollama" ? Self.ollamaCloudRouteModelID(model.id) : model.id
        }
        return providerID.lowercased() == "ollama" ? Self.ollamaCloudRouteModelID(alias) : alias
    }

    private func configuredModelSourceKind(for providerID: String) -> String {
        providerID.caseInsensitiveCompare("factory") == .orderedSame
            ? "factory_droid_cli"
            : "daemon_provider_config"
    }

    private struct LiveRefreshResult: Sendable {
        let advertisedModels: [DiscoveredModel]
        let sourceKind: String
        let refreshedAt: Date
        let error: String?
        let isAuthoritative: Bool
        let blocksRouting: Bool
    }

    struct DiscoveredModel: Sendable {
        let id: String
        let displayName: String
    }

    private struct AccountRefreshContext: Sendable {
        let index: Int
        let configuration: BurnBarResolvedProviderConfiguration
        let account: BurnBarLiveModelAccountDescriptor
        let apiKey: String?
        let providerCanRoute: Bool
        let capabilities: [String]
    }

    private func liveRefreshes(
        for contexts: [AccountRefreshContext]
    ) async -> [Int: LiveRefreshResult] {
        await withTaskGroup(of: (Int, LiveRefreshResult?).self) { group in
            for context in contexts {
                group.addTask {
                    let result = await liveModels(
                        configuration: context.configuration,
                        account: context.account,
                        apiKey: context.apiKey,
                        providerCanRoute: context.providerCanRoute
                    )
                    return (context.index, result)
                }
            }

            var results: [Int: LiveRefreshResult] = [:]
            for await (index, result) in group {
                if let result {
                    results[index] = result
                }
            }
            return results
        }
    }

    private func liveModels(
        configuration: BurnBarResolvedProviderConfiguration,
        account: BurnBarLiveModelAccountDescriptor,
        apiKey: String?,
        providerCanRoute: Bool
    ) async -> LiveRefreshResult? {
        // Local, credential-less providers (e.g. a local Ollama daemon) discover
        // models from the machine with no Authorization header. Bypass the
        // credential/quota guard the cloud providers require.
        if configuration.provider.local {
            guard providerCanRoute, account.enabled else { return nil }
            return await localProviderLiveModels(configuration: configuration, account: account)
        }

        guard providerCanRoute,
              account.enabled,
              account.hasCredential,
              isEligibleQuotaState(account.quotaState),
              let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }

        let formatFamily = configuration.provider.formatFamily
        let providerID = configuration.provider.id

        // OpenAI-compatible providers (including Ollama) use GET /models or /search?c=cloud.
        if formatFamily == .openaiCompat && providerID.caseInsensitiveCompare("factory") != .orderedSame {
            guard let baseURL = URL(string: configuration.settings.baseURL) else { return nil }
            return await openAICompatLiveModels(
                configuration: configuration,
                account: account,
                apiKey: key,
                baseURL: baseURL
            )
        }

        // Factory Droid uses `droid exec --help` CLI discovery.
        if providerID.caseInsensitiveCompare("factory") == .orderedSame {
            return await factoryDroidLiveModels(
                configuration: configuration,
                account: account,
                apiKey: key
            )
        }

        // Anthropic uses GET /v1/models with Anthropic-specific headers.
        if formatFamily == .anthropic {
            guard let baseURL = URL(string: configuration.settings.baseURL) else { return nil }
            return await anthropicLiveModels(
                configuration: configuration,
                account: account,
                apiKey: key,
                baseURL: baseURL
            )
        }

        return nil
    }

    // MARK: - OpenAI-Compatible Discovery

    private func openAICompatLiveModels(
        configuration: BurnBarResolvedProviderConfiguration,
        account: BurnBarLiveModelAccountDescriptor,
        apiKey: String,
        baseURL: URL
    ) async -> LiveRefreshResult {
        let endpoint = liveModelEndpoint(for: configuration.provider, baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = refreshTimeoutSeconds
        if configuration.provider.id.lowercased() != "ollama" {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let endpointLabel = liveModelEndpointLabel(for: configuration.provider)
        let sourceKind = liveModelSourceKind(for: configuration.provider)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return LiveRefreshResult(
                    advertisedModels: [],
                    sourceKind: "daemon_provider_config",
                    refreshedAt: Date(),
                    error: "Live \(endpointLabel) refresh returned an invalid response.",
                    isAuthoritative: false,
                    blocksRouting: false
                )
            }
            let blocksRouting = httpResponse.statusCode == 401 || httpResponse.statusCode == 403
            guard (200..<300).contains(httpResponse.statusCode) else {
                return LiveRefreshResult(
                    advertisedModels: [],
                    sourceKind: "daemon_provider_config",
                    refreshedAt: Date(),
                    error: "Live \(endpointLabel) refresh failed with HTTP \(httpResponse.statusCode).",
                    isAuthoritative: false,
                    blocksRouting: blocksRouting
                )
            }
            let discovered = try Self.parseModelsResponse(data, providerID: configuration.provider.id)
            return LiveRefreshResult(
                advertisedModels: discovered,
                sourceKind: sourceKind,
                refreshedAt: Date(),
                error: nil,
                isAuthoritative: true,
                blocksRouting: false
            )
        } catch {
            return LiveRefreshResult(
                advertisedModels: [],
                sourceKind: "daemon_provider_config",
                refreshedAt: Date(),
                error: "Live \(endpointLabel) refresh failed: \(error.localizedDescription)",
                isAuthoritative: false,
                blocksRouting: false
            )
        }
    }

    /// Discovers models from a local, credential-less provider (a local Ollama
    /// daemon) via `GET {baseURL}/models` with no Authorization header. Returns
    /// an authoritative result when reachable, or a clear "start `ollama serve`"
    /// error when the local server is down.
    private func localProviderLiveModels(
        configuration: BurnBarResolvedProviderConfiguration,
        account: BurnBarLiveModelAccountDescriptor
    ) async -> LiveRefreshResult {
        func failure(_ message: String) -> LiveRefreshResult {
            LiveRefreshResult(
                advertisedModels: [],
                sourceKind: "daemon_provider_config",
                refreshedAt: Date(),
                error: message,
                isAuthoritative: false,
                blocksRouting: false
            )
        }

        // Discover installed models from Ollama's canonical `/api/tags` endpoint
        // (always present, richer than the `/v1/models` compat shim) by deriving
        // the server root from the provider's `/v1` base URL.
        guard let baseURL = URL(string: configuration.settings.baseURL),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return failure("\(configuration.provider.displayName) has an invalid local base URL.")
        }
        components.path = "/api/tags"
        components.query = nil
        guard let endpoint = components.url else {
            return failure("\(configuration.provider.displayName) has an invalid local base URL.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = refreshTimeoutSeconds

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return failure("\(configuration.provider.displayName) returned an invalid response.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                return failure("\(configuration.provider.displayName) refresh failed with HTTP \(httpResponse.statusCode).")
            }
            // `parseOllamaTags` splits installed models into local vs `:cloud`
            // entries. Advertise local-only here so Ollama Cloud models stay with
            // the dedicated `ollama` provider (its own key/quota) and are not
            // duplicated or routed to localhost.
            let discovered = CLIRuntimeModelCatalog.parseOllamaTags(data)
                .filter { $0.source == .ollamaLocalCatalog }
                .map { DiscoveredModel(id: $0.modelID, displayName: $0.modelID) }
            return LiveRefreshResult(
                advertisedModels: discovered,
                sourceKind: "local_ollama_models_endpoint",
                refreshedAt: Date(),
                error: nil,
                isAuthoritative: true,
                blocksRouting: false
            )
        } catch {
            return failure("\(configuration.provider.displayName) is not reachable at \(endpoint.absoluteString). Start it with `ollama serve`.")
        }
    }

    private func liveModelEndpoint(for provider: BurnBarCatalogProvider, baseURL: URL) -> URL {
        if provider.id.lowercased() == "ollama" {
            return Self.ollamaCloudCatalogURL
        }
        return baseURL.appending(path: "models")
    }

    private func liveModelEndpointLabel(for provider: BurnBarCatalogProvider) -> String {
        provider.id.lowercased() == "ollama" ? "/search?c=cloud" : "/models"
    }

    private func liveModelSourceKind(for provider: BurnBarCatalogProvider) -> String {
        provider.id.lowercased() == "ollama" ? "ollama_cloud_catalog_page" : "upstream_models_endpoint"
    }

    private static func parseModelsResponse(_ data: Data, providerID: String) throws -> [DiscoveredModel] {
        if providerID.lowercased() == "ollama" {
            return try parseOllamaCloudCatalogHTML(data)
        }
        return try parseOpenAIModelsResponse(data)
    }

    private static func parseOpenAIModelsResponse(_ data: Data) throws -> [DiscoveredModel] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var models: [DiscoveredModel] = []
        for row in rows {
            guard let rawID = row["id"] as? String else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let normalized = id.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            let displayName = ((row["display_name"] as? String)
                ?? (row["name"] as? String)
                ?? id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            models.append(DiscoveredModel(id: id, displayName: displayName.isEmpty ? id : displayName))
        }
        return models
    }

    private static func parseOllamaCloudCatalogHTML(_ data: Data) throws -> [DiscoveredModel] {
        guard let html = String(data: data, encoding: .utf8) else {
            return []
        }
        let regex = try NSRegularExpression(
            pattern: #"href\s*=\s*["']/library/([A-Za-z0-9][A-Za-z0-9._:-]*)["']"#,
            options: [.caseInsensitive]
        )
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<String>()
        var models: [DiscoveredModel] = []
        for match in regex.matches(in: html, range: fullRange) {
            guard match.numberOfRanges > 1,
                  let slugRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            let slug = String(html[slugRange])
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            guard !slug.isEmpty else { continue }
            let id = ollamaCloudRouteModelID(slug)
            let normalized = id.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            models.append(DiscoveredModel(id: id, displayName: slug))
        }
        return models
    }

    private static func ollamaCloudRouteModelID(_ rawID: String) -> String {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard !trimmed.isEmpty,
              !lowercased.hasSuffix(":cloud"),
              !lowercased.hasSuffix("-cloud") else {
            return trimmed
        }
        return "\(trimmed):cloud"
    }

    // MARK: - Anthropic Messages Discovery

    /// Discover models from Anthropic's `/v1/models` endpoint with pagination.
    ///
    /// Anthropic exposes a list endpoint at `{baseURL}/models` that returns model
    /// IDs like `claude-opus-4-8-20260514` (dated snapshots). We normalize these
    /// dated IDs to their family ID (e.g. `claude-opus-4-8`) using the same
    /// pattern the router uses for wire model resolution.
    ///
    /// The Anthropic API paginates with `has_more` / `last_id` cursors and a
    /// default limit of 20. We fetch all pages to ensure complete coverage.
    private func anthropicLiveModels(
        configuration: BurnBarResolvedProviderConfiguration,
        account: BurnBarLiveModelAccountDescriptor,
        apiKey: String,
        baseURL: URL
    ) async -> LiveRefreshResult {
        // Anthropic accepts two credential shapes:
        //   1. Console API keys via `x-api-key` header (sk-ant-api*).
        //   2. OAuth bearer tokens via `Authorization: Bearer` (sk-ant-oat*).
        let usesOAuth = apiKey.hasPrefix("sk-ant-oat")
        let authHeader: (field: String, value: String) = usesOAuth
            ? ("Authorization", "Bearer \(apiKey)")
            : ("x-api-key", apiKey)

        var allDiscovered: [DiscoveredModel] = []
        var seenIDs = Set<String>()
        var cursor: String?
        var pagesRemaining = 10  // Safety limit: max 10 pages (1000 models)
        var lastError: String?

        repeat {
            var endpoint = baseURL.appending(path: "models")
            if let afterID = cursor {
                endpoint = endpoint.appending(queryItems: [URLQueryItem(name: "after_id", value: afterID)])
            }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = refreshTimeoutSeconds
            request.setValue(authHeader.value, forHTTPHeaderField: authHeader.field)
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    return LiveRefreshResult(
                        advertisedModels: allDiscovered,
                        sourceKind: "daemon_provider_config",
                        refreshedAt: Date(),
                        error: "Anthropic /v1/models refresh returned an invalid response.",
                        isAuthoritative: false,
                        blocksRouting: false
                    )
                }
                let blocksRouting = httpResponse.statusCode == 401 || httpResponse.statusCode == 403
                guard (200..<300).contains(httpResponse.statusCode) else {
                    return LiveRefreshResult(
                        advertisedModels: allDiscovered,
                        sourceKind: "daemon_provider_config",
                        refreshedAt: Date(),
                        error: "Anthropic /v1/models refresh failed with HTTP \(httpResponse.statusCode).",
                        isAuthoritative: false,
                        blocksRouting: blocksRouting
                    )
                }

                let pageResult = try Self.parseAnthropicModelsResponse(data)
                for model in pageResult.models {
                    let normalized = model.id.lowercased()
                    guard seenIDs.insert(normalized).inserted else { continue }
                    allDiscovered.append(model)
                }

                if pageResult.hasMore, let lastID = pageResult.lastID {
                    cursor = lastID
                } else {
                    cursor = nil
                }
            } catch {
                // If we already have partial results, return them as non-authoritative.
                // If this is the first page, return the error.
                lastError = "Anthropic /v1/models refresh failed: \(error.localizedDescription)"
                if allDiscovered.isEmpty {
                    return LiveRefreshResult(
                        advertisedModels: [],
                        sourceKind: "daemon_provider_config",
                        refreshedAt: Date(),
                        error: lastError,
                        isAuthoritative: false,
                        blocksRouting: false
                    )
                }
                break
            }

            pagesRemaining -= 1
        } while cursor != nil && pagesRemaining > 0

        return LiveRefreshResult(
            advertisedModels: allDiscovered,
            sourceKind: "anthropic_messages_models",
            refreshedAt: Date(),
            error: lastError,
            isAuthoritative: true,
            blocksRouting: false
        )
    }

    /// Paginated result from Anthropic's `/v1/models` endpoint.
    struct AnthropicModelsPage: Sendable {
        let models: [DiscoveredModel]
        let hasMore: Bool
        let lastID: String?
    }

    /// Parse the Anthropic `/v1/models` response and normalize dated model IDs
    /// to their family equivalents.
    ///
    /// Anthropic returns model objects with an `id` field containing IDs like
    /// `claude-opus-4-8-20260514`, `claude-sonnet-4-6-20250514`, etc.
    /// We strip the dated suffix (`-YYYYMMDD`) to get the canonical family ID
    /// (`claude-opus-4-8`, `claude-sonnet-4-6`) so the catalog's matchers and
    /// aliases can resolve them.
    ///
    /// The response includes `has_more` and `last_id` for cursor-based pagination.
    static func parseAnthropicModelsResponse(_ data: Data) throws -> AnthropicModelsPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AnthropicModelsPage(models: [], hasMore: false, lastID: nil)
        }
        let rows = object["data"] as? [[String: Any]] ?? []
        let hasMore = object["has_more"] as? Bool ?? false
        let lastID = object["last_id"] as? String

        var seen = Set<String>()
        var models: [DiscoveredModel] = []
        for row in rows {
            guard let rawID = row["id"] as? String else { continue }
            let id = Self.normalizeAnthropicModelID(rawID.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !id.isEmpty else { continue }
            let normalized = id.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            let displayName = ((row["display_name"] as? String)
                ?? (row["name"] as? String)
                ?? id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            models.append(DiscoveredModel(id: id, displayName: displayName.isEmpty ? id : displayName))
        }
        return AnthropicModelsPage(models: models, hasMore: hasMore, lastID: lastID)
    }

    /// Normalize an Anthropic model ID by stripping the dated snapshot suffix.
    ///
    /// Anthropic model IDs follow the pattern `claude-{tier}-{major}-{minor}-YYYYMMDD`
    /// (e.g. `claude-opus-4-8-20260514`). We strip the `-YYYYMMDD` suffix to
    /// get the family ID that matches our catalog entries (e.g. `claude-opus-4-8`).
    ///
    /// IDs without a dated suffix are returned as-is.
    static func normalizeAnthropicModelID(_ rawID: String) -> String {
        // Match a trailing `-YYYYMMDD` (8 digits after the last hyphen).
        // Anthropic uses this pattern for all their dated snapshot IDs.
        let pattern = "-\\d{8,8}$"
        guard let range = rawID.range(of: pattern, options: .regularExpression) else {
            return rawID
        }
        return String(rawID[..<range.lowerBound])
    }

    // MARK: - Factory Droid CLI Discovery

    /// Discover models from the Factory Droid CLI by running `droid exec --help`
    /// and parsing the output with `CLIRuntimeModelCatalog.parseDroidExecHelp`.
    private func factoryDroidLiveModels(
        configuration: BurnBarResolvedProviderConfiguration,
        account: BurnBarLiveModelAccountDescriptor,
        apiKey: String
    ) async -> LiveRefreshResult {
        do {
            let result = try await droidProcessRunner.runDroid(
                arguments: ["exec", "--help"],
                environment: ["FACTORY_API_KEY": apiKey, "HOME": NSHomeDirectory(), "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"],
                timeout: 12
            )
            guard result.exitCode == 0 else {
                return LiveRefreshResult(
                    advertisedModels: [],
                    sourceKind: "factory_droid_cli",
                    refreshedAt: Date(),
                    error: "Factory Droid CLI exited with code \(result.exitCode).",
                    isAuthoritative: false,
                    blocksRouting: false
                )
            }
            let options = CLIRuntimeModelCatalog.parseDroidExecHelp(result.stdout)
            guard !options.isEmpty else {
                return LiveRefreshResult(
                    advertisedModels: [],
                    sourceKind: "factory_droid_cli",
                    refreshedAt: Date(),
                    error: "Factory Droid CLI returned no models.",
                    isAuthoritative: false,
                    blocksRouting: false
                )
            }
            let discovered = options.map { option in
                DiscoveredModel(id: option.modelID, displayName: option.displayName)
            }
            return LiveRefreshResult(
                advertisedModels: discovered,
                sourceKind: "factory_droid_cli",
                refreshedAt: Date(),
                error: nil,
                isAuthoritative: true,
                blocksRouting: false
            )
        } catch {
            return LiveRefreshResult(
                advertisedModels: [],
                sourceKind: "factory_droid_cli",
                refreshedAt: Date(),
                error: "Factory Droid CLI discovery failed: \(error.localizedDescription)",
                isAuthoritative: false,
                blocksRouting: false
            )
        }
    }

    private func quotaState(
        for slot: BurnBarProviderCredentialSlot,
        providerEnabled: Bool,
        hasCredential: Bool,
        now: Date
    ) -> BurnBarLiveModelQuotaState {
        guard providerEnabled, slot.isEnabled else { return .disabled }
        guard hasCredential else { return .missingCredential }
        let effectiveStatus = BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(
            for: slot,
            providerEnabled: providerEnabled,
            now: now
        )
        switch effectiveStatus {
        case .ready:
            if let remaining = slot.lastQuotaRemainingPercent {
                if remaining <= 0 { return .unknown }
                if remaining <= 20 { return .coolingDown }
            }
            return .healthy
        case .coolingDown:
            return .coolingDown
        case .exhausted:
            return .exhausted
        case .disabled:
            return .disabled
        case .missingSecret:
            return .authFailed
        }
    }

    private func hasUsableSecret(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isEligibleQuotaState(_ state: BurnBarLiveModelQuotaState) -> Bool {
        switch state {
        case .healthy, .unknown:
            return true
        case .exhausted, .coolingDown, .authFailed, .disabled, .missingCredential:
            return false
        }
    }

    private func modelCapabilities(for provider: BurnBarCatalogProvider) -> [String] {
        var values = provider.capabilities.map(\.rawValue)
        values.append(provider.formatFamily.rawValue)
        return Array(Set(values)).sorted()
    }

    private func configuredModelCapabilities(
        for modelID: String,
        in models: [BurnBarCatalogModel]
    ) -> ModelIOCapabilities? {
        models.first { $0.matches(modelName: modelID) }?.modelCapabilities
    }

    private func modelSort(_ lhs: BurnBarLiveAdvertisedModel, _ rhs: BurnBarLiveAdvertisedModel) -> Bool {
        if lhs.routeEligible != rhs.routeEligible {
            return lhs.routeEligible && !rhs.routeEligible
        }
        if lhs.providerID != rhs.providerID {
            return lhs.providerID < rhs.providerID
        }
        if lhs.accountID != rhs.accountID {
            return lhs.accountID < rhs.accountID
        }
        return lhs.id < rhs.id
    }

    private func accountSort(_ lhs: BurnBarLiveModelAccountDescriptor, _ rhs: BurnBarLiveModelAccountDescriptor) -> Bool {
        if lhs.providerID != rhs.providerID {
            return lhs.providerID < rhs.providerID
        }
        return lhs.accountID < rhs.accountID
    }
}
