import Foundation
// Merge (train ← origin/main) AE-IMPORT: P-13 moved this file (main's #1590 adapter) from
// the Core monolith into OpenBurnBarQuota. The `ProviderQuotaBucket` / `ProviderQuotaWindowKind`
// / `ProviderQuotaUnit` types it returns live in OpenBurnBarKernel (SharedModels), so the file
// needs an explicit Kernel import in its new home — identical to the sibling ClaudeQuotaAdapter /
// XAIQuotaAdapter / CodexQuotaAdapter, which already import OpenBurnBarKernel.
import OpenBurnBarKernel

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum DomainCoreQuotaMigrationMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static func resolve(environment: [String: String]) -> Self {
        Self(rawValue: DomainCoreBuildProfileResolver.mode(for: .quota, environment: environment).rawValue) ?? .legacy
    }
}

enum ClaudeQuotaDomainCoreAdapter {
    static var isNativeAvailable: Bool {
        #if canImport(OpenBurnBarDomainCoreFFI)
        true
        #else
        false
        #endif
    }

    static func buckets(
        from rateLimits: ClaudeRateLimits,
        environment: [String: String],
        quotaLogger: any QuotaLogger,
        shadowLegacyProbe: (() -> [ProviderQuotaBucket])? = nil,
        shadowRustProbe: (() throws -> ([ProviderQuotaBucket], Bool))? = nil
    ) -> [ProviderQuotaBucket] {
        let mode = DomainCoreQuotaMigrationMode.resolve(environment: environment)
        guard mode != .legacy else { return ClaudeQuotaLegacy.buckets(from: rateLimits) }

        #if canImport(OpenBurnBarDomainCoreFFI)
        if mode == .shadow {
            let legacyMeasurement = DomainCoreQuotaShadowTiming.measure {
                shadowLegacyProbe?() ?? ClaudeQuotaLegacy.buckets(from: rateLimits)
            }
            let rustMeasurement = DomainCoreQuotaShadowTiming.measureResult {
                if let shadowRustProbe { return try shadowRustProbe() }
                let payload = try JSONSerialization.data(withJSONObject: rateLimits.rawDictionary)
                guard try SafeQuotaFFI.domainCoreAbiVersion() == 3 else {
                    throw DomainCoreQuotaShadowProbeError.nativeUnavailable
                }
                let result = try SafeQuotaFFI.parseClaudeStatuslineQuota(payload: payload)
                let buckets = result.status == .parsed
                    ? result.snapshot.buckets.map(mapBucket)
                    : []
                return (buckets, result.status == .malformed)
            }
            var rustCount = 0
            let category = DomainCoreQuotaShadowCategory.classify(rustMeasurement.result) { rustBuckets in
                rustCount = rustBuckets.count
                return equivalent(legacyMeasurement.value, rustBuckets)
            }
            if category != nil {
                quotaLogger.log(
                    "domain_core.claude_quota.shadow_mismatch core=\(DomainCoreQuotaConsumerSupport.safeCoreVersion()) legacy_count=\(legacyMeasurement.value.count) rust_count=\(rustCount)"
                )
            }
            quotaLogger.recordDomainCoreShadowComparison(DomainCoreQuotaShadowComparison(
                operation: "claude_quota",
                coreVersion: DomainCoreQuotaConsumerSupport.safeCoreVersion(),
                observedAt: Date(),
                outcome: category == nil ? .match : .mismatch,
                mismatchCategory: category,
                legacyMicros: legacyMeasurement.micros,
                rustMicros: rustMeasurement.micros
            ))
            return legacyMeasurement.value
        }
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            quotaLogger.log("domain_core.claude_quota.abi_mismatch")
            return []
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: rateLimits.rawDictionary) else {
            quotaLogger.log("domain_core.claude_quota.payload_encode_failed")
            return mode == .shadow ? ClaudeQuotaLegacy.buckets(from: rateLimits) : []
        }

        let result = OpenBurnBarDomainCoreFFI.parseClaudeStatuslineQuota(payload: payload)
        return result.status == .parsed ? result.snapshot.buckets.map(mapBucket) : []
        #else
        if mode == .shadow {
            let legacyMeasurement = DomainCoreQuotaShadowTiming.measure {
                shadowLegacyProbe?() ?? ClaudeQuotaLegacy.buckets(from: rateLimits)
            }
            let rustMeasurement = DomainCoreQuotaShadowTiming.measureResult {
                guard let shadowRustProbe else {
                    throw DomainCoreQuotaShadowProbeError.nativeUnavailable
                }
                return try shadowRustProbe()
            }
            var rustCount = 0
            let category = DomainCoreQuotaShadowCategory.classify(rustMeasurement.result) { rustBuckets in
                rustCount = rustBuckets.count
                return equivalent(legacyMeasurement.value, rustBuckets)
            }
            if category == .nativeUnavailable {
                quotaLogger.log("domain_core.claude_quota.native_unavailable mode=shadow")
            } else if category != nil {
                quotaLogger.log(
                    "domain_core.claude_quota.shadow_mismatch core=0.0.0-unavailable legacy_count=\(legacyMeasurement.value.count) rust_count=\(rustCount)"
                )
            }
            quotaLogger.recordDomainCoreShadowComparison(DomainCoreQuotaShadowComparison(
                operation: "claude_quota",
                coreVersion: "0.0.0-unavailable",
                observedAt: Date(),
                outcome: category == nil ? .match : .mismatch,
                mismatchCategory: category,
                legacyMicros: legacyMeasurement.micros,
                rustMicros: rustMeasurement.micros
            ))
            return legacyMeasurement.value
        }
        quotaLogger.log("domain_core.claude_quota.native_unavailable mode=\(mode.rawValue)")
        return []
        #endif
    }

    #if canImport(OpenBurnBarDomainCoreFFI)
    private static func mapBucket(_ bucket: OpenBurnBarDomainCoreFFI.QuotaBucket) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: bucket.key,
            label: bucket.label,
            windowKind: mapWindowKind(bucket.windowKind),
            usedValue: bucket.usedValue,
            limitValue: bucket.limitValue,
            remainingValue: bucket.remainingValue,
            usedPercent: bucket.usedPercent,
            resetsAt: bucket.resetsAtUnix.map { Date(timeIntervalSince1970: $0) },
            unit: mapUnit(bucket.unit),
            isEstimated: bucket.isEstimated
        )
    }

    private static func mapWindowKind(
        _ kind: OpenBurnBarDomainCoreFFI.QuotaWindowKind
    ) -> ProviderQuotaWindowKind {
        switch kind {
        case .rollingHours: .rollingHours
        case .rollingDays: .rollingDays
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .lifetime: .lifetime
        case .custom: .custom
        }
    }

    private static func mapUnit(_ unit: OpenBurnBarDomainCoreFFI.QuotaUnit) -> ProviderQuotaUnit {
        switch unit {
        case .percent: .percent
        case .requests: .requests
        case .tokens: .tokens
        case .sessions: .sessions
        case .lines: .lines
        case .files: .files
        case .count: .count
        case .currency: .currency
        }
    }
    #endif

    private static func equivalent(
        _ lhs: [ProviderQuotaBucket],
        _ rhs: [ProviderQuotaBucket]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.key == right.key
                && left.label == right.label
                && left.windowKind == right.windowKind
                && approximatelyEqual(left.usedValue, right.usedValue)
                && approximatelyEqual(left.limitValue, right.limitValue)
                && approximatelyEqual(left.remainingValue, right.remainingValue)
                && approximatelyEqual(left.usedPercent, right.usedPercent)
                && approximatelyEqual(
                    left.resetsAt?.timeIntervalSince1970,
                    right.resetsAt?.timeIntervalSince1970,
                    tolerance: 0.001
                )
                && left.unit == right.unit
                && left.isEstimated == right.isEstimated
        }
    }

    private static func approximatelyEqual(
        _ lhs: Double?,
        _ rhs: Double?,
        tolerance: Double = 0.000_001
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (.some(left), .some(right)): abs(left - right) <= tolerance
        default: false
        }
    }
}
