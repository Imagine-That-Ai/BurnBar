import Foundation

/// Cross-surface correlation context for logs, RPC, and relay frames.
public struct TraceContext: Sendable, Equatable, Codable {
    public var traceID: String
    public var sessionID: String?
    public var userIDHash: String?

    public init(traceID: String = UUID().uuidString, sessionID: String? = nil, userIDHash: String? = nil) {
        self.traceID = traceID
        self.sessionID = sessionID
        self.userIDHash = userIDHash
    }

    public func logFields() -> [String: String] {
        var fields = ["trace_id": traceID]
        if let sessionID { fields["session_id"] = sessionID }
        if let userIDHash { fields["user_id_hash"] = userIDHash }
        return fields
    }

    public func formattedMetadata() -> String {
        logFields()
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}

public enum TraceContextBridge {
    private static let lock = NSLock()
    private static var current = TraceContext()

    public static func currentContext() -> TraceContext {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public static func replace(_ context: TraceContext) {
        lock.lock()
        current = context
        lock.unlock()
    }

    public static func withContext<T>(_ context: TraceContext, operation: () throws -> T) rethrows -> T {
        let previous = currentContext()
        replace(context)
        defer { replace(previous) }
        return try operation()
    }
}
