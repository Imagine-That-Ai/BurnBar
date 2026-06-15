import OpenBurnBarCore
import Foundation

extension BurnBarProviderRouter {
    struct SlotInfo {
        let status: BurnBarProviderCredentialSlotStatus
        let cooldownUntil: Date?
        let lastSelectedAt: Date?
        let lastQuotaResetsAt: Date?
        let latencyMs: Double
        let isPreferredSlot: Bool
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
                    slotMap[key] = SlotInfo(
                        status: slot.status,
                        cooldownUntil: slot.cooldownUntil,
                        lastSelectedAt: slot.lastSelectedAt,
                        lastQuotaResetsAt: slot.lastQuotaResetsAt,
                        latencyMs: latencyMs,
                        isPreferredSlot: isPreferred
                    )
                }
            }
        }

        return slotMap
    }

    static func compareQuotaReset(_ lhs: Date?, _ rhs: Date?, now: Date) -> Bool? {
        switch (activeQuotaReset(lhs, now: now), activeQuotaReset(rhs, now: now)) {
        case let (.some(lhsReset), .some(rhsReset)):
            guard lhsReset != rhsReset else { return nil }
            return lhsReset < rhsReset
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return nil
        }
    }

    func sameQuotaDrainPool(_ lhs: BurnBarProviderRoute, _ rhs: BurnBarProviderRoute) -> Bool {
        lhs.providerID == rhs.providerID
            && lhs.resolvedModelID == rhs.resolvedModelID
            && lhs.canonicalModelID == rhs.canonicalModelID
            && lhs.formatFamily == rhs.formatFamily
            && lhs.endpointProfileID == rhs.endpointProfileID
    }

    private static func activeQuotaReset(_ value: Date?, now: Date) -> Date? {
        guard let value, value > now else { return nil }
        return value
    }

    private func estimateLatencyMs(for slot: BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot) -> Double {
        _ = slot
        // The router does not yet persist measured upstream RTT per slot. Keep
        // latency neutral so route recency is handled by the explicit LRU
        // tie-break instead of being conflated with network performance.
        return 100.0
    }
}
