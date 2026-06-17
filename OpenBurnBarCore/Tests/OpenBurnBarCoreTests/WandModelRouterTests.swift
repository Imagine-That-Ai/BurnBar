import XCTest
@testable import OpenBurnBarCore

final class WandModelRouterTests: XCTestCase {
    func test_highestCapabilityPrefersHighestCapabilityModelInRuntimeCatalog() {
        let rows = [
            option("claude-haiku-4-5", tier: "small", providerID: "anthropic", source: .claudeModelCatalog),
            option("claude-opus-4-8", tier: "flagship", providerID: "anthropic", source: .claudeModelCatalog),
            option("claude-sonnet-4-6", tier: "mid", providerID: "anthropic", source: .claudeModelCatalog)
        ]

        let selected = WandModelRouter.select(
            selector: .highestCapability,
            runtimes: [.claude],
            catalogs: [.claude: rows]
        )

        XCTAssertEqual(selected.map(\.requestedModelID), ["claude-opus-4-8"])
    }

    func test_paretoPrefersLocalQuotaBeforeProxyEvenWhenProxyIsFlagship() {
        let rows = [
            option("openburnbar/claude-opus-4-8", tier: "flagship", providerID: "anthropic", source: .openBurnBarProxy),
            option("gpt-5.5", tier: "mid", providerID: "openai", source: .codexModelCatalog),
            option("codex-default", tier: "small", providerID: "openai", source: .cliProfile)
        ]

        let selected = WandModelRouter.select(
            selector: .pareto,
            runtimes: [.codex],
            catalogs: [.codex: rows]
        )

        XCTAssertEqual(selected.map(\.requestedModelID), ["codex-default"])
    }

    func test_policyEmitsConcretePerRuntimeRoutedModels() {
        let policy = WandModelRouter.policy(
            selector: .highestCapability,
            runtimes: [.codex, .claude],
            catalogs: [
                .codex: [
                    option("gpt-5.5", tier: "flagship", providerID: "openai", source: .codexModelCatalog)
                ],
                .claude: [
                    option("claude-opus-4-8", tier: "flagship", providerID: "anthropic", source: .claudeModelCatalog)
                ]
            ]
        )

        XCTAssertEqual(policy.selector, .highestCapability)
        XCTAssertEqual(policy.routedModelID(for: .codex), "gpt-5.5")
        XCTAssertEqual(policy.routedModelID(for: .claude), "claude-opus-4-8")
    }

    func test_providerDiversityFallsBackOnlyWhenNoAlternativeProviderExists() {
        let selected = WandModelRouter.select(
            selector: .highestCapability,
            runtimes: [.codex, .claude],
            catalogs: [
                .codex: [
                    option("gpt-5.5", tier: "flagship", providerID: "openai", source: .codexModelCatalog)
                ],
                .claude: [
                    option("openai-via-claude", tier: "flagship", providerID: "openai", source: .openBurnBarProxy),
                    option("claude-sonnet-4-6", tier: "mid", providerID: "anthropic", source: .claudeModelCatalog)
                ]
            ],
            requireProviderDiversity: true
        )

        XCTAssertEqual(selected.map(\.requestedModelID), ["gpt-5.5", "claude-sonnet-4-6"])
        XCTAssertEqual(selected.map(\.providerDiversityRelaxed), [false, false])
    }

    private func option(
        _ modelID: String,
        tier: String,
        providerID: String,
        source: CLIRuntimeModelSource
    ) -> CLIRuntimeModelOption {
        CLIRuntimeModelOption(
            modelID: modelID,
            displayName: modelID,
            providerID: providerID,
            providerName: providerID,
            tier: tier,
            source: source
        )
    }
}
