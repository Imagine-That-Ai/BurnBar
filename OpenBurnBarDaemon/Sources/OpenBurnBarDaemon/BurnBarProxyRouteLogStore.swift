import OpenBurnBarCore
import Foundation

public actor BurnBarProxyRouteLogStore {
    public static let defaultRecentLimit = 50
    public static let maxRecentLimit = 200
    public static let retainedRecordLimit = 5_000

    private let fileURL: URL
    private let logger: BurnBarDaemonLogger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedEntries: [BurnBarProxyRouteLogEntry]?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultProxyRouteEventsURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "proxy-route-log")
    ) {
        self.fileURL = fileURL
        self.logger = logger
    }

    public func append(_ entry: BurnBarProxyRouteLogEntry) async {
        do {
            var entries = try loadEntries()
            entries.append(entry)
            if entries.count > Self.retainedRecordLimit {
                entries = Array(entries.suffix(Self.retainedRecordLimit))
                try rewrite(entries)
            } else {
                try appendLine(entry)
            }
            cachedEntries = entries
        } catch {
            logger.silentFailure("proxy_route_log_append", error: error)
        }
    }

    public func recent(limit: Int = BurnBarProxyRouteLogStore.defaultRecentLimit) throws -> [BurnBarProxyRouteLogEntry] {
        let boundedLimit = min(max(0, limit), Self.maxRecentLimit)
        return Array(
            try loadEntries()
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(boundedLimit)
        )
    }

    public func clear() throws {
        cachedEntries = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func loadEntries() throws -> [BurnBarProxyRouteLogEntry] {
        if let cachedEntries {
            return cachedEntries
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedEntries = []
            return []
        }

        let fileContents = try String(contentsOf: fileURL, encoding: .utf8)
        var entries: [BurnBarProxyRouteLogEntry] = []
        var corruptLineCount = 0
        for line in fileContents.split(whereSeparator: \.isNewline) {
            do {
                let entry = try decoder.decode(BurnBarProxyRouteLogEntry.self, from: Data(line.utf8))
                entries.append(entry)
            } catch {
                corruptLineCount += 1
            }
        }
        if corruptLineCount > 0 {
            logger.warning(
                "proxy_route_log_corrupt_lines_skipped",
                metadata: ["count": "\(corruptLineCount)"]
            )
        }
        if entries.count > Self.retainedRecordLimit {
            entries = Array(entries.suffix(Self.retainedRecordLimit))
            try rewrite(entries)
        }
        cachedEntries = entries
        return entries
    }

    private func appendLine(_ entry: BurnBarProxyRouteLogEntry) throws {
        try ensureDirectory()
        let encodedRecord = try encoder.encode(entry) + Data([0x0A])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encodedRecord)
        } else {
            try encodedRecord.write(to: fileURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func rewrite(_ entries: [BurnBarProxyRouteLogEntry]) throws {
        try ensureDirectory()
        let data = try entries.reduce(into: Data()) { partial, entry in
            partial.append(try encoder.encode(entry))
            partial.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
