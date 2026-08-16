import BurnBarCore
import Foundation

public enum BurnBarDaemonPaths {
    public static var supportDirectoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["BURNBAR_DAEMON_SUPPORT_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BurnBar", isDirectory: true)
    }

    public static var defaultSocketURL: URL {
        supportDirectoryURL
            .appendingPathComponent("burnbar-daemon.sock", isDirectory: false)
    }

    public static var defaultSocketPath: String {
        defaultSocketURL.path
    }

    /// Resolves the executable's socket override using the same empty-value
    /// semantics as the documented shell and Python readers. An empty
    /// `BURNBAR_DAEMON_SOCKET_PATH` is unset and falls back to the support
    /// directory-derived default.
    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["BURNBAR_DAEMON_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return defaultSocketPath(environment: environment)
    }

    /// Resolves the default socket from an injected environment. The
    /// executable uses this overload so hermetic callers can test the same
    /// support-directory fallback without mutating process-wide environment.
    public static func defaultSocketPath(
        environment: [String: String]
    ) -> String {
        supportDirectoryURL(environment: environment)
            .appendingPathComponent("burnbar-daemon.sock", isDirectory: false)
            .path
    }

    public static var defaultConfigStoreURL: URL {
        supportDirectoryURL.appendingPathComponent("provider-config.json", isDirectory: false)
    }

    public static var defaultUsageLedgerURL: URL {
        supportDirectoryURL.appendingPathComponent("usage-events.jsonl", isDirectory: false)
    }

    public static var defaultRunJournalURL: URL {
        supportDirectoryURL.appendingPathComponent("run-journal.jsonl", isDirectory: false)
    }

    public static var defaultRunCheckpointDirectoryURL: URL {
        supportDirectoryURL.appendingPathComponent("run-checkpoints", isDirectory: true)
    }

    /// Daemon-owned fleet persistence: the GRDB store holding the latest
    /// snapshot + transition-event history + orchestrator/directive schema.
    public static var defaultFleetStoreURL: URL {
        supportDirectoryURL.appendingPathComponent("fleet.sqlite", isDirectory: false)
    }

    /// The well-known atomic snapshot file any local agent can read.
    public static var defaultFleetSnapshotURL: URL {
        supportDirectoryURL.appendingPathComponent("fleet-snapshot.json", isDirectory: false)
    }

    private static func supportDirectoryURL(environment: [String: String]) -> URL {
        if let override = environment["BURNBAR_DAEMON_SUPPORT_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let homePath = environment["HOME"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library/Application Support/BurnBar", isDirectory: true)
    }
}

public enum BurnBarDaemonVersion {
    public static let current = "0.1.0"
}

public struct BurnBarDaemonConfiguration: Sendable {
    public let socketPath: String
    public let daemonVersion: String
    public let catalog: BurnBarCatalog
    /// Read-only path to the BurnBar app SQLite database (`burnbar.sqlite`) for indexed search RPC.
    public let indexDatabasePath: String?
    /// Daemon-owned fleet store path (`fleet.sqlite`). Defaults to the support
    /// dir (`BURNBAR_DAEMON_SUPPORT_DIR`-overridable); injectable for hermetic
    /// tests.
    public let fleetStorePath: String
    /// Well-known atomic snapshot file path (`fleet-snapshot.json`). Same
    /// support-dir default as the store path.
    public let fleetSnapshotFilePath: String
    /// Fleet event retention window (seconds). Default 24h; the
    /// `BURNBAR_FLEET_EVENT_RETENTION_SECONDS` override accelerates pruning
    /// tests (VAL-FLEET-020).
    public let fleetEventRetentionSeconds: TimeInterval
    /// Number of completed snapshot payloads retained in `fleet_snapshots`
    /// (default 240 ≈ 1h at the default 15s cadence).
    public let fleetSnapshotRetentionCount: Int

    public init(
        socketPath: String = BurnBarDaemonPaths.defaultSocketPath,
        daemonVersion: String = BurnBarDaemonVersion.current,
        catalog: BurnBarCatalog = BurnBarCatalogLoader.bundledCatalog,
        indexDatabasePath: String? = nil,
        fleetStorePath: String? = nil,
        fleetSnapshotFilePath: String? = nil,
        fleetEventRetentionSeconds: TimeInterval? = nil,
        fleetSnapshotRetentionCount: Int = BurnBarFleetPersistenceConstants.defaultSnapshotRetentionCount,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.socketPath = socketPath
        self.daemonVersion = daemonVersion
        self.catalog = catalog
        self.indexDatabasePath = indexDatabasePath
        self.fleetStorePath = fleetStorePath ?? BurnBarDaemonPaths.defaultFleetStoreURL.path
        self.fleetSnapshotFilePath = fleetSnapshotFilePath ?? BurnBarDaemonPaths.defaultFleetSnapshotURL.path
        // The retention seam: `BURNBAR_FLEET_EVENT_RETENTION_SECONDS` overrides
        // the 24-hour default unless an explicit value was injected.
        self.fleetEventRetentionSeconds = fleetEventRetentionSeconds
            ?? Self.resolveEventRetentionSeconds(environment: environment)
        self.fleetSnapshotRetentionCount = fleetSnapshotRetentionCount
    }

    /// Resolves the fleet event-retention seam from the environment:
    /// `BURNBAR_FLEET_EVENT_RETENTION_SECONDS` overrides the 24-hour default.
    /// Invalid or non-positive values fall back to the default.
    public static func resolveEventRetentionSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        let raw = environment["BURNBAR_FLEET_EVENT_RETENTION_SECONDS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, let parsed = Double(raw), parsed > 0 else {
            return BurnBarFleetPersistenceConstants.defaultEventRetentionSeconds
        }
        return parsed
    }
}
