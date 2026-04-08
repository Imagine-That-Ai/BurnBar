import Foundation

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif

struct ModelPricing {
    let inputPerMToken: Double
    let outputPerMToken: Double
    let cacheReadPerMToken: Double

    static func lookup(model: String) -> ModelPricing {
        #if canImport(OpenBurnBarCore)
        ModelPricing(OpenBurnBarCatalogLookup.shared.pricing(forModelName: model) ?? .defaultFallback)
        #else
        .fallback
        #endif
    }

    func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0
    ) -> Double {
        Double(inputTokens) / 1_000_000 * inputPerMToken
            + Double(outputTokens) / 1_000_000 * outputPerMToken
            + Double(cacheCreationTokens) / 1_000_000 * inputPerMToken
            + Double(cacheReadTokens) / 1_000_000 * cacheReadPerMToken
    }
}

private extension ModelPricing {
    #if canImport(OpenBurnBarCore)
    init(_ pricing: BurnBarModelPricing) {
        self.init(
            inputPerMToken: pricing.inputPerMToken,
            outputPerMToken: pricing.outputPerMToken,
            cacheReadPerMToken: pricing.cacheReadPerMToken
        )
    }
    #endif

    static let fallback = ModelPricing(
        inputPerMToken: 2.5,
        outputPerMToken: 10,
        cacheReadPerMToken: 1.25
    )
}

private struct OpenBurnBarCatalogLookup {
    static let shared: OpenBurnBarCatalogLookup = OpenBurnBarCatalogLookup()

    #if canImport(OpenBurnBarCore)
    private let catalog: BurnBarCatalog?
    #endif

    private init() {
        #if canImport(OpenBurnBarCore)
        self.catalog = try? BurnBarCatalogLoader.loadBundledCatalog()
        #endif
    }

    #if canImport(OpenBurnBarCore)
    func pricing(forModelName modelName: String) -> BurnBarModelPricing? {
        catalog?.pricing(forModelName: modelName)
    }
    #endif
}
