import Foundation

/// Supervision state for the OpenBurnBar daemon process.
///
/// The supervisor tracks consecutive health-check failures and applies
/// exponential backoff before retrying, preventing CPU-wasting tight loops
/// when the daemon is in a crash loop (launchd restarts it, it crashes
/// immediately, we poll → fail → repeat).
enum OpenBurnBarDaemonSupervisionState: Equatable, Sendable {
    /// No supervision active (daemon has not been checked yet).
    case idle
    /// Daemon is healthy; no backoff needed.
    case healthy
    /// Daemon is unhealthy but within normal retry bounds.
    /// `consecutiveFailures` tracks how many health checks have failed in a row.
    /// `nextRetryAt` is the earliest time the next health probe should fire.
    case retrying(consecutiveFailures: Int, nextRetryAt: Date)
    /// Daemon appears to be in a crash loop — it has failed more than
    /// `crashLoopThreshold` times within the detection window.
    /// The supervisor will not attempt restart until the backoff period
    /// expires, and the UI should surface a "needs repair" prompt.
    case crashLoop(consecutiveFailures: Int, nextRetryAt: Date, detectedAt: Date)

    var isCrashLoop: Bool {
        if case .crashLoop = self { return true }
        return false
    }

    var consecutiveFailures: Int {
        switch self {
        case .idle, .healthy: return 0
        case .retrying(let n, _), .crashLoop(let n, _, _): return n
        }
    }

    var nextRetryAt: Date? {
        switch self {
        case .idle, .healthy: return nil
        case .retrying(_, let date), .crashLoop(_, let date, _): return date
        }
    }
}

/// Configuration for the daemon supervisor's crash-loop detector.
struct OpenBurnBarDaemonSupervisorConfig: Sendable {
    /// Number of consecutive failures before entering crash-loop state.
    let crashLoopThreshold: Int
    /// Base delay for exponential backoff (seconds).
    let backoffBaseDelay: TimeInterval
    /// Maximum backoff delay (seconds).
    let backoffMaxDelay: TimeInterval
    /// Jitter factor (0..1) applied to backoff to avoid thundering-herd sync.
    let jitterFactor: Double
    /// How long (seconds) a crash-loop designation persists before the
    /// supervisor resets and allows a fresh retry sequence.
    let crashLoopResetInterval: TimeInterval

    init(
        crashLoopThreshold: Int = 5,
        backoffBaseDelay: TimeInterval = 2.0,
        backoffMaxDelay: TimeInterval = 120.0,
        jitterFactor: Double = 0.25,
        crashLoopResetInterval: TimeInterval = 300.0
    ) {
        self.crashLoopThreshold = crashLoopThreshold
        self.backoffBaseDelay = backoffBaseDelay
        self.backoffMaxDelay = backoffMaxDelay
        self.jitterFactor = jitterFactor
        self.crashLoopResetInterval = crashLoopResetInterval
    }
}

/// Stateless supervisor that decides the daemon's supervision state
/// after each health check. All state is carried via the
/// `OpenBurnBarDaemonSupervisionState` value; the supervisor itself
/// holds no mutable state so it can be tested deterministically.
enum OpenBurnBarDaemonSupervisor {
    /// Advance the supervision state after a health check.
    ///
    /// - Parameters:
    ///   - currentState: The supervision state before this health check.
    ///   - daemonIsHealthy: Whether the daemon responded to the health RPC.
    ///   - daemonIsInstalled: Whether launchd plist / binary are present.
    ///   - config: Supervisor configuration.
    ///   - now: Current time (injectable for testing).
    /// - Returns: The new supervision state.
    static func advance(
        from currentState: OpenBurnBarDaemonSupervisionState,
        daemonIsHealthy: Bool,
        daemonIsInstalled: Bool,
        config: OpenBurnBarDaemonSupervisorConfig = OpenBurnBarDaemonSupervisorConfig(),
        now: Date = Date()
    ) -> OpenBurnBarDaemonSupervisionState {
        // If daemon isn't installed, supervision is not applicable.
        guard daemonIsInstalled else { return .idle }

        if daemonIsHealthy {
            return .healthy
        }

        // Daemon is unhealthy. Compute backoff.
        let previousFailures = currentState.consecutiveFailures
        let newFailureCount = previousFailures + 1
        let backoff = computeBackoff(
            consecutiveFailures: newFailureCount,
            config: config
        )
        let nextRetryAt = now.addingTimeInterval(backoff)

        if newFailureCount >= config.crashLoopThreshold {
            return .crashLoop(
                consecutiveFailures: newFailureCount,
                nextRetryAt: nextRetryAt,
                detectedAt: now
            )
        }

        return .retrying(consecutiveFailures: newFailureCount, nextRetryAt: nextRetryAt)
    }

    /// Determine whether the supervisor should attempt a health probe right now.
    ///
    /// Returns `true` when there's no backoff active or the backoff period
    /// has expired. In crash-loop state, also checks whether the full
    /// reset interval has elapsed (allowing a fresh attempt).
    static func shouldProbeNow(
        state: OpenBurnBarDaemonSupervisionState,
        config: OpenBurnBarDaemonSupervisorConfig = OpenBurnBarDaemonSupervisorConfig(),
        now: Date = Date()
    ) -> Bool {
        switch state {
        case .idle, .healthy:
            return true
        case .retrying(_, let nextRetryAt):
            return now >= nextRetryAt
        case .crashLoop(_, let nextRetryAt, let detectedAt):
            // In crash-loop, allow one probe per backoff cycle.
            if now >= nextRetryAt { return true }
            // Also reset if the crash-loop interval has fully elapsed
            // (daemon may have been fixed externally).
            let resetAt = detectedAt.addingTimeInterval(config.crashLoopResetInterval)
            return now >= resetAt
        }
    }

    /// Reset the supervision state after a user-initiated repair or reinstall.
    /// This clears the failure counter so the supervisor starts fresh.
    static func resetAfterRepair() -> OpenBurnBarDaemonSupervisionState {
        .idle
    }

    // MARK: - Private

    private static func computeBackoff(
        consecutiveFailures: Int,
        config: OpenBurnBarDaemonSupervisorConfig
    ) -> TimeInterval {
        // Exponential: base * 2^(n-1) capped at maxDelay
        let exponent = max(0, consecutiveFailures - 1)
        let rawDelay = min(
            config.backoffMaxDelay,
            config.backoffBaseDelay * pow(2.0, Double(exponent))
        )
        // Apply jitter: ±jitterFactor
        let jitterRange = config.jitterFactor * rawDelay
        let jitter = Double.random(in: -jitterRange...jitterRange)
        return max(config.backoffBaseDelay, rawDelay + jitter)
    }
}
