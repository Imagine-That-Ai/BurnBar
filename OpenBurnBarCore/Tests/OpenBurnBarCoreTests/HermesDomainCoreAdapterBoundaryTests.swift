import Foundation
@testable import OpenBurnBarKernel
import XCTest

final class HermesDomainCoreAdapterBoundaryTests: XCTestCase {
    private enum BoundaryError: Error {
        case legacyFailure
    }

    func testShadowModeReturnsLegacyWhenRustBoundaryThrows() throws {
        let legacy = Data("legacy".utf8)
        var comparisons: [DomainCoreShadowComparison] = []
        let result = try HermesDomainCoreAdapter.selectBytesWhenNativeAvailable(
            operation: "test_open",
            mode: .shadow,
            legacy: { legacy },
            rust: { throw HermesDomainCoreAdapterError.invalidInput },
            coreVersion: { "1.2.3" },
            recordComparison: { comparisons.append($0) }
        )

        XCTAssertEqual(result, legacy)
        XCTAssertEqual(comparisons.count, 1)
        XCTAssertEqual(comparisons.first?.coreVersion, "1.2.3")
        XCTAssertEqual(comparisons.first?.mismatchCategory, "native_error")
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
        var coreVersionWasCalled = false

        XCTAssertThrowsError(
            try HermesDomainCoreAdapter.selectBytesWhenNativeAvailable(
                operation: "test_open",
                mode: .shadow,
                legacy: { throw BoundaryError.legacyFailure },
                rust: {
                    rustWasCalled = true
                    return Data("rust".utf8)
                },
                coreVersion: {
                    coreVersionWasCalled = true
                    return "1.2.3"
                }
            )
        ) { error in
            XCTAssertTrue(error is BoundaryError)
        }
        XCTAssertFalse(rustWasCalled)
        XCTAssertFalse(coreVersionWasCalled)
    }

    func testShadowABIMismatchRecordsSanitizedEvidenceWithoutCallingOtherNativeSymbols() throws {
        try assertUnavailableShadowBoundary(
            status: .unavailable(coreVersion: "0.0.0-abi-mismatch", mismatchCategory: "native_error"),
            expectedCategory: "native_error",
            expectedCoreVersion: "0.0.0-abi-mismatch"
        )
    }

    func testShadowMissingNativeRecordsSanitizedEvidenceWithoutCallingRust() throws {
        try assertUnavailableShadowBoundary(
            status: .unavailable(
                coreVersion: "0.0.0-native-unavailable",
                mismatchCategory: "native_unavailable"
            ),
            expectedCategory: "native_unavailable",
            expectedCoreVersion: "0.0.0-native-unavailable"
        )
    }

    func testHkdfLengthConversionRejectsValuesThatWouldTrapOrWrap() throws {
        XCTAssertEqual(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(32), 32)
        XCTAssertThrowsError(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(0))
        XCTAssertThrowsError(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(-1))
        XCTAssertThrowsError(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(255 * 32 + 1))
        XCTAssertThrowsError(try HermesDomainCoreAdapter.checkedHkdfOutputByteCount(Int.max))
    }

    private func assertUnavailableShadowBoundary(
        status: HermesDomainCoreAdapter.NativeStatus,
        expectedCategory: String,
        expectedCoreVersion: String
    ) throws {
        var calls: [String] = []
        var comparisons: [DomainCoreShadowComparison] = []
        let legacy = Data([0x00, 0xFF, 0x10])

        let result = try HermesDomainCoreAdapter.selectBytes(
            operation: "key_wrap_info_v1",
            mode: .shadow,
            nativeStatus: {
                calls.append("native_status")
                return status
            },
            coreVersion: {
                XCTFail("core version must not be queried after native rejection")
                calls.append("core_version")
                return "9.9.9"
            },
            legacy: {
                calls.append("legacy")
                return legacy
            },
            rust: {
                XCTFail("Rust must not run after native rejection")
                calls.append("rust")
                return Data()
            },
            recordComparison: { comparisons.append($0) }
        )

        XCTAssertEqual(result, legacy)
        XCTAssertEqual(calls, ["legacy", "native_status"])
        XCTAssertEqual(comparisons.count, 1)
        XCTAssertEqual(comparisons.first?.domain, "hermes")
        XCTAssertEqual(comparisons.first?.slice, "payload-keywrap")
        XCTAssertEqual(comparisons.first?.outcome, "mismatch")
        XCTAssertEqual(comparisons.first?.mismatchCategory, expectedCategory)
        XCTAssertEqual(comparisons.first?.coreVersion, expectedCoreVersion)
        XCTAssertEqual(comparisons.first?.rustMicros, 0)
    }
}
