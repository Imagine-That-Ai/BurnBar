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

    static func lookup(model: String, providerID: String? = nil) -> ModelPricing {
        let normalizedModel = TokenExtractionUtility.normalizeModelName(model)
        #if canImport(OpenBurnBarCore)
        let pricing = OpenBurnBarCatalogLookup.shared.pricing(
            forModelName: normalizedModel,
            providerID: providerID
        )
        return ModelPricing(pricing ?? .defaultFallback)
        #else
        return .fallback
        #endif
    }

    static func hasCatalogPricing(model: String, providerID: String? = nil) -> Bool {
        let normalizedModel = TokenExtractionUtility.normalizeModelName(model)
        #if canImport(OpenBurnBarCore)
        return OpenBurnBarCatalogLookup.shared.pricing(
            forModelName: normalizedModel,
            providerID: providerID
        ) != nil
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
    static let shared = OpenBurnBarCatalogLookup()

    #if canImport(OpenBurnBarCore)
    private let catalog: BurnBarCatalog?
    #endif

    private init() {
        #if canImport(OpenBurnBarCore)
        self.catalog = try? BurnBarCatalogLoader.loadBundledCatalog()
        #endif
    }

    #if canImport(OpenBurnBarCore)
    func pricing(forModelName modelName: String, providerID: String? = nil) -> BurnBarModelPricing? {
        guard let catalog else { return nil }
        if let providerID, let providerPricing = catalog.pricing(forModelName: modelName, providerID: providerID) {
            return providerPricing
        }
        return catalog.pricing(forModelName: modelName)
    }
    #endif
}
