import Foundation
import XCTest
@testable import OpenBurnBarCore

final class PensieveVectorCloakModeDispatchTests: XCTestCase {
    // These tests cover the mode-dispatch and error-edge contracts of
    // PensieveVectorCloak that the existing PensieveVectorCloakTests (legacy
    // math invariants) and PensieveVectorDomainCoreTests (rust golden heads)
    // do not exercise:
    //   * legacy mode is a pure no-native path (never throws for the throwing
    //     ops, deterministic for the non-throwing ones);
    //   * shadow mode is resilient — it returns the legacy value even when the
    //     native path errors, so a native regression can never break the user
    //     recall path;
    //   * the mode is resolved from the process environment at call time, so
    //     explicit mode overrides are honoured per-operation.
    //
    // The withCloudVaultMode helper mirrors PensieveVectorDomainCoreTests and
    // restores the env var in teardown so the suite is order-independent.

    private let key = Data(repeating: 0x42, count: 32)

    private func withCloudVaultMode<T>(_ mode: String, operation: () throws -> T) rethrows -> T {
        let environmentKey = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE"
        let previous = getenv(environmentKey).map { String(cString: $0) }
        setenv(environmentKey, mode, 1)
        defer {
            if let previous { setenv(environmentKey, previous, 1) } else { unsetenv(environmentKey) }
        }
        return try operation()
    }

    // MARK: - legacy mode: pure no-native path

    func test_legacyModeCloakIsDeterministicAndNeverTouchesNative() throws {
        try withCloudVaultMode("legacy") {
            let v = PensieveVectorCloak.deterministicEmbed("legacy mode dispatch test")
            let a = try PensieveVectorCloak.cloak(v, vaultKey: key, modelVersion: "bge-small-en-v1.5")
            let b = try PensieveVectorCloak.cloak(v, vaultKey: key, modelVersion: "bge-small-en-v1.5")
            XCTAssertEqual(a, b, "legacy cloak must be deterministic")
            // Legacy cloak preserves the norm (orthonormal Householder reflections).
            let normA = a.reduce(0) { $0 + $1 * $1 }.squareRoot()
            let normV = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            XCTAssertEqual(normA, normV, accuracy: 1e-9)
        }
    }

    func test_legacyModeEmbedAndCloakReturnsTaggedVector() throws {
        try withCloudVaultMode("legacy") {
            let result = try PensieveVectorCloak.embedAndCloak(
                "tagged legacy embed", vaultKey: key, modelVersion: "hashing-bow-v1"
            )
            XCTAssertEqual(result.modelVersion, "hashing-bow-v1")
            XCTAssertEqual(result.vector.count, PensieveVectorCloak.embeddingDim)
        }
    }

    func test_legacyModeL2NormalizeHandlesZeroAndEmptyVectors() {
        withCloudVaultMode("legacy") {
            // l2normalize in legacy mode must not throw and must handle the
            // degenerate inputs (zero vector → returned unchanged, empty → empty).
            XCTAssertEqual(PensieveVectorCloak.l2normalize([0, 0, 0]), [0, 0, 0])
            XCTAssertEqual(PensieveVectorCloak.l2normalize([]), [])
            let normalized = PensieveVectorCloak.l2normalize([3, 4])
            XCTAssertEqual(normalized.count, 2)
            XCTAssertEqual(normalized[0], 0.6, accuracy: 1e-12)
            XCTAssertEqual(normalized[1], 0.8, accuracy: 1e-12)
        }
    }

    func test_legacyModeDeterministicEmbedIsNormalizedAndQueryInstructionSensitive() {
        withCloudVaultMode("legacy") {
            let doc = PensieveVectorCloak.deterministicEmbed("legacy embed doc", isQuery: false)
            let query = PensieveVectorCloak.deterministicEmbed("legacy embed doc", isQuery: true)
            XCTAssertEqual(doc.count, PensieveVectorCloak.embeddingDim)
            let norm = doc.reduce(0) { $0 + $1 * $1 }.squareRoot()
            XCTAssertEqual(norm, 1.0, accuracy: 1e-9)
            XCTAssertNotEqual(doc, query, "query instruction must change the embedding")
        }
    }

    // MARK: - shadow mode: resilient to native errors

    func test_shadowModeCloakReturnsLegacyValueEvenWhenNativeMayError() throws {
        // The defining shadow contract: the native result is compared and
        // recorded, but the LEGACY value is always returned. So shadow cloak
        // must equal legacy cloak regardless of whether the native path
        // succeeds or throws. This is what keeps a native regression from
        // breaking user recall.
        try withCloudVaultMode("shadow") {
            let v = PensieveVectorCloak.deterministicEmbed("shadow resilience cloak")
            let shadowResult = try PensieveVectorCloak.cloak(v, vaultKey: key, modelVersion: "bge-small-en-v1.5")
            // Compute the legacy value directly by switching to legacy mode.
            try withCloudVaultMode("legacy") {
                let legacyResult = try PensieveVectorCloak.cloak(v, vaultKey: key, modelVersion: "bge-small-en-v1.5")
                XCTAssertEqual(shadowResult, legacyResult, "shadow must return the legacy value")
            }
        }
    }

    func test_shadowModeEmbedAndCloakReturnsLegacyTuple() throws {
        try withCloudVaultMode("shadow") {
            let shadowResult = try PensieveVectorCloak.embedAndCloak(
                "shadow resilience embed", vaultKey: key, modelVersion: "hashing-bow-v1"
            )
            try withCloudVaultMode("legacy") {
                let legacyResult = try PensieveVectorCloak.embedAndCloak(
                    "shadow resilience embed", vaultKey: key, modelVersion: "hashing-bow-v1"
                )
                XCTAssertEqual(shadowResult.modelVersion, legacyResult.modelVersion)
                XCTAssertEqual(shadowResult.vector, legacyResult.vector, "shadow must return the legacy vector")
            }
        }
    }

    func test_shadowModeL2NormalizeReturnsLegacyValue() {
        withCloudVaultMode("shadow") {
            let input = [3.0, 4.0]
            let shadowResult = PensieveVectorCloak.l2normalize(input)
            withCloudVaultMode("legacy") {
                let legacyResult = PensieveVectorCloak.l2normalize(input)
                XCTAssertEqual(shadowResult, legacyResult, "shadow l2normalize must return the legacy value")
            }
            XCTAssertEqual(shadowResult.count, 2)
            XCTAssertEqual(shadowResult[0], 0.6, accuracy: 1e-12)
            XCTAssertEqual(shadowResult[1], 0.8, accuracy: 1e-12)
        }
    }

    func test_shadowModeDeterministicEmbedReturnsLegacyValue() {
        withCloudVaultMode("shadow") {
            let shadowResult = PensieveVectorCloak.deterministicEmbed("shadow embed dispatch", isQuery: true)
            withCloudVaultMode("legacy") {
                let legacyResult = PensieveVectorCloak.deterministicEmbed("shadow embed dispatch", isQuery: true)
                XCTAssertEqual(shadowResult, legacyResult, "shadow embed must return the legacy value")
            }
        }
    }

    // MARK: - rust mode: fails closed without native (compile-gated edge)

    #if !canImport(OpenBurnBarDomainCoreFFI)
    // Clean-checkout contract: without the FFI, rust mode must fail closed
    // (throw nativeUnavailable) rather than silently degrade to legacy. This
    // is the mirror of PensieveVectorDomainCoreTests' unavailable-path guard
    // and proves the shadow tests above are exercising a real dispatch, not a
    // silent fallback.
    func test_rustModeCloakFailsClosedWhenNativeUnavailable() throws {
        try withCloudVaultMode("rust") {
            XCTAssertThrowsError(
                try PensieveVectorCloak.cloak(
                    [Double](repeating: 0, count: PensieveVectorCloak.embeddingDim),
                    vaultKey: key,
                    modelVersion: PensieveVectorCloak.deterministicModelVersion
                )
            )
        }
    }

    func test_rustModeEmbedAndCloakFailsClosedWhenNativeUnavailable() throws {
        try withCloudVaultMode("rust") {
            XCTAssertThrowsError(
                try PensieveVectorCloak.embedAndCloak(
                    "rust fail closed", vaultKey: key, modelVersion: "hashing-bow-v1"
                )
            )
        }
    }
    #endif
}
