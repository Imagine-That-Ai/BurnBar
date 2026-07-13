import Foundation
import OpenBurnBarCore
import XCTest
#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

final class HermesDomainCoreMigrationTests: XCTestCase {
    private func assertNativeDomainCoreLoaded() {
        #if canImport(OpenBurnBarDomainCoreFFI)
        XCTAssertEqual(OpenBurnBarDomainCoreFFI.domainCoreAbiVersion(), 2)
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

        let aad = HermesRelayCrypto.requestAAD(
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
            HermesRelayCrypto.gatewayRelaySafetyCode(
                agentPublicKeyX963: Data((0..<65).map(UInt8.init)),
                phonePublicKeyX963: Data((0..<65).reversed().map(UInt8.init))
            ),
            "897E 3E16 F194 F44A 9E79 B41E F88E CBE7"
        )
    }
}
