import OpenBurnBarEngine
import Foundation

extension BurnBarProviderRouter {
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
        let slotLabel = winner.route.credentialSlotLabel ?? "legacy"
        let utilization = quotaDrainExplanation(for: ranking.rankedRoutes)
        switch ranking.routerMode {
        case .providerFamilyFailover:
            var parts = [
                "Provider-Family Failover selected \(winner.route.providerDisplayName) \(slotLabel) for \(modelName)",
                "cross-provider alternatives were not eligible"
            ]
            if let utilization {
                parts.append(utilization)
            }
            return parts.joined(separator: "; ") + "."
        case .sameModelFailover:
            let canonical = ranking.requiredCanonicalModelID ?? "unknown"
            var parts = [
                "Exact Model Failover selected \(winner.route.providerDisplayName) \(slotLabel) for \(modelName)",
                "every eligible fallback must serve canonical model \(canonical)"
            ]
            if let utilization {
                parts.append(utilization)
            }
            return parts.joined(separator: "; ") + "."
        case .intelligentModelRouter:
            var parts = [
                "Exact Model Failover selected \(winner.route.providerDisplayName) \(slotLabel) for \(modelName)",
                "signals: capability \(String(format: "%.2f", winner.breakdown.score.capability)), cost \(String(format: "%.2f", winner.breakdown.score.cost)), latency \(String(format: "%.2f", winner.breakdown.score.latency)), trust \(String(format: "%.2f", winner.breakdown.score.trust))"
            ]
            if let utilization {
                parts.append(utilization)
            }
            if let status = ranking.benchmarkStatus {
                parts.append("benchmark \(status.freshness.rawValue)")
            }
            return parts.joined(separator: "; ") + "."
        }
    }

    private func quotaDrainExplanation(for rankedRoutes: [BurnBarRankedRoute]) -> String? {
        guard rankedRoutes.count >= 2 else { return nil }
        let winner = rankedRoutes[0]
        let next = rankedRoutes[1]
        guard sameQuotaDrainPool(winner.route, next.route) else { return nil }

        let now = Date()
        guard let comparison = Self.compareQuotaDrain(
            lhsReset: winner.quotaResetsAt,
            lhsRemainingPercent: winner.quotaRemainingPercent,
            rhsReset: next.quotaResetsAt,
            rhsRemainingPercent: next.quotaRemainingPercent,
            now: now
        ), comparison.ordered else {
            return nil
        }

        let winnerLabel = routeSlotLabel(winner.route)
        let nextLabel = routeSlotLabel(next.route)
        switch comparison.factor {
        case .quotaReset:
            return "utilization: \(winnerLabel)'s quota window resets in \(resetWindowLabel(winner.quotaResetsAt, now: now)) vs \(resetWindowLabel(next.quotaResetsAt, now: now)) for \(nextLabel); draining before \(nextLabel)"
        case .remainingPercent:
            guard let winnerRemaining = ProviderQuotaUtilizationOrdering.normalizedRemainingPercent(winner.quotaRemainingPercent),
                  let nextRemaining = ProviderQuotaUtilizationOrdering.normalizedRemainingPercent(next.quotaRemainingPercent) else {
                return nil
            }
            return "utilization: \(winnerLabel) has \(percentLabel(winnerRemaining)) remaining vs \(percentLabel(nextRemaining)) for \(nextLabel); consuming higher headroom before it lapses"
        }
    }

    private func routeSlotLabel(_ route: BurnBarProviderRoute) -> String {
        "\(route.providerDisplayName) \(route.credentialSlotLabel ?? "legacy")"
    }

    private func resetWindowLabel(_ value: Date?, now: Date) -> String {
        guard let value, value > now else { return "unknown" }
        return durationLabel(value.timeIntervalSince(now))
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = max(1, Int((Double(seconds) / 60.0).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        let hours = max(1, Int((Double(minutes) / 60.0).rounded()))
        if hours < 48 { return "\(hours)h" }
        let days = max(1, Int((Double(hours) / 24.0).rounded()))
        return "\(days)d"
    }

    private func percentLabel(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return String(format: "%.1f%%", value)
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
