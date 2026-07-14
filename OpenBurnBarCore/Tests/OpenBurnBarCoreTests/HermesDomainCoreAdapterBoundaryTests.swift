import Foundation
@testable import OpenBurnBarKernel
import XCTest

final class HermesDomainCoreAdapterBoundaryTests: XCTestCase {
    private enum BoundaryError: Error {
        case legacyFailure
    }

    func testShadowModeReturnsLegacyWhenRustBoundaryThrows() throws {
        let legacy = Data("legacy".utf8)
        let result = try HermesDomainCoreAdapter.selectBytesWhenNativeAvailable(
            operation: "test_open",
            mode: .shadow,
            legacy: { legacy },
            rust: { throw HermesDomainCoreAdapterError.invalidInput }
        )

        XCTAssertEqual(result, legacy)
    }

    func testRustModePropagatesBoundaryFailureWithoutLegacyFallback() {
        var legacyWasCalled = false

        XCTAssertThrowsError(
            try HermesDomainCoreAdapter.selectBytesWhenNativeAvailable(
                operation: "test_open",
                mode: .rust,
                legacy: {
                    legacyWasCalled = true
                    return Data()
                },
                rust: { throw HermesDomainCoreAdapterError.invalidInput }
            )
        )
        XCTAssertFalse(legacyWasCalled)
    }

    func testShadowPreservesLegacyFailureWithoutEvaluatingRust() {
        var rustWasCalled = false

        XCTAssertThrowsError(
            try HermesDomainCoreAdapter.selectBytesWhenNativeAvailable(
                operation: "test_open",
                mode: .shadow,
                legacy: { throw BoundaryError.legacyFailure },
                rust: {
                    rustWasCalled = true
                    return Data("rust".utf8)
                }
            )
        ) { error in
            XCTAssertTrue(error is BoundaryError)
        }
        XCTAssertFalse(rustWasCalled)
    }

    func testHkdfLengthConversionRejectsValuesThatWouldTrapOrWrap() throws {
        XCTAssertEqual(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(32), 32)
        XCTAssertThrowsError(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(0))
        XCTAssertThrowsError(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(-1))
        XCTAssertThrowsError(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(255 * 32 + 1))
        XCTAssertThrowsError(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(Int.max))
    }
}
