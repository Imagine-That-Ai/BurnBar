import XCTest
@testable import OpenBurnBarCore

final class BurnBarCatalogTests: XCTestCase {
    func test_bundledCatalog_decodesAndValidates() throws {
        let catalog = BurnBarCatalogLoader.bundledCatalog

        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertNoThrow(try catalog.validate())
        XCTAssertEqual(catalog.provider(id: "zai")?.baseURL, "https://api.z.ai/api/coding/paas/v4")
        XCTAssertEqual(catalog.suggestedModels(forProviderID: "zai").map(\.id), ["glm-5-turbo", "glm-5"])
    }

    func test_catalogPricingLookup_usesMatcherRules() throws {
        let catalog = BurnBarCatalogLoader.bundledCatalog

        let sonnet = try XCTUnwrap(catalog.pricing(forModelName: "claude-3-5-sonnet-20241022"))
        let minimax = try XCTUnwrap(catalog.pricing(forModelName: "MiniMax-M3-pro"))
        let codex = try XCTUnwrap(catalog.pricing(forModelName: "codex-pro"))

        XCTAssertEqual(sonnet.inputPerMToken, 3, accuracy: 0.001)
        XCTAssertEqual(sonnet.outputPerMToken, 15, accuracy: 0.001)
        XCTAssertEqual(minimax.inputPerMToken, 0.69, accuracy: 0.001)
        XCTAssertEqual(codex.outputPerMToken, 12, accuracy: 0.001)
    }

    func test_catalogSupportsConnectorModelsAndRejectsUnknownOnes() {
        let catalog = BurnBarCatalogLoader.bundledCatalog

        XCTAssertTrue(catalog.supportsModel(named: "glm-5-plus", providerID: "zai"))
        XCTAssertTrue(catalog.supportsModel(named: "MiniMax-M3-pro", providerID: "minimax"))
        XCTAssertFalse(catalog.supportsModel(named: "pony-alpha-2", providerID: "zai"))
    }

    func test_capabilityClassID_prefersExplicitClassID() {
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "alpha",
                    displayName: "Alpha",
                    baseURL: "https://alpha.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "alpha-pro",
                            displayName: "Alpha Pro",
                            visibility: .public,
                            aliases: ["alpha-pro-latest"],
                            pricing: BurnBarModelPricing(inputPerMToken: 10, outputPerMToken: 20, cacheReadPerMToken: 1),
                            capabilityClassID: "openai:alpha:pro"
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(
            catalog.capabilityClassID(forModelName: "alpha-pro-latest", providerID: "alpha"),
            "openai:alpha:pro"
        )
    }

    func test_capabilityClassID_fallsBackToModelIDWhenClassMissing() {
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "alpha",
                    displayName: "Alpha",
                    baseURL: "https://alpha.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "alpha-base",
                            displayName: "Alpha Base",
                            visibility: .public,
                            aliases: ["alpha-base-latest"],
                            pricing: BurnBarModelPricing(inputPerMToken: 1, outputPerMToken: 2, cacheReadPerMToken: 0.1)
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(
            catalog.capabilityClassID(forModelName: "alpha-base-latest", providerID: "alpha"),
            "alpha-base"
        )
    }

    func test_bundledCatalog_hasCapabilityClassesForAnthropicModels() {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "claude-opus-4-7", providerID: "anthropic"), "anthropic:opus")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "claude-sonnet-4-6", providerID: "anthropic"), "anthropic:sonnet")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "claude-haiku-4-5", providerID: "anthropic"), "anthropic:haiku")
    }

    func test_bundledCatalog_hasCapabilityClassesForOpenAIModels() {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "gpt-5.4-pro", providerID: "openai"), "openai:pro")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "gpt-5.4", providerID: "openai"), "openai:standard")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "gpt-5.4-mini", providerID: "openai"), "openai:mini")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "o3-pro", providerID: "openai"), "openai:pro")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "o1-pro", providerID: "openai"), "openai:pro")
    }
}
