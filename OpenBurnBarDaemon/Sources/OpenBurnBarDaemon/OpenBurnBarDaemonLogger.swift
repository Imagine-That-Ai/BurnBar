import Foundation
import OSLog

public struct BurnBarDaemonLogger: Sendable {
    private let logger: Logger

    public init(
        subsystem: String = "com.openburnbar.daemon",
        category: String = "bootstrap"
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ event: String, metadata: [String: String] = [:]) {
        logger.debug("\(format(event: event, metadata: metadata), privacy: .public)")
    }

    public func info(_ event: String, metadata: [String: String] = [:]) {
        logger.info("\(format(event: event, metadata: metadata), privacy: .public)")
    }

    public func notice(_ event: String, metadata: [String: String] = [:]) {
        logger.notice("\(format(event: event, metadata: metadata), privacy: .public)")
    }

    public func warning(_ event: String, metadata: [String: String] = [:]) {
        logger.warning("\(format(event: event, metadata: metadata), privacy: .public)")
    }

    public func error(_ event: String, metadata: [String: String] = [:]) {
        logger.error("\(format(event: event, metadata: metadata), privacy: .public)")
    }

    /// Log a failed operation that was intentionally handled silently.
    public func silentFailure(_ operation: String, error: Error, context: [String: String] = [:]) {
        var metadata = context
        metadata["error"] = String(describing: error)
        logger.warning("Silent failure: \(format(event: operation, metadata: metadata), privacy: .public)")
    }

    private func format(event: String, metadata: [String: String]) -> String {
        guard !metadata.isEmpty else {
            return "event=\(event)"
        }

        let fields = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        return "event=\(event) \(fields)"
    }
}
