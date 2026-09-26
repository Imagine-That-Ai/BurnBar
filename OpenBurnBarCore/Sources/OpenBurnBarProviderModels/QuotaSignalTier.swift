import Foundation

/// Quota-signal tier (3.2: extracted so provider contracts reference it without a UsageModels edge).

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
