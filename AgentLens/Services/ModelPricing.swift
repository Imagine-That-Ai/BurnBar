import Foundation

#if canImport(BurnBarCore)
import BurnBarCore
#endif

struct ModelPricing {
    let inputPerMToken: Double
    let outputPerMToken: Double
    let cacheReadPerMToken: Double

    static func lookup(model: String) -> ModelPricing {
        #if canImport(BurnBarCore)
        ModelPricing(BurnBarCatalogLookup.shared.pricing(forModelName: model) ?? .defaultFallback)
        #else
        .fallback
        #endif
    }

    func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) -> Double {
        Double(inputTokens) / 1_000_000 * inputPerMToken
            + Double(outputTokens) / 1_000_000 * outputPerMToken
            + Double(cacheCreationTokens) / 1_000_000 * inputPerMToken
            + Double(cacheReadTokens) / 1_000_000 * cacheReadPerMToken
    }
}

private extension ModelPricing {
    #if canImport(BurnBarCore)
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

private struct BurnBarCatalogLookup {
    static let shared: BurnBarCatalogLookup = BurnBarCatalogLookup()

    #if canImport(BurnBarCore)
    private let catalog: BurnBarCatalog?
    #endif

    private init() {
        #if canImport(BurnBarCore)
        self.catalog = try? BurnBarCatalogLoader.loadBundledCatalog()
        #endif
    }

    #if canImport(BurnBarCore)
    func pricing(forModelName modelName: String) -> BurnBarModelPricing? {
        catalog?.pricing(forModelName: modelName)
    }
    #endif
}
