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

    /// Reverse runtime direction: a libsignal-FREE sealer (pure CryptoKit HPKE.Sender, the same
    /// suite + 0x01||enc||ct framing) produces an envelope that REAL libsignal opens. Together
    /// with the test above this proves the interop in both directions with fresh keys.
    @available(macOS 14.0, iOS 17.0, *)
    func testLibsignalOpensCryptoKitHpkeSeal() throws {
        let recipientPriv = PrivateKey.generate()
        let recipientPub = recipientPriv.publicKey

        let plaintext = Data("at-rest payload sealed without any libsignal".utf8)
        let info = Data("OpenBurnBar-AtRest-KAT-v1".utf8)
        let aad = Data("binding|uid-123|device-abc".utf8)

        // Seal with ONLY CryptoKit (what a libsignal-free writer would do).
        let pubRaw = Data(recipientPub.serialize()).suffix(32)
        let ckPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw)
        let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
        var sender = try HPKE.Sender(recipientKey: ckPub, ciphersuite: suite, info: info)
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        XCTAssertEqual(sender.encapsulatedKey.count, 32)
        var sealed = Data([0x01])
        sealed.append(sender.encapsulatedKey)
        sealed.append(ciphertext)

        // Open with REAL libsignal.
        let opened = try recipientPriv.open(Array(sealed), info: Array(info), associatedData: Array(aad))
        XCTAssertEqual(Data(opened), plaintext, "libsignal must open the CryptoKit-sealed envelope")
    }

    /// COMMITTED vector, direction 1 (ADR-001 §7.2): the fixture's case sealed by official
    /// libsignal (Node bindings, Rust core) opens with ONLY CryptoKit. The committed bytes —
    /// not a runtime round-trip — are the interop fact the public trust copy points at.
    @available(macOS 14.0, iOS 17.0, *)
    func testCryptoKitOpensCommittedLibsignalSealedVector() throws {
        let vector = try loadInteropVector()
        let testCase = try XCTUnwrap(
            vector.cases.first { $0.id == "libsignal-seals-cryptokit-opens" },
            "committed vector is missing the libsignal-seals case"
        )

        let sealed = try XCTUnwrap(Data(base64Encoded: testCase.sealedB64))
        XCTAssertEqual(sealed.first, 0x01)
        let enc = sealed.subdata(in: 1 ..< 33)
        let ciphertext = sealed.subdata(in: 33 ..< sealed.count)

        let privRaw = try XCTUnwrap(Data(base64Encoded: vector.recipientPrivateKeyB64))
        let ckPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privRaw.suffix(32))
        let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
        var recipient = try HPKE.Recipient(
            privateKey: ckPriv,
            ciphersuite: suite,
            info: try XCTUnwrap(Data(base64Encoded: vector.infoB64)),
            encapsulatedKey: enc
        )
        let aad = try XCTUnwrap(Data(base64Encoded: vector.aadB64))
        let opened = try recipient.open(ciphertext, authenticating: aad)

        XCTAssertEqual(opened, Data(base64Encoded: testCase.plaintextB64))
    }

    /// COMMITTED vector, direction 2 (ADR-001 §7.2): the fixture's case sealed by pure CryptoKit
    /// (scripts/ci/cryptokit-hpke-cli.swift, zero libsignal) opens with REAL libsignal.
    func testLibsignalOpensCommittedCryptoKitSealedVector() throws {
        let vector = try loadInteropVector()
        let testCase = try XCTUnwrap(
            vector.cases.first { $0.id == "cryptokit-seals-libsignal-opens" },
            "committed vector is missing the cryptokit-seals case"
        )

        let privRaw = try XCTUnwrap(Data(base64Encoded: vector.recipientPrivateKeyB64))
        let priv = try PrivateKey(privRaw)
        let sealed = try XCTUnwrap(Data(base64Encoded: testCase.sealedB64))
        let info = try XCTUnwrap(Data(base64Encoded: vector.infoB64))
        let aad = try XCTUnwrap(Data(base64Encoded: vector.aadB64))

        let opened = try priv.open(Array(sealed), info: Array(info), associatedData: Array(aad))
        XCTAssertEqual(Data(opened), Data(base64Encoded: testCase.plaintextB64))

        // Tamper fails closed.
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertThrowsError(
            try priv.open(Array(tampered), info: Array(info), associatedData: Array(aad))
        )
    }

    private func loadInteropVector() throws -> InteropVector {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "CryptoKitAtRestInteropVector", withExtension: "json"),
            "missing committed interop vector — run scripts/ci/generate-cryptokit-interop-vector.mjs --emit"
        )
        return try JSONDecoder().decode(InteropVector.self, from: Data(contentsOf: url))
    }
}

private struct InteropVector: Decodable {
    struct Case: Decodable {
        var id: String
        var plaintextB64: String
        var sealedB64: String
    }

    var version: Int
    var recipientPrivateKeyB64: String
    var infoB64: String
    var aadB64: String
    var cases: [Case]
}
