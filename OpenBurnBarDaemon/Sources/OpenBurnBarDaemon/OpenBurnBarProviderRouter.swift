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
    public let rankedRoutes: [BurnBarRankedRoute]

    /// The winning route (same as rankedRoutes.first?.route).
    public var winner: BurnBarProviderRoute? {
        rankedRoutes.first?.route
    }

    public init(rankedRoutes: [BurnBarRankedRoute]) {
        self.rankedRoutes = rankedRoutes
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

        if let preferredProviderID, !configStore.catalogSupport.isSupported(providerID: preferredProviderID) {
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
        excludedRouteKeys: Set<String> = []
    ) async throws -> BurnBarRouteRankingResult {
        let candidates = try await candidateRoutes(
            modelName: modelName,
            preferredProviderID: preferredProviderID,
            excludedRouteKeys: excludedRouteKeys
        )

        guard !candidates.isEmpty else {
            return BurnBarRouteRankingResult(rankedRoutes: [])
        }

        // Build slot-info map for trust/latency scoring
        let slotInfoMap = try await buildSlotInfoMap(for: candidates)

        // Extract raw cost range for normalization
        let costRange = extractCostRange(from: candidates)

        // Score each route
        var rankedRoutes: [BurnBarRankedRoute] = candidates.map { route in
            let breakdown = computeBreakdown(
                for: route,
                slotInfoMap: slotInfoMap,
                costRange: costRange,
                preferredProviderID: preferredProviderID
            )
            return BurnBarRankedRoute(route: route, breakdown: breakdown)
        }

        // Sort by composite score (desc), then deterministic tie-break
        rankedRoutes.sort { lhs, rhs in
            let lhsScore = lhs.breakdown.score.composite
            let rhsScore = rhs.breakdown.score.composite
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            // Deterministic tie-break: providerID asc, slotID asc (nil = "legacy" first)
            let lhsProvider = lhs.breakdown.providerID
            let rhsProvider = rhs.breakdown.providerID
            if lhsProvider != rhsProvider {
                return lhsProvider < rhsProvider
            }
            let lhsSlot = lhs.breakdown.slotID ?? "legacy"
            let rhsSlot = rhs.breakdown.slotID ?? "legacy"
            return lhsSlot < rhsSlot
        }

        return BurnBarRouteRankingResult(rankedRoutes: rankedRoutes)
    }

    /// Returns score breakdowns for all candidate routes without filtering or selection.
    public func scoreBreakdowns(
        modelName: String,
        preferredProviderID: String? = nil
    ) async throws -> [BurnBarRouteScoreBreakdown] {
        let candidates = try await candidateRoutes(
            modelName: modelName,
            preferredProviderID: preferredProviderID
        )

        guard !candidates.isEmpty else { return [] }

        let slotInfoMap = try await buildSlotInfoMap(for: candidates)
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
        for routes: [BurnBarProviderRoute]
    ) async throws -> [String: SlotInfo] {
        let configurations = try await configStore.resolvedConfigurations()
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
        // If we have a lastSelectedAt, estimate based on time since last use
        // (In production this would come from actual latency tracking)
        if let lastSelected = slot.slot.lastSelectedAt {
            let secondsSince = Date().timeIntervalSince(lastSelected)
            // Simulate 50-200ms base latency + aging factor
            let baseLatency = 75.0
            let agingFactor = min(secondsSince / 3600, 1.0) * 25.0 // up to 25ms extra after 1 hour
            return baseLatency + agingFactor
        }
        return 100.0 // default estimated latency
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
        let normalizedPolicyFit: Double = rawPolicyFitPreferred ? 1.0 : 0.3

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
}
