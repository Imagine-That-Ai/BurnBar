import OpenBurnBarEngine
import Foundation

extension BurnBarProviderRouter {
    func rankRoutesWithStrictQuotaDrainPools(
        _ routes: [BurnBarRankedRoute],
        routerMode: ProviderRouterMode,
        taskCategory: ProviderRoutingTaskCategory,
        benchmarkIndex: [String: [ProviderModelBenchmarkSnapshot]],
        slotInfoMap: [String: SlotInfo],
        now: Date
    ) -> [BurnBarRankedRoute] {
        let pools = Dictionary(grouping: routes) { rankedRoute in
            quotaDrainPoolKey(for: rankedRoute.route)
        }
        let rankedPools = pools.map { key, poolRoutes in
            RankedQuotaDrainPool(
                key: key,
                rankedRoutes: poolRoutes.sorted { lhs, rhs in
                    compareWithinQuotaDrainPool(
                        lhs,
                        rhs,
                        routerMode: routerMode,
                        taskCategory: taskCategory,
                        benchmarkIndex: benchmarkIndex,
                        slotInfoMap: slotInfoMap,
                        now: now
                    )
                }
            )
        }
        return rankedPools.sorted { lhs, rhs in
            compareQuotaDrainPools(
                lhs,
                rhs,
                routerMode: routerMode,
                taskCategory: taskCategory,
                benchmarkIndex: benchmarkIndex
            )
        }
        .flatMap(\.rankedRoutes)
    }

    private struct QuotaDrainPoolKey: Hashable, Sendable {
        let providerID: String
        let resolvedModelID: String
        let canonicalModelID: String?
        let formatFamily: BurnBarProviderFormatFamily
        let endpointProfileID: String?

        var sortComponents: [String] {
            [
                providerID,
                resolvedModelID,
                canonicalModelID.map { "some:\($0)" } ?? "nil:",
                formatFamily.rawValue,
                endpointProfileID.map { "some:\($0)" } ?? "nil:"
            ]
        }
    }

    private struct RankedQuotaDrainPool: Sendable {
        let key: QuotaDrainPoolKey
        let rankedRoutes: [BurnBarRankedRoute]

        var representative: BurnBarRankedRoute {
            rankedRoutes[0]
        }
    }

    private func quotaDrainPoolKey(for route: BurnBarProviderRoute) -> QuotaDrainPoolKey {
        QuotaDrainPoolKey(
            providerID: route.providerID,
            resolvedModelID: route.resolvedModelID,
            canonicalModelID: route.canonicalModelID,
            formatFamily: route.formatFamily,
            endpointProfileID: route.endpointProfileID
        )
    }

    private func compareWithinQuotaDrainPool(
        _ lhs: BurnBarRankedRoute,
        _ rhs: BurnBarRankedRoute,
        routerMode: ProviderRouterMode,
        taskCategory: ProviderRoutingTaskCategory,
        benchmarkIndex: [String: [ProviderModelBenchmarkSnapshot]],
        slotInfoMap: [String: SlotInfo],
        now: Date
    ) -> Bool {
        if let quotaOrder = Self.compareQuotaDrain(
            lhsReset: lhs.quotaResetsAt,
            lhsRemainingPercent: lhs.quotaRemainingPercent,
            rhsReset: rhs.quotaResetsAt,
            rhsRemainingPercent: rhs.quotaRemainingPercent,
            now: now
        ) {
            return quotaOrder.ordered
        }
        let lhsScore = rankedCompositeScore(
            lhs,
            routerMode: routerMode,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        let rhsScore = rankedCompositeScore(
            rhs,
            routerMode: routerMode,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return compareDeterministicRouteTies(lhs, rhs, slotInfoMap: slotInfoMap)
    }

    private func compareQuotaDrainPools(
        _ lhs: RankedQuotaDrainPool,
        _ rhs: RankedQuotaDrainPool,
        routerMode: ProviderRouterMode,
        taskCategory: ProviderRoutingTaskCategory,
        benchmarkIndex: [String: [ProviderModelBenchmarkSnapshot]]
    ) -> Bool {
        let lhsScore = rankedCompositeScore(
            lhs.representative,
            routerMode: routerMode,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        let rhsScore = rankedCompositeScore(
            rhs.representative,
            routerMode: routerMode,
            taskCategory: taskCategory,
            benchmarkIndex: benchmarkIndex
        )
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return lhs.key.sortComponents.lexicographicallyPrecedes(rhs.key.sortComponents)
    }

    private func compareDeterministicRouteTies(
        _ lhs: BurnBarRankedRoute,
        _ rhs: BurnBarRankedRoute,
        slotInfoMap: [String: SlotInfo]
    ) -> Bool {
        if lhs.breakdown.providerID != rhs.breakdown.providerID {
            return lhs.breakdown.providerID < rhs.breakdown.providerID
        }
        let lhsPriority = slotInfoMap[lhs.breakdown.routeKey]?.priority ?? Int.max
        let rhsPriority = slotInfoMap[rhs.breakdown.routeKey]?.priority ?? Int.max
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        let lhsLastSelected = slotInfoMap[lhs.breakdown.routeKey]?.lastSelectedAt ?? .distantPast
        let rhsLastSelected = slotInfoMap[rhs.breakdown.routeKey]?.lastSelectedAt ?? .distantPast
        if lhsLastSelected != rhsLastSelected {
            return lhsLastSelected < rhsLastSelected
        }
        let lhsSlot = lhs.breakdown.slotID ?? "legacy"
        let rhsSlot = rhs.breakdown.slotID ?? "legacy"
        if lhsSlot != rhsSlot {
            return lhsSlot < rhsSlot
        }
        return lhs.breakdown.routeKey < rhs.breakdown.routeKey
    }
}
