import OpenBurnBarEngine
import Foundation

extension BurnBarProviderRouter {
    struct SlotInfo {
        let status: BurnBarProviderCredentialSlotStatus
        let cooldownUntil: Date?
        let lastSelectedAt: Date?
        let lastQuotaResetsAt: Date?
        let lastQuotaRemainingPercent: Double?
        let latencyMs: Double
        let isPreferredSlot: Bool
        let priority: Int?
    }

    func buildSlotInfoMap(
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
                    let priority = config.settings.ollamaEndpoints.first { $0.id == slotID }?.priority
                    slotMap[key] = SlotInfo(
                        status: slot.status,
                        cooldownUntil: slot.cooldownUntil,
                        lastSelectedAt: slot.lastSelectedAt,
                        lastQuotaResetsAt: slot.lastQuotaResetsAt,
                        lastQuotaRemainingPercent: slot.lastQuotaRemainingPercent,
                        latencyMs: latencyMs,
                        isPreferredSlot: isPreferred,
                        priority: priority
                    )
                }
            }
        }

        return slotMap
    }

    static func compareQuotaDrain(
        lhsReset: Date?,
        lhsRemainingPercent: Double?,
        rhsReset: Date?,
        rhsRemainingPercent: Double?,
        now: Date
    ) -> ProviderQuotaUtilizationComparison? {
        ProviderQuotaUtilizationOrdering.compare(
            lhsReset: lhsReset,
            lhsRemainingPercent: lhsRemainingPercent,
            rhsReset: rhsReset,
            rhsRemainingPercent: rhsRemainingPercent,
            now: now
        )
    }

    func sameQuotaDrainPool(_ lhs: BurnBarProviderRoute, _ rhs: BurnBarProviderRoute) -> Bool {
        lhs.providerID == rhs.providerID
            && lhs.resolvedModelID == rhs.resolvedModelID
            && lhs.canonicalModelID == rhs.canonicalModelID
            && lhs.formatFamily == rhs.formatFamily
            && lhs.endpointProfileID == rhs.endpointProfileID
    }

    private func estimateLatencyMs(for slot: BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot) -> Double {
        _ = slot
        // The router does not yet persist measured upstream RTT per slot. Keep
        // latency neutral so route recency is handled by the explicit LRU
        // tie-break instead of being conflated with network performance.
        return 100.0
    }
}
