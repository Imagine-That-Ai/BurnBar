import Foundation
import OpenBurnBarKernel

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum DomainCorePricingMigrationMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static func resolve(environment: [String: String]) -> Self {
        Self(rawValue: DomainCoreBuildProfileResolver.mode(for: .pricing, environment: environment).rawValue) ?? .legacy
    }
}

enum DomainCorePricingAdapter {
    struct LegacyMeasurement {
        let value: Double
        let micros: UInt64
    }

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
    ) -> Double? {
        let mode = DomainCorePricingMigrationMode.resolve(environment: environment)
        guard mode != .legacy else { return legacy() }
        let legacyMeasurement = mode == .shadow ? measure(legacy) : nil

        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            return rejected(
                mode: mode,
                event: "domain_core.pricing.abi_mismatch",
                category: "native_error",
                coreVersion: "0.0.0-abi-mismatch",
                legacyMeasurement: legacyMeasurement
            )
        }
        let coreVersion = OpenBurnBarDomainCoreFFI.domainCoreVersion()
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
            return rejected(
                mode: mode,
                event: "domain_core.pricing.invalid_input",
                category: "invalid_result",
                coreVersion: coreVersion,
                legacyMeasurement: legacyMeasurement
            )
        }
        let rustStarted = Date.timeIntervalSinceReferenceDate
        do {
            let nanoUsd = try OpenBurnBarDomainCoreFFI.calculateTokenCostNanoUsd(
                rates: rates,
                buckets: buckets
            )
            guard nanoUsd <= UInt64(maximumExactlyRepresentableInteger) else {
                return rejected(
                    mode: mode,
                    event: "domain_core.pricing.inexact_output",
                    category: "invalid_result",
                    coreVersion: coreVersion,
                    legacyMeasurement: legacyMeasurement
                )
            }
            let rust = Double(nanoUsd) / nanoUsdPerUsd
            if mode == .rust { return rust }
            let rustMicros = elapsedMicros(since: rustStarted)
            guard let legacyMeasurement else { return nil }
            let swift = legacyMeasurement.value
            let matches = withinShadowBound(legacyUsd: swift, rustNanoUsd: nanoUsd)
            if !matches {
                ParserDiagnostics.silentFailure("domain_core.pricing.shadow_mismatch")
            }
            record(
                matches: matches,
                category: matches ? nil : "result_mismatch",
                coreVersion: coreVersion,
                legacyMicros: legacyMeasurement.micros,
                rustMicros: rustMicros,
                recordComparison: DomainCoreShadowComparisonCollector.record
            )
            return swift
        } catch {
            return rejected(
                mode: mode,
                event: "domain_core.pricing.arithmetic_rejected",
                category: "native_error",
                coreVersion: coreVersion,
                legacyMeasurement: legacyMeasurement,
                rustMicros: elapsedMicros(since: rustStarted)
            )
        }
        #else
        return rejected(
            mode: mode,
            event: "domain_core.pricing.native_unavailable",
            category: "native_unavailable",
            coreVersion: "0.0.0-native-unavailable",
            legacyMeasurement: legacyMeasurement
        )
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

    private static func elapsedMicros(since started: TimeInterval) -> UInt64 {
        UInt64(min(600_000_000, max(0, ((Date.timeIntervalSinceReferenceDate - started) * 1_000_000).rounded())))
    }

    static func record(
        matches: Bool,
        category: String?,
        coreVersion: String,
        legacyMicros: UInt64,
        rustMicros: UInt64,
        recordComparison: (DomainCoreShadowComparison) -> Void
    ) {
        recordComparison(.init(
            domain: "pricing",
            slice: "token-cost",
            operation: "calculate_token_cost",
            coreVersion: coreVersion,
            outcome: matches ? "match" : "mismatch",
            mismatchCategory: category,
            legacyMicros: legacyMicros,
            rustMicros: rustMicros
        ))
    }

    static func rejected(
        mode: DomainCorePricingMigrationMode,
        event: String,
        category: String,
        coreVersion: String,
        legacyMeasurement: LegacyMeasurement?,
        rustMicros: UInt64 = 0,
        recordComparison: (DomainCoreShadowComparison) -> Void = DomainCoreShadowComparisonCollector.record
    ) -> Double? {
        ParserDiagnostics.silentFailure(event)
        guard mode == .shadow, let legacyMeasurement else { return nil }
        record(
            matches: false,
            category: category,
            coreVersion: coreVersion,
            legacyMicros: legacyMeasurement.micros,
            rustMicros: rustMicros,
            recordComparison: recordComparison
        )
        return legacyMeasurement.value
    }

    static func measure(_ legacy: () -> Double) -> LegacyMeasurement {
        let started = Date.timeIntervalSinceReferenceDate
        return LegacyMeasurement(value: legacy(), micros: elapsedMicros(since: started))
    }
}
