import Foundation

// MARK: - BurnBar Widget Snapshot

/// Lightweight flat model written by the main iOS app and read by the widget extension.
/// Serialized to the App Group container as JSON (~1 KB).
public struct BurnBarWidgetSnapshot: Codable, Sendable, Hashable {
    public let heroTotalCost: Double
    public let heroTotalTokens: Int
    public let heroTotalRequests: Int
    public let topProviders: [String]
    public let topProviderTokens: [Int]
    public let topModels: [String]
    public let dailyPoints: [Double]
    public let windowKey: String
    public let lastSync: Date

    public init(
        heroTotalCost: Double,
        heroTotalTokens: Int,
        heroTotalRequests: Int,
        topProviders: [String],
        topProviderTokens: [Int],
        topModels: [String],
        dailyPoints: [Double],
        windowKey: String,
        lastSync: Date
    ) {
        self.heroTotalCost = heroTotalCost
        self.heroTotalTokens = heroTotalTokens
        self.heroTotalRequests = heroTotalRequests
        self.topProviders = topProviders
        self.topProviderTokens = topProviderTokens
        self.topModels = topModels
        self.dailyPoints = dailyPoints
        self.windowKey = windowKey
        self.lastSync = lastSync
    }

    /// True when every field the widget renders data from matches `other`,
    /// ignoring `lastSync` (stamped fresh on every write by construction, so
    /// including it would defeat any unchanged-content comparison).
    public func hasSameContent(as other: BurnBarWidgetSnapshot) -> Bool {
        heroTotalCost == other.heroTotalCost
            && heroTotalTokens == other.heroTotalTokens
            && heroTotalRequests == other.heroTotalRequests
            && topProviders == other.topProviders
            && topProviderTokens == other.topProviderTokens
            && topModels == other.topModels
            && dailyPoints == other.dailyPoints
            && windowKey == other.windowKey
    }

    /// Preview snapshot with realistic placeholder data.
    public static let preview = BurnBarWidgetSnapshot(
        heroTotalCost: 3.42,
        heroTotalTokens: 12_400,
        heroTotalRequests: 18,
        topProviders: ["Claude", "Codex", "Cursor"],
        topProviderTokens: [5_200, 4_100, 3_100],
        topModels: ["claude-3.5-sonnet", "o3-mini", "gpt-4o"],
        dailyPoints: [0.3, 0.5, 0.8, 1.0, 0.6, 0.4, 0.2],
        windowKey: "today",
        lastSync: Date()
    )
}

// MARK: - Shared App Group Utilities

public enum BurnBarWidgetShared {
    public static let appGroupIdentifier = "group.com.openburnbar.app"
    public static let snapshotFilename = "widget_snapshot.json"

    /// The shared container URL for the App Group. Returns `nil` if the app group is not configured.
    public static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Full path to the widget snapshot JSON file.
    public static var snapshotURL: URL? {
        containerURL?.appendingPathComponent(snapshotFilename)
    }

    /// Write a snapshot to the shared App Group container.
    public static func writeSnapshot(_ snapshot: BurnBarWidgetSnapshot) throws {
        guard let url = snapshotURL else {
            throw BurnBarWidgetError.appGroupUnavailable
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// On-disk snapshots older than this are rewritten even when the content
    /// is unchanged, so the Large/XL widgets' "Updated" footer keeps advancing
    /// at a coarse cadence between real data changes.
    public static let snapshotStaleAfter: TimeInterval = 15 * 60

    /// Pure decision for `writeSnapshotIfChanged`: write when there is no
    /// readable on-disk snapshot, the content changed, or the on-disk copy
    /// has gone stale relative to the candidate's `lastSync`.
    public static func shouldWrite(
        _ snapshot: BurnBarWidgetSnapshot,
        replacing existing: BurnBarWidgetSnapshot?,
        staleAfter: TimeInterval = snapshotStaleAfter
    ) -> Bool {
        guard let existing, existing.hasSameContent(as: snapshot) else { return true }
        return snapshot.lastSync.timeIntervalSince(existing.lastSync) >= staleAfter
    }

    /// Write `snapshot` only when the on-disk copy needs it (see `shouldWrite`).
    /// Returns whether a write happened, so callers can reload widget
    /// timelines only for real changes — every Firestore listener tick used
    /// to rewrite an identical snapshot and burn the WidgetCenter reload
    /// budget. Comparing against the on-disk snapshot (not a shared in-memory
    /// hash) keeps concurrent `DashboardStore` instances from ping-ponging
    /// each other's guards.
    @discardableResult
    public static func writeSnapshotIfChanged(
        _ snapshot: BurnBarWidgetSnapshot,
        staleAfter: TimeInterval = snapshotStaleAfter
    ) throws -> Bool {
        guard shouldWrite(snapshot, replacing: try? readSnapshot(), staleAfter: staleAfter) else {
            return false
        }
        try writeSnapshot(snapshot)
        return true
    }

    /// Read the latest snapshot from the shared App Group container.
    public static func readSnapshot() throws -> BurnBarWidgetSnapshot {
        guard let url = snapshotURL else {
            throw BurnBarWidgetError.appGroupUnavailable
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BurnBarWidgetSnapshot.self, from: data)
    }
}

// MARK: - BurnBar Widget Error

public enum BurnBarWidgetError: Error, LocalizedError {
    case appGroupUnavailable

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container is not available. Ensure the app group entitlement is configured."
        }
    }
}
