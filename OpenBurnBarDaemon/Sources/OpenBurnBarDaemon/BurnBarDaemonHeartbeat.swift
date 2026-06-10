import Foundation
import OpenBurnBarCore

/// Periodic on-disk liveness signal written by the OpenBurnBar daemon process.
/// The Mac app reads this file to distinguish "daemon hung" from "daemon not running".
public struct BurnBarDaemonHeartbeatSnapshot: Codable, Sendable, Equatable {
    public let pid: Int32
    public let daemonVersion: String
    public let protocolVersion: Int
    public let updatedAt: Date

    public init(pid: Int32, daemonVersion: String, protocolVersion: Int, updatedAt: Date) {
        self.pid = pid
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.updatedAt = updatedAt
    }
}

public enum BurnBarDaemonHeartbeat {
    /// Half the stale threshold: a beat can land a full interval late and the
    /// file age still stays under `defaultStaleThreshold` for readers.
    public static let defaultInterval: TimeInterval = 10
    public static let defaultStaleThreshold: TimeInterval = 20

    public static var defaultFileURL: URL {
        BurnBarDaemonPaths.defaultHeartbeatURL
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Writes a heartbeat snapshot atomically to the configured path.
    /// `.atomic` already does the temp-file + rename dance internally and
    /// preserves the existing file's mode on Darwin, so the chmod only runs
    /// on first create instead of every beat.
    public static func writeSnapshot(
        _ snapshot: BurnBarDaemonHeartbeatSnapshot,
        to fileURL: URL = defaultFileURL,
        fileManager: FileManager = .default
    ) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let payload = try encoder.encode(snapshot)
        let isFirstWrite = !fileManager.fileExists(atPath: fileURL.path)
        try payload.write(to: fileURL, options: .atomic)
        if isFirstWrite {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    public static func readSnapshot(
        from fileURL: URL = defaultFileURL,
        fileManager: FileManager = .default
    ) -> BurnBarDaemonHeartbeatSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? decoder.decode(BurnBarDaemonHeartbeatSnapshot.self, from: data)
    }

    public static func isStale(
        snapshot: BurnBarDaemonHeartbeatSnapshot?,
        now: Date = Date(),
        maxAge: TimeInterval = defaultStaleThreshold
    ) -> Bool {
        guard let snapshot else { return true }
        return now.timeIntervalSince(snapshot.updatedAt) > maxAge
    }

    public static func startPeriodicWriter(
        daemonVersion: String,
        protocolVersion: Int = BurnBarProtocolVersion.current,
        interval: TimeInterval = defaultInterval,
        fileURL: URL = defaultFileURL
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let snapshot = BurnBarDaemonHeartbeatSnapshot(
                    pid: ProcessInfo.processInfo.processIdentifier,
                    daemonVersion: daemonVersion,
                    protocolVersion: protocolVersion,
                    updatedAt: Date()
                )
                _ = try? writeSnapshot(snapshot, to: fileURL)
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }
}
