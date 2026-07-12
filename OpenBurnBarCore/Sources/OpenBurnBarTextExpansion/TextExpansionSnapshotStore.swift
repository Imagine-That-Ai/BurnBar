import Foundation

public enum TextExpansionSnapshotStore {
    public static let appGroupIdentifier = "group.com.openburnbar.app"
    public static let snapshotFileName = "text-expansion-snippets.json"

    public static func snapshotURL(appGroupIdentifier: String = appGroupIdentifier) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(snapshotFileName)
    }

    public static func write(_ snapshot: TextExpansionSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    public static func read(from url: URL) throws -> TextExpansionSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TextExpansionSnapshot.self, from: data)
    }
}
