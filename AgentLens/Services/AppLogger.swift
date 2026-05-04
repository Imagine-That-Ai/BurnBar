import Foundation
import OSLog

#if canImport(Sentry)
import Sentry
#endif

/// Structured logger for AgentLens with category-based filtering.
///
/// Mirrors the pattern used in `BurnBarDaemonLogger` for consistency.
/// Use `AppLogger.shared` for the default logger or create category-specific loggers.
public struct AppLogger: Sendable {
    
    private let logger: Logger
    private let category: String
    
    /// Shared default logger instance.
    public static let shared = AppLogger(category: "app")
    
    // MARK: - Category-Specific Loggers
    
    public static let dataStore = AppLogger(category: "data")
    public static let chat = AppLogger(category: "chat")
    public static let search = AppLogger(category: "search")
    public static let sync = AppLogger(category: "sync")
    public static let network = AppLogger(category: "network")
    public static let parser = AppLogger(category: "parser")
    public static let metrics = AppLogger(category: "metrics")
    
    // MARK: - Initialization
    
    public init(
        subsystem: String = "com.openburnbar.agentlens",
        category: String = "general"
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }
    
    // MARK: - Sanitization
    
    /// Keys whose values should be fully redacted from telemetry.
    private static let sensitiveKeys: Set<String> = [
        "token", "apiKey", "api_key", "apikey", "auth", "authorization", "bearer",
        "password", "secret", "cookie", "refreshToken", "accessToken", "idToken",
        "credential", "privateKey", "x-api-key", "x_auth_token", "firebase_auth",
        "prompt", "message", "content", "body", "chatBody", "projectName", "model",
        "project_name", "model_name", "model_id", "path", "filePath", "file_path",
        "directory", "url", "home", "HOME", "ssh_key", "key_path", "private_key",
        "cert", "certificate", "session_log", "log_path", "db_path", "database_path",
    ]
    
    /// Substrings that indicate a value contains sensitive material.
    private static let sensitiveValuePatterns: [String] = [
        "sk-", "bearer ", "token=", "apikey=", "secret=", "password=",
        "/Users/", "~", ".ssh", ".aws", ".env", "keychain", "BEGIN RSA",
        "BEGIN OPENSSH", "-----BEGIN",
    ]
    
    /// Sanitizes metadata before it leaves the process boundary (e.g. to Sentry).
    /// - Redacts values for known sensitive keys.
    /// - Redacts values that look like paths, tokens, or auth headers.
    /// - Truncates free-form text fields that may contain user content.
    ///
    /// This is a defense-in-depth layer: OSLog already uses `.private` hashing,
    /// but Sentry breadcrumbs receive raw dictionaries unless we scrub them first.
    public static func sanitizeMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [String: String]()) { result, entry in
            let key = entry.key.lowercased()
            let value = entry.value
            
            // Full redaction for known sensitive keys
            if sensitiveKeys.contains(key) || sensitiveKeys.contains(entry.key.lowercased()) {
                result[entry.key] = "[REDACTED]"
                return
            }
            
            // Partial pattern match on key name
            let keyContainsSensitive = sensitiveKeys.contains(where: { key.contains($0) })
            
            // Check value for sensitive patterns
            let lowerValue = value.lowercased()
            let valueLooksSensitive = sensitiveValuePatterns.contains(where: { lowerValue.contains($0.lowercased()) })
            
            if keyContainsSensitive || valueLooksSensitive {
                result[entry.key] = "[REDACTED]"
                return
            }
            
            // Truncate long free-form values that could contain prompts or logs
            if value.count > 500 {
                result[entry.key] = String(value.prefix(500)) + "...[TRUNCATED]"
            } else {
                result[entry.key] = value
            }
        }
    }
    
    // MARK: - Logging Methods
    
    /// Log a debug message (only in DEBUG builds).
    public func debug(_ event: String, metadata: [String: String] = [:]) {
        #if DEBUG
        logger.debug("event=\(event, privacy: .public)")
        logMetadata(metadata, at: .debug)
        #endif
    }
    
    /// Log an informational message.
    public func info(_ event: String, metadata: [String: String] = [:]) {
        logger.info("event=\(event, privacy: .public)")
        logMetadata(metadata, at: .info)
    }
    
    /// Log a notable event that should be observed.
    public func notice(_ event: String, metadata: [String: String] = [:]) {
        logger.notice("event=\(event, privacy: .public)")
        logMetadata(metadata, at: .default)
    }
    
    /// Log an error that should be investigated.
    public func error(_ event: String, metadata: [String: String] = [:]) {
        logger.error("event=\(event, privacy: .public)")
        logMetadata(metadata, at: .error)
        #if canImport(Sentry)
        let breadcrumb = Breadcrumb(level: .error, category: category)
        breadcrumb.message = event
        breadcrumb.data = Self.sanitizeMetadata(metadata)
        SentrySDK.addBreadcrumb(breadcrumb)
        #endif
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
        logger.warning("Silent failure: event=\(operation, privacy: .public)")
        logMetadata(metadata, at: .default)
        #if canImport(Sentry)
        let breadcrumb = Breadcrumb(level: .warning, category: category)
        breadcrumb.message = operation
        breadcrumb.data = Self.sanitizeMetadata(metadata)
        SentrySDK.addBreadcrumb(breadcrumb)
        #endif
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
    
    /// Log metadata pairs with private values (hashed in production logs).
    private func logMetadata(_ metadata: [String: String], at level: OSLogType = .default) {
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            logger.log(level: level, "\(key, privacy: .public)=\(value, privacy: .private(mask: .hash))")
        }
    }
}
