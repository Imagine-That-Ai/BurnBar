import OpenBurnBarDaemon
import OpenBurnBarCore
import Darwin
import Dispatch
import Foundation

#if canImport(Sentry)
import Sentry
#endif

@main
struct OpenBurnBarDaemonExecutable {
    static func main() async throws {
        // Disable the shared URLCache disk store. URLSession.shared uses a
        // persistent disk cache at ~/Library/Caches/OpenBurnBarDaemon/Cache.db
        // that is prone to SQLite WAL corruption when the daemon is restarted
        // by launchd while the cache is still active.  A nil URLCache forces
        // all URLSession.shared requests to use an in-memory or no-cache policy,
        // preventing the disk I/O error loop that blocks the socket RPC thread.
        URLCache.shared = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)

        #if canImport(Sentry)
        configureSentryIfAvailable()
        #endif
        let configuration = try BurnBarDaemonCommandLine.makeConfiguration(
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: ProcessInfo.processInfo.environment
        )
        try configuration.validate()
        let logger = BurnBarDaemonLogger(category: "process")
        let peerAuthenticator = makePeerAuthenticator(
            environment: ProcessInfo.processInfo.environment,
            logger: logger
        )
        let server = BurnBarDaemonServer(
            configuration: configuration,
            logger: logger,
            peerAuthenticator: peerAuthenticator
        )
        let pensieveWatcher = makePensieveKnowledgeWatcher(
            environment: ProcessInfo.processInfo.environment,
            logger: logger
        )
        pensieveWatcher?.start()

        try await server.start()

        logger.notice(
            "process_ready",
            metadata: [
                "socket_path": configuration.socketPath,
                "daemon_version": configuration.daemonVersion
            ]
        )

        let signal = await BurnBarSignalMonitor(signals: [SIGINT, SIGTERM]).waitForSignal()
        logger.notice("shutdown_signal_received", metadata: ["signal": "\(signal)"])
        pensieveWatcher?.stop()
        await server.stop()
    }
}

/// RR-3: build the control-socket peer authenticator for this process.
///
/// Enforcement of the first-party code-signature gate is ON by default — a
/// production daemon refuses any accepted peer that does not satisfy the
/// canonical designated requirement. Unsigned developer builds (where no binary
/// can carry the first-party identity) opt out with
/// `OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1`, mirroring the fail-closed-by-default
/// escape hatch the HTTP gateway uses for unauthenticated loopback binds. The
/// opt-out is logged loudly so a misconfiguration is never silent.
private func makePeerAuthenticator(
    environment: [String: String],
    logger: BurnBarDaemonLogger
) -> BurnBarDaemonPeerAuthenticator {
    let disabled = environment["OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG"] == "1"
        || environment["BURNBAR_DAEMON_DISABLE_PEER_CODESIG"] == "1"
    if disabled {
        logger.warning(
            "rpc_peer_code_signature_enforcement_disabled",
            metadata: ["reason": "OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1"]
        )
        return .disabled
    }
    return BurnBarDaemonPeerAuthenticator(enforced: true, logger: logger)
}

private func makePensieveKnowledgeWatcher(
    environment: [String: String],
    logger: BurnBarDaemonLogger
) -> PensieveKnowledgeWatcher? {
    let repoDocsURL = environment["OPENBURNBAR_PENSIEVE_REPO_DOCS_PATH"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    let notesURL = environment["OPENBURNBAR_PENSIEVE_NOTES_PATH"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    let roots = PensieveKnowledgeWatcher.standardRoots(
        repoDocsURL: repoDocsURL,
        notesURL: notesURL
    )
    guard roots.isEmpty == false else { return nil }

    let uid = environment["OPENBURNBAR_PENSIEVE_VAULT_UID"] ?? environment["OPENBURNBAR_USER_ID"]
    let trimmedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyStore = CloudVaultKeyStore(service: "com.openburnbar.cloud-vault")
    logger.notice(
        "pensieve_watcher_configured",
        metadata: [
            "root_count": "\(roots.count)",
            "vault_uid_present": "\(trimmedUID?.isEmpty == false)"
        ]
    )
    return PensieveKnowledgeWatcher(roots: roots) {
        guard let trimmedUID, trimmedUID.isEmpty == false else { return nil }
        return try? keyStore.loadKey(uid: trimmedUID)
    }
}

private enum BurnBarDaemonCommandLine {
    static func makeConfiguration(
        arguments: [String],
        environment: [String: String]
    ) throws -> BurnBarDaemonConfiguration {
        var socketPath = environment["OPENBURNBAR_DAEMON_SOCKET_PATH"]
            ?? environment["BURNBAR_DAEMON_SOCKET_PATH"]
            ?? BurnBarDaemonPaths.defaultSocketPath
        var daemonVersion = environment["OPENBURNBAR_DAEMON_VERSION"]
            ?? environment["BURNBAR_DAEMON_VERSION"]
            ?? BurnBarDaemonVersion.current
        var indexDatabasePath = environment["OPENBURNBAR_INDEX_DATABASE_PATH"]
            ?? environment["BURNBAR_INDEX_DATABASE_PATH"]
        var gatewayEnabled = environment["OPENBURNBAR_GATEWAY_ENABLED"] == "1"
            || environment["BURNBAR_GATEWAY_ENABLED"] == "1"
        var gatewayHost = environment["OPENBURNBAR_GATEWAY_HOST"]
            ?? environment["BURNBAR_GATEWAY_HOST"]
            ?? "127.0.0.1"
        var gatewayPort = Int(environment["OPENBURNBAR_GATEWAY_PORT"]
            ?? environment["BURNBAR_GATEWAY_PORT"]
            ?? "8317") ?? 8317
        var gatewayAuthToken = environment["OPENBURNBAR_GATEWAY_AUTH_TOKEN"]
            ?? environment["BURNBAR_GATEWAY_AUTH_TOKEN"]
        var gatewayAllowUnauthenticatedLoopback = environment["OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK"] == "1"
            || environment["BURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK"] == "1"
        var socketAuthToken = environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]
            ?? environment["BURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--socket-path":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                socketPath = arguments[index]
            case "--index-database-path":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                indexDatabasePath = arguments[index]
            case "--version":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                daemonVersion = arguments[index]
            case "--gateway-enable":
                gatewayEnabled = true
            case "--gateway-host":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                gatewayHost = arguments[index]
            case "--gateway-port":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                gatewayPort = Int(arguments[index]) ?? 8317
            case "--gateway-auth-token":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                gatewayAuthToken = arguments[index]
            case "--gateway-allow-unauthenticated-loopback":
                gatewayAllowUnauthenticatedLoopback = true
            case "--socket-auth-token":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                socketAuthToken = arguments[index]
            case "--help":
                print(
                    """
                    Usage: OpenBurnBarDaemon [OPTIONS]

                    Options:
                      --socket-path PATH          Unix socket path for RPC
                      --index-database-path PATH  SQLite database path for search
                      --version VERSION            Daemon version string
                      --gateway-enable             Enable the HTTP gateway
                      --gateway-host HOST          Gateway bind host (default 127.0.0.1)
                      --gateway-port PORT          Gateway port (default 8317)
                      --gateway-auth-token TOKEN   Bearer token for gateway auth
                      --gateway-allow-unauthenticated-loopback
                                                   Opt out of gateway auth on a loopback bind (unsafe)
                      --socket-auth-token TOKEN    (Required) Auth token for daemon socket RPC

                    Environment overrides:
                      OPENBURNBAR_DAEMON_SOCKET_PATH
                      OPENBURNBAR_DAEMON_VERSION
                      OPENBURNBAR_INDEX_DATABASE_PATH
                      OPENBURNBAR_GATEWAY_ENABLED=1
                      OPENBURNBAR_GATEWAY_HOST
                      OPENBURNBAR_GATEWAY_PORT
                      OPENBURNBAR_GATEWAY_AUTH_TOKEN
                      OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK=1
                      OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN
                    """
                )
                Darwin.exit(EXIT_SUCCESS)
            default:
                throw BurnBarDaemonCommandLineError.unknownArgument(argument)
            }
            index += 1
        }

        let trimmedIndexPath = indexDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let gateway = BurnBarGatewayConfiguration(
            isEnabled: gatewayEnabled,
            host: gatewayHost,
            port: gatewayPort,
            authToken: gatewayAuthToken,
            allowUnauthenticatedLoopback: gatewayAllowUnauthenticatedLoopback
        )
        return BurnBarDaemonConfiguration(
            socketPath: socketPath,
            socketAuthToken: socketAuthToken,
            daemonVersion: daemonVersion,
            indexDatabasePath: (trimmedIndexPath?.isEmpty == false) ? trimmedIndexPath : nil,
            gateway: gateway
        )
    }
}

private enum BurnBarDaemonCommandLineError: Error, LocalizedError {
    case missingValue(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let argument):
            return "Missing value for command-line option \(argument)."
        case .unknownArgument(let argument):
            return "Unknown OpenBurnBarDaemon argument \(argument)."
        }
    }
}

#if canImport(Sentry)
private func configureSentryIfAvailable() {
    guard let dsn = ProcessInfo.processInfo.environment["OPENBURNBAR_SENTRY_DSN"],
          !dsn.trimmingCharacters(in: .whitespaces).isEmpty else {
        return
    }
    SentrySDK.start { options in
        options.dsn = dsn
        options.environment = "daemon"
        options.releaseName = "openburnbar-daemon@\(BurnBarDaemonVersion.current)"
        options.tracesSampleRate = 0.0
        #if DEBUG
        options.debug = false
        #endif
    }
}
#endif

// All stored properties are let; DispatchSourceSignal sources are immutable after init.
// Formally Sendable because no mutable state exists post-init.
private final class BurnBarSignalMonitor: Sendable {
    private let queue: DispatchQueue
    private let continuation: AsyncStream<Int32>.Continuation
    private let stream: AsyncStream<Int32>
    private let sources: [DispatchSourceSignal]

    init(signals: [Int32]) {
        let queue = DispatchQueue(label: "com.openburnbar.daemon.signal-monitor")
        var storedContinuation: AsyncStream<Int32>.Continuation?
        self.stream = AsyncStream { continuation in
            storedContinuation = continuation
        }
        self.continuation = storedContinuation!
        self.queue = queue
        let continuation = self.continuation

        self.sources = signals.map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [continuation] in
                continuation.yield(signalNumber)
            }
            source.resume()
            return source
        }
    }

    func waitForSignal() async -> Int32 {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? SIGTERM
    }
}
