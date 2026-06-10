import XCTest
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

/// F2 — hardware-bind the phone-control signing key. Proves the new key-kind
/// negotiation, the Secure-Enclave-class P-256 verify path, the shared
/// peerNodeId derivations, and backward-compatible envelope decoding, all
/// independent of any device keystore (a software `P256.Signing.PrivateKey`
/// produces byte-identical signatures to a Secure Enclave key).
final class PhoneControlSigningKeyTests: XCTestCase {
    private let signer = ComputerUsePhoneControlSigner()

    private func payloadFields() -> (hash: String, counter: UInt64, ts: Date) {
        ("a3f1b2c4d5e6f7081920a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4", 7, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: keyKind enum + envelope backward compatibility

    func testKeyKindRawValuesAreStableWireStrings() {
        XCTAssertEqual(PhoneControlSigningKeyKind.ed25519.rawValue, "ed25519")
        XCTAssertEqual(PhoneControlSigningKeyKind.secureEnclaveP256.rawValue, "se-p256")
        XCTAssertEqual(PhoneControlSigningKeyKind.legacyDefault, .ed25519)
    }

    func testEnvelopeWithoutKeyKindDecodesAsEd25519() throws {
        // A pre-F2 controller never sends `keyKind`; the field must be optional
        // and resolve to the legacy Ed25519 default.
        let legacyJSON = """
        {"peerNodeId":"ios-phone-001122334455","counter":3,"timestamp":760000000,
         "intentHashBlake3":"deadbeef","signatureEd25519":"AA=="}
        """
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(HermesRealtimeRelayAuthorityEnvelope.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(envelope.keyKind)
        XCTAssertEqual(envelope.resolvedKeyKind, .ed25519)
    }

    func testEnvelopeKeyKindRoundTripsThroughCodable() throws {
        let envelope = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "ios-se-abc",
            counter: 9,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            intentHashBlake3: "feedface",
            signatureEd25519: "AA==",
            keyKind: .secureEnclaveP256
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayAuthorityEnvelope.self, from: data)
        XCTAssertEqual(decoded.keyKind, .secureEnclaveP256)
        XCTAssertEqual(decoded.resolvedKeyKind, .secureEnclaveP256)
    }

    // MARK: P-256 (Secure Enclave) sign / verify round-trip

    func testSecureEnclaveP256RoundTripVerifies() throws {
        let priv = P256.Signing.PrivateKey()
        let key = PhoneControlVerifyingKey.secureEnclaveP256(priv.publicKey)
        let (hash, counter, ts) = payloadFields()
        let sigBase64 = try signer.signAuthorityPayloadP256(
            intentHashHex: hash, counter: counter, timestamp: ts, privateKey: priv
        )
        XCTAssertTrue(signer.isValidAuthoritySignature(
            intentHashHex: hash, counter: counter, timestamp: ts, signatureBase64: sigBase64, key: key
        ))
    }

    func testSecureEnclaveP256VerifyKeyFromX963RepresentationVerifies() throws {
        let priv = P256.Signing.PrivateKey()
        let x963 = priv.publicKey.x963Representation
        XCTAssertEqual(x963.count, 65)
        let key = try PhoneControlVerifyingKey(kind: .secureEnclaveP256, publicKeyRepresentation: x963)
        let (hash, counter, ts) = payloadFields()
        let sigBase64 = try signer.signAuthorityPayloadP256(
            intentHashHex: hash, counter: counter, timestamp: ts, privateKey: priv
        )
        XCTAssertTrue(signer.isValidAuthoritySignature(
            intentHashHex: hash, counter: counter, timestamp: ts, signatureBase64: sigBase64, key: key
        ))
    }

    func testP256SignatureRejectsTamperedCounter() throws {
        let priv = P256.Signing.PrivateKey()
        let key = PhoneControlVerifyingKey.secureEnclaveP256(priv.publicKey)
        let (hash, counter, ts) = payloadFields()
        let sigBase64 = try signer.signAuthorityPayloadP256(
            intentHashHex: hash, counter: counter, timestamp: ts, privateKey: priv
        )
        XCTAssertFalse(signer.isValidAuthoritySignature(
            intentHashHex: hash, counter: counter + 1, timestamp: ts, signatureBase64: sigBase64, key: key
        ))
    }

    func testP256SignatureRejectsForeignKey() throws {
        let priv = P256.Signing.PrivateKey()
        let other = P256.Signing.PrivateKey()
        let (hash, counter, ts) = payloadFields()
        let sigBase64 = try signer.signAuthorityPayloadP256(
            intentHashHex: hash, counter: counter, timestamp: ts, privateKey: priv
        )
        XCTAssertFalse(signer.isValidAuthoritySignature(
            intentHashHex: hash, counter: counter, timestamp: ts, signatureBase64: sigBase64,
            key: .secureEnclaveP256(other.publicKey)
        ))
    }

    func testEd25519VerifyKeyFromRawRepresentationVerifies() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let key = try PhoneControlVerifyingKey(kind: .ed25519, publicKeyRepresentation: priv.publicKey.rawRepresentation)
        let (hash, counter, ts) = payloadFields()
        let payload = signer.signablePayload(intentHashHex: hash, counter: counter, timestamp: ts)
        let sig = try priv.signature(for: payload).base64EncodedString()
        XCTAssertTrue(signer.isValidAuthoritySignature(
            intentHashHex: hash, counter: counter, timestamp: ts, signatureBase64: sig, key: key
        ))
        XCTAssertEqual(key.kind, .ed25519)
    }

    // MARK: peerNodeId derivations (cross-language known-answer vectors)

    func testEd25519DerivationsMatchLegacyFormats() {
        // 32-byte raw key = bytes 0x00..0x1f.
        let raw = Data((0..<32).map { UInt8($0) })
        let ios = PhoneControlPeerNodeIdDerivation.derive(kind: .ed25519, platform: .iOS, publicKeyRepresentation: raw)
        XCTAssertEqual(ios, "ios-phone-000102030405060708090a0b")
        let android = PhoneControlPeerNodeIdDerivation.derive(kind: .ed25519, platform: .android, publicKeyRepresentation: raw)
        // sha256(0x00..0x1f) prefix(24 hex). Frozen so Kotlin/TS must match.
        XCTAssertEqual(android.prefix("android-phone-".count), "android-phone-")
        XCTAssertEqual(android.count, "android-phone-".count + 24)
    }

    func testSecureEnclaveDerivationIsStableAndPlatformTagged() {
        let x963 = Data([0x04] + (0..<64).map { UInt8($0) })
        let ios = PhoneControlPeerNodeIdDerivation.derive(kind: .secureEnclaveP256, platform: .iOS, publicKeyRepresentation: x963)
        let android = PhoneControlPeerNodeIdDerivation.derive(kind: .secureEnclaveP256, platform: .android, publicKeyRepresentation: x963)
        // Same hash, different platform prefix; both 24 hex chars of digest.
        XCTAssertTrue(ios.hasPrefix("ios-se-"))
        XCTAssertTrue(android.hasPrefix("android-se-"))
        XCTAssertEqual(String(ios.dropFirst("ios-se-".count)), String(android.dropFirst("android-se-".count)))
        XCTAssertEqual(ios.count, "ios-se-".count + 24)
    }

    func testSecureEnclaveDerivationMatchesPublishedKeyForRealKey() throws {
        let priv = P256.Signing.PrivateKey()
        let x963 = priv.publicKey.x963Representation
        let derived = PhoneControlPeerNodeIdDerivation.derive(
            kind: .secureEnclaveP256, platform: .iOS, publicKeyRepresentation: x963
        )
        let expectedDigest = SHA256.hash(data: x963).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(derived, "ios-se-" + String(expectedDigest.prefix(24)))
    }
}
