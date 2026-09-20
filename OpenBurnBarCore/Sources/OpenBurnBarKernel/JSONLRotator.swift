import Foundation

/// Size-caps append-only `*.jsonl` journals. Rotation is copy-truncate: the
/// live file is renamed to `name.jsonl.<utc>` and a new empty file is created.
/// Callers keep writing the original URL.
public enum JSONLRotator: Sendable {
    public static let defaultMaxBytes: Int64 = 32 * 1024 * 1024

    @discardableResult
    public static func rotateIfNeeded(
        url: URL,
        maxBytes: Int64 = defaultMaxBytes,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL? {
        guard maxBytes > 0 else { return nil }
        let path = url.path
        guard fileManager.fileExists(atPath: path) else { return nil }
        let attrs = try fileManager.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= maxBytes else { return nil }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "." + stamp)
        try fileManager.moveItem(at: url, to: rotated)
        fileManager.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600])
        return rotated
    }
}
