import Foundation
import OpenBurnBarDomainCoreRuntime
import XCTest

final class DomainCoreShadowRuntimeTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case nativeUnavailable
        case verifierFailed
    }

    func testVerifiedLegacyModeCallsOnlyLegacy() throws {
        var calls: [String] = []

        let result = try DomainCoreShadowRuntime.selectVerifiedLegacy(
            domain: "hermes",
            slice: "ratchet",
            operation: "seal",
            mode: .legacy,
            nativeStatus: {
                XCTFail("legacy mode must not inspect native status")
                return .available
            },
            coreVersion: {
                XCTFail("legacy mode must not read the core version")
                return "unused"
            },
            legacy: {
                calls.append("legacy")
                return "legacy-ciphertext"
            },
            rustAuthority: {
                XCTFail("legacy mode must not call Rust")
                return "unused"
            },
            verifyLegacyWithRust: { _ in
                XCTFail("legacy mode must not verify through Rust")
                return false
            },
            nativeUnavailableError: TestError.nativeUnavailable,
            recordComparison: { _ in XCTFail("legacy mode must not emit shadow evidence") }
        )

        XCTAssertEqual(result, "legacy-ciphertext")
        XCTAssertEqual(calls, ["legacy"])
    }

    func testVerifiedLegacyShadowMatchReturnsExactLegacyValueWithoutCallingRustAuthority() throws {
        var calls: [String] = []
        var comparisons: [DomainCoreShadowComparison] = []

        let result = try DomainCoreShadowRuntime.selectVerifiedLegacy(
            domain: "hermes",
            slice: "ratchet",
            operation: "seal",
            mode: .shadow,
            nativeStatus: {
                calls.append("status")
                return .available
            },
            coreVersion: {
                calls.append("version")
                return "3.2.1"
            },
            legacy: {
                calls.append("legacy")
                return "legacy-ciphertext"
            },
            rustAuthority: {
                XCTFail("shadow mode must not generate an unrelated Rust ciphertext")
                return "unused"
            },
            verifyLegacyWithRust: { ciphertext in
                calls.append("verify:\(ciphertext)")
                return true
            },
            nativeUnavailableError: TestError.nativeUnavailable,
            recordComparison: { comparisons.append($0) }
        )

        XCTAssertEqual(result, "legacy-ciphertext")
        XCTAssertEqual(calls, ["legacy", "status", "version", "verify:legacy-ciphertext"])
        XCTAssertEqual(comparisons.count, 1)
        XCTAssertEqual(comparisons.first?.outcome, "match")
        XCTAssertNil(comparisons.first?.mismatchCategory)
        XCTAssertEqual(comparisons.first?.coreVersion, "3.2.1")
    }

    func testVerifiedLegacyShadowMismatchRecordsResultMismatchAndReturnsLegacy() throws {
        var comparisons: [DomainCoreShadowComparison] = []
        var diagnostics: [(String, String)] = []

        let result = try makeShadowSelection(
            verify: { _ in false },
            diagnostic: { diagnostics.append(($0, $1)) },
            record: { comparisons.append($0) }
        )

        XCTAssertEqual(result, "legacy-ciphertext")
        XCTAssertEqual(comparisons.count, 1)
        XCTAssertEqual(comparisons.first?.outcome, "mismatch")
        XCTAssertEqual(comparisons.first?.mismatchCategory, "result_mismatch")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.0, "seal")
        XCTAssertEqual(diagnostics.first?.1, "shadow_mismatch")
    }

    func testVerifiedLegacyShadowContainsVerifierFailureAndReturnsLegacy() throws {
        var comparisons: [DomainCoreShadowComparison] = []
        var diagnostics: [(String, String)] = []

        let result = try makeShadowSelection(
            verify: { _ in throw TestError.verifierFailed },
            diagnostic: { diagnostics.append(($0, $1)) },
            record: { comparisons.append($0) }
        )

        XCTAssertEqual(result, "legacy-ciphertext")
        XCTAssertEqual(comparisons.count, 1)
        XCTAssertEqual(comparisons.first?.outcome, "mismatch")
        XCTAssertEqual(comparisons.first?.mismatchCategory, "native_error")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.1, "native_error")
    }

    func testVerifiedLegacyShadowUnavailableRecordsSanitizedEvidenceWithoutVerifier() throws {
        var calls: [String] = []
        var comparisons: [DomainCoreShadowComparison] = []

        let result = try DomainCoreShadowRuntime.selectVerifiedLegacy(
            domain: "hermes",
            slice: "ratchet",
            operation: "seal",
            mode: .shadow,
            nativeStatus: {
                calls.append("status")
                return .unavailable(
                    coreVersion: "0.0.0-native-unavailable",
                    mismatchCategory: "native_unavailable"
                )
            },
            coreVersion: {
                XCTFail("rejected native code must not be queried again")
                return "unused"
            },
            legacy: {
                calls.append("legacy")
                return "legacy-ciphertext"
            },
            rustAuthority: {
                XCTFail("shadow mode must not call Rust authority")
                return "unused"
            },
            verifyLegacyWithRust: { _ in
                XCTFail("unavailable native code must not verify")
                return false
            },
            nativeUnavailableError: TestError.nativeUnavailable,
            recordComparison: { comparisons.append($0) }
        )

        XCTAssertEqual(result, "legacy-ciphertext")
        XCTAssertEqual(calls, ["legacy", "status"])
        XCTAssertEqual(comparisons.count, 1)
        XCTAssertEqual(comparisons.first?.coreVersion, "0.0.0-native-unavailable")
        XCTAssertEqual(comparisons.first?.mismatchCategory, "native_unavailable")
        XCTAssertEqual(comparisons.first?.rustMicros, 0)
    }

    func testVerifiedLegacyRustModeCallsOnlyRustAuthority() throws {
        var calls: [String] = []

        let result = try DomainCoreShadowRuntime.selectVerifiedLegacy(
            domain: "hermes",
            slice: "ratchet",
            operation: "seal",
            mode: .rust,
            nativeStatus: {
                calls.append("status")
                return .available
            },
            coreVersion: {
                XCTFail("Rust authority mode does not need comparison metadata")
                return "unused"
            },
            legacy: {
                XCTFail("Rust authority mode must not call legacy")
                return "unused"
            },
            rustAuthority: {
                calls.append("rust")
                return "rust-ciphertext"
            },
            verifyLegacyWithRust: { _ in
                XCTFail("Rust authority mode must not call the shadow verifier")
                return false
            },
            nativeUnavailableError: TestError.nativeUnavailable,
            recordComparison: { _ in XCTFail("Rust authority mode must not emit shadow evidence") }
        )

        XCTAssertEqual(result, "rust-ciphertext")
        XCTAssertEqual(calls, ["status", "rust"])
    }

    func testVerifiedLegacyRustModeFailsClosedWhenNativeIsUnavailable() {
        var rustWasCalled = false

        XCTAssertThrowsError(
            try DomainCoreShadowRuntime.selectVerifiedLegacy(
                domain: "hermes",
                slice: "ratchet",
                operation: "seal",
                mode: .rust,
                nativeStatus: {
                    .unavailable(coreVersion: "0.0.0-abi-mismatch", mismatchCategory: "native_error")
                },
                coreVersion: { "unused" },
                legacy: { "unused" },
                rustAuthority: {
                    rustWasCalled = true
                    return "unused"
                },
                verifyLegacyWithRust: { _ in false },
                nativeUnavailableError: TestError.nativeUnavailable,
                recordComparison: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? TestError, .nativeUnavailable)
        }
        XCTAssertFalse(rustWasCalled)
    }

    func testComparisonCollectorSinkCanReconfigureWithoutDeadlocking() {
        let callbackFinished = DispatchSemaphore(value: 0)
        let comparison = DomainCoreShadowComparison(
            domain: "hermes",
            slice: "ratchet",
            operation: "seal",
            coreVersion: "3.2.1",
            outcome: "match",
            mismatchCategory: nil,
            legacyMicros: 1,
            rustMicros: 1
        )
        DomainCoreShadowComparisonCollector.configure { _ in
            DomainCoreShadowComparisonCollector.configure(nil)
            callbackFinished.signal()
        }

        DispatchQueue.global().async {
            DomainCoreShadowComparisonCollector.record(comparison)
        }

        XCTAssertEqual(callbackFinished.wait(timeout: .now() + 1), .success)
    }

    private func makeShadowSelection(
        verify: (String) throws -> Bool,
        diagnostic: (String, String) -> Void,
        record: (DomainCoreShadowComparison) -> Void
    ) throws -> String {
        try DomainCoreShadowRuntime.selectVerifiedLegacy(
            domain: "hermes",
            slice: "ratchet",
            operation: "seal",
            mode: .shadow,
            nativeStatus: { .available },
            coreVersion: { "3.2.1" },
            legacy: { "legacy-ciphertext" },
            rustAuthority: {
                XCTFail("shadow mode must not call Rust authority")
                return "unused"
            },
            verifyLegacyWithRust: verify,
            nativeUnavailableError: TestError.nativeUnavailable,
            diagnostic: diagnostic,
            recordComparison: record
        )
    }
}
