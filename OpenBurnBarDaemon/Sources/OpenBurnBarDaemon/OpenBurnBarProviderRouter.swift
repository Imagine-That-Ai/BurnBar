import OpenBurnBarCore
import Foundation

public struct BurnBarProviderRouter: Sendable {
    let configStore: BurnBarConfigStore
    let logger: BurnBarDaemonLogger
    let routingEventStore: BurnBarProviderRoutingDecisionEventStore?
    let allowDynamicOpenAICompatibleModels: Bool

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
}
