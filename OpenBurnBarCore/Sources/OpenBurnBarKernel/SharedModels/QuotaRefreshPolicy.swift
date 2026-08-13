import Foundation

public enum QuotaSignalTier: Int, Codable, CaseIterable, Hashable, Sendable {
    case trafficHeaders = 0
    case localArtifact = 1
    case cachedSnapshot = 2
    case statusEndpoint = 3
    case serverSweep = 4
    case spendProbe = 5

    public var contractName: String {
        switch self {
        case .trafficHeaders:
            return "TrafficHeaders"
        case .localArtifact:
            return "LocalArtifact"
        case .cachedSnapshot:
            return "CachedSnapshot"
        case .statusEndpoint:
            return "StatusEndpoint"
        case .serverSweep:
            return "ServerSweep"
        case .spendProbe:
            return "SpendProbe"
        }
    }
}

public struct QuotaRefreshPolicySnapshot: Sendable, Hashable {
    public let fetchedAt: Date
    public let remainingFraction: Double?
    public let windowKind: ProviderQuotaWindowKind
    public let resetsAt: Date?

    public init(
        fetchedAt: Date,
        remainingFraction: Double?,
        windowKind: ProviderQuotaWindowKind,
        resetsAt: Date?
    ) {
        self.fetchedAt = fetchedAt
        self.remainingFraction = remainingFraction
        self.windowKind = windowKind
        self.resetsAt = resetsAt
    }
}

public enum QuotaRefreshPolicy {
    public static let minimumTTL: TimeInterval = 60
    public static let maximumTTL: TimeInterval = 4 * 60 * 60
    public static let highRemainingTTL: TimeInterval = 30 * 60
    public static let mediumRemainingTTL: TimeInterval = 10 * 60
    public static let lowRemainingTTL: TimeInterval = 3 * 60
    public static let unknownRemainingTTL: TimeInterval = 15 * 60
    public static let defaultDailyProbeBudget = 4

    public static func adaptiveTTL(
        remainingFraction: Double?,
        windowKind _: ProviderQuotaWindowKind,
        resetsAt: Date?,
        now: Date = Date()
    ) -> TimeInterval {
        let baseTTL: TimeInterval
        if let remainingFraction, remainingFraction.isFinite {
            let clamped = min(max(remainingFraction, 0), 1)
            if clamped >= 0.5 {
                baseTTL = highRemainingTTL
            } else if clamped >= 0.2 {
                baseTTL = mediumRemainingTTL
            } else {
                baseTTL = lowRemainingTTL
            }
        } else {
            baseTTL = unknownRemainingTTL
        }

        let resetBound = resetsAt.map { reset in
            max(minimumTTL, min(maximumTTL, reset.timeIntervalSince(now)))
        } ?? maximumTTL
        return min(max(baseTTL, minimumTTL), resetBound)
    }

    public static func shouldSpendProbe(
        lastProbeAt: Date?,
        probesToday: Int,
        dailyProbeBudget: Int = defaultDailyProbeBudget,
        now: Date = Date()
    ) -> Bool {
        guard dailyProbeBudget > 0 else { return false }
        guard probesToday >= 0, probesToday < dailyProbeBudget else { return false }
        if let lastProbeAt, lastProbeAt > now {
            return false
        }
        return true
    }

    public static func nextRefreshAfter(
        _ snapshot: QuotaRefreshPolicySnapshot,
        now: Date = Date()
    ) -> Date {
        let ttl = adaptiveTTL(
            remainingFraction: snapshot.remainingFraction,
            windowKind: snapshot.windowKind,
            resetsAt: snapshot.resetsAt,
            now: now
        )
        return snapshot.fetchedAt.addingTimeInterval(ttl)
    }

    /// Hosted-sweep equivalent: min remaining/limit across buckets, first
    /// non-custom window, earliest `resetsAt`. Empty buckets → unknown TTL.
    public static func policySnapshot(from snapshot: ProviderQuotaSnapshot) -> QuotaRefreshPolicySnapshot {
        var remainingFraction: Double?
        var windowKind: ProviderQuotaWindowKind = .custom
        var resetsAt: Date?

        for bucket in snapshot.buckets {
            if let limit = bucket.limitValue, limit > 0, limit.isFinite,
               let remaining = bucket.remainingValue, remaining.isFinite {
                let candidate = min(max(remaining / limit, 0), 1)
                remainingFraction = remainingFraction.map { min($0, candidate) } ?? candidate
            }
            if resetsAt == nil {
                resetsAt = bucket.resetsAt
            }
            if windowKind == .custom {
                windowKind = bucket.windowKind
            }
        }

        return QuotaRefreshPolicySnapshot(
            fetchedAt: snapshot.fetchedAt,
            remainingFraction: remainingFraction,
            windowKind: windowKind,
            resetsAt: resetsAt
        )
    }

    public static func isFresh(
        _ snapshot: ProviderQuotaSnapshot,
        now: Date = Date()
    ) -> Bool {
        now < nextRefreshAfter(policySnapshot(from: snapshot), now: now)
    }

    /// Providers with no snapshot, or whose adaptive TTL has elapsed.
    /// Order matches `providers`.
    public static func providersDueForRefresh<S: Sequence>(
        _ providers: S,
        snapshots: [AgentProvider: ProviderQuotaSnapshot],
        now: Date = Date()
    ) -> [AgentProvider] where S.Element == AgentProvider {
        providers.filter { provider in
            guard let snapshot = snapshots[provider] else { return true }
            return !isFresh(snapshot, now: now)
        }
    }
}
