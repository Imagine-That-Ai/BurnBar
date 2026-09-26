import Foundation

/// Mac publishes; mobile mirrors. Mobile never becomes the write owner of
/// usage/rollup/quota snapshots.
public enum MobileSyncPublisherRole: String, Sendable, Equatable {
    case macPublishes = "mac-publishes"
    case mobileMirrorsReadOnly = "mobile-mirrors-read-only"
}

public enum MobileSyncFreshness: String, Sendable, Equatable, CaseIterable {
    case live
    case stale
    case offline
    case empty
    case failed
    case partial

    /// Empty/failed/offline must never render as a live zero.
    public var looksLikeLiveZero: Bool { self == .live }

    public var label: String {
        switch self {
        case .live: return "Live"
        case .stale: return "Stale"
        case .offline: return "Offline"
        case .empty: return "No Mac-published data"
        case .failed: return "Cloud load failed"
        case .partial: return "Partial"
        }
    }
}

public enum MobileSyncOwnershipPolicy {
    public static let macRole = MobileSyncPublisherRole.macPublishes
    public static let mobileRole = MobileSyncPublisherRole.mobileMirrorsReadOnly

    public static var mobileMayPublishUsage: Bool { false }

    public static func freshness(
        hasData: Bool,
        failed: Bool,
        offline: Bool,
        stale: Bool,
        partial: Bool
    ) -> MobileSyncFreshness {
        if failed { return .failed }
        if offline { return .offline }
        if !hasData { return .empty }
        if partial { return .partial }
        if stale { return .stale }
        return .live
    }

    /// Cancel and process-restart share one generation token so a late result
    /// cannot double-apply.
    public static func shouldApply(
        startedGeneration: Int,
        currentGeneration: Int,
        cancelled: Bool
    ) -> Bool {
        !cancelled && startedGeneration == currentGeneration
    }

    public static func nextGeneration(_ current: Int) -> Int {
        current &+ 1
    }
}
