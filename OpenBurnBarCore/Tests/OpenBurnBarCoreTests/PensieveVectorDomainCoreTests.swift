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

    /// Shadow comparison records must carry the four canonical pensieve operation IDs
    /// (pensieve_vector_cloak, pensieve_l2_normalize, pensieve_deterministic_embed,
    /// pensieve_deterministic_embed_and_cloak), never the short aliases the legacy shadow
    /// branches once emitted (cloak, l2_normalize, embed, embed_and_cloak). Console and
    /// Windows admission maps only admit the canonical IDs, so a short-alias record is
    /// silently dropped downstream — the exact cross-surface defect this guards.
    func test_shadowComparisonsUseCanonicalPensieveOperationIDsNotShortAliases() {
        let expected: Set<String> = [
            "pensieve_vector_cloak",
            "pensieve_l2_normalize",
            "pensieve_deterministic_embed",
            "pensieve_deterministic_embed_and_cloak",
        ]
        let forbidden: Set<String> = [
            "cloak",
            "l2_normalize",
            "embed",
            "embed_and_cloak",
        ]

        var captured: [DomainCoreShadowComparison] = []
        DomainCoreShadowComparisonCollector.configure { comparison in
            captured.append(comparison)
        }
        defer { DomainCoreShadowComparisonCollector.configure(nil) }

        let vaultKey = Data(repeating: 0x42, count: 32)
        try? withCloudVaultMode("shadow") {
            _ = try PensieveVectorCloak.cloak([0.6, 0.8], vaultKey: vaultKey, modelVersion: "hashing-bow-v1")
            _ = PensieveVectorCloak.l2normalize([3, 4])
            _ = PensieveVectorCloak.deterministicEmbed("pensieve contract vector", isQuery: false)
            _ = try PensieveVectorCloak.embedAndCloak("pensieve contract vector", vaultKey: vaultKey, isQuery: false)
        }

        // Each of the four methods records exactly one comparison in shadow mode, even when
        // the native path throws (the catch branch still records with the operation string).
        XCTAssertEqual(captured.count, 4, "Each shadow method must record one comparison (got \(captured.count)).")

        let operations = Set(captured.map(\.operation))
        let slices = Set(captured.map(\.slice))
        let domains = Set(captured.map(\.domain))

        // The four canonical IDs must all be present — one per method, no duplicates, none missing.
        XCTAssertEqual(operations, expected, "Shadow records must use all four canonical pensieve operation IDs.")
        // No short alias may survive the cutover.
        XCTAssertTrue(operations.isDisjoint(with: forbidden), "Short aliases must not appear in shadow records: \(operations.intersection(forbidden)).")
        // Every record is a pensieve-vectors cloudvault record, never a misrouted slice.
        XCTAssertEqual(slices, ["pensieve-vectors"], "Shadow records must target the pensieve-vectors slice.")
        XCTAssertEqual(domains, ["cloudvault"], "Shadow records must target the cloudvault domain.")
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
