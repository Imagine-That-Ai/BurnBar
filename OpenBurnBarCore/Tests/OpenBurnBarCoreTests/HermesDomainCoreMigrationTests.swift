import Foundation
import OpenBurnBarCore
import OpenBurnBarDomainCoreRuntime
import XCTest
#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

final class HermesDomainCoreMigrationTests: XCTestCase {
    private func assertNativeDomainCoreLoaded() {
        #if canImport(OpenBurnBarDomainCoreFFI)
        XCTAssertEqual(OpenBurnBarDomainCoreFFI.domainCoreAbiVersion(), 3)
        #else
        XCTFail("domain-core FFI module is unavailable in native-required test")
        #endif
    }

    func testRustModeMatchesCanonicalAadAndCrossOpensLegacyCiphertext() throws {
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"] == "1" else {
            throw XCTSkip("native-required in domain-core CI")
        }
        assertNativeDomainCoreLoaded()
        setenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE", "rust", 1)
        defer { unsetenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE") }

        let aad = try HermesRelayCrypto.requestAAD(
            uid: "user-1",
            connectionID: "connection-2",
            requestID: "request-3"
        )
        XCTAssertEqual(
            String(data: aad, encoding: .utf8),
            "OpenBurnBar-HermesRelay-v1|request|user-1|connection-2|request-3"
        )
        let key = Data(repeating: 0x11, count: 32)
        let sealed = try HermesRelayCrypto.sealToBase64(
            plaintext: Data("hello Hermes".utf8),
            keyData: key,
            aad: aad
        )
        XCTAssertEqual(
            try HermesRelayCrypto.openBase64(ciphertext: sealed, keyData: key, aad: aad),
            Data("hello Hermes".utf8)
        )
    }

    func testRustModeMatchesCanonicalSafetyCode() throws {
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"] == "1" else {
            throw XCTSkip("native-required in domain-core CI")
        }
        assertNativeDomainCoreLoaded()
        setenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE", "rust", 1)
        defer { unsetenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE") }
        XCTAssertEqual(
            try HermesRelayCrypto.gatewayRelaySafetyCode(
                agentPublicKeyX963: data(hex:
                    "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
                    "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
                ),
                phonePublicKeyX963: data(hex:
                    "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978" +
                    "07775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"
                )
            ),
            "97AB 6CD8 FEF0 9594 D5ED FAF1 1D10 B6F7"
        )
    }

    // MARK: - Relay key-wrap AEAD domain-core routing

    /// Shadow mode must route the relay key-wrap AEAD seal/open through the
    /// Rust domain-core adapter and record comparison evidence for
    /// `seal_combined`/`open_combined`. On the pre-fix head the key-wrap path
    /// calls `HermesRelayLegacyCrypto` directly, bypassing the adapter entirely,
    /// so no `seal_combined`/`open_combined` comparison is ever recorded.
    func testShadowModeRecordsKeyWrapAeadComparisonEvidence() throws {
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"] == "1" else {
            throw XCTSkip("native-required in domain-core CI")
        }
        assertNativeDomainCoreLoaded()

        var comparisons: [DomainCoreShadowComparison] = []
        DomainCoreShadowComparisonCollector.configure { comparisons.append($0) }
        defer { DomainCoreShadowComparisonCollector.configure(nil) }

        setenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE", "shadow", 1)
        defer { unsetenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE") }

        let recipient = HermesRelayCrypto.generatePrivateKey()
        let symmetricKey = try HermesRelayCrypto.generateSymmetricKeyData()
        let aad = try HermesRelayCrypto.keyAAD(
            uid: "user-1",
            connectionID: "connection-2",
            requestID: "request-3"
        )

        let wrapped = try HermesRelayCrypto.wrapSymmetricKey(
            symmetricKey,
            recipientPublicKeyBase64: recipient.publicKeyBase64,
            aad: aad
        )
        let unwrapped = try HermesRelayCrypto.unwrapSymmetricKey(
            wrapped,
            privateKey: recipient,
            aad: aad
        )

        // The wrapped key must round-trip regardless of mode.
        XCTAssertEqual(unwrapped, symmetricKey)

        // The adapter must have routed the key-wrap AEAD seal and open through
        // the domain-core dispatch, recording a shadow comparison for each.
        let sealComparisons = comparisons.filter {
            $0.domain == "hermes" && $0.slice == "payload-keywrap" && $0.operation == "seal_combined"
        }
        let openComparisons = comparisons.filter {
            $0.domain == "hermes" && $0.slice == "payload-keywrap" && $0.operation == "open_combined"
        }
        XCTAssertFalse(sealComparisons.isEmpty,
            "key-wrap seal must route through HermesDomainCoreAdapter and record a seal_combined shadow comparison")
        XCTAssertFalse(openComparisons.isEmpty,
            "key-wrap open must route through HermesDomainCoreAdapter and record an open_combined shadow comparison")
    }

    /// In rust mode the key-wrap AEAD must round-trip through the native
    /// domain-core library. The loaded native identity (ABI version 3) is the
    /// evidence that the Rust path is live, not a mocked fallback.
    func testRustModeRoundTripsKeyWrapThroughNativeDomainCore() throws {
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"] == "1" else {
            throw XCTSkip("native-required in domain-core CI")
        }
        assertNativeDomainCoreLoaded()
        setenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE", "rust", 1)
        defer { unsetenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE") }

        let recipient = HermesRelayCrypto.generatePrivateKey()
        let symmetricKey = try HermesRelayCrypto.generateSymmetricKeyData()
        let aad = try HermesRelayCrypto.keyAAD(
            uid: "user-1",
            connectionID: "connection-2",
            requestID: "request-3"
        )

        let wrapped = try HermesRelayCrypto.wrapSymmetricKey(
            symmetricKey,
            recipientPublicKeyBase64: recipient.publicKeyBase64,
            aad: aad
        )
        let unwrapped = try HermesRelayCrypto.unwrapSymmetricKey(
            wrapped,
            privateKey: recipient,
            aad: aad
        )
        XCTAssertEqual(unwrapped, symmetricKey)
    }

    /// In rust mode a tampered wrapped key must fail closed — the AES-GCM tag
    /// verification failure must propagate as an error, never silently succeed
    /// or fall back to legacy.
    func testRustModeFailsClosedOnTamperedWrappedKey() throws {
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"] == "1" else {
            throw XCTSkip("native-required in domain-core CI")
        }
        assertNativeDomainCoreLoaded()
        setenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE", "rust", 1)
        defer { unsetenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE") }

        let recipient = HermesRelayCrypto.generatePrivateKey()
        let symmetricKey = try HermesRelayCrypto.generateSymmetricKeyData()
        let aad = try HermesRelayCrypto.keyAAD(
            uid: "user-1",
            connectionID: "connection-2",
            requestID: "request-3"
        )

        let wrapped = try HermesRelayCrypto.wrapSymmetricKey(
            symmetricKey,
            recipientPublicKeyBase64: recipient.publicKeyBase64,
            aad: aad
        )
        // Flip the last byte (inside the GCM tag) — the tag verification must fail.
        var tampered = Data(base64Encoded: wrapped)!
        let lastIndex = tampered.count - 1
        tampered[lastIndex] ^= 0xFF
        let tamperedWrapped = tampered.base64EncodedString()

        XCTAssertThrowsError(
            try HermesRelayCrypto.unwrapSymmetricKey(
                tamperedWrapped,
                privateKey: recipient,
                aad: aad
            )
        )
    }

    /// Shadow mode must return the legacy-authoritative result: the wrapped key
    /// round-trips and the recorded `seal_combined`/`open_combined` comparisons
    /// report `match` (Rust agrees with legacy), never `mismatch`.
    func testShadowModeKeyWrapComparisonReportsMatchNotMismatch() throws {
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"] == "1" else {
            throw XCTSkip("native-required in domain-core CI")
        }
        assertNativeDomainCoreLoaded()

        var comparisons: [DomainCoreShadowComparison] = []
        DomainCoreShadowComparisonCollector.configure { comparisons.append($0) }
        defer { DomainCoreShadowComparisonCollector.configure(nil) }

        setenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE", "shadow", 1)
        defer { unsetenv("OPENBURNBAR_DOMAIN_CORE_HERMES_MODE") }

        let recipient = HermesRelayCrypto.generatePrivateKey()
        let symmetricKey = try HermesRelayCrypto.generateSymmetricKeyData()
        let aad = try HermesRelayCrypto.keyAAD(
            uid: "user-1",
            connectionID: "connection-2",
            requestID: "request-3"
        )

        let wrapped = try HermesRelayCrypto.wrapSymmetricKey(
            symmetricKey,
            recipientPublicKeyBase64: recipient.publicKeyBase64,
            aad: aad
        )
        let unwrapped = try HermesRelayCrypto.unwrapSymmetricKey(
            wrapped,
            privateKey: recipient,
            aad: aad
        )
        XCTAssertEqual(unwrapped, symmetricKey)

        let keyWrapComparisons = comparisons.filter {
            $0.domain == "hermes" && $0.slice == "payload-keywrap"
            && ($0.operation == "seal_combined" || $0.operation == "open_combined")
        }
        XCTAssertFalse(keyWrapComparisons.isEmpty,
            "key-wrap AEAD must produce shadow comparison evidence")
        XCTAssertTrue(
            keyWrapComparisons.allSatisfy { $0.outcome == "match" },
            "shadow mode must report match (legacy-authoritative, Rust agrees) for key-wrap AEAD, got: \(keyWrapComparisons.map { $0.outcome })"
        )
    }

    private func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        })
    }
}