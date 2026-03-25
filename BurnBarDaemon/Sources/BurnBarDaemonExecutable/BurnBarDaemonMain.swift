import BurnBarDaemon
import Darwin
import Dispatch
import Foundation

@main
struct BurnBarDaemonExecutable {
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
        var socketPath = environment["BURNBAR_DAEMON_SOCKET_PATH"] ?? BurnBarDaemonPaths.defaultSocketPath
        var daemonVersion = environment["BURNBAR_DAEMON_VERSION"] ?? BurnBarDaemonVersion.current
        var indexDatabasePath = environment["BURNBAR_INDEX_DATABASE_PATH"]

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
            case "--help":
                print(
                    """
                    Usage: BurnBarDaemon [--socket-path PATH] [--index-database-path PATH] [--version VERSION]

                    Environment overrides:
                      BURNBAR_DAEMON_SOCKET_PATH
                      BURNBAR_DAEMON_VERSION
                      BURNBAR_INDEX_DATABASE_PATH
                    """
                )
                Darwin.exit(EXIT_SUCCESS)
            default:
                throw BurnBarDaemonCommandLineError.unknownArgument(argument)
            }
            index += 1
        }

        let trimmedIndexPath = indexDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BurnBarDaemonConfiguration(
            socketPath: socketPath,
            daemonVersion: daemonVersion,
            indexDatabasePath: (trimmedIndexPath?.isEmpty == false) ? trimmedIndexPath : nil
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
            return "Unknown BurnBarDaemon argument \(argument)."
        }
    }
}

private final class BurnBarSignalMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let continuation: AsyncStream<Int32>.Continuation
    private let stream: AsyncStream<Int32>
    private let sources: [DispatchSourceSignal]

    init(signals: [Int32]) {
        let queue = DispatchQueue(label: "com.burnbar.daemon.signal-monitor")
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
