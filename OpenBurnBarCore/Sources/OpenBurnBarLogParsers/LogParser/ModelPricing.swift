import Foundation

import OpenBurnBarKernel

public struct ModelPricing: Sendable {
    public let inputPerMToken: Double
    public let outputPerMToken: Double
    public let cacheCreationPerMToken: Double?
    public let cacheReadPerMToken: Double

    public init(
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

    public init(
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

    public static func lookup(model: String, providerID: String? = nil) -> ModelPricing {
        let normalizedModel = TokenExtractionUtility.normalizeModelName(model)
        #if canImport(OpenBurnBarKernel)
        let pricing = OpenBurnBarCatalogLookup.shared.pricing(
            forModelName: normalizedModel,
            providerID: providerID
        )
        return ModelPricing(pricing ?? .defaultFallback)
        #else
        return .fallback
        #endif
    }

    public static func hasCatalogPricing(model: String, providerID: String? = nil) -> Bool {
        let normalizedModel = TokenExtractionUtility.normalizeModelName(model)
        #if canImport(OpenBurnBarKernel)
        return OpenBurnBarCatalogLookup.shared.pricing(
            forModelName: normalizedModel,
            providerID: providerID
        ) != nil
        #else
        return false
        #endif
    }

    public func cost(
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
    #if canImport(OpenBurnBarKernel)
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

    #if canImport(OpenBurnBarKernel)
    private let catalog: BurnBarCatalog?
    #endif

    private init() {
        #if canImport(OpenBurnBarKernel)
        self.catalog = try? BurnBarCatalogLoader.loadBundledCatalog() // try?-ok(catalog load has fallback)
        #endif
    }

    #if canImport(OpenBurnBarKernel)
    func pricing(forModelName modelName: String, providerID: String? = nil) -> BurnBarModelPricing? {
        guard let catalog else { return nil }
        if let providerID, let providerPricing = catalog.pricing(forModelName: modelName, providerID: providerID) {
            return providerPricing
        }
        return catalog.pricing(forModelName: modelName)
    }
    #endif
}
