import Foundation

// MARK: - Usage Tracking

/// One snippet's usage statistics, persisted in the shared App Group container so
/// that the iOS keyboard extension can rank the user's most-reached-for snippets
/// first in the suggestion bar.
public struct TextExpansionUsageRecord: Codable, Equatable, Sendable {
    public var count: Int
    public var lastUsedAt: Date

    public init(count: Int = 0, lastUsedAt: Date = .distantPast) {
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}

/// The full usage ledger: snippet id → usage record. Stored as a tiny JSON file
/// alongside the snippet snapshot. The keyboard increments it on every insertion
/// (chip tap or `&&` expansion); the ranking helper reads it to order the bar.
public struct TextExpansionUsageLog: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var records: [String: TextExpansionUsageRecord]

    public init(schemaVersion: Int = 1, records: [String: TextExpansionUsageRecord] = [:]) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    public func record(for id: String) -> TextExpansionUsageRecord? {
        records[id]
    }

    /// Returns a copy with the given snippet's usage incremented.
    public func incrementing(_ id: String, at date: Date) -> TextExpansionUsageLog {
        var copy = self
        var record = copy.records[id] ?? TextExpansionUsageRecord()
        record.count += 1
        record.lastUsedAt = max(record.lastUsedAt, date)
        copy.records[id] = record
        return copy
    }
}

public enum TextExpansionUsageStore {
    public static let usageFileName = "text-expansion-usage.json"

    public static func usageURL(
        appGroupIdentifier: String = TextExpansionSnapshotStore.appGroupIdentifier
    ) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(usageFileName)
    }

    public static func read(from url: URL) -> TextExpansionUsageLog {
        guard let data = try? Data(contentsOf: url) else { return TextExpansionUsageLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TextExpansionUsageLog.self, from: data)) ?? TextExpansionUsageLog()
    }

    public static func write(_ log: TextExpansionUsageLog, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(log)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    /// Records a single use of a snippet, persisting the incremented ledger.
    /// Returns the updated log so callers can re-rank without a second read.
    @discardableResult
    public static func recordUse(
        snippetID: String,
        at date: Date = Date(),
        appGroupIdentifier: String = TextExpansionSnapshotStore.appGroupIdentifier
    ) -> TextExpansionUsageLog {
        guard let url = usageURL(appGroupIdentifier: appGroupIdentifier) else {
            return TextExpansionUsageLog().incrementing(snippetID, at: date)
        }
        let updated = read(from: url).incrementing(snippetID, at: date)
        try? write(updated, to: url)
        return updated
    }

    /// Pure ranking: most-used first, then most-recently-used, then alphabetical
    /// by title for a stable, predictable order. Never reorders within ties in a
    /// way that flickers, because `title` is the final tiebreaker.
    public static func rank(
        _ snippets: [TextExpansionSnippet],
        using log: TextExpansionUsageLog
    ) -> [TextExpansionSnippet] {
        snippets.sorted { lhs, rhs in
            let lhsRecord = log.record(for: lhs.id)
            let rhsRecord = log.record(for: rhs.id)
            let lhsCount = lhsRecord?.count ?? 0
            let rhsCount = rhsRecord?.count ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            let lhsUsed = lhsRecord?.lastUsedAt ?? .distantPast
            let rhsUsed = rhsRecord?.lastUsedAt ?? .distantPast
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
