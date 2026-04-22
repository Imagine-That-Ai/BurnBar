import Foundation
import OSLog

/// Structured logger for AgentLens with category-based filtering.
///
/// Mirrors the pattern used in `BurnBarDaemonLogger` for consistency.
/// Use `AppLogger.shared` for the default logger or create category-specific loggers.
public struct AppLogger: Sendable {
    
    private let logger: Logger
    
    /// Shared default logger instance.
    public static let shared = AppLogger(category: "app")
    
    // MARK: - Category-Specific Loggers
    
    public static let dataStore = AppLogger(category: "data")
    public static let chat = AppLogger(category: "chat")
    public static let search = AppLogger(category: "search")
    public static let sync = AppLogger(category: "sync")
    public static let network = AppLogger(category: "network")
    public static let parser = AppLogger(category: "parser")
    
    // MARK: - Initialization
    
    public init(
        subsystem: String = "com.openburnbar.agentlens",
        category: String = "general"
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }
    
    // MARK: - Logging Methods
    
    /// Log a debug message (only in DEBUG builds).
    public func debug(_ event: String, metadata: [String: String] = [:]) {
        #if DEBUG
        logger.debug("\(Self.format(event: event, metadata: metadata), privacy: .public)")
        #endif
    }
    
    /// Log an informational message.
    public func info(_ event: String, metadata: [String: String] = [:]) {
        logger.info("\(Self.format(event: event, metadata: metadata), privacy: .public)")
    }
    
    /// Log a notable event that should be observed.
    public func notice(_ event: String, metadata: [String: String] = [:]) {
        logger.notice("\(Self.format(event: event, metadata: metadata), privacy: .public)")
    }
    
    /// Log an error that should be investigated.
    public func error(_ event: String, metadata: [String: String] = [:]) {
        logger.error("\(Self.format(event: event, metadata: metadata), privacy: .public)")
    }
    
    // MARK: - Convenience Methods for Silent Failures
    
    /// Log a failed operation that was intentionally handled silently.
    /// Use this for operations where failure is expected/acceptable but worth tracking.
    public func silentFailure(
        _ operation: String,
        error: Error,
        context: [String: String] = [:]
    ) {
        var metadata = context
        metadata["error"] = String(describing: error)
        logger.warning("Silent failure: \(Self.format(event: operation, metadata: metadata), privacy: .public)")
    }
    
    /// Execute a throwing expression, logging failures silently and returning a fallback value.
    /// Replaces `try? expr` patterns where failure should be tracked.
    public func silently<T>(
        _ operation: String,
        _ body: @autoclosure () throws -> T,
        fallback: T
    ) -> T {
        do {
            return try body()
        } catch {
            silentFailure(operation, error: error)
            return fallback
        }
    }
    
    // MARK: - Formatting
    
    private static func format(event: String, metadata: [String: String]) -> String {
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
