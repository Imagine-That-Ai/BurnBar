import XCTest
import FirebaseFirestore
@testable import OpenBurnBar

// MARK: - Retry Policy Tests

final class CloudSyncRetryPolicyTests: XCTestCase {

    // MARK: - Delay Computation

    func test_delay_exponentialBackoff() {
        let policy = CloudSyncRetryPolicy(maxAttempts: 5, baseDelay: 1.0, maxDelay: 30.0, jitterFactor: 0.0)

        // With zero jitter, delays should be exact powers of 2
        XCTAssertEqual(policy.delay(for: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 1), 2.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 2), 4.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 3), 8.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 4), 16.0, accuracy: 0.001)
    }

    // MARK: - Jitter Bounds

    func test_delay_jitterBounds() {
        let policy = CloudSyncRetryPolicy(maxAttempts: 3, baseDelay: 10.0, maxDelay: 100.0, jitterFactor: 0.25)

        // For attempt 0: base = 10.0, range should be 10 * (1-0.25) to 10 * (1+0.25) = [7.5, 12.5]
        for _ in 0..<50 {
            let d = policy.delay(for: 0)
            XCTAssertGreaterThanOrEqual(d, 7.5)
            XCTAssertLessThanOrEqual(d, 12.5)
        }
    }

    // MARK: - Max Delay Cap

    func test_delay_cappedAtMaxDelay() {
        let policy = CloudSyncRetryPolicy(maxAttempts: 10, baseDelay: 1.0, maxDelay: 5.0, jitterFactor: 0.0)

        // Attempt 10 would be 2^10 = 1024, but should be capped at 5.0
        XCTAssertEqual(policy.delay(for: 10), 5.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 20), 5.0, accuracy: 0.001)
    }

    func test_delay_cappedAtMaxDelayWithJitter() {
        let policy = CloudSyncRetryPolicy(maxAttempts: 10, baseDelay: 1.0, maxDelay: 5.0, jitterFactor: 0.25)

        // With jitter, max possible is 5.0 * 1.25 = 6.25
        for _ in 0..<50 {
            let d = policy.delay(for: 10)
            XCTAssertLessThanOrEqual(d, 6.25)
            XCTAssertGreaterThanOrEqual(d, 3.75)
        }
    }

    // MARK: - Default Values

    func test_defaultPolicy_hasReasonableDefaults() {
        let policy = CloudSyncRetryPolicy()
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.baseDelay, 1.0)
        XCTAssertEqual(policy.maxDelay, 30.0)
        XCTAssertEqual(policy.jitterFactor, 0.25)
    }
}

// MARK: - Error Classification Tests

final class CloudSyncErrorClassifierTests: XCTestCase {

    // MARK: - Retryable Firestore Errors

    func test_classify_unavailable_isRetryable() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unavailable.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .retryable)
    }

    func test_classify_deadlineExceeded_isRetryable() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.deadlineExceeded.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .retryable)
    }

    func test_classify_aborted_isRetryable() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.aborted.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .retryable)
    }

    func test_classify_resourceExhausted_isRetryable() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.resourceExhausted.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .retryable)
    }

    func test_classify_internal_isRetryable() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.internal.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .retryable)
    }

    // MARK: - Permission Denied

    func test_classify_permissionDenied_isPermissionDenied() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .permissionDenied)
    }

    func test_classify_unauthenticated_isPermissionDenied() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unauthenticated.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .permissionDenied)
    }

    // MARK: - Terminal Firestore Errors

    func test_classify_notFound_isTerminal() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.notFound.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .terminal)
    }

    func test_classify_invalidArgument_isTerminal() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.invalidArgument.rawValue)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .terminal)
    }

    // MARK: - Retryable NSURLError Codes

    func test_classify_timedOut_isRetryable() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .retryable)
    }

    func test_classify_connectionLost_isRetryable() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .retryable)
    }

    func test_classify_notConnected_isRetryable() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .retryable)
    }

    // MARK: - Terminal NSURLError

    func test_classify_badURL_isTerminal() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .terminal)
    }

    // MARK: - Unknown Domain

    func test_classify_unknownDomain_isTerminal() {
        let error = NSError(domain: "com.example.unknown", code: 42)
        XCTAssertEqual(CloudSyncErrorClassifier.classify(error), .terminal)
    }
}

// MARK: - withCloudSyncRetry Tests

@MainActor
final class CloudSyncRetryExecutorTests: XCTestCase {

    // MARK: - Succeeds on First Try

    func test_withRetry_succeedsOnFirstTry() async throws {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 5, resetTimeout: 60, successThresholdToClose: 2)
        let policy = CloudSyncRetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1, jitterFactor: 0.0)

        let callCount = ManagedAtomic(0)
        let result = try await withCloudSyncRetry(policy: policy, circuitBreaker: breaker, domain: "test") {
            callCount.increment()
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount.value, 1)
    }

    // MARK: - Retries on Transient Error Then Succeeds

    func test_withRetry_retriesOnTransientThenSucceeds() async throws {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 10, resetTimeout: 60, successThresholdToClose: 2)
        let policy = CloudSyncRetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1, jitterFactor: 0.0)

        let callCount = ManagedAtomic(0)
        let result: String = try await withCloudSyncRetry(policy: policy, circuitBreaker: breaker, domain: "test") {
            let count = callCount.increment()
            if count < 3 {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            return "recovered"
        }

        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount.value, 3)
    }

    // MARK: - Gives Up After Max Attempts

    func test_withRetry_givesUpAfterMaxAttempts() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 10, resetTimeout: 60, successThresholdToClose: 2)
        let policy = CloudSyncRetryPolicy(maxAttempts: 2, baseDelay: 0.01, maxDelay: 0.1, jitterFactor: 0.0)

        let callCount = ManagedAtomic(0)
        do {
            let _: String = try await withCloudSyncRetry(policy: policy, circuitBreaker: breaker, domain: "test") {
                callCount.increment()
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount.value, 2)
            XCTAssertEqual((error as NSError).code, NSURLErrorTimedOut)
        }
    }

    // MARK: - Does Not Retry Terminal Errors

    func test_withRetry_doesNotRetryTerminalErrors() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 10, resetTimeout: 60, successThresholdToClose: 2)
        let policy = CloudSyncRetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1, jitterFactor: 0.0)

        let callCount = ManagedAtomic(0)
        do {
            let _: String = try await withCloudSyncRetry(policy: policy, circuitBreaker: breaker, domain: "test") {
                callCount.increment()
                throw NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.notFound.rawValue)
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount.value, 1, "Terminal error should not be retried")
        }
    }

    // MARK: - Does Not Retry Permission Denied

    func test_withRetry_doesNotRetryPermissionDenied() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 10, resetTimeout: 60, successThresholdToClose: 2)
        let policy = CloudSyncRetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1, jitterFactor: 0.0)

        let callCount = ManagedAtomic(0)
        do {
            let _: String = try await withCloudSyncRetry(policy: policy, circuitBreaker: breaker, domain: "test") {
                callCount.increment()
                throw NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount.value, 1, "Permission denied should not be retried")
        }
    }

    // MARK: - Circuit Breaker Open Rejects Immediately

    func test_withRetry_rejectsWhenCircuitBreakerOpen() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 1, resetTimeout: 60, successThresholdToClose: 2)
        let policy = CloudSyncRetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1, jitterFactor: 0.0)

        // Trip the breaker
        await breaker.recordFailure()

        let callCount = ManagedAtomic(0)
        do {
            let _: String = try await withCloudSyncRetry(policy: policy, circuitBreaker: breaker, domain: "test") {
                callCount.increment()
                return "should not reach"
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is CloudSyncCircuitBreakerOpenError)
            XCTAssertEqual(callCount.value, 0, "Operation should not have been called")
        }
    }
}

// MARK: - Thread-safe Counter for Tests

/// Simple actor-based atomic counter for use in async test closures.
private final class ManagedAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int

    init(_ initial: Int) {
        _value = initial
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }
}
