import Foundation
import XCTest
@testable import OpenBurnBarCore

final class PensieveVectorDomainCoreTests: XCTestCase {
    // The three Rust-authority Pensieve contracts below depend on the optional
    // domain-core FFI module (the vendored OpenBurnBarDomainCore.xcframework).
    // They compile only when the FFI is linked, matching the established
    // canImport guard used by CloudVaultDocumentRewrapDomainCoreAdapterTests.
    // The shared native-required CI lane (`--filter DomainCore` with
    // OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE=1) discovers and runs them whenever
    // the framework is present; a clean checkout without the untracked framework
    // compile-skips them instead of crashing at Rust explicit-mode
    // nativeUnavailable (PensieveVectorCloak.l2normalize traps; .cloak throws).
    #if canImport(OpenBurnBarDomainCoreFFI)
    func test_rustAuthority_l2NormalizationMatchesLegacyContract() {
        withCloudVaultMode("rust") {
            let normalized = PensieveVectorCloak.l2normalize([3, 4])
            XCTAssertEqual(normalized, [0.6, 0.8])
            XCTAssertEqual(PensieveVectorCloak.l2normalize([0, 0]), [0, 0])
            XCTAssertEqual(PensieveVectorCloak.l2normalize([]), [])
        }
    }

    func test_rustAuthority_l2NormalizationPreservesUnboundedAndNonFiniteLegacyInputs() {
        withCloudVaultMode("rust") {
            let dimensions = 4_097
            let normalized = PensieveVectorCloak.l2normalize(
                [Double](repeating: 1, count: dimensions)
            )
            let expected = 1 / Double(dimensions).squareRoot()
            XCTAssertEqual(normalized.count, dimensions)
            XCTAssertTrue(normalized.allSatisfy { $0 == expected })

            let nanResult = PensieveVectorCloak.l2normalize([.nan, 1])
            XCTAssertTrue(nanResult[0].isNaN)
            XCTAssertEqual(nanResult[1], 1)

            let infiniteResult = PensieveVectorCloak.l2normalize([.infinity])
            XCTAssertTrue(infiniteResult[0].isNaN)
        }
    }

    func test_rustAuthority_matchesPublishedGoldenHeads() throws {
        try withCloudVaultMode("rust") {
            var basis = [Double](repeating: 0, count: PensieveVectorCloak.embeddingDim)
            basis[5] = 1
            let result = try PensieveVectorCloak.cloak(
                basis,
                vaultKey: Data(repeating: 0x42, count: 32),
                modelVersion: "hashing-bow-v1"
            )
            let expected = [
                0.024962057620774702,
                -0.0012100986493098734,
                0.01970170194431331,
                -0.01876288243402278,
                0.050834395709711204,
                0.8367944634995997
            ]
            for (actual, expected) in zip(result, expected) {
                XCTAssertEqual(actual, expected, accuracy: 1e-12)
            }
        }
    }
    #else
    /// Clean-checkout unavailable path: with the FFI module absent, the
    /// Rust-authority Pensieve facade must fail closed (throw) rather than
    /// silently degrade to the legacy implementation. Proves the native tests
    /// above are intentionally compile-skipped, not silently passing on a stale
    /// fallback.
    func test_rustAuthorityFailsClosedWhenNativeFFIIsUnavailable() throws {
        try withCloudVaultMode("rust") {
            XCTAssertThrowsError(
                try PensieveVectorCloak.cloak(
                    [Double](repeating: 0, count: PensieveVectorCloak.embeddingDim),
                    vaultKey: Data(repeating: 0x42, count: 32),
                    modelVersion: PensieveVectorCloak.deterministicModelVersion
                )
            )
        }
    }
    #endif

    func test_nonLegacySourcesDoNotCallDeletedL2Implementation() throws {
        let vectorKitSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBurnBarVectorKit")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: vectorKitSources,
            includingPropertiesForKeys: nil
        ))
        var offenders: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard !fileURL.path.contains("/Legacy/") else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            if source.contains("PensieveVectorLegacy.l2normalize") {
                offenders.append(fileURL.path)
            }
        }
        XCTAssertEqual(offenders, [], "The migrated L2 implementation must be deletable outside Legacy/")
    }

    private func withCloudVaultMode<T>(_ mode: String, operation: () throws -> T) rethrows -> T {
        let environmentKey = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE"
        let previous = getenv(environmentKey).map { String(cString: $0) }
        setenv(environmentKey, mode, 1)
        defer {
            if let previous { setenv(environmentKey, previous, 1) } else { unsetenv(environmentKey) }
        }
        return try operation()
    }
}
