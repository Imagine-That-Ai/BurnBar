import CryptoKit
import Foundation
import Testing
@testable import OpenBurnBarCore

@Suite("Cloud vault crypto")
struct CloudVaultCryptoTests {
    @Test("AES-GCM text and blob envelopes decrypt only with the vault key")
    func textAndBlobRoundTrip() throws {
        let key = Data(repeating: 0x42, count: 32)
        let otherKey = Data(repeating: 0x24, count: 32)

        let sealedText = try CloudVaultCrypto.sealText("private launch plan", keyData: key)
        #expect(try CloudVaultCrypto.openText(sealedText, keyData: key) == "private launch plan")
        #expect(throws: Error.self) {
            _ = try CloudVaultCrypto.openText(sealedText, keyData: otherKey)
        }

        let body = Data("full encrypted session markdown".utf8)
        let sealedBlob = try CloudVaultCrypto.sealBlob(body, keyData: key)
        #expect(try CloudVaultCrypto.openBlob(sealedBlob, keyData: key) == body)
        #expect(throws: Error.self) {
            _ = try CloudVaultCrypto.openBlob(sealedBlob, keyData: otherKey)
        }
    }

    @Test("Cloud search token hashes are deterministic, keyed, deduplicated, and not plaintext")
    func tokenHashesAreKeyedAndStable() throws {
        let key = Data(repeating: 0x11, count: 32)
        let otherKey = Data(repeating: 0x22, count: 32)
        let text = "BurnBar BurnBar hosted MiniMax encrypted session search"

        let first = try CloudVaultCrypto.tokenHashes(for: text, keyData: key)
        let second = try CloudVaultCrypto.tokenHashes(for: text, keyData: key)
        let other = try CloudVaultCrypto.tokenHashes(for: text, keyData: otherKey)

        #expect(first == second)
        #expect(first != other)
        #expect(first.count == Set(first).count)
        #expect(first.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        #expect(!first.contains("burnbar"))
        #expect(try CloudVaultCrypto.tokenHashes(for: "the and for", keyData: key).isEmpty)
    }

    @Test("P-256 wrapped vault keys unwrap across generated device keys")
    func wrappedVaultKeyRoundTrip() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let vaultKey = Data((0..<32).map(UInt8.init))

        let wrapped = try CloudVaultCrypto.wrapVaultKey(
            vaultKey,
            recipientPublicKey: recipient.publicKey.x963Representation
        )
        let unwrapped = try CloudVaultCrypto.unwrapVaultKey(wrapped, privateKey: recipient)

        #expect(unwrapped == vaultKey)
    }
}
