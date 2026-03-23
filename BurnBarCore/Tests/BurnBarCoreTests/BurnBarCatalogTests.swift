import XCTest
@testable import BurnBarCore

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
}
