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
