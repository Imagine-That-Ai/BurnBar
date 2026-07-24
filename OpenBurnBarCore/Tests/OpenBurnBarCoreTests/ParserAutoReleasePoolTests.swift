import Foundation
import XCTest
@testable import OpenBurnBarLogParsers

final class ParserAutoReleasePoolTests: XCTestCase {

    // MARK: - Closure execution

    func testAutoReleasePoolRunsTheClosureExactlyOnce() {
        // Defends the single-execution contract: the pool helper must not
        // double-invoke its body (a real regression would surface as a
        // duplicated accumulator mutation or doubled side effect).
        var invocations = 0
        parserAutoReleasePool { invocations += 1 }
        XCTAssertEqual(invocations, 1, "parserAutoReleasePool must execute its body exactly once")
    }

    // MARK: - Return value propagation

    func testAutoReleasePoolPropagatesTheReturnValue() throws {
        // Defends the generic-return contract used by headDigestHex and
        // BufferedLineReader: the value produced inside the pool must reach
        // the caller unchanged. A dropped or defaulted return would redden this.
        let digest: UInt64 = parserAutoReleasePool { 0xdead_beef_cafe_babe }
        XCTAssertEqual(digest, 0xdead_beef_cafe_babe)
    }

    func testAutoReleasePoolPropagatesAnOptionalReturnValue() {
        // The non-throwing path must preserve optionality: a nil produced
        // inside the pool must surface as nil, not a synthesized fallback.
        let absent: String? = parserAutoReleasePool { nil }
        XCTAssertNil(absent)
    }

    // MARK: - Error propagation

    private struct PoolProbeError: Error, Equatable {
        let code: Int
    }

    func testAutoReleasePoolRethrowsErrorsThrownByTheClosure() {
        // Defends the rethrows contract: an error raised inside the pool must
        // propagate as the caller's error, not be swallowed or wrapped. This is
        // the regression boundary — a catch-and-return-default would redden it.
        let code = 0o7253 // sentinel unlikely to arise by accident
        XCTAssertThrowsError(try parserAutoReleasePool { throw PoolProbeError(code: code) }) { caught in
            guard let probe = caught as? PoolProbeError else {
                XCTFail("expected PoolProbeError, got \(type(of: caught))")
                return
            }
            XCTAssertEqual(probe.code, code, "rethrown error must be the exact thrown instance")
        }
    }

    // MARK: - Void-result shape (the majority of call sites)

    func testAutoReleasePoolAcceptsAVoidClosureAsAStatement() {
        // Pins the Void-result compilation shape: 7 of the 9 call sites use
        // parserAutoReleasePool as a statement with a Void-returning closure
        // that mutates an inout accumulator. If the single generic overload
        // ever lost its Void-as-Result call-site ergonomics this would fail to
        // compile — the contract is "one overload serves both shapes".
        var accumulator = 0
        parserAutoReleasePool {
            accumulator += 41
            accumulator += 1
        }
        XCTAssertEqual(accumulator, 42)
    }
}