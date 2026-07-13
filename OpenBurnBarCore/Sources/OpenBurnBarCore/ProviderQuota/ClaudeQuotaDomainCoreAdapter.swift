import Foundation

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum DomainCoreQuotaMigrationMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static func resolve(environment: [String: String]) -> Self {
        guard let raw = environment["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE"]?.lowercased() else {
            return .legacy
        }
        return Self(rawValue: raw) ?? .legacy
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

    private static let windowCandidates: [(key: String, label: String, kind: ProviderQuotaWindowKind)] = [
        ("five_hour", "5-hour window", .rollingHours),
        ("seven_day", "7-day window", .rollingDays),
        ("seven_day_sonnet", "7-day Sonnet window", .rollingDays),
        ("seven_day_opus", "7-day Opus window", .rollingDays),
        ("seven_day_oauth_apps", "7-day OAuth Apps window", .rollingDays)
    ]

    static func buckets(
        from rateLimits: ClaudeRateLimits,
        environment: [String: String],
        quotaLogger: any QuotaLogger
    ) -> [ProviderQuotaBucket] {
        let mode = DomainCoreQuotaMigrationMode.resolve(environment: environment)
        guard mode != .legacy else { return legacyBuckets(from: rateLimits) }

        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            quotaLogger.log("domain_core.claude_quota.abi_mismatch")
            return legacyBuckets(from: rateLimits)
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: rateLimits.rawDictionary) else {
            quotaLogger.log("domain_core.claude_quota.payload_encode_failed")
            return legacyBuckets(from: rateLimits)
        }

        let result = OpenBurnBarDomainCoreFFI.parseClaudeStatuslineQuota(payload: payload)
        let rust = result.status == .parsed
            ? result.snapshot.buckets.map(mapBucket)
            : []

        if mode == .shadow {
            let legacy = legacyBuckets(from: rateLimits)
            if !equivalent(legacy, rust) {
                quotaLogger.log(
                    "domain_core.claude_quota.shadow_mismatch core=\(OpenBurnBarDomainCoreFFI.domainCoreVersion()) legacy_count=\(legacy.count) rust_count=\(rust.count)"
                )
            }
            return legacy
        }
        return rust
        #else
        quotaLogger.log("domain_core.claude_quota.native_unavailable mode=\(mode.rawValue)")
        return legacyBuckets(from: rateLimits)
        #endif
    }

    static func legacyBuckets(from rateLimits: ClaudeRateLimits) -> [ProviderQuotaBucket] {
        windowCandidates.compactMap { key, label, windowKind in
            guard let window = rateLimits.window(named: key) else { return nil }
            guard window.usedPercentage != nil || window.remainingPercentage != nil else {
                return nil
            }
            return ProviderQuotaBucket(
                key: "claude-\(FlexibleQuotaBucketNormalizer.sanitizeKey(key))",
                label: label,
                windowKind: windowKind,
                usedValue: window.usedPercentage,
                limitValue: 100,
                remainingValue: window.remainingPercentage,
                usedPercent: window.usedPercentage,
                resetsAt: window.resetsAt,
                unit: .percent,
                isEstimated: false
            )
        }
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
