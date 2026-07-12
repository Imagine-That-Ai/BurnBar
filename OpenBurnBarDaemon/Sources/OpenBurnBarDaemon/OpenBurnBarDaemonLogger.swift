import Foundation
#if canImport(OSLog)
import OSLog
#endif
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
#if canImport(OSLog)
    private let logger: Logger
#else
    private let subsystem: String
    private let category: String
#endif

    public init(
        subsystem: String = "com.openburnbar.daemon",
        category: String = "bootstrap"
    ) {
#if canImport(OSLog)
        self.logger = Logger(subsystem: subsystem, category: category)
#else
        self.subsystem = subsystem
        self.category = category
#endif
    }

    public func debug(_ event: String, metadata: [String: String] = [:]) {
#if canImport(OSLog)
        logger.debug("\(format(event: event, metadata: metadata), privacy: .private)")
#else
        emit("debug", event: event, metadata: metadata)
#endif
    }

    public func info(_ event: String, metadata: [String: String] = [:]) {
#if canImport(OSLog)
        logger.info("\(format(event: event, metadata: metadata), privacy: .private)")
#else
        emit("info", event: event, metadata: metadata)
#endif
    }

    public func notice(_ event: String, metadata: [String: String] = [:]) {
#if canImport(OSLog)
        logger.notice("\(format(event: event, metadata: metadata), privacy: .private)")
#else
        emit("notice", event: event, metadata: metadata)
#endif
    }

    public func warning(_ event: String, metadata: [String: String] = [:]) {
#if canImport(OSLog)
        logger.warning("\(format(event: event, metadata: metadata), privacy: .private)")
#else
        emit("warning", event: event, metadata: metadata)
#endif
    }

    public func error(_ event: String, metadata: [String: String] = [:]) {
#if canImport(OSLog)
        logger.error("\(format(event: event, metadata: metadata), privacy: .private)")
#else
        emit("error", event: event, metadata: metadata)
#endif
    }

    /// Log a failed operation that was intentionally handled silently.
    public func silentFailure(_ operation: String, error: Error, context: [String: String] = [:]) {
        var metadata = context
        metadata["error"] = String(describing: error)
#if canImport(OSLog)
        logger.warning("Silent failure: \(format(event: operation, metadata: metadata), privacy: .public)")
#else
        emit("warning", event: "silent_failure.\(operation)", metadata: metadata)
#endif
    }

#if !canImport(OSLog)
    private func emit(_ level: String, event: String, metadata: [String: String]) {
        let line = "\(Date()) level=\(level) subsystem=\(subsystem) category=\(category) \(format(event: event, metadata: metadata))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
#endif

    private func format(event: String, metadata: [String: String]) -> String {
        var merged = TraceContextBridge.currentContext().logFields().mapValues(Self.redactedMetadataValue)
        for (key, value) in metadata {
            merged[key] = Self.redactedMetadataValue(value)
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

    static func redactedMetadataValue(_ value: String) -> String {
        var output = value
        let patterns = [
            #"(?i)\bBearer\s+[A-Za-z0-9._~+\-/=]+"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            #"(?i)\b(refresh[_-]?token|id[_-]?token|app[_-]?check[_-]?token|authorization|api[_-]?key|secret|private[_-]?key)\s*[:=]\s*[^\s,;]+"#,
            #"\bAIza[0-9A-Za-z_-]{16,}\b"#
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        output = output.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if output.count > 120 {
            return String(output.prefix(117)) + "..."
        }
        return output
    }
}

// MARK: - BurnBarDaemonLogging conformance

extension BurnBarDaemonLogger: BurnBarDaemonLogging {}
