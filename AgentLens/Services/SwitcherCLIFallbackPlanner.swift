import Foundation
import OpenBurnBarCore

struct CLIFallbackQuotaStatus: Sendable {
    let fiveHourRemainingPercent: Double?
    let weeklyRemainingPercent: Double?
    let statusMessage: String?
}

struct SwitcherCLIFallbackPlanner: CLIFallbackPlanning {
    let quotaLookup: @Sendable (SwitcherProfileRecord) async -> CLIFallbackQuotaStatus?

    init(
        quotaLookup: @escaping @Sendable (SwitcherProfileRecord) async -> CLIFallbackQuotaStatus?
    ) {
        self.quotaLookup = quotaLookup
    }

    func orderedCandidates(
        for requestedProfile: SwitcherProfileRecord,
        allProfiles: [SwitcherProfileRecord]
    ) async -> [SwitcherProfileRecord] {
        guard let requestedGroup = fallbackGroup(for: requestedProfile) else {
            return [requestedProfile]
        }

        let matchingProfiles = allProfiles.filter { profile in
            fallbackGroup(for: profile) == requestedGroup
        }
        let compatibleProfiles = matchingProfiles.filter { profile in
            isRuntimeCompatible(candidate: profile, requestedProfile: requestedProfile)
        }

        guard let requestedIndex = compatibleProfiles.firstIndex(where: { $0.id == requestedProfile.id }) else {
            return compatibleProfiles
        }

        return [compatibleProfiles[requestedIndex]]
            + compatibleProfiles.enumerated()
                .filter { $0.offset != requestedIndex }
                .map(\.element)
    }

    func eligibility(for profile: SwitcherProfileRecord) async -> CLIFallbackEligibility {
        if let metadata = profile.cliMetadata,
           let exhaustedUntil = metadata.exhaustedUntil,
           exhaustedUntil > Date() {
            let reason = metadata.lastQuotaExhaustionDetail
                ?? "\(profile.displayName) is held in reserve until quota resets."
            return .quotaExhausted(reason: reason)
        }

        if let quotaStatus = await quotaLookup(profile),
           isDepleted(quotaStatus.fiveHourRemainingPercent) || isDepleted(quotaStatus.weeklyRemainingPercent) {
            let reason = quotaStatus.statusMessage
                ?? "\(profile.displayName) has no remaining quota in the current provider window."
            return .quotaExhausted(reason: reason)
        }

        return .eligible
    }

    /// Profiles only round-robin when they share a quota provider pool.
    /// Codex and Claude use different pools, so they do not preempt each other.
    private func fallbackGroup(for profile: SwitcherProfileRecord) -> CLIFallbackGroup? {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType else {
            return nil
        }

        if let provider = sharedQuotaProvider(for: cliType) {
            return .provider(provider)
        }

        return .isolatedCLI(cliType)
    }

    private func sharedQuotaProvider(for cliType: SwitcherCLIProfileType) -> AgentProvider? {
        switch cliType {
        case .codex:
            return .codex
        case .claude:
            return .claudeCode
        case .opencode:
            return .openCode
        }
    }

    private func isRuntimeCompatible(
        candidate: SwitcherProfileRecord,
        requestedProfile: SwitcherProfileRecord
    ) -> Bool {
        if candidate.id == requestedProfile.id {
            return true
        }

        guard let requestedCLIType = requestedProfile.cliType,
              candidate.cliType == requestedCLIType else {
            return false
        }

        let requestedMetadata = requestedProfile.cliMetadata
        let candidateMetadata = candidate.cliMetadata

        if candidateMetadata?.neverAutoSwitch == true {
            return false
        }

        if let requestedProviderID = requestedMetadata?.providerID {
            guard candidateMetadata?.providerID == requestedProviderID else {
                return false
            }
        }

        if let requestedCapabilityClassID = normalized(requestedMetadata?.modelCapabilityClassID) {
            guard normalized(candidateMetadata?.modelCapabilityClassID) == requestedCapabilityClassID else {
                return false
            }
        }

        if let requestedTierID = normalized(requestedMetadata?.subscriptionTierID) {
            guard normalized(candidateMetadata?.subscriptionTierID) == requestedTierID else {
                return false
            }
        }

        return true
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private func isDepleted(_ remainingPercent: Double?) -> Bool {
        guard let remainingPercent else { return false }
        return remainingPercent <= 0
    }
}

private enum CLIFallbackGroup: Equatable {
    case provider(AgentProvider)
    case isolatedCLI(SwitcherCLIProfileType)
}
