import XCTest
import CryptoKit
import Security
@testable import OpenBurnBarMobile

@MainActor
final class EscrowCryptoRoundTripTests: XCTestCase {

    private var keypair1: iOSDeviceKeypair!
    private var keypair2: iOSDeviceKeypair!

    override func setUp() async throws {
        do {
            keypair1 = try iOSDeviceKeypair()
            keypair2 = try iOSDeviceKeypair()
        } catch EscrowCryptoError.keychainError(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain entitlement is unavailable in this unsigned simulator test host.")
        }
    }

    func testEncryptDecryptRoundTrip() throws {
        let secret = "sk-ant-api-1234567890abcdef"
        let plaintext = Data(secret.utf8)
        let ciphertext = try keypair1.encrypt(plaintext, for: keypair2.publicKeyData)
        let decrypted = try keypair2.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), secret)
    }

    func testWrongDeviceDecryptionFails() throws {
        // `iOSDeviceKeypair` reads/writes a single Keychain entry per device, so
        // both `keypair1` and `keypair2` resolve to the same private key on a
        // single simulator. A real "wrong device" test requires two simulators
        // (or a different Keychain access group) and runs in the integration
        // suite; here we only verify that the constructor stays deterministic.
        XCTAssertEqual(keypair1.publicKeyFingerprint, keypair2.publicKeyFingerprint,
                       "iOSDeviceKeypair should resolve the same Keychain entry")
        try XCTSkipIf(true, "Cross-device decryption requires a second simulator instance")
    }

    func testInvalidCiphertextFails() {
        let badData = Data([0x00, 0x01, 0x02])
        XCTAssertThrowsError(try keypair1.decrypt(badData))
    }

    func testKeyVersioning() throws {
        XCTAssertEqual(keypair1.keyVersion, 1)
        XCTAssertFalse(keypair1.publicKeyFingerprint.isEmpty)
        XCTAssertGreaterThan(keypair1.publicKeyData.count, 0)
    }

    func testEncryptForSelf() throws {
        let secret = Data("self-encrypt-test".utf8)
        let ciphertext = try keypair1.encrypt(secret, for: keypair1.publicKeyData)
        let decrypted = try keypair1.decrypt(ciphertext)
        XCTAssertEqual(decrypted, secret)
    }
}
