import OpenBurnBarCore
import Darwin
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

    public static var defaultProviderSecretContinuityURL: URL {
        supportDirectoryURL.appendingPathComponent("provider-secrets.continuity.json", isDirectory: false)
    }

    public static var defaultUsageLedgerURL: URL {
        supportDirectoryURL.appendingPathComponent("usage-events.jsonl", isDirectory: false)
    }

    public static var defaultRunJournalURL: URL {
        supportDirectoryURL.appendingPathComponent("run-journal.jsonl", isDirectory: false)
    }

    public static var defaultRoutingDecisionEventsURL: URL {
        supportDirectoryURL.appendingPathComponent("provider-routing-decisions.jsonl", isDirectory: false)
    }

    public static var defaultProxyRouteEventsURL: URL {
        supportDirectoryURL.appendingPathComponent("proxy-route-events.jsonl", isDirectory: false)
    }

    public static var defaultGatewayModelHealthURL: URL {
        supportDirectoryURL.appendingPathComponent("gateway-model-health.json", isDirectory: false)
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

    public static var defaultHeartbeatURL: URL {
        supportDirectoryURL
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent("openburnbar-daemon.heartbeat.json", isDirectory: false)
    }

    /// On-disk store of companion-mode interactive Claude handoff sessions (B1).
    public static var defaultClaudeHandoffSessionsURL: URL {
        supportDirectoryURL.appendingPathComponent("claude-handoff-sessions.json", isDirectory: false)
    }
}

public enum BurnBarDaemonVersion {
    public static let current = "1.0.2"
}

public struct BurnBarGatewayConfiguration: Codable, Hashable, Sendable {
    /// Whether the HTTP gateway is enabled.
    public var isEnabled: Bool
    /// Host to bind (default 127.0.0.1).
    public var host: String
    /// Port to bind (default 8317).
    public var port: Int
    /// Optional bearer token for authentication. Required whenever the gateway
    /// is enabled — including loopback binds — unless `allowUnauthenticatedLoopback`
    /// is explicitly opted in.
    public var authToken: String?
    /// Opt-in, off-by-default escape hatch that permits an unauthenticated
    /// loopback (127.0.0.1) bind. Fail-closed by default: without a token, any
    /// same-host process could spend the user's provider credits via the
    /// gateway, so the gateway refuses to start unless this is explicitly set.
    public var allowUnauthenticatedLoopback: Bool
    /// Rate limiting configuration for the HTTP gateway.
    /// Default: 30 req/s sustained, 50 burst.
    public var rateLimit: BurnBarRateLimitConfiguration?

    public init(
        isEnabled: Bool = false,
        host: String = "127.0.0.1",
        port: Int = 8317,
        authToken: String? = nil,
        allowUnauthenticatedLoopback: Bool = false,
        rateLimit: BurnBarRateLimitConfiguration? = nil
    ) {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
        self.authToken = authToken
        self.allowUnauthenticatedLoopback = allowUnauthenticatedLoopback
        self.rateLimit = rateLimit
    }
    public var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether the gateway bind address is loopback.
    public var isLoopback: Bool {
        normalizedHost == "127.0.0.1" || normalizedHost == "localhost" || normalizedHost == "::1"
    }

    /// Validates the configuration. Returns an error description if invalid.
    public var validationError: String? {
        if !isEnabled { return nil }
        if normalizedHost.isEmpty {
            return "Gateway host must not be empty."
        }
        if port < 1 || port > 65535 {
            return "Gateway port must be between 1 and 65535."
        }
        if normalizedHost == "0.0.0.0" || normalizedHost == "::" {
            return "Gateway wildcard bind addresses are not allowed. Use a specific interface address."
        }
        if !Self.isValidHost(normalizedHost) {
            return "Gateway host '\(host)' is not a valid hostname or IP address."
        }
        let hasAuthToken = (authToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !hasAuthToken {
            if !isLoopback {
                return "A non-loopback gateway bind address requires an auth token for security."
            }
            // Fail-closed on loopback too: any same-host process can reach the
            // gateway and spend the user's provider credits without a token.
            if !allowUnauthenticatedLoopback {
                return "The gateway requires an auth token. Enable \"Allow unauthenticated loopback\" to bind 127.0.0.1 without one."
            }
        }
        return nil
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" {
            return true
        }

        var ipv4 = in_addr()
        return inet_pton(AF_INET, host, &ipv4) == 1
    }
}

public struct BurnBarDaemonConfiguration: Sendable {
    public let socketPath: String
    public let socketAuthToken: String?
    public let daemonVersion: String
    public let catalog: BurnBarCatalog
    /// Read-only path to the OpenBurnBar app SQLite database (`openburnbar.sqlite`) for indexed search RPC.
    public let indexDatabasePath: String?
    /// HTTP gateway configuration for OpenBurnBar Hydrant client access.
    public let gateway: BurnBarGatewayConfiguration
    /// Rate limiting configuration for Unix domain socket RPC.
    /// Default: 60 req/s sustained, 100 burst.
    public let socketRateLimit: BurnBarRateLimitConfiguration
    /// Starts Mission Control's scheduler/notification background loop when the daemon boots.
    /// Production keeps this on; tests and narrow socket harnesses should disable it unless
    /// they explicitly exercise scheduler behavior with isolated Mission Control storage.
    public let startsMissionControlBackgroundLoops: Bool

    public init(
        socketPath: String = BurnBarDaemonPaths.defaultSocketPath,
        socketAuthToken: String? = nil,
        daemonVersion: String = BurnBarDaemonVersion.current,
        catalog: BurnBarCatalog = BurnBarCatalogLoader.bundledCatalog,
        indexDatabasePath: String? = nil,
        gateway: BurnBarGatewayConfiguration = BurnBarGatewayConfiguration(),
        socketRateLimit: BurnBarRateLimitConfiguration = BurnBarRateLimitConfiguration(
            requestsPerSecond: 60,
            burstCapacity: 100
        ),
        startsMissionControlBackgroundLoops: Bool = true
    ) {
        self.socketPath = socketPath
        self.socketAuthToken = socketAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.daemonVersion = daemonVersion
        self.catalog = catalog
        self.indexDatabasePath = indexDatabasePath
        self.gateway = gateway
        self.socketRateLimit = socketRateLimit
        self.startsMissionControlBackgroundLoops = startsMissionControlBackgroundLoops
    }

    /// Validates that required configuration is present.
    /// The daemon refuses to start without a socket auth token to prevent
    /// unauthenticated local processes from issuing RPC commands.
    public enum ValidationError: Error, LocalizedError {
        case missingSocketAuthToken

        public var errorDescription: String? {
            switch self {
            case .missingSocketAuthToken:
                return "Socket auth token is required. Provide it via --socket-auth-token TOKEN or OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN environment variable. The OpenBurnBar app automatically generates and passes a token."
            }
        }
    }

    /// Throws if the configuration is invalid (e.g., missing required auth token).
    public func validate() throws {
        guard let token = socketAuthToken, !token.isEmpty else {
            throw ValidationError.missingSocketAuthToken
        }
    }
}
