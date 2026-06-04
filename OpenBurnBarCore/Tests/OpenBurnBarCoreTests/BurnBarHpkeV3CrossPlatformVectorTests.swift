import CryptoKit
import Foundation
import XCTest

/// Proves Swift CryptoKit — an independent RFC 9180 HPKE implementation — opens
/// the canonical Python-generated HPKE **v3** relay vectors. This is the
/// cross-language byte-agreement gate for `relayKeyVersion == 3`: if Apple's
/// CryptoKit and the Hermes Python agent disagree on a single suite id, label,
/// `info` byte, or X9.63 encoding, one of these opens fails.
///
/// Suite: `DHKEM(P-256, HKDF-SHA256) + HKDF-SHA256 + AES-256-GCM`, HPKE **auth**
/// mode. `info = "OpenBurnBar-HermesRelay-HPKE-v3|" + key_aad`; the AEAD `aad`
/// for the single HPKE seal is `key_aad`; HPKE wraps only the 32-byte content
/// key, which then opens the existing AES-GCM payload layer (`nonce ‖ ct ‖ tag`).
///
/// Fixture: `Fixtures/BurnBarHpkeV3Vector.json`, emitted by the Hermes test lane
/// (`tests/gateway/vectors/generate_burnbar_hpke_v3_vectors.py`) and opened by
/// `tests/gateway/test_burnbar_hpke_v3_vectors.py`. This is the vendored
/// canonical v3 fixture for this PR; regenerate and re-vendor through all three
/// language owners whenever the frozen contract changes.
final class BurnBarHpkeV3CrossPlatformVectorTests: XCTestCase {
    private static let ciphersuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

    private static let fixtureURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("BurnBarHpkeV3Vector.json")
    }()

    private func loadFixture() throws -> V3Fixture {
        try JSONDecoder().decode(V3Fixture.self, from: Data(contentsOf: Self.fixtureURL))
    }

    private func decodeBase64(_ value: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: value), "value is not valid base64")
    }

    func test_fixtureIsTheFrozenV3Contract() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.relayKeyVersion, 3)
        XCTAssertEqual(fixture.relayEncryption, "hpke-auth-p256-hkdfsha256-aes256gcm")
        XCTAssertEqual(fixture.suite.kemId, 0x0010)
        XCTAssertEqual(fixture.suite.kdfId, 0x0001)
        XCTAssertEqual(fixture.suite.aeadId, 0x0002)
        XCTAssertEqual(fixture.suite.modeId, 0x02)
    }

    /// CryptoKit opens every positive vector: the HPKE Auth wrap recovers the
    /// exact content key, and that key opens the sealed payload to the exact
    /// plaintext under its payload AAD.
    func test_cryptoKitOpensEveryPositivePythonVector() throws {
        let fixture = try loadFixture()
        var opened = 0
        for vector in fixture.cases where vector.expected == "open" {
            let contentKey = try openContentKey(vector)
            XCTAssertEqual(
                contentKey,
                try decodeBase64(try XCTUnwrap(vector.plaintextContentKey)),
                "\(vector.name): unwrapped content key mismatch"
            )

            let sealedBox = try AES.GCM.SealedBox(
                combined: try decodeBase64(try XCTUnwrap(vector.payloadCiphertext))
            )
            let payload = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: contentKey),
                authenticating: Data(try XCTUnwrap(vector.payloadAAD).utf8)
            )
            XCTAssertEqual(
                String(data: payload, encoding: .utf8),
                vector.payloadPlaintext,
                "\(vector.name): sealed payload mismatch"
            )
            opened += 1
        }
        XCTAssertEqual(opened, 5, "expected all five positive v3 vectors to open")
    }

    /// The HPKE Auth pin is the forgery defense: binding the wrong sender static
    /// key makes CryptoKit's AEAD authentication fail.
    func test_cryptoKitRejectsWrongPinnedSender() throws {
        let fixture = try loadFixture()
        let negative = try XCTUnwrap(fixture.cases.first { $0.name == "wrong_pinned_sender_key" })
        let base = try XCTUnwrap(fixture.cases.first { $0.name == negative.derivedFrom })

        let recipientKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try decodeBase64(try XCTUnwrap(base.recipientPrivateKeyRaw))
        )
        let wrongSender = try P256.KeyAgreement.PublicKey(
            x963Representation: try decodeBase64(try XCTUnwrap(negative.pinnedSenderPublicKeyX963Override))
        )
        var recipient = try HPKE.Recipient(
            privateKey: recipientKey,
            ciphersuite: Self.ciphersuite,
            info: Data(try XCTUnwrap(base.info).utf8),
            encapsulatedKey: try decodeBase64(try XCTUnwrap(base.enc)),
            authenticatedBy: wrongSender
        )
        XCTAssertThrowsError(
            try recipient.open(
                try decodeBase64(try XCTUnwrap(base.wrappedKey)),
                authenticating: Data(try XCTUnwrap(base.keyAAD).utf8)
            ),
            "binding the wrong pinned sender key must fail authentication"
        )
    }

    /// Tampering with the HPKE ciphertext fails the AEAD tag.
    func test_cryptoKitRejectsMutatedWrappedKey() throws {
        let fixture = try loadFixture()
        let base = try XCTUnwrap(fixture.cases.first { $0.name == "phone_event_text" })

        let recipientKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try decodeBase64(try XCTUnwrap(base.recipientPrivateKeyRaw))
        )
        let pinnedSender = try P256.KeyAgreement.PublicKey(
            x963Representation: try decodeBase64(try XCTUnwrap(base.pinnedSenderPublicKeyX963))
        )
        var wrapped = try decodeBase64(try XCTUnwrap(base.wrappedKey))
        wrapped[wrapped.startIndex] ^= 0x01
        var recipient = try HPKE.Recipient(
            privateKey: recipientKey,
            ciphersuite: Self.ciphersuite,
            info: Data(try XCTUnwrap(base.info).utf8),
            encapsulatedKey: try decodeBase64(try XCTUnwrap(base.enc)),
            authenticatedBy: pinnedSender
        )
        XCTAssertThrowsError(
            try recipient.open(wrapped, authenticating: Data(try XCTUnwrap(base.keyAAD).utf8)),
            "a mutated HPKE ciphertext must fail the AEAD tag"
        )
    }

    /// A mutated `key_aad` (the AEAD associated data) fails authentication.
    func test_cryptoKitRejectsWrongKeyAAD() throws {
        let fixture = try loadFixture()
        let base = try XCTUnwrap(fixture.cases.first { $0.name == "phone_event_text" })

        let recipientKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try decodeBase64(try XCTUnwrap(base.recipientPrivateKeyRaw))
        )
        let pinnedSender = try P256.KeyAgreement.PublicKey(
            x963Representation: try decodeBase64(try XCTUnwrap(base.pinnedSenderPublicKeyX963))
        )
        var recipient = try HPKE.Recipient(
            privateKey: recipientKey,
            ciphersuite: Self.ciphersuite,
            info: Data(try XCTUnwrap(base.info).utf8),
            encapsulatedKey: try decodeBase64(try XCTUnwrap(base.enc)),
            authenticatedBy: pinnedSender
        )
        let tamperedAAD = try XCTUnwrap(base.keyAAD) + "|tampered"
        XCTAssertThrowsError(
            try recipient.open(
                try decodeBase64(try XCTUnwrap(base.wrappedKey)),
                authenticating: Data(tamperedAAD.utf8)
            ),
            "a mutated key_aad must fail authentication"
        )
    }

    /// The v3 wire shapes: `enc` is a 65-byte X9.63 point, `wrappedKey` is the
    /// 48-byte HPKE ciphertext (`ct(32) ‖ tag(16)`).
    func test_v3WireShapesAreExact() throws {
        let fixture = try loadFixture()
        var checked = 0
        for vector in fixture.cases where vector.expected == "open" {
            XCTAssertEqual(
                try decodeBase64(try XCTUnwrap(vector.enc)).count, 65, "\(vector.name): enc must be 65 bytes"
            )
            XCTAssertEqual(
                try decodeBase64(try XCTUnwrap(vector.wrappedKey)).count, 48, "\(vector.name): wrappedKey must be 48 bytes"
            )
            checked += 1
        }
        XCTAssertEqual(checked, 5)
    }

    // MARK: - Helpers

    private func openContentKey(_ vector: V3Case) throws -> Data {
        let recipientKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try decodeBase64(try XCTUnwrap(vector.recipientPrivateKeyRaw))
        )
        let pinnedSender = try P256.KeyAgreement.PublicKey(
            x963Representation: try decodeBase64(try XCTUnwrap(vector.pinnedSenderPublicKeyX963))
        )
        var recipient = try HPKE.Recipient(
            privateKey: recipientKey,
            ciphersuite: Self.ciphersuite,
            info: Data(try XCTUnwrap(vector.info).utf8),
            encapsulatedKey: try decodeBase64(try XCTUnwrap(vector.enc)),
            authenticatedBy: pinnedSender
        )
        return try recipient.open(
            try decodeBase64(try XCTUnwrap(vector.wrappedKey)),
            authenticating: Data(try XCTUnwrap(vector.keyAAD).utf8)
        )
    }
}

// MARK: - Fixture shapes (a subset of the rich union fixture schema)

private struct V3Fixture: Decodable {
    let relayKeyVersion: Int
    let relayEncryption: String
    let suite: V3Suite
    let cases: [V3Case]
}

private struct V3Suite: Decodable {
    let kemId: Int
    let kdfId: Int
    let aeadId: Int
    let modeId: Int
}

private struct V3Case: Decodable {
    let name: String
    let expected: String
    let recipientPrivateKeyRaw: String?
    let pinnedSenderPublicKeyX963: String?
    let info: String?
    let keyAAD: String?
    let enc: String?
    let wrappedKey: String?
    let plaintextContentKey: String?
    let payloadAAD: String?
    let payloadCiphertext: String?
    let payloadPlaintext: String?
    let derivedFrom: String?
    let pinnedSenderPublicKeyX963Override: String?
}
