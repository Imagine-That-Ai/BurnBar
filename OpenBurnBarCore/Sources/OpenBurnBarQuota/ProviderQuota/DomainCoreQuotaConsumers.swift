import Foundation
import OpenBurnBarKernel

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum DomainCoreQuotaConsumerError: Error {
    case invalidPayload
    case nativeUnavailable
}

enum DomainCoreQuotaConsumerSupport {
    static var isNativeAvailable: Bool {
        #if canImport(OpenBurnBarDomainCoreFFI)
        true
        #else
        false
        #endif
    }

    static func safeCoreVersion() -> String {
        #if canImport(OpenBurnBarDomainCoreFFI)
        (try? SafeQuotaFFI.domainCoreVersion()) ?? "0.0.0-unavailable"
        #else
        "0.0.0-unavailable"
        #endif
    }

    #if canImport(OpenBurnBarDomainCoreFFI)
    static func snapshot(
        from snapshot: OpenBurnBarDomainCoreFFI.QuotaSnapshot,
        fetchedAt: Date,
        managementURL: String
    ) -> ProviderQuotaSnapshot? {
        guard let provider = provider(snapshot.provider) else { return nil }
        return ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: fetchedAt,
            source: source(snapshot.source),
            confidence: confidence(snapshot.confidence),
            managementURL: managementURL,
            statusMessage: snapshot.statusMessage,
            buckets: snapshot.buckets.map(bucket)
        )
    }

    static func shadowMismatch(
        domain: String,
        legacy: ProviderQuotaSnapshot,
        rust: ProviderQuotaSnapshot?
    ) -> String? {
        guard let rust, equivalent(legacy, rust) else { return diagnostic(domain: domain, legacy: legacy, rust: rust) }
        return nil
    }

    private static func diagnostic(
        domain: String,
        legacy: ProviderQuotaSnapshot,
        rust: ProviderQuotaSnapshot?
    ) -> String {
        "domain_core.\(domain).shadow_mismatch core=\(safeCoreVersion()) legacy_count=\(legacy.buckets.count) rust_count=\(rust?.buckets.count ?? 0)"
    }

    private static func provider(_ value: String) -> AgentProvider? {
        switch value {
        case "codex": .codex
        case "cursor": .cursor
        case "claudeCode": .claudeCode
        default: nil
        }
    }

    private static func source(_ value: OpenBurnBarDomainCoreFFI.QuotaSourceKind) -> ProviderQuotaSourceKind {
        switch value {
        case .officialApi: .officialAPI
        case .localCli: .localCLI
        case .localSession: .localSession
        case .manualEstimate: .manualEstimate
        case .unavailable: .unavailable
        }
    }

    private static func confidence(_ value: OpenBurnBarDomainCoreFFI.QuotaConfidence) -> ProviderQuotaConfidence {
        switch value {
        case .exact: .exact
        case .estimated: .estimated
        case .unavailable: .unavailable
        }
    }

    private static func bucket(_ value: OpenBurnBarDomainCoreFFI.QuotaBucket) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: value.key,
            label: value.label,
            windowKind: windowKind(value.windowKind),
            usedValue: value.usedValue,
            limitValue: value.limitValue,
            remainingValue: value.remainingValue,
            usedPercent: value.usedPercent,
            resetsAt: value.resetsAtUnix.map { Date(timeIntervalSince1970: $0) },
            unit: unit(value.unit),
            isEstimated: value.isEstimated
        )
    }

    private static func windowKind(_ value: OpenBurnBarDomainCoreFFI.QuotaWindowKind) -> ProviderQuotaWindowKind {
        switch value {
        case .rollingHours: .rollingHours
        case .rollingDays: .rollingDays
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .lifetime: .lifetime
        case .custom: .custom
        }
    }

    private static func unit(_ value: OpenBurnBarDomainCoreFFI.QuotaUnit) -> ProviderQuotaUnit {
        switch value {
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

    private static func equivalent(_ lhs: ProviderQuotaSnapshot, _ rhs: ProviderQuotaSnapshot) -> Bool {
        lhs.providerID == rhs.providerID
            && lhs.sourceKind == rhs.sourceKind
            && lhs.confidence == rhs.confidence
            && lhs.statusMessage == rhs.statusMessage
            && bucketsEquivalent(lhs.buckets, rhs.buckets)
    }

    private static func bucketsEquivalent(_ lhs: [ProviderQuotaBucket], _ rhs: [ProviderQuotaBucket]) -> Bool {
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
    #endif
}

enum CodexQuotaDomainCoreAdapter {
    static func snapshot(
        payload: Data,
        now: Date,
        environment: [String: String],
        quotaLogger: any QuotaLogger,
        legacy: () throws -> ProviderQuotaSnapshot
    ) throws -> ProviderQuotaSnapshot {
        let mode = DomainCoreQuotaMigrationMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }

        #if canImport(OpenBurnBarDomainCoreFFI)
        if mode == .shadow {
            let legacyMeasurement = try DomainCoreQuotaShadowTiming.measure(legacy)
            let rustMeasurement = DomainCoreQuotaShadowTiming.measureResult {
                guard try SafeQuotaFFI.domainCoreAbiVersion() == 3 else {
                    throw DomainCoreQuotaShadowProbeError.nativeUnavailable
                }
                let parsed = try SafeQuotaFFI.parseCodexUsageQuota(
                    payload: payload,
                    nowUnix: Int64(now.timeIntervalSince1970)
                )
                let snapshot = parsed.status == .parsed
                    ? DomainCoreQuotaConsumerSupport.snapshot(
                        from: parsed.snapshot,
                        fetchedAt: now,
                        managementURL: "https://chatgpt.com/codex/settings/usage"
                    )
                    : nil
                return (snapshot, parsed.status == .malformed)
            }
            var diagnostic: String?
            let category = DomainCoreQuotaShadowCategory.classify(rustMeasurement.result) { rust in
                diagnostic = DomainCoreQuotaConsumerSupport.shadowMismatch(
                    domain: "codex_quota",
                    legacy: legacyMeasurement.value,
                    rust: rust
                )
                return diagnostic == nil
            }
            if category != nil, diagnostic == nil {
                diagnostic = DomainCoreQuotaConsumerSupport.shadowMismatch(
                    domain: "codex_quota",
                    legacy: legacyMeasurement.value,
                    rust: nil
                )
            }
            if let diagnostic { quotaLogger.log(diagnostic) }
            quotaLogger.recordDomainCoreShadowComparison(DomainCoreQuotaShadowComparison(
                operation: "codex_quota",
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
            quotaLogger.log("domain_core.codex_quota.abi_mismatch")
            throw DomainCoreQuotaConsumerError.nativeUnavailable
        }
        let parsed = OpenBurnBarDomainCoreFFI.parseCodexUsageQuota(
            payload: payload,
            nowUnix: Int64(now.timeIntervalSince1970)
        )
        let rust = parsed.status == .parsed
            ? DomainCoreQuotaConsumerSupport.snapshot(
                from: parsed.snapshot,
                fetchedAt: now,
                managementURL: "https://chatgpt.com/codex/settings/usage"
            )
            : nil
        guard let rust else { throw DomainCoreQuotaConsumerError.invalidPayload }
        return rust
        #else
        quotaLogger.log("domain_core.codex_quota.native_unavailable mode=\(mode.rawValue)")
        if mode == .shadow {
            let legacyMeasurement = try DomainCoreQuotaShadowTiming.measure(legacy)
            quotaLogger.recordDomainCoreShadowComparison(DomainCoreQuotaShadowComparison(
                operation: "codex_quota",
                coreVersion: "0.0.0-unavailable",
                observedAt: Date(),
                outcome: .mismatch,
                mismatchCategory: .nativeUnavailable,
                legacyMicros: legacyMeasurement.micros,
                rustMicros: 0
            ))
            return legacyMeasurement.value
        }
        throw DomainCoreQuotaConsumerError.nativeUnavailable
        #endif
    }
}

enum CursorQuotaDomainCoreAdapter {
    static func snapshot(
        payload: Data,
        userEmail: String?,
        now: Date,
        environment: [String: String],
        quotaLogger: any QuotaLogger,
        legacy: () throws -> ProviderQuotaSnapshot
    ) throws -> ProviderQuotaSnapshot {
        let mode = DomainCoreQuotaMigrationMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }

        #if canImport(OpenBurnBarDomainCoreFFI)
        if mode == .shadow {
            let legacyMeasurement = try DomainCoreQuotaShadowTiming.measure(legacy)
            let rustMeasurement = DomainCoreQuotaShadowTiming.measureResult {
                guard try SafeQuotaFFI.domainCoreAbiVersion() == 3 else {
                    throw DomainCoreQuotaShadowProbeError.nativeUnavailable
                }
                let parsed = try SafeQuotaFFI.parseCursorUsageQuota(payload: payload, userEmail: userEmail)
                let snapshot = parsed.status == .parsed
                    ? DomainCoreQuotaConsumerSupport.snapshot(
                        from: parsed.snapshot,
                        fetchedAt: now,
                        managementURL: "https://cursor.com/dashboard"
                    )
                    : nil
                return (snapshot, parsed.status == .malformed)
            }
            var diagnostic: String?
            let category = DomainCoreQuotaShadowCategory.classify(rustMeasurement.result) { rust in
                diagnostic = DomainCoreQuotaConsumerSupport.shadowMismatch(
                    domain: "cursor_quota",
                    legacy: legacyMeasurement.value,
                    rust: rust
                )
                return diagnostic == nil
            }
            if category != nil, diagnostic == nil {
                diagnostic = DomainCoreQuotaConsumerSupport.shadowMismatch(
                    domain: "cursor_quota",
                    legacy: legacyMeasurement.value,
                    rust: nil
                )
            }
            if let diagnostic { quotaLogger.log(diagnostic) }
            quotaLogger.recordDomainCoreShadowComparison(DomainCoreQuotaShadowComparison(
                operation: "cursor_quota",
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
            quotaLogger.log("domain_core.cursor_quota.abi_mismatch")
            throw DomainCoreQuotaConsumerError.nativeUnavailable
        }
        let parsed = OpenBurnBarDomainCoreFFI.parseCursorUsageQuota(payload: payload, userEmail: userEmail)
        let rust = parsed.status == .parsed
            ? DomainCoreQuotaConsumerSupport.snapshot(
                from: parsed.snapshot,
                fetchedAt: now,
                managementURL: "https://cursor.com/dashboard"
            )
            : nil
        guard let rust else { throw DomainCoreQuotaConsumerError.invalidPayload }
        return rust
        #else
        quotaLogger.log("domain_core.cursor_quota.native_unavailable mode=\(mode.rawValue)")
        if mode == .shadow {
            let legacyMeasurement = try DomainCoreQuotaShadowTiming.measure(legacy)
            quotaLogger.recordDomainCoreShadowComparison(DomainCoreQuotaShadowComparison(
                operation: "cursor_quota",
                coreVersion: "0.0.0-unavailable",
                observedAt: Date(),
                outcome: .mismatch,
                mismatchCategory: .nativeUnavailable,
                legacyMicros: legacyMeasurement.micros,
                rustMicros: 0
            ))
            return legacyMeasurement.value
        }
        throw DomainCoreQuotaConsumerError.nativeUnavailable
        #endif
    }
}

enum AnthropicRateLimitDomainCoreAdapter {
    static func snapshot(
        payload: Data,
        shape: AnthropicCredentialProbe.Shape,
        now: Date,
        environment: [String: String],
        quotaLogger: any QuotaLogger,
        legacy: () -> ProviderQuotaSnapshot?
    ) -> ProviderQuotaSnapshot? {
        let mode = DomainCoreQuotaMigrationMode.resolve(environment: environment)
        guard mode != .legacy else { return legacy() }

        #if canImport(OpenBurnBarDomainCoreFFI)
        let ffiShape: OpenBurnBarDomainCoreFFI.AnthropicCredentialShape = switch shape {
        case .consoleAPIKey: .consoleApiKey
        case .oauthBearer: .oauthBearer
        }
        if mode == .shadow {
            let legacyMeasurement = DomainCoreQuotaShadowTiming.measure(legacy)
            let rustMeasurement = DomainCoreQuotaShadowTiming.measureResult {
                guard try SafeQuotaFFI.domainCoreAbiVersion() == 3 else {
                    throw DomainCoreQuotaShadowProbeError.nativeUnavailable
                }
                let parsed = try SafeQuotaFFI.parseAnthropicRateLimitHeaders(
                    payload: payload,
                    nowUnix: Int64(now.timeIntervalSince1970),
                    shape: ffiShape
                )
                let snapshot = parsed.status == .parsed
                    ? DomainCoreQuotaConsumerSupport.snapshot(
                        from: parsed.snapshot,
                        fetchedAt: now,
                        managementURL: "https://claude.ai/settings/usage"
                    )
                    : nil
                return (snapshot, parsed.status == .malformed)
            }
            var diagnostic: String?
            let category = DomainCoreQuotaShadowCategory.classify(rustMeasurement.result) { rust in
                diagnostic = legacyMeasurement.value.map {
                    DomainCoreQuotaConsumerSupport.shadowMismatch(
                        domain: "anthropic_ratelimit",
                        legacy: $0,
                        rust: rust
                    )
                } ?? rust.map {
                    "domain_core.anthropic_ratelimit.shadow_mismatch core=\(DomainCoreQuotaConsumerSupport.safeCoreVersion()) legacy_count=0 rust_count=\($0.buckets.count)"
                }
                return diagnostic == nil
            }
            if category != nil, diagnostic == nil {
                diagnostic = legacyMeasurement.value.map {
                    DomainCoreQuotaConsumerSupport.shadowMismatch(
                        domain: "anthropic_ratelimit",
                        legacy: $0,
                        rust: nil
                    )
                } ?? "domain_core.anthropic_ratelimit.shadow_mismatch core=\(DomainCoreQuotaConsumerSupport.safeCoreVersion()) legacy_count=0 rust_count=0"
            }
            if let diagnostic { quotaLogger.log(diagnostic) }
            quotaLogger.recordDomainCoreShadowComparison(DomainCoreQuotaShadowComparison(
                operation: "anthropic_quota",
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
            quotaLogger.log("domain_core.anthropic_ratelimit.abi_mismatch")
            return nil
        }
        let parsed = OpenBurnBarDomainCoreFFI.parseAnthropicRateLimitHeaders(
            payload: payload,
            nowUnix: Int64(now.timeIntervalSince1970),
            shape: ffiShape
        )
        return parsed.status == .parsed
            ? DomainCoreQuotaConsumerSupport.snapshot(
                from: parsed.snapshot,
                fetchedAt: now,
                managementURL: "https://claude.ai/settings/usage"
            )
            : nil
        #else
        quotaLogger.log("domain_core.anthropic_ratelimit.native_unavailable mode=\(mode.rawValue)")
        if mode == .shadow {
            let legacyMeasurement = DomainCoreQuotaShadowTiming.measure(legacy)
            quotaLogger.recordDomainCoreShadowComparison(DomainCoreQuotaShadowComparison(
                operation: "anthropic_quota",
                coreVersion: "0.0.0-unavailable",
                observedAt: Date(),
                outcome: .mismatch,
                mismatchCategory: .nativeUnavailable,
                legacyMicros: legacyMeasurement.micros,
                rustMicros: 0
            ))
            return legacyMeasurement.value
        }
        return nil
        #endif
    }
}
