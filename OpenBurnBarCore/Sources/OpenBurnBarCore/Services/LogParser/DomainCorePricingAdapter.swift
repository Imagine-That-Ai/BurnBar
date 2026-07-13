import Foundation

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum DomainCorePricingMigrationMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static func resolve(environment: [String: String]) -> Self {
        guard let raw = environment["OPENBURNBAR_DOMAIN_CORE_PRICING_MODE"]?.lowercased() else {
            return .legacy
        }
        return Self(rawValue: raw) ?? .legacy
    }
}

enum DomainCorePricingAdapter {
    static let runtimeEnvironment = ProcessInfo.processInfo.environment

    private static let nanoUsdPerUsd = 1_000_000_000.0
    private static let maximumExactlyRepresentableInteger = 9_007_199_254_740_991.0
    private static let shadowMaximumDeltaNanoUsd = 0.500_001

    static var isNativeAvailable: Bool {
        #if canImport(OpenBurnBarDomainCoreFFI)
        true
        #else
        false
        #endif
    }

    static func cost(
        inputPerMToken: Double,
        outputPerMToken: Double,
        cacheCreationPerMToken: Double?,
        cacheReadPerMToken: Double,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        environment: [String: String],
        legacy: () -> Double
    ) -> Double {
        let mode = DomainCorePricingMigrationMode.resolve(environment: environment)
        guard mode != .legacy else { return legacy() }

        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            return rejected(mode: mode, event: "domain_core.pricing.abi_mismatch", legacy: legacy)
        }
        guard let rates = encodeRates(
            inputPerMToken: inputPerMToken,
            outputPerMToken: outputPerMToken,
            cacheCreationPerMToken: cacheCreationPerMToken,
            cacheReadPerMToken: cacheReadPerMToken
        ), let buckets = encodeBuckets(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        ) else {
            return rejected(mode: mode, event: "domain_core.pricing.invalid_input", legacy: legacy)
        }
        do {
            let nanoUsd = try OpenBurnBarDomainCoreFFI.calculateTokenCostNanoUsd(
                rates: rates,
                buckets: buckets
            )
            guard nanoUsd <= UInt64(maximumExactlyRepresentableInteger) else {
                return rejected(mode: mode, event: "domain_core.pricing.inexact_output", legacy: legacy)
            }
            let rust = Double(nanoUsd) / nanoUsdPerUsd
            if mode == .rust { return rust }
            let swift = legacy()
            if !withinShadowBound(legacyUsd: swift, rustNanoUsd: nanoUsd) {
                ParserDiagnostics.silentFailure("domain_core.pricing.shadow_mismatch")
            }
            return swift
        } catch {
            return rejected(mode: mode, event: "domain_core.pricing.arithmetic_rejected", legacy: legacy)
        }
        #else
        return rejected(mode: mode, event: "domain_core.pricing.native_unavailable", legacy: legacy)
        #endif
    }

    #if canImport(OpenBurnBarDomainCoreFFI)
    private static func encodeRates(
        inputPerMToken: Double,
        outputPerMToken: Double,
        cacheCreationPerMToken: Double?,
        cacheReadPerMToken: Double
    ) -> TokenPricingRates? {
        guard let input = encodeRate(inputPerMToken),
              let output = encodeRate(outputPerMToken),
              let cacheRead = encodeRate(cacheReadPerMToken)
        else { return nil }
        let cacheCreation: UInt64?
        if let cacheCreationPerMToken {
            guard let encoded = encodeRate(cacheCreationPerMToken) else { return nil }
            cacheCreation = encoded
        } else {
            cacheCreation = nil
        }
        return TokenPricingRates(
            inputNanoUsdPerMToken: input,
            outputNanoUsdPerMToken: output,
            cacheCreationNanoUsdPerMToken: cacheCreation,
            cacheReadNanoUsdPerMToken: cacheRead
        )
    }

    private static func encodeBuckets(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) -> TokenPricingBuckets? {
        guard inputTokens >= 0, outputTokens >= 0, cacheCreationTokens >= 0, cacheReadTokens >= 0 else {
            return nil
        }
        return TokenPricingBuckets(
            inputTokens: UInt64(inputTokens),
            outputTokens: UInt64(outputTokens),
            cacheCreationTokens: UInt64(cacheCreationTokens),
            cacheReadTokens: UInt64(cacheReadTokens)
        )
    }
    #endif

    private static func encodeRate(_ value: Double) -> UInt64? {
        guard value.isFinite, value >= 0 else { return nil }
        let nanoUsd = value * nanoUsdPerUsd
        guard nanoUsd <= maximumExactlyRepresentableInteger, nanoUsd.rounded() == nanoUsd else { return nil }
        return UInt64(nanoUsd)
    }

    private static func withinShadowBound(legacyUsd: Double, rustNanoUsd: UInt64) -> Bool {
        guard legacyUsd.isFinite else { return false }
        return abs(legacyUsd * nanoUsdPerUsd - Double(rustNanoUsd)) <= shadowMaximumDeltaNanoUsd
    }

    private static func rejected(
        mode: DomainCorePricingMigrationMode,
        event: String,
        legacy: () -> Double
    ) -> Double {
        ParserDiagnostics.silentFailure(event)
        return mode == .shadow ? legacy() : .nan
    }
}
