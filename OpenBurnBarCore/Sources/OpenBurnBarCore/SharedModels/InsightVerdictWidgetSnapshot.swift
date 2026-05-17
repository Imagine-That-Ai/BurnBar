import Foundation

/// Lightweight verdict snapshot written by the main app and read by
/// the Insights widget extension. Serialized to the App Group container.
public struct InsightVerdictWidgetSnapshot: Codable, Sendable, Hashable {
    public let headline: String
    public let spendCurrent: Double
    public let spendTarget: Double
    public let cacheCurrent: Double
    public let cacheTarget: Double
    public let sessionsCurrent: Int
    public let sessionsTarget: Int
    public let windowLabel: String
    public let isStale: Bool
    public let lastSync: Date

    public init(
        headline: String,
        spendCurrent: Double,
        spendTarget: Double,
        cacheCurrent: Double,
        cacheTarget: Double,
        sessionsCurrent: Int,
        sessionsTarget: Int,
        windowLabel: String,
        isStale: Bool,
        lastSync: Date
    ) {
        self.headline = headline
        self.spendCurrent = spendCurrent
        self.spendTarget = spendTarget
        self.cacheCurrent = cacheCurrent
        self.cacheTarget = cacheTarget
        self.sessionsCurrent = sessionsCurrent
        self.sessionsTarget = sessionsTarget
        self.windowLabel = windowLabel
        self.isStale = isStale
        self.lastSync = lastSync
    }

    /// Preview snapshot for design-time.
    public static let preview = InsightVerdictWidgetSnapshot(
        headline: "You spent $4.12 yesterday — 28% under average.",
        spendCurrent: 4.12,
        spendTarget: 12.0,
        cacheCurrent: 91,
        cacheTarget: 85,
        sessionsCurrent: 3,
        sessionsTarget: 2,
        windowLabel: "Today",
        isStale: false,
        lastSync: Date()
    )
}

public enum InsightWidgetShared {
    public static let appGroupIdentifier = "group.com.openburnbar.app"
    public static let verdictFilename = "insight_verdict_snapshot.json"

    public static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    public static var verdictURL: URL? {
        containerURL?.appendingPathComponent(verdictFilename)
    }

    public static func writeVerdictSnapshot(_ snapshot: InsightVerdictWidgetSnapshot) throws {
        guard let url = verdictURL else {
            throw BurnBarWidgetError.appGroupUnavailable
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public static func readVerdictSnapshot() throws -> InsightVerdictWidgetSnapshot {
        guard let url = verdictURL else {
            throw BurnBarWidgetError.appGroupUnavailable
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(InsightVerdictWidgetSnapshot.self, from: data)
    }
}
