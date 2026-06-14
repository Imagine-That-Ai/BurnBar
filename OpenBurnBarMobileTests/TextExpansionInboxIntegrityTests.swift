import XCTest
import CryptoKit
@testable import OpenBurnBarMobile

// MARK: - Text Expansion Inbox Integrity MAC (T-IOS-06)
//
// Locks the authenticity contract for the keyboard → app inbox that crosses the
// App Group boundary. The pure MAC primitives take the key as a parameter so the
// decision is testable without the shared keychain.

final class TextExpansionInboxIntegrityTests: XCTestCase {
    private func makeKey() -> Data {
        Data((0 ..< 32).map { UInt8($0) })
    }

    func testAuthenticPayloadVerifies() {
        let key = makeKey()
        let payload = Data(#"[{"id":"abc","trigger":"/sig"}]"#.utf8)
        let mac = TextExpansionInboxIntegrity.computeMAC(payload: payload, key: key)
        XCTAssertTrue(
            TextExpansionInboxIntegrity.verify(payload: payload, key: key, expectedHex: mac),
            "A MAC computed over the payload must verify against it"
        )
    }

    func testTamperedPayloadFails() {
        let key = makeKey()
        let payload = Data(#"[{"id":"abc","trigger":"/sig"}]"#.utf8)
        let mac = TextExpansionInboxIntegrity.computeMAC(payload: payload, key: key)
        let tampered = Data(#"[{"id":"abc","trigger":"/evil"}]"#.utf8)
        XCTAssertFalse(
            TextExpansionInboxIntegrity.verify(payload: tampered, key: key, expectedHex: mac),
            "A modified payload must fail the original MAC"
        )
    }

    func testWrongKeyFails() {
        let payload = Data("hello".utf8)
        let mac = TextExpansionInboxIntegrity.computeMAC(payload: payload, key: makeKey())
        let otherKey = Data(repeating: 0xAB, count: 32)
        XCTAssertFalse(
            TextExpansionInboxIntegrity.verify(payload: payload, key: otherKey, expectedHex: mac),
            "A MAC must not verify under a different key (App-Group-keyed)"
        )
    }

    func testMalformedHexFails() {
        let key = makeKey()
        let payload = Data("hello".utf8)
        XCTAssertFalse(
            TextExpansionInboxIntegrity.verify(payload: payload, key: key, expectedHex: "nothex"),
            "A non-hex MAC string must fail closed"
        )
        XCTAssertFalse(
            TextExpansionInboxIntegrity.verify(payload: payload, key: key, expectedHex: ""),
            "An empty MAC must fail closed"
        )
    }

    func testMACMatchesReferenceHMAC() {
        // Cross-check the helper against a direct CryptoKit computation so the
        // hex encoding stays stable across refactors.
        let key = makeKey()
        let payload = Data("integrity".utf8)
        let reference = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(TextExpansionInboxIntegrity.computeMAC(payload: payload, key: key), reference)
    }

    func testSidecarURLNaming() {
        let inbox = URL(fileURLWithPath: "/tmp/text-expansion-inbox.json")
        XCTAssertEqual(
            TextExpansionInboxIntegrity.macURL(for: inbox).lastPathComponent,
            "text-expansion-inbox.json.mac"
        )
    }
}
