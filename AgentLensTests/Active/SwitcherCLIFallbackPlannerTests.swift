import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class SwitcherCLIFallbackPlannerTests: XCTestCase {
    func testOrderedCandidates_staysWithinSameProviderAndCapabilityClass() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }
        let requested = makeCLIProfile(
            id: "requested",
            cliType: .codex,
            label: "Requested",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro"
        )
        let sameClass = makeCLIProfile(
            id: "same-class",
            cliType: .codex,
            label: "Same Class",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro"
        )
        let differentClass = makeCLIProfile(
            id: "different-class",
            cliType: .codex,
            label: "Different Class",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-base",
            subscriptionTierID: "openai-gpt-base"
        )
        let differentProvider = makeCLIProfile(
            id: "different-provider",
            cliType: .codex,
            label: "Different Provider",
            providerID: .anthropic,
            capabilityClassID: "anthropic:sonnet",
            subscriptionTierID: "claude-max"
        )

        let ordered = await planner.orderedCandidates(
            for: requested,
            allProfiles: [requested, sameClass, differentClass, differentProvider]
        )

        XCTAssertEqual(ordered.map(\.id), ["requested", "same-class"])
    }

    func testOrderedCandidates_skipsNeverAutoSwitchFallbackProfiles() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }
        let requested = makeCLIProfile(
            id: "requested",
            cliType: .codex,
            label: "Requested",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro"
        )
        let noAutoSwitch = makeCLIProfile(
            id: "no-auto-switch",
            cliType: .codex,
            label: "No Auto",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro",
            neverAutoSwitch: true
        )

        let ordered = await planner.orderedCandidates(
            for: requested,
            allProfiles: [requested, noAutoSwitch]
        )

        XCTAssertEqual(ordered.map(\.id), ["requested"])
    }

    func testEligibility_marksExhaustedWhenProfileIsInExhaustionWindow() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }
        let profile = makeCLIProfile(
            id: "exhausted",
            cliType: .codex,
            label: "Exhausted",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro",
            exhaustedUntil: Date().addingTimeInterval(60),
            lastQuotaExhaustionDetail: "5-hour limit reached"
        )

        let eligibility = await planner.eligibility(for: profile)
        XCTAssertEqual(eligibility, .quotaExhausted(reason: "5-hour limit reached"))
    }

    func testEligibility_usesQuotaLookupWhenRemainingPercentIsZero() async {
        let planner = SwitcherCLIFallbackPlanner { _ in
            CLIFallbackQuotaStatus(
                fiveHourRemainingPercent: 0,
                weeklyRemainingPercent: 5,
                statusMessage: "No quota remaining."
            )
        }
        let profile = makeCLIProfile(
            id: "quota-lookup",
            cliType: .codex,
            label: "Quota lookup",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro"
        )

        let eligibility = await planner.eligibility(for: profile)
        XCTAssertEqual(eligibility, .quotaExhausted(reason: "No quota remaining."))
    }

    private func makeCLIProfile(
        id: String,
        cliType: SwitcherCLIProfileType,
        label: String,
        providerID: ProviderID,
        capabilityClassID: String,
        subscriptionTierID: String,
        neverAutoSwitch: Bool = false,
        exhaustedUntil: Date? = nil,
        lastQuotaExhaustionDetail: String? = nil
    ) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: label,
                providerID: providerID,
                subscriptionTierID: subscriptionTierID,
                modelCapabilityClassID: capabilityClassID,
                neverAutoSwitch: neverAutoSwitch,
                exhaustedUntil: exhaustedUntil,
                lastQuotaExhaustionDetail: lastQuotaExhaustionDetail
            ),
            sortKey: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
