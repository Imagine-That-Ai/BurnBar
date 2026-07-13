import Foundation

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
        "domain_core.\(domain).shadow_mismatch core=\(OpenBurnBarDomainCoreFFI.domainCoreVersion()) legacy_count=\(legacy.buckets.count) rust_count=\(rust?.buckets.count ?? 0)"
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
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            quotaLogger.log("domain_core.codex_quota.abi_mismatch")
            if mode == .shadow { return try legacy() }
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
        if mode == .shadow {
            let legacySnapshot = try legacy()
            if let diagnostic = DomainCoreQuotaConsumerSupport.shadowMismatch(
                domain: "codex_quota",
                legacy: legacySnapshot,
                rust: rust
            ) {
                quotaLogger.log(diagnostic)
            }
            return legacySnapshot
        }
        guard let rust else { throw DomainCoreQuotaConsumerError.invalidPayload }
        return rust
        #else
        quotaLogger.log("domain_core.codex_quota.native_unavailable mode=\(mode.rawValue)")
        if mode == .shadow { return try legacy() }
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
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            quotaLogger.log("domain_core.cursor_quota.abi_mismatch")
            if mode == .shadow { return try legacy() }
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
        if mode == .shadow {
            let legacySnapshot = try legacy()
            if let diagnostic = DomainCoreQuotaConsumerSupport.shadowMismatch(
                domain: "cursor_quota",
                legacy: legacySnapshot,
                rust: rust
            ) {
                quotaLogger.log(diagnostic)
            }
            return legacySnapshot
        }
        guard let rust else { throw DomainCoreQuotaConsumerError.invalidPayload }
        return rust
        #else
        quotaLogger.log("domain_core.cursor_quota.native_unavailable mode=\(mode.rawValue)")
        if mode == .shadow { return try legacy() }
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
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            quotaLogger.log("domain_core.anthropic_ratelimit.abi_mismatch")
            return mode == .shadow ? legacy() : nil
        }
        let ffiShape: OpenBurnBarDomainCoreFFI.AnthropicCredentialShape = switch shape {
        case .consoleAPIKey: .consoleApiKey
        case .oauthBearer: .oauthBearer
        }
        let parsed = OpenBurnBarDomainCoreFFI.parseAnthropicRateLimitHeaders(
            payload: payload,
            nowUnix: Int64(now.timeIntervalSince1970),
            shape: ffiShape
        )
        let rust = parsed.status == .parsed
            ? DomainCoreQuotaConsumerSupport.snapshot(
                from: parsed.snapshot,
                fetchedAt: now,
                managementURL: "https://claude.ai/settings/usage"
            )
            : nil
        if mode == .shadow {
            let legacySnapshot = legacy()
            if let legacySnapshot,
               let diagnostic = DomainCoreQuotaConsumerSupport.shadowMismatch(
                domain: "anthropic_ratelimit",
                legacy: legacySnapshot,
                rust: rust
               ) {
                quotaLogger.log(diagnostic)
            } else if legacySnapshot == nil, rust != nil {
                quotaLogger.log(
                    "domain_core.anthropic_ratelimit.shadow_mismatch core=\(OpenBurnBarDomainCoreFFI.domainCoreVersion()) legacy_count=0 rust_count=\(rust?.buckets.count ?? 0)"
                )
            }
            return legacySnapshot
        }
        return rust
        #else
        quotaLogger.log("domain_core.anthropic_ratelimit.native_unavailable mode=\(mode.rawValue)")
        return mode == .shadow ? legacy() : nil
        #endif
    }
}
