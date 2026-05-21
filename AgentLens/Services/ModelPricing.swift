import Foundation

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif

struct ModelPricing {
    let inputPerMToken: Double
    let outputPerMToken: Double
    let cacheCreationPerMToken: Double?
    let cacheReadPerMToken: Double

    init(
        inputPerMToken: Double,
        outputPerMToken: Double,
        cacheReadPerMToken: Double
    ) {
        self.init(
            inputPerMToken: inputPerMToken,
            outputPerMToken: outputPerMToken,
            cacheReadPerMToken: cacheReadPerMToken,
            cacheCreationPerMToken: nil
        )
    }

    init(
        inputPerMToken: Double,
        outputPerMToken: Double,
        cacheReadPerMToken: Double,
        cacheCreationPerMToken: Double?
    ) {
        self.inputPerMToken = inputPerMToken
        self.outputPerMToken = outputPerMToken
        self.cacheCreationPerMToken = cacheCreationPerMToken
        self.cacheReadPerMToken = cacheReadPerMToken
    }

    static func lookup(model: String) -> ModelPricing {
        let normalizedModel = TokenExtractionUtility.normalizeModelName(model)
        #if canImport(OpenBurnBarCore)
        return ModelPricing(OpenBurnBarCatalogLookup.shared.pricing(forModelName: normalizedModel) ?? .defaultFallback)
        #else
        return .fallback
        #endif
    }

    static func hasCatalogPricing(model: String) -> Bool {
        let normalizedModel = TokenExtractionUtility.normalizeModelName(model)
        #if canImport(OpenBurnBarCore)
        return OpenBurnBarCatalogLookup.shared.pricing(forModelName: normalizedModel) != nil
        #else
        return false
        #endif
    }

    func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0
    ) -> Double {
        let cacheCreationRate = cacheCreationPerMToken ?? inputPerMToken
        return Double(inputTokens) / 1_000_000 * inputPerMToken
            + Double(outputTokens) / 1_000_000 * outputPerMToken
            + Double(cacheCreationTokens) / 1_000_000 * cacheCreationRate
            + Double(cacheReadTokens) / 1_000_000 * cacheReadPerMToken
    }
}

private extension ModelPricing {
    #if canImport(OpenBurnBarCore)
    init(_ pricing: BurnBarModelPricing) {
        self.init(
            inputPerMToken: pricing.inputPerMToken,
            outputPerMToken: pricing.outputPerMToken,
            cacheReadPerMToken: pricing.cacheReadPerMToken,
            cacheCreationPerMToken: pricing.cacheCreationPerMToken
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
