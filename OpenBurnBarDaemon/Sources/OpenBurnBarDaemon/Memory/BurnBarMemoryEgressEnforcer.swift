import Foundation
import OpenBurnBarEngine

/// The memory purposes a request may declare with `X-OpenBurnBar-Purpose`.
public enum GatewayPurpose: String, CaseIterable, Sendable {
    case extract = "memory-extract"
    case judge = "memory-judge"
    case embed = "memory-embed"
    case rerank = "memory-rerank"
    case answer = "memory-answer"

    public static let headerName = "x-openburnbar-purpose"

    public init?(header: String?) {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        self.init(rawValue: raw)
    }
}

/// A policy refusal. `code` is one of the six contract strings the Python
/// engine maps to its own `ModelUnavailable`.
public struct BurnBarMemoryEgressDenial: Error, Sendable, Hashable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// The gate every memory-purpose request passes before it leaves the Mac.
/// Order matters and is the contract: Pro entitlement, the master switch,
/// provider consent, the retention requirement, then the daily budget.
public struct BurnBarMemoryEgressEnforcer: Sendable {
    public static let executionSource = UsageExecutionSource(
        id: "memory-pro",
        name: "Memory Pro",
        kind: .automation,
        confidence: .exact
    )
    public static let allowedPaths: Set<String> = ["/v1/chat/completions", "/v1/embeddings"]

    let configStore: BurnBarConfigStore
    let membership: any BurnBarMembershipServing
    public let tokenStore: BurnBarGatewayScopedTokenStore
    public let log: BurnBarMemoryEgressLogStore
    let spentTodayUSD: @Sendable (Date) async throws -> Double
    let now: @Sendable () -> Date

    public init(
        configStore: BurnBarConfigStore,
        membership: any BurnBarMembershipServing,
        tokenStore: BurnBarGatewayScopedTokenStore,
        log: BurnBarMemoryEgressLogStore,
        spentTodayUSD: @escaping @Sendable (Date) async throws -> Double,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configStore = configStore
        self.membership = membership
        self.tokenStore = tokenStore
        self.log = log
        self.spentTodayUSD = spentTodayUSD
        self.now = now
    }

    /// Production spend reader: the usage ledger's cost for today's
    /// Memory Pro requests.
    public static func spentTodayReader(usageRecorder: BurnBarUsageRecorder?) -> @Sendable (Date) async throws -> Double {
        { now in
            guard let usageRecorder else { return 0 }
            let startOfDay = Calendar.current.startOfDay(for: now)
            return try await usageRecorder.sumCost(since: startOfDay) { $0.executionSourceID == executionSource.id }
        }
    }

    public func validateToken(_ token: String, purpose: GatewayPurpose) async -> Bool {
        await tokenStore.validate(token: token, purpose: purpose.rawValue, now: now())
    }

    public func evaluate(purpose: GatewayPurpose, providerID: String) async throws {
        let membershipSnapshot = await membership.status().membership
        guard BurnBarMembershipFreshness.isProActive(membershipSnapshot, now: now()) else {
            throw BurnBarMemoryEgressDenial(code: "PRO_REQUIRED", message: "Memory Pro needs an active BurnBar Pro membership on this Mac.")
        }
        let policy = try await configStore.snapshot().memoryEgress
        guard policy.enabled else {
            throw BurnBarMemoryEgressDenial(code: "CLOUD_CONSENT_REQUIRED", message: "Cloud models for memory are off. Turn them on in Settings → Privacy → Memory.")
        }
        let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard policy.consentedProviderIDs.contains(normalizedProvider) else {
            throw BurnBarMemoryEgressDenial(code: "PROVIDER_NOT_CONSENTED", message: "Provider \(normalizedProvider) is not enabled for memory in Settings → Privacy → Memory.")
        }
        let retention = BurnBarMemoryModelPolicy.retentionClass(providerID: normalizedProvider)
        if policy.requireNoRetention, retention != "deny" {
            throw BurnBarMemoryEgressDenial(code: "EGRESS_BLOCKED_RETENTION", message: "Provider \(normalizedProvider) cannot promise no data retention; allow provider-policy retention or pick another provider.")
        }
        let spent = try await spentTodayUSD(now())
        if spent >= policy.dailyCapUSD {
            throw BurnBarMemoryEgressDenial(code: "BUDGET_EXCEEDED", message: "Today's memory model budget (\(policy.dailyCapUSD) USD) is spent.")
        }
    }

    public func record(
        purpose: GatewayPurpose,
        providerID: String,
        modelID: String,
        requestBytes: Int,
        responseBytes: Int,
        outcome: String,
        code: String?,
        latencyMs: Int
    ) async {
        let entry = BurnBarMemoryEgressEntry(
            purpose: purpose.rawValue,
            providerID: providerID,
            modelID: modelID,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            retention: BurnBarMemoryModelPolicy.retentionClass(providerID: providerID),
            outcome: outcome,
            code: code,
            latencyMs: latencyMs
        )
        try? await log.append(entry)
    }
}
