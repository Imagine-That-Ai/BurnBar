import CryptoKit
import Foundation
import LibSignalClient
import XCTest

/// D3 iOS-satellite proof: a libsignal-FREE client (Apple CryptoKit only) can OPEN an at-rest
/// envelope sealed by real libsignal HPKE. The iOS App Store binary ships no libsignal, yet must
/// read its own CloudVault data, which is sealed (on Mac/Android/backend) with libsignal's
/// `Base_X25519_HkdfSha256_Aes256Gcm` HPKE. That suite is byte-identical to CryptoKit's
/// `Curve25519_SHA256_AES_GCM_256`, so this KAT locks the interop with a vector: seal with
/// libsignal, open with ONLY CryptoKit.
final class CryptoKitAtRestInteropTests: XCTestCase {

    @available(macOS 14.0, iOS 17.0, *)
    func testCryptoKitOpensLibsignalHpkeSeal() throws {
        // Recipient keypair (the iOS device's at-rest key).
        let recipientPriv = PrivateKey.generate()
        let recipientPub = recipientPriv.publicKey

        let plaintext = Array("at-rest payload that only the device key opens".utf8)
        let info = Array("OpenBurnBar-AtRest-KAT-v1".utf8)
        let aad = Array("binding|uid-123|device-abc".utf8)

        // Seal with REAL libsignal HPKE (this is what Mac/Android/backend do at rest).
        let sealed = recipientPub.seal(plaintext, info: info, associatedData: aad)

        // Sanity: libsignal itself round-trips.
        let libOpened = try recipientPriv.open(sealed, info: info, associatedData: aad)
        XCTAssertEqual(Array(libOpened), plaintext)

        // ---- The iOS-satellite path: open with ONLY CryptoKit, no libsignal ----
        let sealedData = Data(sealed)
        XCTAssertEqual(sealedData.first, 0x01, "expected Signal Base_X25519_HkdfSha256_Aes256Gcm type byte")
        let enc = sealedData.subdata(in: 1 ..< 33) // 32-byte X25519 encapsulated key (Nenc=32)
        let ciphertext = sealedData.subdata(in: 33 ..< sealedData.count)

        // Reconstruct the recipient X25519 private key for CryptoKit (strip any type prefix).
        let privRaw = Data(recipientPriv.serialize())
        let ckPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privRaw.suffix(32))

        // libsignal's Base_X25519_HkdfSha256_Aes256Gcm == this RFC 9180 suite.
        let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
        var recipient = try HPKE.Recipient(
            privateKey: ckPriv,
            ciphersuite: suite,
            info: Data(info),
            encapsulatedKey: enc
        )
        let ckOpened = try recipient.open(ciphertext, authenticating: Data(aad))

        XCTAssertEqual(Array(ckOpened), plaintext, "CryptoKit (no libsignal) must open the libsignal-sealed envelope")
    }
}
