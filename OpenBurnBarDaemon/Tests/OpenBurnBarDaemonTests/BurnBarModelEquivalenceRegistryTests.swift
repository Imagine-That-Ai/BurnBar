import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarDaemon

final class BurnBarModelEquivalenceRegistryTests: XCTestCase {
    func testExactCanonicalResolutionNeverCrossesFormatFamilies() {
        let registry = BurnBarModelEquivalenceRegistry(catalog: makeCatalog())

        XCTAssertNil(registry.exactCanonicalModelID(for: "smart-model"))
        XCTAssertEqual(
            registry.exactCanonicalModelID(for: "smart-model", requestedFormatFamily: .openaiCompat),
            "openai:gpt-5"
        )
        XCTAssertEqual(
            registry.exactCanonicalModelID(for: "smart-model", requestedFormatFamily: .anthropic),
            "anthropic:claude-opus"
        )
    }

    func testBenchmarkBandsAreScopedToFormatFamily() {
        let registry = BurnBarModelEquivalenceRegistry(catalog: makeCatalog())

        XCTAssertNil(registry.benchmarkBandID(for: "smart-model"))
        XCTAssertEqual(registry.benchmarkBandID(for: "smart-model", requestedFormatFamily: .openaiCompat), "frontier")
        XCTAssertEqual(registry.benchmarkBandID(for: "smart-model", requestedFormatFamily: .anthropic), "standard")
    }

    func testResolutionPrefersExactCanonicalOverClassAndBenchmarkBand() {
        let registry = BurnBarModelEquivalenceRegistry(catalog: makeCatalog())

        let resolution = registry.resolution(for: "smart-model", requestedFormatFamily: .openaiCompat)

        XCTAssertEqual(resolution?.tier, .exactCanonical)
        XCTAssertEqual(resolution?.identifier, "openai:gpt-5")
        XCTAssertEqual(resolution?.formatFamily, .openaiCompat)
    }

    private func makeCatalog() -> BurnBarCatalog {
        BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "openai",
                    displayName: "OpenAI",
                    baseURL: "https://api.openai.com/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "gpt-5",
                            displayName: "GPT-5",
                            visibility: .public,
                            aliases: ["smart-model"],
                            pricing: .defaultFallback,
                            canonicalModelID: "openai:gpt-5",
                            capabilityClassID: "frontier-text",
                            capabilityClassRank: 5
                        )
                    ],
                    formatFamily: .openaiCompat
                ),
                BurnBarCatalogProvider(
                    id: "anthropic",
                    displayName: "Anthropic",
                    baseURL: "https://api.anthropic.com/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "claude-opus",
                            displayName: "Claude Opus",
                            visibility: .public,
                            aliases: ["smart-model"],
                            pricing: .defaultFallback,
                            canonicalModelID: "anthropic:claude-opus",
                            capabilityClassID: "frontier-text",
                            capabilityClassRank: 40
                        )
                    ],
                    formatFamily: .anthropic
                )
            ]
        )
    }
}
