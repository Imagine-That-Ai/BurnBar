import Foundation
import OpenBurnBarCore

// MARK: - BurnBarConnectionGate

/// Bounded concurrency gate for the daemon accept loop.
///
/// Round-4 perf sweep: `runAcceptLoop` previously spawned an unbounded
/// `Task.detached` per accepted connection with no upper bound on concurrent
/// handlers. A burst of clients (e.g. multiple devices + CI + extensions)
/// could exhaust file descriptors or memory before the per-RPC rate limiter
/// even saw a request. This gate caps the number of simultaneously in-flight
/// connection handlers; connections that arrive while the gate is full are
/// closed immediately with a logged "server_busy" rejection, which is the
/// correct back-pressure signal for a local Unix-domain-socket daemon — the
/// client's retry is cheap and immediate.
///
/// The gate is a `Sendable` value backed by `Locked<Int>` so it can be
/// captured by the static `runAcceptLoop` and the per-connection
/// `Task.detached` without crossing actor boundaries.
final class BurnBarConnectionGate: Sendable {
    private let active = Locked<Int>(0)
    private let maxConcurrent: Int

    /// Default cap: 128 concurrent connections. A local daemon serving one
    /// user + a handful of devices rarely exceeds single digits; 128 is
    /// generous headroom that still prevents FD exhaustion (default Darwin
    /// `ulimit -n` is 256).
    static let defaultMaxConcurrent = 128

    init(maxConcurrent: Int = BurnBarConnectionGate.defaultMaxConcurrent) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Attempt to admit a new connection. Returns `true` if the connection
    /// was admitted (caller must call `release()` when done), `false` if the
    /// gate is at capacity (caller should close the FD immediately).
    func tryAcquire() -> Bool {
        active.withLock { count in
            guard count < maxConcurrent else { return false }
            count += 1
            return true
        }
    }

    /// Release a previously-admitted connection.
    func release() {
        active.withLock { count in
            if count > 0 { count -= 1 }
        }
    }

    /// Current number of in-flight connections (diagnostic/test surface).
    var activeCount: Int {
        active.read()
    }

    /// The configured maximum (diagnostic/test surface).
    var maxCount: Int {
        maxConcurrent
    }
}
