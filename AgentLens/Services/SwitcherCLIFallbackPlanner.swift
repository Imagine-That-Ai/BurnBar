import Foundation
import OpenBurnBarCore

struct CLIFallbackQuotaStatus: Sendable {
    let fiveHourRemainingPercent: Double?
    let weeklyRemainingPercent: Double?
    let statusMessage: String?
}

struct SwitcherCLIFallbackPlanner: CLIFallbackPlanning {
    let quotaLookup: @Sendable (SwitcherCLIProfileType) async -> CLIFallbackQuotaStatus?

    init(
        quotaLookup: @escaping @Sendable (SwitcherCLIProfileType) async -> CLIFallbackQuotaStatus?
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

        guard let requestedIndex = matchingProfiles.firstIndex(where: { $0.id == requestedProfile.id }) else {
            return matchingProfiles
        }

        return [matchingProfiles[requestedIndex]]
            + matchingProfiles.enumerated()
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
            return nil
        }
    }
}

private enum CLIFallbackGroup: Equatable {
    case provider(AgentProvider)
    case isolatedCLI(SwitcherCLIProfileType)
}
