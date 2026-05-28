import Foundation

/// JSON contract shared with `BurnBarDaemonHeartbeat` in OpenBurnBarDaemon.
struct OpenBurnBarDaemonHeartbeatSnapshot: Codable, Sendable, Equatable {
    let pid: Int32
    let daemonVersion: String
    let protocolVersion: Int
    let updatedAt: Date
}

enum OpenBurnBarDaemonHeartbeatReader {
    static let defaultStaleThreshold: TimeInterval = 20

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func readSnapshot(from fileURL: URL) -> OpenBurnBarDaemonHeartbeatSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(OpenBurnBarDaemonHeartbeatSnapshot.self, from: data)
    }

    static func isStale(
        snapshot: OpenBurnBarDaemonHeartbeatSnapshot?,
        now: Date = Date(),
        maxAge: TimeInterval = defaultStaleThreshold
    ) -> Bool {
        guard let snapshot else { return true }
        return now.timeIntervalSince(snapshot.updatedAt) > maxAge
    }
}
