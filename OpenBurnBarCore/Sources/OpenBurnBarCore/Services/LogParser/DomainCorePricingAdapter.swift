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
            ParserDiagnostics.silentFailure("domain_core.pricing.abi_mismatch")
            return legacy()
        }
        let rust = OpenBurnBarDomainCoreFFI.calculateTokenCost(
            rates: TokenPricingRates(
                inputPerMToken: inputPerMToken,
                outputPerMToken: outputPerMToken,
                cacheCreationPerMToken: cacheCreationPerMToken,
                cacheReadPerMToken: cacheReadPerMToken
            ),
            buckets: TokenPricingBuckets(
                inputTokens: Double(inputTokens),
                outputTokens: Double(outputTokens),
                cacheCreationTokens: Double(cacheCreationTokens),
                cacheReadTokens: Double(cacheReadTokens)
            )
        )
        if mode == .rust { return rust }
        let swift = legacy()
        if !approximatelyEqual(swift, rust) {
            ParserDiagnostics.silentFailure("domain_core.pricing.shadow_mismatch")
        }
        return swift
        #else
        ParserDiagnostics.silentFailure("domain_core.pricing.native_unavailable")
        return legacy()
        #endif
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        let tolerance = max(0.000_000_000_001, abs(lhs) * 0.000_000_000_001)
        return abs(lhs - rhs) <= tolerance
    }

}
