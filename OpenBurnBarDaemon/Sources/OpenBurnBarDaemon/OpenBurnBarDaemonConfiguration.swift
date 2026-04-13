import OpenBurnBarCore
import Foundation

public enum BurnBarDaemonPaths {
    public static var supportDirectoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_DAEMON_SUPPORT_DIR"]
            ?? ProcessInfo.processInfo.environment["BURNBAR_DAEMON_SUPPORT_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBurnBar", isDirectory: true)
    }

    public static var defaultSocketURL: URL {
        supportDirectoryURL
            .appendingPathComponent("openburnbar-daemon.sock", isDirectory: false)
    }

    public static var defaultSocketPath: String {
        defaultSocketURL.path
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

    public static var defaultControllerEventJournalURL: URL {
        supportDirectoryURL.appendingPathComponent("controller-events.jsonl", isDirectory: false)
    }

    public static var defaultControllerProjectionURL: URL {
        supportDirectoryURL.appendingPathComponent("controller-projection.json", isDirectory: false)
    }

    public static var defaultControllerActivitySnapshotURL: URL {
        supportDirectoryURL.appendingPathComponent("controller-activity-snapshot.json", isDirectory: false)
    }

    public static var defaultConnectorPlaneURL: URL {
        supportDirectoryURL.appendingPathComponent("connector-plane.json", isDirectory: false)
    }

    public static var defaultBrowserToolingURL: URL {
        supportDirectoryURL.appendingPathComponent("browser-tooling.json", isDirectory: false)
    }
}

public enum BurnBarDaemonVersion {
    public static let current = "0.1.2-beta"
}

public struct BurnBarGatewayConfiguration: Codable, Hashable, Sendable {
    /// Whether the HTTP gateway is enabled.
    public var isEnabled: Bool
    /// Host to bind (default 127.0.0.1).
    public var host: String
    /// Port to bind (default 8317).
    public var port: Int
    /// Optional bearer token for authentication. Required if binding to non-loopback.
    public var authToken: String?

    public init(
        isEnabled: Bool = false,
        host: String = "127.0.0.1",
        port: Int = 8317,
        authToken: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
        self.authToken = authToken
    }

    /// Whether the gateway bind address is loopback.
    public var isLoopback: Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Validates the configuration. Returns an error description if invalid.
    public var validationError: String? {
        if !isEnabled { return nil }
        if port < 1 || port > 65535 {
            return "Gateway port must be between 1 and 65535."
        }
        if !isLoopback && (authToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A non-loopback gateway bind address requires an auth token for security."
        }
        return nil
    }
}

public struct BurnBarDaemonConfiguration: Sendable {
    public let socketPath: String
    public let daemonVersion: String
    public let catalog: BurnBarCatalog
    /// Read-only path to the OpenBurnBar app SQLite database (`openburnbar.sqlite`) for indexed search RPC.
    public let indexDatabasePath: String?
    /// HTTP gateway configuration for external client access (Vibe Proxy style).
    public let gateway: BurnBarGatewayConfiguration

    public init(
        socketPath: String = BurnBarDaemonPaths.defaultSocketPath,
        daemonVersion: String = BurnBarDaemonVersion.current,
        catalog: BurnBarCatalog = BurnBarCatalogLoader.bundledCatalog,
        indexDatabasePath: String? = nil,
        gateway: BurnBarGatewayConfiguration = BurnBarGatewayConfiguration()
    ) {
        self.socketPath = socketPath
        self.daemonVersion = daemonVersion
        self.catalog = catalog
        self.indexDatabasePath = indexDatabasePath
        self.gateway = gateway
    }
}
