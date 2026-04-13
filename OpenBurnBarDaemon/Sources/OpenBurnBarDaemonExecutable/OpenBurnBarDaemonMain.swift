import OpenBurnBarDaemon
import Darwin
import Dispatch
import Foundation

@main
struct OpenBurnBarDaemonExecutable {
    static func main() async throws {
        let configuration = try BurnBarDaemonCommandLine.makeConfiguration(
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: ProcessInfo.processInfo.environment
        )
        let logger = BurnBarDaemonLogger(category: "process")
        let server = BurnBarDaemonServer(configuration: configuration, logger: logger)

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
        await server.stop()
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

                    Environment overrides:
                      OPENBURNBAR_DAEMON_SOCKET_PATH
                      OPENBURNBAR_DAEMON_VERSION
                      OPENBURNBAR_INDEX_DATABASE_PATH
                      OPENBURNBAR_GATEWAY_ENABLED=1
                      OPENBURNBAR_GATEWAY_HOST
                      OPENBURNBAR_GATEWAY_PORT
                      OPENBURNBAR_GATEWAY_AUTH_TOKEN
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
            authToken: gatewayAuthToken
        )
        return BurnBarDaemonConfiguration(
            socketPath: socketPath,
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

private final class BurnBarSignalMonitor: @unchecked Sendable {
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
