import OpenBurnBarCore
import Foundation

// MARK: - Router Scorecard

extension BurnBarProviderRouter {
    private func restrictFailoverToMatchingEndpointProfile(_ ranked: [BurnBarRankedRoute]) -> [BurnBarRankedRoute] {
        guard let winner = ranked.first,
              let profileID = winner.route.endpointProfileID,
              !profileID.isEmpty,
              !profileID.hasPrefix("legacy.") else {
            return ranked
        }

        var result: [BurnBarRankedRoute] = [winner]
        for entry in ranked.dropFirst() {
            if entry.route.providerID != winner.route.providerID {
                result.append(entry)
            } else if entry.route.endpointProfileID == profileID {
                result.append(entry)
            }
        }
        return result
    }

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
        let resolvedRequiredCapabilityClassID = resolveRequiredCapabilityClassID(
            explicitCapabilityClassID: requiredCapabilityClassID,
            modelName: modelName,
            preferredProviderID: effectivePreferredProviderID,
            requestedFormatFamily: requestedFormatFamily,
            requiredCanonicalModelID: resolvedRequiredCanonicalModelID,
            routerMode: effectiveRouterMode
        )
        let candidates = try candidateRoutes(
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

        // Retain legacy capability-class filtering for older direct router
        // callers. The HTTP gateway now enforces exact canonical model identity.
        let blockedByCapabilityClass: [BurnBarProviderRoute]
        if resolvedRequiredCapabilityClassID != nil {
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
            let slotInfo = slotInfoMap[breakdown.routeKey]
            return BurnBarRankedRoute(
                route: route,
                breakdown: breakdown,
                quotaResetsAt: slotInfo?.lastQuotaResetsAt,
                quotaRemainingPercent: slotInfo?.lastQuotaRemainingPercent
            )
        }

        let benchmarkIndex = benchmarkSnapshotsByModelAndTask(benchmarkSnapshots)

        // Inside one provider/model pool, maximize subscription utilization
        // before composite score: soonest active reset wins, then highest
        // remaining percent, then the normal score/LRU/deterministic ties.
        let rankingNow = Date()
        rankedRoutes = rankRoutesWithStrictQuotaDrainPools(
            rankedRoutes,
            routerMode: effectiveRouterMode,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex,
            slotInfoMap: slotInfoMap,
            now: rankingNow
        )

        rankedRoutes = restrictFailoverToMatchingEndpointProfile(rankedRoutes)

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

    /// Cross-vendor degrade candidates (Part B3, opt-in).
    ///
    /// Returns `[]` unless `policy.isEnabled` is true, so the default routing
    /// path is byte-for-byte unchanged. When enabled, this deliberately ignores
    /// the exact-canonical-model invariant: it substitutes a *different*,
    /// allow-listed OpenAI-compatible model that runs on the user's own key,
    /// ranked by the same five-factor scorer used for normal routing. The
    /// gateway only consults this as a last resort after the requested model is
    /// genuinely unavailable, and logs a `cross_vendor_degrade` event whenever a
    /// candidate is used.
    public func crossVendorDegradeRoutes(
        policy: BurnBarCrossVendorDegradePolicy,
        excludedRouteKeys: Set<String> = [],
        taskCategory: ProviderRoutingTaskCategory = .unknown
    ) async throws -> [BurnBarRankedRoute] {
        guard policy.isEnabled else { return [] }
        let configurations = try await configStore.resolvedConfigurations()

        var candidates: [BurnBarProviderRoute] = []
        var seenRouteKeys: Set<String> = []
        for vendorID in policy.allowedVendorIDs {
            guard let configuration = configurations.first(where: { configuration in
                configuration.provider.id.lowercased() == vendorID
                    && configuration.settings.isEnabled
                    && configuration.provider.formatFamily == .openaiCompat
            }) else { continue }

            guard let modelName = degradeModelName(for: configuration, policy: policy) else { continue }

            let vendorRoutes = selectRoutes(for: modelName, configurations: [configuration])
                .filter { $0.formatFamily == .openaiCompat }
                .filter { route in
                    let key = routeKey(providerID: route.providerID, slotID: route.credentialSlotID)
                    guard !excludedRouteKeys.contains(key) else { return false }
                    return seenRouteKeys.insert(key).inserted
                }
            candidates.append(contentsOf: vendorRoutes)
        }

        guard !candidates.isEmpty else { return [] }

        let slotInfoMap = buildSlotInfoMap(for: candidates, configurations: configurations)
        let costRange = extractCostRange(from: candidates)
        var ranked = candidates.map { route in
            BurnBarRankedRoute(
                route: route,
                breakdown: computeBreakdown(
                    for: route,
                    slotInfoMap: slotInfoMap,
                    costRange: costRange,
                    preferredProviderID: nil
                ),
                quotaResetsAt: slotInfoMap[routeKey(providerID: route.providerID, slotID: route.credentialSlotID)]?.lastQuotaResetsAt,
                quotaRemainingPercent: slotInfoMap[routeKey(providerID: route.providerID, slotID: route.credentialSlotID)]?.lastQuotaRemainingPercent
            )
        }

        let benchmarkIndex = benchmarkSnapshotsByModelAndTask([])
        let rankingNow = Date()
        ranked = rankRoutesWithStrictQuotaDrainPools(
            ranked,
            routerMode: .providerFamilyFailover,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex,
            slotInfoMap: slotInfoMap,
            now: rankingNow
        )

        return Array(ranked.prefix(policy.maxCandidates))
    }

    /// Resolves the model name to send a degrade vendor: the policy's preferred
    /// model when the catalog can resolve it, otherwise the vendor's first
    /// public catalog model.
    private func degradeModelName(
        for configuration: BurnBarResolvedProviderConfiguration,
        policy: BurnBarCrossVendorDegradePolicy
    ) -> String? {
        if let preferred = policy.preferredModelByVendorID[configuration.provider.id.lowercased()],
           resolveModel(named: preferred, in: configuration) != nil {
            return preferred
        }
        if let publicModel = configuration.preferredModels.first(where: { $0.visibility == .public }) {
            return publicModel.id
        }
        return configuration.preferredModels.first?.id
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

    func rankedCompositeScore(
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
