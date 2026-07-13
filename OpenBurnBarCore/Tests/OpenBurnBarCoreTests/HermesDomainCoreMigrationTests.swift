import Foundation
import OpenBurnBarCore
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

    private func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        })
    }
}
