import Foundation
import OSLog
import OpenBurnBarCore

/// Abstraction over structured daemon logging so tests can intercept log
/// emissions without coupling to `OSLog`. Production code uses
/// ``BurnBarDaemonLogger`` exclusively; test code injects a capturing stub.
public protocol BurnBarDaemonLogging: Sendable {
    func debug(_ event: String, metadata: [String: String])
    func info(_ event: String, metadata: [String: String])
    func notice(_ event: String, metadata: [String: String])
    func warning(_ event: String, metadata: [String: String])
    func error(_ event: String, metadata: [String: String])
    func silentFailure(_ operation: String, error: Error, context: [String: String])
}

extension BurnBarDaemonLogging {
    public func debug(_ event: String) {
        debug(event, metadata: [:])
    }

    public func info(_ event: String) {
        info(event, metadata: [:])
    }

    public func notice(_ event: String) {
        notice(event, metadata: [:])
    }

    public func warning(_ event: String) {
        warning(event, metadata: [:])
    }

    public func error(_ event: String) {
        error(event, metadata: [:])
    }

    public func silentFailure(_ operation: String, error: Error) {
        silentFailure(operation, error: error, context: [:])
    }
}

public struct BurnBarDaemonLogger: Sendable {
    private let logger: Logger

    public init(
        subsystem: String = "com.openburnbar.daemon",
        category: String = "bootstrap"
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ event: String, metadata: [String: String] = [:]) {
        logger.debug("\(format(event: event, metadata: metadata), privacy: .private)")
    }

    public func info(_ event: String, metadata: [String: String] = [:]) {
        logger.info("\(format(event: event, metadata: metadata), privacy: .private)")
    }

    public func notice(_ event: String, metadata: [String: String] = [:]) {
        logger.notice("\(format(event: event, metadata: metadata), privacy: .private)")
    }

    public func warning(_ event: String, metadata: [String: String] = [:]) {
        logger.warning("\(format(event: event, metadata: metadata), privacy: .private)")
    }

    public func error(_ event: String, metadata: [String: String] = [:]) {
        logger.error("\(format(event: event, metadata: metadata), privacy: .private)")
    }

    /// Log a failed operation that was intentionally handled silently.
    public func silentFailure(_ operation: String, error: Error, context: [String: String] = [:]) {
        var metadata = context
        metadata["error"] = String(describing: error)
        logger.warning("Silent failure: \(format(event: operation, metadata: metadata), privacy: .public)")
    }

    private func format(event: String, metadata: [String: String]) -> String {
        var merged = TraceContextBridge.currentContext().logFields()
        for (key, value) in metadata {
            merged[key] = sanitize(value)
        }
        guard !merged.isEmpty else {
            return "event=\(event)"
        }

        let fields = merged
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        return "event=\(event) \(fields)"
    }

    private func sanitize(_ value: String) -> String {
        if value.count > 120 {
            return String(value.prefix(117)) + "..."
        }
        return value
    }
}

// MARK: - BurnBarDaemonLogging conformance

extension BurnBarDaemonLogger: BurnBarDaemonLogging {}
