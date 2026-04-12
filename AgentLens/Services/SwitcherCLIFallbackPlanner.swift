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
        guard requestedProfile.targetKind == .cli,
              let cliType = requestedProfile.cliType else {
            return [requestedProfile]
        }

        let matchingProfiles = allProfiles.filter { profile in
            profile.targetKind == .cli && profile.cliType == cliType
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
        guard let cliType = profile.cliType,
              let quotaStatus = await quotaLookup(cliType) else {
            return .eligible
        }

        let hasFiveHourQuota = quotaStatus.fiveHourRemainingPercent.map { $0 <= 0 } ?? false
        let hasWeeklyQuota = quotaStatus.weeklyRemainingPercent.map { $0 <= 0 } ?? false

        guard hasFiveHourQuota || hasWeeklyQuota else {
            return .eligible
        }

        let reason = quotaStatus.statusMessage ?? "\(profile.displayName) has no remaining quota."
        return .ineligible(reason: reason)
    }
}
