import XCTest
@testable import OpenBurnBar

// MARK: - Circuit Breaker Tests

final class CloudSyncCircuitBreakerTests: XCTestCase {

    // MARK: - Closed -> Open on Threshold Failures

    func test_closedToOpen_afterThresholdFailures() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 3, resetTimeout: 60, successThresholdToClose: 2)
        let now = Date()

        // First two failures: still closed
        await breaker.recordFailure(now: now)
        var allowed = await breaker.shouldAllowRequest(now: now)
        XCTAssertTrue(allowed, "Should still allow after 1 failure")

        await breaker.recordFailure(now: now)
        allowed = await breaker.shouldAllowRequest(now: now)
        XCTAssertTrue(allowed, "Should still allow after 2 failures")

        // Third failure trips the breaker
        await breaker.recordFailure(now: now)
        allowed = await breaker.shouldAllowRequest(now: now)
        XCTAssertFalse(allowed, "Should be open after 3 failures (threshold)")
    }

    // MARK: - Open -> HalfOpen on Timeout

    func test_openToHalfOpen_afterResetTimeout() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 2, resetTimeout: 10, successThresholdToClose: 1)
        let now = Date()

        // Trip the breaker
        await breaker.recordFailure(now: now)
        await breaker.recordFailure(now: now)

        // Before timeout: still open
        let beforeTimeout = now.addingTimeInterval(5)
        var allowed = await breaker.shouldAllowRequest(now: beforeTimeout)
        XCTAssertFalse(allowed, "Should still be open before timeout")

        // After timeout: transitions to halfOpen, allows one probe
        let afterTimeout = now.addingTimeInterval(11)
        allowed = await breaker.shouldAllowRequest(now: afterTimeout)
        XCTAssertTrue(allowed, "Should transition to halfOpen and allow probe")

        let state = await breaker.state
        XCTAssertEqual(state, .halfOpen)
    }

    // MARK: - HalfOpen -> Closed on Probe Success

    func test_halfOpenToClosed_onProbeSuccess() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 1, resetTimeout: 1, successThresholdToClose: 2)
        let now = Date()

        // Trip the breaker
        await breaker.recordFailure(now: now)

        // Wait for halfOpen transition
        let afterTimeout = now.addingTimeInterval(2)
        _ = await breaker.shouldAllowRequest(now: afterTimeout)

        // First success: still halfOpen
        await breaker.recordSuccess()
        var state = await breaker.state
        XCTAssertEqual(state, .halfOpen, "Should still be halfOpen after 1 success (threshold is 2)")

        // Second success: should close
        await breaker.recordSuccess()
        state = await breaker.state
        XCTAssertEqual(state, .closed, "Should close after 2 successes")

        // Should allow requests normally
        let allowed = await breaker.shouldAllowRequest()
        XCTAssertTrue(allowed)
    }

    // MARK: - HalfOpen -> Open on Probe Failure

    func test_halfOpenToOpen_onProbeFailure() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 1, resetTimeout: 1, successThresholdToClose: 2)
        let now = Date()

        // Trip the breaker
        await breaker.recordFailure(now: now)

        // Wait for halfOpen
        let afterTimeout = now.addingTimeInterval(2)
        _ = await breaker.shouldAllowRequest(now: afterTimeout)
        var state = await breaker.state
        XCTAssertEqual(state, .halfOpen)

        // Probe failure: should go back to open
        let failTime = now.addingTimeInterval(3)
        await breaker.recordFailure(now: failTime)
        state = await breaker.state
        if case .open = state {
            // expected
        } else {
            XCTFail("Expected open state after halfOpen probe failure, got \(state)")
        }

        // Should reject calls
        let allowed = await breaker.shouldAllowRequest(now: failTime)
        XCTAssertFalse(allowed)
    }

    // MARK: - Success Resets Counter in Closed State

    func test_successResets_consecutiveFailures() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 3, resetTimeout: 60, successThresholdToClose: 1)
        let now = Date()

        // Two failures, then a success
        await breaker.recordFailure(now: now)
        await breaker.recordFailure(now: now)
        await breaker.recordSuccess()

        // Two more failures: should NOT trip (counter was reset)
        await breaker.recordFailure(now: now)
        await breaker.recordFailure(now: now)

        let allowed = await breaker.shouldAllowRequest(now: now)
        XCTAssertTrue(allowed, "Counter should have been reset by success")
    }

    // MARK: - Reset

    func test_reset_returnsToClosedState() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 1, resetTimeout: 60, successThresholdToClose: 1)
        let now = Date()

        // Trip the breaker
        await breaker.recordFailure(now: now)
        var allowed = await breaker.shouldAllowRequest(now: now)
        XCTAssertFalse(allowed)

        // Reset
        await breaker.reset()
        allowed = await breaker.shouldAllowRequest(now: now)
        XCTAssertTrue(allowed)

        let state = await breaker.state
        XCTAssertEqual(state, .closed)
    }

    // MARK: - Concurrent Access Safety

    func test_concurrentAccess_doesNotCrash() async {
        let breaker = CloudSyncCircuitBreaker(failureThreshold: 10, resetTimeout: 1, successThresholdToClose: 2)

        // Fire many concurrent operations to stress-test the actor
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i % 3 == 0 {
                        await breaker.recordFailure()
                    } else if i % 3 == 1 {
                        await breaker.recordSuccess()
                    } else {
                        _ = await breaker.shouldAllowRequest()
                    }
                }
            }
        }
        // If we get here without a crash, the actor properly serialized access
    }
}
