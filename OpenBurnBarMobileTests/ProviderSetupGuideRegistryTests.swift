import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

/// Guards that the curated provider-setup copy used by both the wizard and
/// the manual sheet stays complete. Every shipped provider must answer
/// "where do I find the credential?" — silent gaps would leave first-run
/// users stuck on a blank screen.
final class ProviderSetupGuideRegistryTests: XCTestCase {

    func testEveryProviderHasGuide() {
        for provider in AgentProvider.allCases {
            let guide = ProviderSetupGuide.guide(for: provider)
            XCTAssertEqual(guide.provider, provider, "Guide returned wrong provider for \(provider.displayName)")
            XCTAssertFalse(guide.kinds.isEmpty, "\(provider.displayName) guide must declare at least one credential kind")
            XCTAssertTrue(guide.kinds.contains(guide.defaultKind), "\(provider.displayName) defaultKind must be in `kinds`")
            XCTAssertFalse(guide.oneLineHint.isEmpty, "\(provider.displayName) must have a one-line hint")
            XCTAssertFalse(guide.labelSuggestion.isEmpty, "\(provider.displayName) must suggest an account label")
            XCTAssertFalse(guide.credentialPlaceholder.isEmpty, "\(provider.displayName) must have a credential placeholder")
            XCTAssertFalse(guide.credentialFooterMarkdown.isEmpty, "\(provider.displayName) must have a footer markdown")
            XCTAssertFalse(guide.dashboardCTA.isEmpty, "\(provider.displayName) must have a dashboard CTA label")
            XCTAssertGreaterThanOrEqual(guide.instructions.count, 2, "\(provider.displayName) must have at least 2 setup steps")
            for step in guide.instructions {
                XCTAssertGreaterThan(step.number, 0)
                XCTAssertFalse(step.title.isEmpty, "Empty step title in \(provider.displayName) guide")
            }
        }
    }

    func testInstructionsAreNumberedSequentially() {
        for provider in AgentProvider.allCases {
            let guide = ProviderSetupGuide.guide(for: provider)
            let numbers = guide.instructions.map(\.number)
            XCTAssertEqual(numbers, Array(1...numbers.count), "Step numbers for \(provider.displayName) must be 1…N sequentially")
        }
    }

    func testHostedSelfHostedSupportMatchesAdapterCapabilities() {
        // Codex is the only hosted-supporting provider in `AddProviderConnectionView`'s
        // legacy gate; Claude Code + Codex both support self-hosted runners. The
        // wizard reads these flags from `ProviderSetupGuide`, so they must
        // mirror the backend reality.
        let codex = ProviderSetupGuide.guide(for: .codex)
        XCTAssertTrue(codex.supportsHosted, "Codex guide must advertise hosted sync")
        XCTAssertTrue(codex.supportsSelfHosted, "Codex guide must advertise self-hosted sync")

        let claude = ProviderSetupGuide.guide(for: .claudeCode)
        XCTAssertTrue(claude.supportsHosted, "Claude Code guide must advertise hosted sync")
        XCTAssertTrue(claude.supportsSelfHosted, "Claude Code guide must advertise self-hosted sync")

        let cursor = ProviderSetupGuide.guide(for: .cursor)
        XCTAssertFalse(cursor.supportsHosted)
        XCTAssertFalse(cursor.supportsSelfHosted)
    }

    func testRecommendedAreAllValidProviders() {
        let cases = Set(AgentProvider.mobileAccountConnectableProviders)
        for recommended in ProviderSetupGuide.recommended {
            XCTAssertTrue(cases.contains(recommended), "Recommended provider \(recommended) must be a valid AgentProvider case")
        }
    }

    func testSortedProvidersForOnboardingPlacesRecommendedFirst() {
        let sorted = ProviderSetupGuide.sortedProvidersForOnboarding()
        XCTAssertEqual(Set(sorted).count, sorted.count, "Sorted list must not contain duplicate providers")
        XCTAssertEqual(sorted.count, AgentProvider.mobileAccountConnectableProviders.count, "Sorted list must contain every mobile-connectable provider")
        XCTAssertFalse(sorted.contains(.hermes), "Hermes has no provider quota account to add from onboarding")
        XCTAssertFalse(sorted.contains(.ollama), "Local Ollama model counts are not quota accounts")
        XCTAssertFalse(sorted.contains(.geminiCLI), "Gemini CLI has no quota credential for mobile onboarding")

        let recommendedSet = Set(ProviderSetupGuide.recommended)
        let firstChunk = Array(sorted.prefix(ProviderSetupGuide.recommended.count))
        for provider in firstChunk {
            XCTAssertTrue(recommendedSet.contains(provider), "Top of list must be recommended; got \(provider.displayName)")
        }
    }
}
