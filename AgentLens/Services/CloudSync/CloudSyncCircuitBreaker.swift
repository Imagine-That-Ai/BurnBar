import FirebaseFirestore
import Foundation
import OSLog

// MARK: - Circuit Breaker

/// Thread-safe circuit breaker for cloud sync Firestore calls.
///
/// Three states:
/// - **closed** – normal operation, calls flow through.
/// - **open** – tripped after consecutive transient failures; all calls rejected.
/// - **halfOpen** – after `resetTimeout`, one probe is allowed to test recovery.
actor CloudSyncCircuitBreaker {
    enum State: Sendable, Equatable {
        case closed
        case open(since: Date)
        case halfOpen
    }

    // MARK: - Configuration

    let failureThreshold: Int
    let resetTimeout: TimeInterval
    let successThresholdToClose: Int

    // MARK: - Internal State

    private(set) var state: State = .closed
    private var consecutiveFailures: Int = 0
    private var halfOpenSuccesses: Int = 0

    private let logger = Logger(subsystem: "com.openburnbar.cloudsync", category: "circuitbreaker")

    // MARK: - Init

    init(
        failureThreshold: Int = 5,
        resetTimeout: TimeInterval = 60,
        successThresholdToClose: Int = 2
    ) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
        self.successThresholdToClose = successThresholdToClose
    }

    // MARK: - Public API

    /// Whether a request should be allowed through.
    func shouldAllowRequest(now: Date = Date()) -> Bool {
        switch state {
        case .closed:
            return true
        case .open(let since):
            if now.timeIntervalSince(since) >= resetTimeout {
                state = .halfOpen
                halfOpenSuccesses = 0
                logger.info("circuit breaker transitioning open -> halfOpen")
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }

    /// Record a successful call. Resets failure count; in halfOpen may close the breaker.
    func recordSuccess() {
        switch state {
        case .halfOpen:
            halfOpenSuccesses += 1
            if halfOpenSuccesses >= successThresholdToClose {
                state = .closed
                consecutiveFailures = 0
                halfOpenSuccesses = 0
                logger.info("circuit breaker transitioning halfOpen -> closed")
            }
        case .closed:
            consecutiveFailures = 0
        case .open:
            break
        }
    }

    /// Record a failed call. May trip the breaker if threshold is reached.
    func recordFailure(now: Date = Date()) {
        switch state {
        case .closed:
            consecutiveFailures += 1
            if consecutiveFailures >= failureThreshold {
                state = .open(since: now)
                logger.warning("circuit breaker tripped closed -> open after \(self.consecutiveFailures) failures")
            }
        case .halfOpen:
            state = .open(since: now)
            halfOpenSuccesses = 0
            logger.warning("circuit breaker tripped halfOpen -> open on probe failure")
        case .open:
            break
        }
    }

    /// Reset to closed state (e.g. for testing or manual recovery).
    func reset() {
        state = .closed
        consecutiveFailures = 0
        halfOpenSuccesses = 0
    }

    /// Advance time for testing by shifting the open timestamp backward.
    func advanceTime(by interval: TimeInterval) {
        switch state {
        case .open(let since):
            state = .open(since: since.addingTimeInterval(-interval))
        case .closed, .halfOpen:
            break
        }
    }
}

// MARK: - Retry Policy

/// Configures exponential backoff with jitter for cloud sync retries.
struct CloudSyncRetryPolicy: Sendable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let jitterFactor: Double

    init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        jitterFactor: Double = 0.25
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFactor = jitterFactor
    }

    /// Computes the delay for a given zero-based attempt number using exponential backoff with jitter.
    func delay(for attempt: Int) -> TimeInterval {
        let exponential = min(maxDelay, baseDelay * pow(2.0, Double(attempt)))
        let jitter = Double.random(in: -jitterFactor...jitterFactor)
        return exponential * (1.0 + jitter)
    }
}

// MARK: - Error Classification

/// Classifies Firestore and network errors for retry decisions.
enum CloudSyncErrorClassifier {
    enum Classification: Sendable, Equatable {
        case retryable
        case permissionDenied
        case terminal
    }

    /// Classify an error for retry/circuit-breaker purposes.
    static func classify(_ error: Error) -> Classification {
        let nsError = error as NSError

        // Firestore errors
        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .unavailable, .deadlineExceeded, .aborted, .resourceExhausted, .internal:
                return .retryable
            case .permissionDenied, .unauthenticated:
                return .permissionDenied
            default:
                return .terminal
            }
        }

        // NSURLError transient codes
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,             // -1001
                 NSURLErrorNetworkConnectionLost, // -1005
                 NSURLErrorNotConnectedToInternet: // -1009
                return .retryable
            default:
                return .terminal
            }
        }

        return .terminal
    }
}

// MARK: - Retry Executor

/// Error thrown when the circuit breaker is open and rejects a call.
struct CloudSyncCircuitBreakerOpenError: Error, LocalizedError, Sendable {
    var errorDescription: String? { "Cloud sync circuit breaker is open — calls are temporarily suspended" }
}

/// Namespace for the retry logger.
private enum CloudSyncRetryLog {
    static let logger = Logger(subsystem: "com.openburnbar.cloudsync", category: "retry")
}

/// Executes an async operation with retry + circuit breaker protection.
///
/// - Parameters:
///   - policy: Retry policy (exponential backoff with jitter).
///   - circuitBreaker: Shared circuit breaker actor.
///   - domain: A label for logging (e.g. "usage", "conversation").
///   - operation: The async throwing closure to execute.
/// - Returns: The result of the operation on success.
/// - Throws: The last error if all retries are exhausted, or immediately on terminal/permission errors.
func withCloudSyncRetry<T>(
    policy: CloudSyncRetryPolicy,
    circuitBreaker: CloudSyncCircuitBreaker,
    domain: String,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?

    for attempt in 0..<policy.maxAttempts {
        // Check circuit breaker
        let allowed = await circuitBreaker.shouldAllowRequest()
        guard allowed else {
            CloudSyncRetryLog.logger.warning("circuit breaker open, rejecting \(domain, privacy: .public) attempt \(attempt)")
            throw CloudSyncCircuitBreakerOpenError()
        }

        do {
            let result = try await operation()
            await circuitBreaker.recordSuccess()
            if attempt > 0 {
                CloudSyncRetryLog.logger.info("\(domain, privacy: .public) succeeded on attempt \(attempt + 1)")
            }
            return result
        } catch {
            let classification = CloudSyncErrorClassifier.classify(error)

            switch classification {
            case .retryable:
                await circuitBreaker.recordFailure()
                lastError = error

                if attempt < policy.maxAttempts - 1 {
                    let delay = policy.delay(for: attempt)
                    CloudSyncRetryLog.logger.warning(
                        "\(domain, privacy: .public) transient failure on attempt \(attempt + 1)/\(policy.maxAttempts), retrying in \(String(format: "%.2f", delay))s: \(error.localizedDescription, privacy: .public)"
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    CloudSyncRetryLog.logger.error(
                        "\(domain, privacy: .public) exhausted \(policy.maxAttempts) attempts: \(error.localizedDescription, privacy: .public)"
                    )
                }

            case .permissionDenied:
                CloudSyncRetryLog.logger.error("\(domain, privacy: .public) permission denied, not retrying")
                throw error

            case .terminal:
                CloudSyncRetryLog.logger.error("\(domain, privacy: .public) terminal error, not retrying: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }

    throw lastError!
}
