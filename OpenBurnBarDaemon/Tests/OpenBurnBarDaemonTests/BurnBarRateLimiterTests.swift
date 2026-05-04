import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarRateLimiterTests: XCTestCase {
    func testBasicAllowance() async {
        let limiter = BurnBarRateLimiter(
            configuration: BurnBarRateLimitConfiguration(requestsPerSecond: 10, burstCapacity: 5)
        )

        // First 5 requests should be allowed (burst capacity)
        for i in 0..<5 {
            let result = await limiter.checkLimit(clientKey: "client-a")
            XCTAssertEqual(result, .allowed, "Request \(i) should be allowed")
        }

        // 6th request should be throttled
        let result = await limiter.checkLimit(clientKey: "client-a")
        if case .throttled = result {
            // expected
        } else {
            XCTFail("6th request should be throttled")
        }
    }

    func testPerClientIsolation() async {
        let limiter = BurnBarRateLimiter(
            configuration: BurnBarRateLimitConfiguration(requestsPerSecond: 10, burstCapacity: 2)
        )

        // Exhaust client-a's burst
        _ = await limiter.checkLimit(clientKey: "client-a")
        _ = await limiter.checkLimit(clientKey: "client-a")
        let aThrottled = await limiter.checkLimit(clientKey: "client-a")
        if case .throttled = aThrottled {
            // expected
        } else {
            XCTFail("client-a should be throttled after burst")
        }

        // client-b should still be allowed
        let bAllowed = await limiter.checkLimit(clientKey: "client-b")
        XCTAssertEqual(bAllowed, .allowed, "client-b should not be affected by client-a")
    }

    func testRefillOverTime() async throws {
        let limiter = BurnBarRateLimiter(
            configuration: BurnBarRateLimitConfiguration(requestsPerSecond: 100, burstCapacity: 1)
        )

        // Exhaust the single token
        _ = await limiter.checkLimit(clientKey: "client-c")
        let throttled = await limiter.checkLimit(clientKey: "client-c")
        if case .throttled = throttled {
            // expected
        } else {
            XCTFail("Should be throttled immediately after burst")
        }

        // Wait for token refill (100 req/s = 1 token per 0.01s)
        try await Task.sleep(nanoseconds: 20_000_000) // 20ms

        let allowed = await limiter.checkLimit(clientKey: "client-c")
        XCTAssertEqual(allowed, .allowed, "Should be allowed after refill")
    }

    func testRetryAfterValue() async {
        let limiter = BurnBarRateLimiter(
            configuration: BurnBarRateLimitConfiguration(requestsPerSecond: 1, burstCapacity: 1)
        )

        _ = await limiter.checkLimit(clientKey: "client-d")
        let result = await limiter.checkLimit(clientKey: "client-d")

        if case .throttled(let retryAfter) = result {
            XCTAssertGreaterThan(retryAfter, 0, "retryAfter should be positive")
            XCTAssertLessThanOrEqual(retryAfter, 1.1, "retryAfter should be approximately 1 second for 1 req/s")
        } else {
            XCTFail("Should be throttled")
        }
    }
}
