import Foundation

/// Process-wide RPC counters surfaced on `GET /metrics`.
///
/// Intentionally lock-based (not actor-isolated) so hot RPC paths can increment
/// without awaiting. See `docs/runbooks/slos.md` for SLO probe names.
public enum BurnBarDaemonMetricsCounters {
    private static let lock = NSLock()
    private static var rpcRequestsTotal = 0
    private static var rpcErrorsTotal = 0

    public static func recordRPCRequest() {
        lock.lock()
        rpcRequestsTotal &+= 1
        lock.unlock()
    }

    public static func recordRPCError() {
        lock.lock()
        rpcErrorsTotal &+= 1
        lock.unlock()
    }

    public static func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "rpc_requests_total": rpcRequestsTotal,
            "rpc_errors_total": rpcErrorsTotal,
        ]
    }

    #if DEBUG
    /// Resets counters for unit tests only.
    public static func _resetForTesting() {
        lock.lock()
        rpcRequestsTotal = 0
        rpcErrorsTotal = 0
        lock.unlock()
    }
    #endif
}
