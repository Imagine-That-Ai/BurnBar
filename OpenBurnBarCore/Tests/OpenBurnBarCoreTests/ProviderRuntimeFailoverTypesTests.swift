import XCTest
@testable import OpenBurnBarCore

final class ProviderRuntimeFailoverTypesTests: XCTestCase {
    func testTierCompatible_requiresExactTierByDefault() {
        XCTAssertTrue(
            ProviderRuntimeFailoverPolicy.tierCompatible(
                requestedTierID: "openai-gpt-pro",
                candidateTierID: "openai-gpt-pro",
                allowDowngrade: false
            )
        )
        XCTAssertFalse(
            ProviderRuntimeFailoverPolicy.tierCompatible(
                requestedTierID: "openai-gpt-pro",
                candidateTierID: "openai-gpt-base",
                allowDowngrade: false
            )
        )
    }

    func testTierCompatible_allowsDowngradeWhenExplicitlyEnabled() {
        XCTAssertTrue(
            ProviderRuntimeFailoverPolicy.tierCompatible(
                requestedTierID: "openai-gpt-pro",
                candidateTierID: "openai-gpt-base",
                allowDowngrade: true
            )
        )
    }

    func testIsAccountEligible_requiresSameProviderAndBoundRuntimeIdentity() {
        let account = ProviderRuntimeAccount(
            accountID: "work",
            providerID: .openAI,
            subscriptionTierID: "openai-gpt-pro",
            credentialRef: "slot-work",
            storageScope: .deviceKeychain,
            linkedDaemonSlotID: "slot-work",
            linkedHarnessIDs: ["droid", "codex"]
        )
        XCTAssertTrue(
            ProviderRuntimeFailoverPolicy.isAccountEligible(
                account,
                forProvider: .openAI,
                capabilityClassID: "openai:gpt-5.5:pro",
                requestedSubscriptionTierID: "openai-gpt-pro"
            )
        )
        XCTAssertFalse(
            ProviderRuntimeFailoverPolicy.isAccountEligible(
                account,
                forProvider: .anthropic,
                capabilityClassID: "anthropic:opus",
                requestedSubscriptionTierID: "claude-max"
            )
        )
    }

    func testModelCapabilityClass_matchesCanonicalAndAlias() {
        let modelClass = ModelCapabilityClass(
            providerID: .openAI,
            formatFamily: .openaiCompat,
            classID: "openai:gpt-5.5:pro",
            canonicalModelIDs: ["gpt-5.5"],
            aliases: ["gpt-5.5-latest"]
        )
        XCTAssertTrue(modelClass.matches(modelID: "gpt-5.5"))
        XCTAssertTrue(modelClass.matches(modelID: "gpt-5.5-latest"))
        XCTAssertFalse(modelClass.matches(modelID: "gpt-4.1"))
    }
}
