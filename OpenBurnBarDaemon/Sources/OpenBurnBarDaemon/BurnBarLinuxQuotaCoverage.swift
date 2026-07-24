import OpenBurnBarEngine

/// Provenance for quota snapshots emitted by the Linux daemon.
///
/// The signal tier is part of the persisted daemon contract. Keeping the
/// mapping typed prevents a future local artifact or cached value from being
/// presented as a fresh provider/API response in the Linux UI.
public enum BurnBarLinuxQuotaCoverage: String, Codable, Hashable, Sendable {
    case apiBacked
    case localArtifact
    case cachedSnapshot
    case unavailable

    public var sourceKind: ProviderQuotaSourceKind {
        switch self {
        case .apiBacked, .cachedSnapshot:
            return .provider
        case .localArtifact:
            return .localSession
        case .unavailable:
            return .unavailable
        }
    }

    public var sourceLabel: String {
        switch self {
        case .apiBacked:
            return "Provider/API quota signal"
        case .localArtifact:
            return "Local quota artifact"
        case .cachedSnapshot:
            return "Cached provider quota signal"
        case .unavailable:
            return "Quota unavailable"
        }
    }
}

public extension QuotaSignalTier {
    /// Maps the persisted signal tier to the source/provenance shown in a
    /// Linux `ProviderQuotaSnapshot`.
    var linuxQuotaCoverage: BurnBarLinuxQuotaCoverage {
        switch self {
        case .trafficHeaders, .statusEndpoint, .serverSweep, .spendProbe:
            return .apiBacked
        case .localArtifact:
            return .localArtifact
        case .cachedSnapshot:
            return .cachedSnapshot
        }
    }
}
