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
    public let sourceID: String
    public let sourceKind: String
    public let capabilities: [String]
    public let quotaState: BurnBarLiveModelQuotaState
    public let enabled: Bool
    public let advertisementEnabled: Bool
    public let routeEligible: Bool
    public let lastRefreshAt: Date?
    public let lastError: String?

    public init(
        id: String,
        displayName: String,
        providerID: String,
        providerName: String,
        accountID: String,
        accountLabel: String,
        sourceID: String,
        sourceKind: String,
        capabilities: [String],
        quotaState: BurnBarLiveModelQuotaState,
        enabled: Bool,
        advertisementEnabled: Bool = true,
        routeEligible: Bool,
        lastRefreshAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.capabilities = capabilities
        self.quotaState = quotaState
        self.enabled = enabled
        self.advertisementEnabled = advertisementEnabled
        self.routeEligible = routeEligible
        self.lastRefreshAt = lastRefreshAt
        self.lastError = lastError
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

    private let configStore: BurnBarConfigStore
    private let session: URLSession
    private let refreshTimeoutSeconds: TimeInterval

    public init(
        configStore: BurnBarConfigStore,
        session: URLSession = .shared,
        refreshTimeoutSeconds: TimeInterval = 1.5
    ) {
        self.configStore = configStore
        self.session = session
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
                let hasCredential = hasUsableSecret(apiKey)
                let account = BurnBarLiveModelAccountDescriptor(
                    providerID: providerID,
                    providerName: providerName,
                    accountID: "legacy",
                    accountLabel: providerName,
                    enabled: providerEnabled,
                    hasCredential: hasCredential,
                    quotaState: providerEnabled ? (hasCredential ? .unknown : .missingCredential) : .disabled
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

        let configuredRows = configuration.preferredModels.map { model in
            let wireModelID = advertisedModelID(for: model, providerID: configuration.provider.id)
            let liveModel = liveRefresh?.advertisedModels.first { $0.id.caseInsensitiveCompare(wireModelID) == .orderedSame }
            let liveConfirmed = liveIDSet?.contains(wireModelID.lowercased())
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
            return BurnBarLiveAdvertisedModel(
                id: wireModelID,
                displayName: liveModel?.displayName ?? model.displayName,
                providerID: configuration.provider.id,
                providerName: configuration.provider.displayName,
                accountID: account.accountID,
                accountLabel: account.accountLabel,
                sourceID: "\(configuration.provider.id)#\(account.accountID)",
                sourceKind: liveRefresh?.sourceKind ?? "daemon_provider_config",
                capabilities: capabilities,
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
        }

        guard liveRefresh?.isAuthoritative == true else {
            return configuredRows
        }

        var seenIDs = Set(configuredRows.map { $0.id.lowercased() })
        let liveRows = (liveRefresh?.advertisedModels ?? []).compactMap { liveModel -> BurnBarLiveAdvertisedModel? in
            guard seenIDs.insert(liveModel.id.lowercased()).inserted else { return nil }
            let advertisementEnabled = configuration.settings.isModelAdvertisementEnabled(liveModel.id)
            return BurnBarLiveAdvertisedModel(
                id: liveModel.id,
                displayName: liveModel.displayName,
                providerID: configuration.provider.id,
                providerName: configuration.provider.displayName,
                accountID: account.accountID,
                accountLabel: account.accountLabel,
                sourceID: "\(configuration.provider.id)#\(account.accountID)",
                sourceKind: liveRefresh?.sourceKind ?? "upstream_models_endpoint",
                capabilities: capabilities,
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
        }

        return configuredRows + liveRows
    }

    private func advertisedModelID(for model: BurnBarCatalogModel, providerID: String) -> String {
        guard model.id.lowercased().hasSuffix("-family"),
              let alias = model.aliases.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alias.isEmpty else {
            return providerID.lowercased() == "ollama" ? Self.ollamaCloudRouteModelID(model.id) : model.id
        }
        return providerID.lowercased() == "ollama" ? Self.ollamaCloudRouteModelID(alias) : alias
    }

    private struct LiveRefreshResult: Sendable {
        let advertisedModels: [DiscoveredModel]
        let sourceKind: String
        let refreshedAt: Date
        let error: String?
        let isAuthoritative: Bool
        let blocksRouting: Bool
    }

    private struct DiscoveredModel: Sendable {
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
        guard providerCanRoute,
              account.enabled,
              account.hasCredential,
              isEligibleQuotaState(account.quotaState),
              configuration.provider.formatFamily == .openaiCompat,
              let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              let baseURL = URL(string: configuration.settings.baseURL) else {
            return nil
        }

        let endpoint = liveModelEndpoint(for: configuration.provider, baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = refreshTimeoutSeconds
        if configuration.provider.id.lowercased() != "ollama" {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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

    private func quotaState(
        for slot: BurnBarProviderCredentialSlot,
        providerEnabled: Bool,
        hasCredential: Bool,
        now: Date
    ) -> BurnBarLiveModelQuotaState {
        guard providerEnabled, slot.isEnabled else { return .disabled }
        guard hasCredential else { return .missingCredential }
        if let cooldownUntil = slot.cooldownUntil, cooldownUntil > now {
            return .coolingDown
        }
        switch slot.status {
        case .ready:
            if let remaining = slot.lastQuotaRemainingPercent, remaining <= 0 {
                return .exhausted
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
