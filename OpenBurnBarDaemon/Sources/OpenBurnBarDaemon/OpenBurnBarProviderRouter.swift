import OpenBurnBarCore
import Foundation

// MARK: - Router Scorecard Types

/// Five-dimensional score for route ranking.
/// All dimensions are normalized to 0.0-1.0 where higher is better.
public struct BurnBarRouteScore: Hashable, Sendable, Codable {
    /// Provider capability score (0.0-1.0) based on provider features.
    public let capability: Double

    /// Cost efficiency score (0.0-1.0) — lower cost = higher score.
    /// Computed relative to the cheapest and most expensive candidates.
    public let cost: Double

    /// Latency score (0.0-1.0) — lower latency = higher score.
    /// Based on historical round-trip time for this slot/provider.
    public let latency: Double

    /// Trust score (0.0-1.0) based on credential slot status and cooldown state.
    public let trust: Double

    /// Policy-fit score (0.0-1.0) based on preferred-provider and preferred-slot alignment.
    public let policyFit: Double

    /// Weighted composite score. Weights: capability=0.20, cost=0.25, latency=0.15, trust=0.25, policyFit=0.15.
    public var composite: Double {
        capability * 0.20 + cost * 0.25 + latency * 0.15 + trust * 0.25 + policyFit * 0.15
    }

    public init(
        capability: Double,
        cost: Double,
        latency: Double,
        trust: Double,
        policyFit: Double
    ) {
        self.capability = Self.clamp01(capability)
        self.cost = Self.clamp01(cost)
        self.latency = Self.clamp01(latency)
        self.trust = Self.clamp01(trust)
        self.policyFit = Self.clamp01(policyFit)
    }

    private static func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}

/// Full score breakdown artifact for a route, used to prove all five dimensions are considered.
public struct BurnBarRouteScoreBreakdown: Hashable, Sendable, Codable {
    public let routeKey: String
    public let providerID: String
    public let slotID: String?
    public let score: BurnBarRouteScore

    /// Raw dimension values before normalization (for debugging/determinism verification).
    public let rawCapability: Double
    public let rawCostPerMToken: Double
    public let rawLatencyMs: Double
    public let rawTrustStatus: String
    public let rawPolicyFitPreferred: Bool

    public init(
        routeKey: String,
        providerID: String,
        slotID: String?,
        score: BurnBarRouteScore,
        rawCapability: Double,
        rawCostPerMToken: Double,
        rawLatencyMs: Double,
        rawTrustStatus: String,
        rawPolicyFitPreferred: Bool
    ) {
        self.routeKey = routeKey
        self.providerID = providerID
        self.slotID = slotID
        self.score = score
        self.rawCapability = rawCapability
        self.rawCostPerMToken = rawCostPerMToken
        self.rawLatencyMs = rawLatencyMs
        self.rawTrustStatus = rawTrustStatus
        self.rawPolicyFitPreferred = rawPolicyFitPreferred
    }
}

/// Ranked route with score breakdown.
public struct BurnBarRankedRoute: Hashable, Sendable {
    public let route: BurnBarProviderRoute
    public let breakdown: BurnBarRouteScoreBreakdown

    public init(route: BurnBarProviderRoute, breakdown: BurnBarRouteScoreBreakdown) {
        self.route = route
        self.breakdown = breakdown
    }
}

/// Result of scoring and ranking routes.
public struct BurnBarRouteRankingResult: Hashable, Sendable {
    /// All candidate routes ranked by composite score (highest first).
    /// When `requiredCapabilityClassID` was provided, this contains only same-class routes.
    public let rankedRoutes: [BurnBarRankedRoute]
    public let routerMode: ProviderRouterMode
    public let taskCategory: ProviderRoutingTaskCategory
    public let benchmarkStatus: ProviderModelBenchmarkStatus?
    public let requiredCanonicalModelID: String?

    /// Routes that were excluded because they belong to a different capability class
    /// than the requested one. Non-empty only when `requiredCapabilityClassID` filtering
    /// was applied. Used by callers (e.g., the gateway) to report "downgrade disabled"
    /// when the same-class pool is exhausted.
    public let blockedCapabilityClassRoutes: [BurnBarProviderRoute]
    public let blockedExactModelRoutes: [BurnBarProviderRoute]

    /// The winning route (same as rankedRoutes.first?.route).
    public var winner: BurnBarProviderRoute? {
        rankedRoutes.first?.route
    }

    public init(
        rankedRoutes: [BurnBarRankedRoute],
        routerMode: ProviderRouterMode = .providerFamilyFailover,
        taskCategory: ProviderRoutingTaskCategory = .unknown,
        benchmarkStatus: ProviderModelBenchmarkStatus? = nil,
        requiredCanonicalModelID: String? = nil,
        blockedCapabilityClassRoutes: [BurnBarProviderRoute] = [],
        blockedExactModelRoutes: [BurnBarProviderRoute] = []
    ) {
        self.rankedRoutes = rankedRoutes
        self.routerMode = routerMode
        self.taskCategory = taskCategory
        self.benchmarkStatus = benchmarkStatus
        self.requiredCanonicalModelID = BurnBarCatalogModel.normalizedCanonicalModelID(requiredCanonicalModelID)
        self.blockedCapabilityClassRoutes = blockedCapabilityClassRoutes
        self.blockedExactModelRoutes = blockedExactModelRoutes
    }
}

public actor BurnBarProviderRoutingDecisionEventStore {
    private let fileURL: URL
    private let encoder: JSONEncoder

    public init(fileURL: URL = BurnBarDaemonPaths.defaultRoutingDecisionEventsURL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func append(_ event: ProviderRoutingDecisionEvent) {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(event)
            let line = data + Data([0x0A])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        } catch {
            // Routing must never fail because audit persistence failed.
        }
    }
}

// MARK: - Route Type

public struct BurnBarProviderRoute: Hashable, Sendable {
    public let providerID: String
    public let providerDisplayName: String
    public let credentialSlotID: String?
    public let credentialSlotLabel: String?
    public let baseURL: String
    public let requestedModel: String
    public let resolvedModelID: String
    public let canonicalModelID: String?
    public let apiKey: String
    public let pricing: BurnBarModelPricing
    /// Same-tier failover class. Retry attempts must stay inside this class
    /// unless explicit downgrade policy is enabled.
    public let modelCapabilityClassID: String
    /// Wire-format family this route serves. Determined by the upstream
    /// provider's catalog declaration. The gateway enforces that an incoming
    /// request only matches routes in the same family — Anthropic-shape
    /// requests never get routed to OpenAI-compatible upstreams and vice
    /// versa.
    public let formatFamily: BurnBarProviderFormatFamily

    public init(
        providerID: String,
        providerDisplayName: String,
        credentialSlotID: String? = nil,
        credentialSlotLabel: String? = nil,
        baseURL: String,
        requestedModel: String,
        resolvedModelID: String,
        canonicalModelID: String? = nil,
        apiKey: String,
        pricing: BurnBarModelPricing,
        modelCapabilityClassID: String? = nil,
        formatFamily: BurnBarProviderFormatFamily = .openaiCompat
    ) {
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.credentialSlotID = credentialSlotID
        self.credentialSlotLabel = credentialSlotLabel
        self.baseURL = baseURL
        self.requestedModel = requestedModel
        self.resolvedModelID = resolvedModelID
        self.canonicalModelID = BurnBarCatalogModel.normalizedCanonicalModelID(canonicalModelID)
        self.apiKey = apiKey
        self.pricing = pricing
        self.modelCapabilityClassID = Self.normalizedCapabilityClassID(
            modelCapabilityClassID ?? resolvedModelID
        )
        self.formatFamily = formatFamily
    }

    private static func normalizedCapabilityClassID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum BurnBarProviderRouterError: Error, LocalizedError {
    case noEnabledProviders
    case unsupportedProvider(String)
    case providerDisabled(String)
    case missingCredential(String)
    case credentialsUnavailable(providerID: String, reason: String)
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
        case .credentialsUnavailable(let providerID, let reason):
            return "Provider '\(providerID)' has no usable credentials: \(reason)"
        case .unsupportedModel(let modelName):
            return "Model '\(modelName)' is not supported by the configured OpenBurnBar providers."
        }
    }
}

public struct BurnBarProviderRouter: Sendable {
    private let configStore: BurnBarConfigStore
    private let logger: BurnBarDaemonLogger
    private let routingEventStore: BurnBarProviderRoutingDecisionEventStore?
    private let allowDynamicOpenAICompatibleModels: Bool

    public init(
        configStore: BurnBarConfigStore,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "provider-router"),
        routingEventStore: BurnBarProviderRoutingDecisionEventStore? = nil,
        allowDynamicOpenAICompatibleModels: Bool = false
    ) {
        self.configStore = configStore
        self.logger = logger
        self.routingEventStore = routingEventStore
        self.allowDynamicOpenAICompatibleModels = allowDynamicOpenAICompatibleModels
    }

    public func route(
        modelName: String,
        preferredProviderID: String? = nil,
        excludedRouteKeys: Set<String> = [],
        requestedFormatFamily: BurnBarProviderFormatFamily? = nil,
        requiredCapabilityClassID: String? = nil,
        requiredCanonicalModelID: String? = nil,
        routerMode: ProviderRouterMode? = nil,
        taskCategory: ProviderRoutingTaskCategory = .unknown,
        benchmarkSnapshots: [ProviderModelBenchmarkSnapshot] = [],
        benchmarkStatus: ProviderModelBenchmarkStatus? = nil
    ) async throws -> BurnBarProviderRoute {
        // Use scoreAndRankRoutes() to select the best route based on five-dimensional scoring:
        // capability, cost, latency, trust, and policy-fit. This ensures routing decisions
        // are driven by the scorecard rather than legacy candidate ordering.
        let ranking = try await scoreAndRankRoutes(
            modelName: modelName,
            preferredProviderID: preferredProviderID,
            excludedRouteKeys: excludedRouteKeys,
            requestedFormatFamily: requestedFormatFamily,
            requiredCapabilityClassID: requiredCapabilityClassID,
            requiredCanonicalModelID: requiredCanonicalModelID,
            routerMode: routerMode,
            taskCategory: taskCategory,
            benchmarkSnapshots: benchmarkSnapshots,
            benchmarkStatus: benchmarkStatus
        )

        guard let route = ranking.winner else {
            throw BurnBarProviderRouterError.unsupportedModel(modelName.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        await persistDecisionIfNeeded(ranking: ranking, modelName: modelName)

        if let slotID = route.credentialSlotID {
            do {
                try await configStore.recordCredentialSelection(providerID: route.providerID, slotID: slotID)
            } catch {
                logger.silentFailure("record_credential_selection", error: error)
            }
        }
        return route
    }

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
            configurations: configurations
        )
        return try candidateRoutes(
            modelName: modelName,
            preferredProviderID: effectivePreferredProviderID,
            excludedRouteKeys: excludedRouteKeys,
            requestedFormatFamily: requestedFormatFamily,
            requiredCapabilityClassID: requiredCapabilityClassID,
            requiredCanonicalModelID: resolvedRequiredCanonicalModelID,
            configurations: configurations,
            routerMode: effectiveRouterMode,
            strictPreferredProvider: preferredProviderID != nil
        )
    }

    private func candidateRoutes(
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
            configurations: scopedConfigurations
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
                routes = []
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

            if slotsWithSecret.allSatisfy({ $0.slot.status == .exhausted }) {
                return .credentialsUnavailable(
                    providerID: configuration.provider.id,
                    reason: unavailableCredentialReason(
                        prefix: "all configured credential slots are exhausted",
                        slots: slotsWithSecret
                    )
                )
            }

            let coolingSlots = slotsWithSecret.filter { resolvedSlot in
                guard let cooldownUntil = resolvedSlot.slot.cooldownUntil else { return false }
                return cooldownUntil > now
            }
            if coolingSlots.count == slotsWithSecret.count {
                let nextRetry = coolingSlots
                    .compactMap(\.slot.cooldownUntil)
                    .sorted()
                    .first
                let suffix = nextRetry.map { " Retry after \($0.formatted(date: .abbreviated, time: .standard))." } ?? ""
                return .credentialsUnavailable(
                    providerID: configuration.provider.id,
                    reason: "all configured credential slots are cooling down.\(suffix)"
                )
            }

            if slotsWithSecret.allSatisfy({ $0.slot.status == .missingSecret }) {
                return .missingCredential(configuration.provider.id)
            }

            return .credentialsUnavailable(
                providerID: configuration.provider.id,
                reason: unavailableCredentialReason(
                    prefix: "configured credential slots are not ready",
                    slots: slotsWithSecret
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

    public func markRouteFailure(
        _ route: BurnBarProviderRoute,
        error: Error
    ) async {
        guard let slotID = route.credentialSlotID else { return }
        let now = Date()
        let cooldown = Calendar.current.date(byAdding: .minute, value: 5, to: now)
        var status: BurnBarProviderCredentialSlotStatus?
        var cooldownUntil: Date?
        if let providerError = error as? BurnBarProviderExecutorError,
           case .upstreamError(let statusCode, let body) = providerError {
            if FactoryDroidProviderExecutor.isStrictStandardUsageExhaustion(error: error, route: route) {
                return
            }
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
            } else if statusCode == 429 || lowerBody.contains("rate limit") || lowerBody.contains("rate_limit") {
                if Self.shouldPreserveSlotAvailabilityForRateLimit(route) {
                    return
                }
                status = .coolingDown
                cooldownUntil = cooldown
            } else {
                return
            }
        } else {
            if FactoryDroidProviderExecutor.isStrictStandardUsageExhaustion(error: error, route: route) {
                return
            }
            let lowercasedDescription = error.localizedDescription.lowercased()
            if lowercasedDescription.contains("quota")
                || lowercasedDescription.contains("insufficient")
                || lowercasedDescription.contains("exhaust") {
                status = .exhausted
                cooldownUntil = nil
            } else if lowercasedDescription.contains("rate limit")
                || lowercasedDescription.contains("rate_limit")
                || lowercasedDescription.contains("429") {
                if Self.shouldPreserveSlotAvailabilityForRateLimit(route) {
                    return
                }
                status = .coolingDown
                cooldownUntil = cooldown
            } else if lowercasedDescription.contains("401")
                || lowercasedDescription.contains("403")
                || lowercasedDescription.contains("invalid api key") {
                status = .missingSecret
                cooldownUntil = nil
            } else {
                return
            }
        }

        guard let status else { return }
        do {
            try await configStore.updateCredentialSlotStatus(
                providerID: route.providerID,
                slotID: slotID,
                status: status,
                cooldownUntil: cooldownUntil,
                message: error.localizedDescription
            )
        } catch {
            logger.silentFailure("update_credential_slot_status_failure", error: error)
        }
    }

    private static func shouldPreserveSlotAvailabilityForRateLimit(_ route: BurnBarProviderRoute) -> Bool {
        guard route.providerID.caseInsensitiveCompare("anthropic") == .orderedSame,
              route.formatFamily == .anthropic else {
            return false
        }

        let normalizedKey = route.apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedKey.hasPrefix("sk-ant-oat")
    }

    public func markRouteSuccess(_ route: BurnBarProviderRoute) async {
        guard let slotID = route.credentialSlotID else { return }
        do {
            try await configStore.updateCredentialSlotStatus(
                providerID: route.providerID,
                slotID: slotID,
                status: .ready,
                cooldownUntil: nil,
                message: nil
            )
        } catch {
            logger.silentFailure("update_credential_slot_status_success", error: error)
        }
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

            let formatFamily = configuration.provider.formatFamily

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
                    guard let key = OpenBurnBarProviderCredentialNormalizer.routingAPIKey(
                        providerID: configuration.provider.id,
                        rawSecret: slot.apiKey
                    ) else {
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
                            canonicalModelID: resolvedModel.canonicalModelID,
                            apiKey: key,
                            pricing: resolvedModel.pricing,
                            modelCapabilityClassID: resolvedModel.capabilityClassID,
                            formatFamily: formatFamily
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
                        canonicalModelID: resolvedModel.canonicalModelID,
                        apiKey: apiKey,
                        pricing: resolvedModel.pricing,
                        modelCapabilityClassID: resolvedModel.capabilityClassID,
                        formatFamily: formatFamily
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

    private func resolveModel(
        named modelName: String,
        in configuration: BurnBarResolvedProviderConfiguration
    ) -> BurnBarCatalogModel? {
        let normalized = modelName.lowercased()

        if configuration.provider.id.lowercased() == "ollama",
           isOllamaCloudBaseURL(configuration.settings.baseURL),
           normalizedOllamaCloudModelID(from: modelName) == nil {
            return nil
        }

        if configuration.provider.id.lowercased() == "ollama",
           let directCloudModelID = normalizedOllamaCloudModelID(from: modelName) {
            let exactCloudModel = configuration.preferredModels.first(where: {
                $0.id.lowercased() == normalized || $0.aliases.contains(where: { $0.lowercased() == normalized })
            })
            let cloudFamily = configuration.provider.models.first(where: { $0.id == "ollama-cloud-family" })
            let modelTemplate = exactCloudModel ?? cloudFamily
            guard let modelTemplate else { return nil }
            let capabilityClassID: String? = {
                if let exactCloudModel {
                    return exactCloudModel.capabilityClassID ?? exactCloudModel.id
                }
                return directCloudModelID
            }()
            return BurnBarCatalogModel(
                id: directCloudModelID,
                displayName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                visibility: .hidden,
                aliases: [modelName],
                matchers: [],
                pricing: modelTemplate.pricing,
                canonicalModelID: directCloudModelID,
                capabilityClassID: capabilityClassID,
                capabilityClassRank: cloudFamily?.capabilityClassRank ?? modelTemplate.capabilityClassRank
            )
        }

        if let exactMatch = configuration.preferredModels.first(where: {
            $0.id.lowercased() == normalized || $0.aliases.contains(where: { $0.lowercased() == normalized })
        }) {
            return wireModel(for: exactMatch, requestedModel: modelName)
        }

        if let dynamicModel = dynamicOpenAICompatibleModel(
            named: modelName,
            in: configuration
        ) {
            return dynamicModel
        }

        guard let matchedModel = configuration.preferredModels.first(where: { $0.matches(modelName: normalized) }) else {
            return nil
        }

        if configuration.provider.id.lowercased() == "ollama",
           matchedModel.id == "ollama-cloud-family",
           let directCloudModelID = normalizedOllamaCloudModelID(from: modelName) {
            return BurnBarCatalogModel(
                id: directCloudModelID,
                displayName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                visibility: .hidden,
                aliases: [modelName],
                matchers: [],
                pricing: matchedModel.pricing,
                canonicalModelID: directCloudModelID,
                capabilityClassID: matchedModel.capabilityClassID ?? matchedModel.id,
                capabilityClassRank: matchedModel.capabilityClassRank
            )
        }

        return wireModel(for: matchedModel, requestedModel: modelName)
    }

    private func dynamicOpenAICompatibleModel(
        named modelName: String,
        in configuration: BurnBarResolvedProviderConfiguration
    ) -> BurnBarCatalogModel? {
        guard allowDynamicOpenAICompatibleModels,
              configuration.provider.formatFamily == .openaiCompat,
              configuration.provider.capabilities.contains(.routing),
              let template = configuration.preferredModels.first ?? configuration.provider.models.first(where: { $0.visibility == .public }) else {
            return nil
        }

        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        let capabilityTemplate = configuration.provider.models.first(where: { $0.matches(modelName: normalized) }) ?? template

        return BurnBarCatalogModel(
            id: trimmed,
            displayName: trimmed,
            visibility: .hidden,
            aliases: [trimmed],
            matchers: [],
            pricing: capabilityTemplate.pricing,
            canonicalModelID: trimmed,
            capabilityClassID: trimmed,
            capabilityClassRank: capabilityTemplate.capabilityClassRank
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

    private func normalizedOllamaCloudModelID(from modelName: String) -> String? {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func resolveRequiredCanonicalModelID(
        explicitCanonicalModelID: String?,
        modelName: String,
        preferredProviderID: String?,
        requestedFormatFamily: BurnBarProviderFormatFamily?,
        configurations: [BurnBarResolvedProviderConfiguration]
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
            resolveModel(named: modelName, in: configuration)?.canonicalModelID
        }
        let uniqueCanonicalIDs = Set(canonicalIDs)
        return uniqueCanonicalIDs.count == 1 ? uniqueCanonicalIDs.first : nil
    }

    private func resolvedRouterMode(_ requested: ProviderRouterMode?) async throws -> ProviderRouterMode {
        if let requested { return requested.effectiveMode }
        return try await configStore.snapshot().routerMode.effectiveMode
    }

    private func preferredProviderForProviderFamilyMode(
        modelName: String,
        routerMode: ProviderRouterMode,
        requestedFormatFamily: BurnBarProviderFormatFamily?,
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> String? {
        guard routerMode == .providerFamilyFailover else { return nil }
        if normalizedOllamaCloudModelID(from: modelName) != nil {
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

    public func persistDecisionIfNeeded(
        ranking: BurnBarRouteRankingResult,
        modelName: String
    ) async {
        guard let routingEventStore else { return }
        let event = routingDecisionEvent(ranking: ranking, modelName: modelName)
        await routingEventStore.append(event)
    }

    public func routingDecisionEvent(
        ranking: BurnBarRouteRankingResult,
        modelName: String,
        now: Date = Date()
    ) -> ProviderRoutingDecisionEvent {
        let selected = ranking.rankedRoutes.first.map { candidate(from: $0.route) }
        let nextFallback = ranking.rankedRoutes.dropFirst().first.map { candidate(from: $0.route) }
        let failedExactAlternatives = ranking.blockedExactModelRoutes.map { route in
            ProviderRoutingRejectedAlternative(
                providerID: ProviderID(rawValue: route.providerID),
                accountID: route.credentialSlotID ?? "legacy",
                accountLabel: route.credentialSlotLabel ?? route.providerDisplayName,
                reason: exactModelBlockedReason(
                    route: route,
                    requiredCanonicalModelID: ranking.requiredCanonicalModelID
                )
            )
        }
        let rejected = ranking.rankedRoutes.dropFirst().map { rankedRoute in
            ProviderRoutingRejectedAlternative(
                providerID: ProviderID(rawValue: rankedRoute.route.providerID),
                accountID: rankedRoute.route.credentialSlotID ?? "legacy",
                accountLabel: rankedRoute.route.credentialSlotLabel ?? rankedRoute.route.providerDisplayName,
                reason: "Lower score than selected route"
            )
        } + failedExactAlternatives
        let reason: String
        switch (selected, nextFallback) {
        case (.some(let selected), .some(let next)):
            reason = "\(selected.accountLabel) is active; \(next.accountLabel) is next fallback."
        case (.some(let selected), .none):
            reason = "\(selected.accountLabel) is active."
        case (.none, _):
            reason = "No eligible route is available."
        }
        return ProviderRoutingDecisionEvent(
            occurredAt: now,
            modelID: modelName,
            routerMode: ranking.routerMode,
            selected: selected,
            nextFallback: nextFallback,
            attemptedModelID: modelName,
            attemptedCanonicalModelID: ranking.requiredCanonicalModelID,
            exactModelInvariantPassed: exactModelInvariantPassed(
                selected: selected,
                requiredCanonicalModelID: ranking.requiredCanonicalModelID,
                routerMode: ranking.routerMode
            ),
            reason: reason,
            explanation: routingExplanation(ranking: ranking, modelName: modelName),
            rejectedAlternatives: rejected,
            benchmarkStatus: ranking.benchmarkStatus,
            skipped: []
        )
    }

    private func candidate(from route: BurnBarProviderRoute) -> ProviderRoutingCandidate {
        ProviderRoutingCandidate(
            providerID: ProviderID(rawValue: route.providerID),
            accountID: route.credentialSlotID ?? "legacy",
            accountLabel: route.credentialSlotLabel ?? route.providerDisplayName,
            credentialHandle: "daemon-provider-slot",
            storageScope: .deviceKeychain,
            modelCompatibility: .compatible,
            canonicalModelID: route.canonicalModelID,
            quotaState: .healthy,
            localCredentialAvailable: true
        )
    }

    private func routingExplanation(
        ranking: BurnBarRouteRankingResult,
        modelName: String
    ) -> String {
        guard let winner = ranking.rankedRoutes.first else {
            return "No eligible route for \(modelName)."
        }
        switch ranking.routerMode {
        case .providerFamilyFailover:
            return "Provider-Family Failover selected \(winner.route.providerDisplayName) \(winner.route.credentialSlotLabel ?? "legacy") for \(modelName); cross-provider alternatives were not eligible."
        case .sameModelFailover:
            let canonical = ranking.requiredCanonicalModelID ?? "unknown"
            return "Exact Model Failover selected \(winner.route.providerDisplayName) \(winner.route.credentialSlotLabel ?? "legacy") for \(modelName); every eligible fallback must serve canonical model \(canonical)."
        case .intelligentModelRouter:
            var parts = [
                "Exact Model Failover selected \(winner.route.providerDisplayName) \(winner.route.credentialSlotLabel ?? "legacy") for \(modelName)",
                "signals: capability \(String(format: "%.2f", winner.breakdown.score.capability)), cost \(String(format: "%.2f", winner.breakdown.score.cost)), latency \(String(format: "%.2f", winner.breakdown.score.latency)), trust \(String(format: "%.2f", winner.breakdown.score.trust))"
            ]
            if let status = ranking.benchmarkStatus {
                parts.append("benchmark \(status.freshness.rawValue)")
            }
            return parts.joined(separator: "; ") + "."
        }
    }

    private func exactModelBlockedReason(
        route: BurnBarProviderRoute,
        requiredCanonicalModelID: String?
    ) -> String {
        guard let requiredCanonicalModelID else {
            return "Exact model failover requires a canonical model ID."
        }
        let served = route.canonicalModelID ?? "unknown"
        return "Canonical model mismatch: \(served) is not \(requiredCanonicalModelID)."
    }

    private func exactModelInvariantPassed(
        selected: ProviderRoutingCandidate?,
        requiredCanonicalModelID: String?,
        routerMode: ProviderRouterMode
    ) -> Bool {
        guard routerMode.usesExactSameModelInvariant || requiredCanonicalModelID != nil else {
            return true
        }
        guard let selected, let requiredCanonicalModelID else {
            return false
        }
        return selected.canonicalModelID == requiredCanonicalModelID
    }
}

// MARK: - Router Scorecard

extension BurnBarProviderRouter {

    /// Scores and ranks all candidate routes using a five-dimensional scorecard.
    /// Returns ranked routes with full score breakdowns for all five dimensions:
    /// capability, cost, latency, trust, and policy-fit.
    ///
    /// Deterministic tie-break: routes with identical composite scores are ordered by
    /// providerID ascending (lexicographic), then slotID ascending (nil "legacy" sorts first).
    public func scoreAndRankRoutes(
        modelName: String,
        preferredProviderID: String? = nil,
        excludedRouteKeys: Set<String> = [],
        requestedFormatFamily: BurnBarProviderFormatFamily? = nil,
        requiredCapabilityClassID: String? = nil,
        requiredCanonicalModelID: String? = nil,
        routerMode: ProviderRouterMode? = nil,
        taskCategory: ProviderRoutingTaskCategory = .unknown,
        benchmarkSnapshots: [ProviderModelBenchmarkSnapshot] = [],
        benchmarkStatus: ProviderModelBenchmarkStatus? = nil
    ) async throws -> BurnBarRouteRankingResult {
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
            configurations: configurations
        )
        let candidates = try candidateRoutes(
            modelName: modelName,
            preferredProviderID: effectivePreferredProviderID,
            excludedRouteKeys: excludedRouteKeys,
            requestedFormatFamily: requestedFormatFamily,
            requiredCapabilityClassID: requiredCapabilityClassID,
            requiredCanonicalModelID: resolvedRequiredCanonicalModelID,
            configurations: configurations,
            routerMode: effectiveRouterMode,
            strictPreferredProvider: preferredProviderID != nil
        )

        // When capability-class filtering is active, also fetch the unfiltered candidates
        // to compute which lower-class routes were excluded. Used by callers (gateway)
        // to report "downgrade disabled" when the same-class pool is exhausted.
        let blockedByCapabilityClass: [BurnBarProviderRoute]
        if requiredCapabilityClassID != nil {
            let unfilteredCandidates = try candidateRoutes(
                modelName: modelName,
                preferredProviderID: effectivePreferredProviderID,
                excludedRouteKeys: excludedRouteKeys,
                requestedFormatFamily: requestedFormatFamily,
                requiredCapabilityClassID: nil,
                requiredCanonicalModelID: resolvedRequiredCanonicalModelID,
                configurations: configurations,
                routerMode: effectiveRouterMode,
                strictPreferredProvider: preferredProviderID != nil
            )
            let sameClassIDs = Set(candidates.map(\.modelCapabilityClassID))
            blockedByCapabilityClass = unfilteredCandidates.filter { !sameClassIDs.contains($0.modelCapabilityClassID) }
        } else {
            blockedByCapabilityClass = []
        }

        let blockedByExactModel: [BurnBarProviderRoute]
        if resolvedRequiredCanonicalModelID != nil || effectiveRouterMode.usesExactSameModelInvariant {
            let unfilteredExactCandidates = try candidateRoutes(
                modelName: modelName,
                preferredProviderID: effectivePreferredProviderID,
                excludedRouteKeys: excludedRouteKeys,
                requestedFormatFamily: requestedFormatFamily,
                requiredCapabilityClassID: requiredCapabilityClassID,
                requiredCanonicalModelID: nil,
                configurations: configurations,
                routerMode: effectiveRouterMode,
                enforceExactModelInvariant: false,
                strictPreferredProvider: preferredProviderID != nil
            )
            blockedByExactModel = unfilteredExactCandidates.filter { route in
                guard let resolvedRequiredCanonicalModelID else { return true }
                return route.canonicalModelID != resolvedRequiredCanonicalModelID
            }
        } else {
            blockedByExactModel = []
        }

        guard !candidates.isEmpty else {
            return BurnBarRouteRankingResult(
                rankedRoutes: [],
                routerMode: effectiveRouterMode,
                taskCategory: taskCategory,
                benchmarkStatus: benchmarkStatus,
                requiredCanonicalModelID: resolvedRequiredCanonicalModelID,
                blockedCapabilityClassRoutes: blockedByCapabilityClass,
                blockedExactModelRoutes: blockedByExactModel
            )
        }

        // Build slot-info map for trust/latency scoring
        let slotInfoMap = buildSlotInfoMap(for: candidates, configurations: configurations)

        // Extract raw cost range for normalization
        let costRange = extractCostRange(from: candidates)

        // Score each route
        var rankedRoutes: [BurnBarRankedRoute] = candidates.map { route in
            let breakdown = computeBreakdown(
                for: route,
                slotInfoMap: slotInfoMap,
                costRange: costRange,
                preferredProviderID: effectivePreferredProviderID
            )
            return BurnBarRankedRoute(route: route, breakdown: breakdown)
        }

        let benchmarkIndex = benchmarkSnapshotsByModelAndTask(benchmarkSnapshots)

        // Sort by composite score (desc), then deterministic tie-breaks.
        // When scores tie inside one provider, prefer the least-recently selected
        // slot so unpinned provider plans rotate instead of sticking to one key.
        rankedRoutes.sort { lhs, rhs in
            let lhsScore = rankedCompositeScore(
                lhs,
                routerMode: effectiveRouterMode,
                taskCategory: taskCategory,
                benchmarkIndex: benchmarkIndex
            )
            let rhsScore = rankedCompositeScore(
                rhs,
                routerMode: effectiveRouterMode,
                taskCategory: taskCategory,
                benchmarkIndex: benchmarkIndex
            )
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            // Deterministic tie-break: providerID asc, slotID asc (nil = "legacy" first)
            let lhsProvider = lhs.breakdown.providerID
            let rhsProvider = rhs.breakdown.providerID
            if lhsProvider != rhsProvider {
                return lhsProvider < rhsProvider
            }
            let lhsLastSelected = slotInfoMap[lhs.breakdown.routeKey]?.lastSelectedAt ?? .distantPast
            let rhsLastSelected = slotInfoMap[rhs.breakdown.routeKey]?.lastSelectedAt ?? .distantPast
            if lhsLastSelected != rhsLastSelected {
                return lhsLastSelected < rhsLastSelected
            }
            let lhsSlot = lhs.breakdown.slotID ?? "legacy"
            let rhsSlot = rhs.breakdown.slotID ?? "legacy"
            return lhsSlot < rhsSlot
        }

        return BurnBarRouteRankingResult(
            rankedRoutes: rankedRoutes,
            routerMode: effectiveRouterMode,
            taskCategory: taskCategory,
            benchmarkStatus: benchmarkStatus,
            requiredCanonicalModelID: resolvedRequiredCanonicalModelID,
            blockedCapabilityClassRoutes: blockedByCapabilityClass,
            blockedExactModelRoutes: blockedByExactModel
        )
    }

    /// Returns score breakdowns for all candidate routes without filtering or selection.
    public func scoreBreakdowns(
        modelName: String,
        preferredProviderID: String? = nil,
        requestedFormatFamily: BurnBarProviderFormatFamily? = nil,
        requiredCapabilityClassID: String? = nil
    ) async throws -> [BurnBarRouteScoreBreakdown] {
        let configurations = try await configStore.resolvedConfigurations()
        let candidates = try candidateRoutes(
            modelName: modelName,
            preferredProviderID: preferredProviderID,
            excludedRouteKeys: [],
            requestedFormatFamily: requestedFormatFamily,
            requiredCapabilityClassID: requiredCapabilityClassID,
            requiredCanonicalModelID: nil,
            configurations: configurations
        )

        guard !candidates.isEmpty else { return [] }

        let slotInfoMap = buildSlotInfoMap(for: candidates, configurations: configurations)
        let costRange = extractCostRange(from: candidates)

        return candidates.map { route in
            computeBreakdown(
                for: route,
                slotInfoMap: slotInfoMap,
                costRange: costRange,
                preferredProviderID: preferredProviderID
            )
        }
    }

    // MARK: - Private Scoring Helpers

    private struct SlotInfo {
        let status: BurnBarProviderCredentialSlotStatus
        let cooldownUntil: Date?
        let lastSelectedAt: Date?
        let latencyMs: Double
        let isPreferredSlot: Bool
    }

    private func buildSlotInfoMap(
        for routes: [BurnBarProviderRoute],
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> [String: SlotInfo] {
        var slotMap: [String: SlotInfo] = [:]

        for route in routes {
            guard let slotID = route.credentialSlotID else { continue }
            let key = routeKey(providerID: route.providerID, slotID: slotID)

            if slotMap[key] != nil { continue }

            for config in configurations where config.provider.id == route.providerID {
                if let resolvedSlot = config.credentialSlots.first(where: { $0.slot.slotID == slotID }) {
                    let slot = resolvedSlot.slot
                    let latencyMs = estimateLatencyMs(for: resolvedSlot)
                    let isPreferred = config.settings.preferredCredentialSlotID == slotID
                    slotMap[key] = SlotInfo(
                        status: slot.status,
                        cooldownUntil: slot.cooldownUntil,
                        lastSelectedAt: slot.lastSelectedAt,
                        latencyMs: latencyMs,
                        isPreferredSlot: isPreferred
                    )
                }
            }
        }

        return slotMap
    }

    private func estimateLatencyMs(for slot: BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot) -> Double {
        _ = slot
        // The router does not yet persist measured upstream RTT per slot. Keep
        // latency neutral so route recency is handled by the explicit LRU
        // tie-break instead of being conflated with network performance.
        return 100.0
    }

    private struct CostRange {
        let minCost: Double
        let maxCost: Double
    }

    private func extractCostRange(from routes: [BurnBarProviderRoute]) -> CostRange {
        var minCost = Double.infinity
        var maxCost = -Double.infinity

        for route in routes {
            // cost per million tokens (input + output)
            let costPerM = route.pricing.inputPerMToken + route.pricing.outputPerMToken
            minCost = min(minCost, costPerM)
            maxCost = max(maxCost, costPerM)
        }

        if minCost == maxCost {
            // Avoid division by zero — single candidate case
            minCost = maxCost - 0.001
        }

        return CostRange(minCost: minCost, maxCost: maxCost)
    }

    private func computeBreakdown(
        for route: BurnBarProviderRoute,
        slotInfoMap: [String: SlotInfo],
        costRange: CostRange,
        preferredProviderID: String?
    ) -> BurnBarRouteScoreBreakdown {
        let routeKey = routeKey(providerID: route.providerID, slotID: route.credentialSlotID)

        // 1. Capability (based on provider capabilities)
        let rawCapability = computeCapabilityScore(route: route)
        let normalizedCapability = rawCapability // Already 0-1

        // 2. Cost (normalized: lower cost = higher score)
        let costPerM = route.pricing.inputPerMToken + route.pricing.outputPerMToken
        let rawCostPerMToken = costPerM
        let costRangeSpan = costRange.maxCost - costRange.minCost
        let normalizedCost = costRangeSpan > 0
            ? 1.0 - ((costPerM - costRange.minCost) / costRangeSpan)
            : 1.0

        // 3. Latency (normalized: lower latency = higher score)
        let latencyMs: Double
        let isPreferredSlot: Bool
        if route.credentialSlotID != nil,
           let info = slotInfoMap[routeKey] {
            latencyMs = info.latencyMs
            isPreferredSlot = info.isPreferredSlot
        } else {
            latencyMs = 150.0 // default for legacy routes
            isPreferredSlot = false
        }
        let rawLatencyMs = latencyMs
        // Normalize: 0-50ms = 1.0, 200+ms = 0.0
        let normalizedLatency = max(0.0, min(1.0, 1.0 - (latencyMs - 50) / 150))

        // 4. Trust (based on slot status)
        let (rawTrustStatus, normalizedTrust) = computeTrustScore(
            route: route,
            slotInfoMap: slotInfoMap
        )

        // 5. Policy-fit (preferred provider + preferred slot)
        let rawPolicyFitPreferred = (preferredProviderID == route.providerID) || isPreferredSlot
        let normalizedPolicyFit: Double
        if isPreferredSlot {
            normalizedPolicyFit = 1.0
        } else if preferredProviderID == route.providerID {
            normalizedPolicyFit = 0.85
        } else {
            normalizedPolicyFit = 0.3
        }

        let score = BurnBarRouteScore(
            capability: normalizedCapability,
            cost: normalizedCost,
            latency: normalizedLatency,
            trust: normalizedTrust,
            policyFit: normalizedPolicyFit
        )

        return BurnBarRouteScoreBreakdown(
            routeKey: routeKey,
            providerID: route.providerID,
            slotID: route.credentialSlotID,
            score: score,
            rawCapability: rawCapability,
            rawCostPerMToken: rawCostPerMToken,
            rawLatencyMs: rawLatencyMs,
            rawTrustStatus: rawTrustStatus,
            rawPolicyFitPreferred: rawPolicyFitPreferred
        )
    }

    private func computeCapabilityScore(route: BurnBarProviderRoute) -> Double {
        // Base capability score derived from provider features.
        // All configured providers get 0.7 base + feature bonuses.
        var score = 0.7

        // Bonus for having routing capability (basic requirement)
        if let provider = configStore.catalogSupport.provider(id: route.providerID) {
            if provider.capabilities.contains(.routing) {
                score += 0.1
            }
            if provider.capabilities.contains(.accounting) {
                score += 0.1
            }
            if provider.capabilities.contains(.cursorConnector) {
                score += 0.1
            }
        }

        return min(1.0, score)
    }

    private func computeTrustScore(
        route: BurnBarProviderRoute,
        slotInfoMap: [String: SlotInfo]
    ) -> (status: String, score: Double) {
        guard let slotID = route.credentialSlotID,
              let info = slotInfoMap[routeKey(providerID: route.providerID, slotID: slotID)] else {
            // Legacy route (no slot) — moderate trust
            return ("legacy", 0.6)
        }

        let status = info.status
        var score: Double

        switch status {
        case .ready:
            score = 1.0
        case .coolingDown:
            // Check if still in cooldown
            if let cooldownUntil = info.cooldownUntil, cooldownUntil > Date() {
                score = 0.3
            } else {
                score = 0.9 // cooldown expired
            }
        case .exhausted:
            score = 0.1
        case .missingSecret:
            score = 0.0
        case .disabled:
            score = 0.0
        }

        return (status.rawValue, score)
    }

    private func benchmarkSnapshotsByModelAndTask(
        _ snapshots: [ProviderModelBenchmarkSnapshot]
    ) -> [String: [ProviderModelBenchmarkSnapshot]] {
        Dictionary(grouping: snapshots) { snapshot in
            "\(snapshot.modelID.lowercased())#\(snapshot.taskCategory.rawValue)"
        }
    }

    private func rankedCompositeScore(
        _ rankedRoute: BurnBarRankedRoute,
        routerMode: ProviderRouterMode,
        taskCategory: ProviderRoutingTaskCategory,
        benchmarkIndex: [String: [ProviderModelBenchmarkSnapshot]]
    ) -> Double {
        let base = rankedRoute.breakdown.score.composite
        guard routerMode == .intelligentModelRouter else {
            return base
        }

        let route = rankedRoute.route
        let taskFit = taskFitScore(modelID: route.resolvedModelID, taskCategory: taskCategory)
        let benchmark = benchmarkScore(
            modelID: route.resolvedModelID,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        let context = contextSignal(
            modelID: route.resolvedModelID,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        let reliability = reliabilitySignal(
            modelID: route.resolvedModelID,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        return base * 0.55
            + taskFit * 0.15
            + benchmark * 0.15
            + context * 0.05
            + reliability * 0.10
    }

    private func taskFitScore(
        modelID: String,
        taskCategory: ProviderRoutingTaskCategory
    ) -> Double {
        let lower = modelID.lowercased()
        switch taskCategory {
        case .coding, .terminal, .agent:
            if lower.contains("code") || lower.contains("codex") || lower.contains("glm") || lower.contains("claude") {
                return 1.0
            }
            return 0.65
        case .design:
            if lower.contains("image") || lower.contains("design") || lower.contains("gpt") {
                return 0.9
            }
            return 0.6
        case .analysis, .general, .unknown:
            return 0.75
        }
    }

    private func benchmarkScore(
        modelID: String,
        taskCategory: ProviderRoutingTaskCategory,
        benchmarkIndex: [String: [ProviderModelBenchmarkSnapshot]]
    ) -> Double {
        let snapshots = benchmarkSnapshots(
            modelID: modelID,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        guard !snapshots.isEmpty else { return 0.5 }
        let normalized = snapshots.compactMap { snapshot -> Double? in
            if let score = snapshot.score {
                return max(0.0, min(1.0, score > 1.0 ? score / 100.0 : score))
            }
            if let rank = snapshot.rank, rank > 0 {
                return max(0.0, 1.0 - Double(rank - 1) / 100.0)
            }
            return nil
        }
        guard !normalized.isEmpty else { return 0.5 }
        return normalized.reduce(0, +) / Double(normalized.count)
    }

    private func contextSignal(
        modelID: String,
        taskCategory: ProviderRoutingTaskCategory,
        benchmarkIndex: [String: [ProviderModelBenchmarkSnapshot]]
    ) -> Double {
        let contexts = benchmarkSnapshots(
            modelID: modelID,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        ).compactMap(\.contextWindowTokens)
        guard let maxContext = contexts.max() else { return 0.5 }
        if maxContext >= 1_000_000 { return 1.0 }
        if maxContext >= 200_000 { return 0.85 }
        if maxContext >= 128_000 { return 0.7 }
        if maxContext >= 32_000 { return 0.55 }
        return 0.4
    }

    private func reliabilitySignal(
        modelID: String,
        taskCategory: ProviderRoutingTaskCategory,
        benchmarkIndex: [String: [ProviderModelBenchmarkSnapshot]]
    ) -> Double {
        let snapshots = benchmarkSnapshots(
            modelID: modelID,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        let reliability = snapshots.compactMap(\.reliabilitySignal)
        if !reliability.isEmpty {
            return reliability.reduce(0, +) / Double(reliability.count)
        }
        let confidence = snapshots.compactMap(\.confidence)
        guard !confidence.isEmpty else { return 0.5 }
        return confidence.reduce(0, +) / Double(confidence.count)
    }

    private func benchmarkSnapshots(
        modelID: String,
        taskCategory: ProviderRoutingTaskCategory,
        benchmarkIndex: [String: [ProviderModelBenchmarkSnapshot]]
    ) -> [ProviderModelBenchmarkSnapshot] {
        let normalizedModelID = modelID.lowercased()
        let exactKey = "\(normalizedModelID)#\(taskCategory.rawValue)"
        if let exact = benchmarkIndex[exactKey], !exact.isEmpty {
            return exact
        }
        let generalKey = "\(normalizedModelID)#\(ProviderRoutingTaskCategory.general.rawValue)"
        return benchmarkIndex[generalKey] ?? []
    }
}
