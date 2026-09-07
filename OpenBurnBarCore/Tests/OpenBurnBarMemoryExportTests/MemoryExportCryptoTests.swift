// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportCryptoTests — §2.1's crypto profile, proved rather than asserted.
//
// The point of naming an RFC is that its vectors are published, so equality
// between two independent implementations is provable. `test_rfc9180AppendixA2…`
// is that proof for this suite; everything below it pins the parts §2.1 states
// that RFC 9180 does not — the salt, the two info strings, the bare section
// name, the derive-32-then-truncate nonce, and the chunk AAD.
//
// Provenance of the vectors: RFC 9180 (Barnes, Bhargavan, Lipp, Wood, February
// 2022), Appendix A.2 "DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
// ChaCha20Poly1305", A.2.1 "Base Setup Information" and the first record of
// A.2.1.1 "Encryptions" (sequence number 0), transcribed from
// https://www.rfc-editor.org/rfc/rfc9180.txt. Line-wrapping in the RFC's
// rendering is removed; no other byte is changed.

import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import OpenBurnBarMemoryExport

final class MemoryExportCryptoTests: XCTestCase {

    // MARK: - RFC 9180 Appendix A.2, base mode

    /// mode 0, kem_id 32 (DHKEM(X25519, HKDF-SHA256)), kdf_id 1 (HKDF-SHA256),
    /// aead_id 3 (ChaCha20Poly1305) — the suite D-0021 ruling 1 admits, and the
    /// only one.
    private enum A2 {
        static let info = "4f6465206f6e2061204772656369616e2055726e"
        static let skRm = "8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb"
        static let pkRm = "4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a"
        static let enc = "1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a"
        // A.2.1.1, sequence number 0.
        static let pt = "4265617574792069732074727574682c20747275746820626561757479"
        static let aad = "436f756e742d30"
        static let ct = "1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db"
            + "21993c62ce81883d2dd1b51a28"
    }

    /// The vector, opened by the same CryptoKit `HPKE` the wrap uses. If this
    /// passes, this build's HPKE *is* RFC 9180 mode_base for the suite — which
    /// is the whole reason D-0021 named an RFC instead of describing a shape.
    func test_rfc9180AppendixA2BaseVectorOpensUnderThisBuildsHPKE() throws {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try XCTUnwrap(Self.hex(A2.skRm))
        )
        // The vector's own public key must follow from its private key, or the
        // transcription is wrong in a way the open below could still hide.
        XCTAssertEqual(Self.hexString(privateKey.publicKey.rawRepresentation), A2.pkRm)

        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: try XCTUnwrap(Self.hex(A2.info)),
            encapsulatedKey: try XCTUnwrap(Self.hex(A2.enc))
        )
        let opened = try recipient.open(
            try XCTUnwrap(Self.hex(A2.ct)),
            authenticating: try XCTUnwrap(Self.hex(A2.aad))
        )
        XCTAssertEqual(Self.hexString(opened), A2.pt)
    }

    /// The same vector with one AAD byte changed must NOT open. Without this
    /// the test above would pass on an implementation that ignored `aad`
    /// entirely — and `aad = recipient_key_id` is the binding D-0021 ruling 1
    /// exists for.
    func test_rfc9180AppendixA2VectorRefusesAWrongAAD() throws {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try XCTUnwrap(Self.hex(A2.skRm))
        )
        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: try XCTUnwrap(Self.hex(A2.info)),
            encapsulatedKey: try XCTUnwrap(Self.hex(A2.enc))
        )
        XCTAssertThrowsError(
            try recipient.open(
                try XCTUnwrap(Self.hex(A2.ct)),
                authenticating: Data("Count-1".utf8)
            )
        )
    }

    // MARK: - The wrap

    func test_theWrappedBundleKeyOpensForItsRecipientAndNoOther() throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let recipient = MemoryExportRecipient(
            keyID: MemoryExportRecipient.keyID(for: privateKey.publicKey),
            publicKey: privateKey.publicKey,
            storeID: "target-store"
        )
        let bundleKey = MemoryExportCrypto.deterministicBundleKey(seed: "wrap")
        let wrapped = try MemoryExportCrypto.wrap(bundleKey: bundleKey, recipient: recipient)

        var opener = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: MemoryExportCrypto.keywrapInfo,
            encapsulatedKey: wrapped.encapsulatedKey
        )
        let unwrapped = try opener.open(
            wrapped.ciphertext,
            authenticating: Data(recipient.keyID.utf8)
        )
        XCTAssertEqual(unwrapped, bundleKey.withUnsafeBytes { Data($0) })

        // A different recipient's key does not open it. The AAD carries the
        // binding, so even a correct DH would fail here.
        var wrongKey = try HPKE.Recipient(
            privateKey: Curve25519.KeyAgreement.PrivateKey(),
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: MemoryExportCrypto.keywrapInfo,
            encapsulatedKey: wrapped.encapsulatedKey
        )
        XCTAssertThrowsError(
            try wrongKey.open(wrapped.ciphertext, authenticating: Data(recipient.keyID.utf8))
        )

        var wrongAAD = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: MemoryExportCrypto.keywrapInfo,
            encapsulatedKey: wrapped.encapsulatedKey
        )
        XCTAssertThrowsError(
            try wrongAAD.open(wrapped.ciphertext, authenticating: Data("rcp_somebody-else".utf8))
        )
    }

    /// `keys/wrapped-bundle-key` is `b64url(enc) "." b64url(ct)`, unpadded.
    func test_theWrappedKeyWireFormIsTwoUnpaddedB64URLPartsSeparatedByADot() throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let recipient = MemoryExportRecipient(
            keyID: MemoryExportRecipient.keyID(for: privateKey.publicKey),
            publicKey: privateKey.publicKey,
            storeID: "target-store"
        )
        let wrapped = try MemoryExportCrypto.wrap(
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "wire"),
            recipient: recipient
        )
        let parts = wrapped.wireForm.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2)
        XCTAssertFalse(wrapped.wireForm.contains("="), "b64url here is unpadded")
        XCTAssertFalse(wrapped.wireForm.contains("+"))
        XCTAssertFalse(wrapped.wireForm.contains("/"))
        XCTAssertEqual(MemoryExportBase64URL.decode(String(parts[0])), wrapped.encapsulatedKey)
        XCTAssertEqual(MemoryExportBase64URL.decode(String(parts[1])), wrapped.ciphertext)
        XCTAssertEqual(wrapped.encapsulatedKey.count, 32, "HPKE's enc for X25519")
    }

    // MARK: - The key schedule, `mif1-hkdf-v1`

    /// The salt, the info strings and the bare section name, pinned against
    /// values computed OUTSIDE this code path (`python3` + `hashlib`, from
    /// §2.1's formulae). Deriving the expected value by calling the code under
    /// test would pin nothing.
    func test_theSegmentKeyMatchesTheSpecFormulaComputedIndependently() throws {
        let bundleKey = SymmetricKey(data: Data(repeating: 0x2A, count: 32))
        let key = MemoryExportCrypto.segmentKey(bundleKey: bundleKey, section: .memories)
        XCTAssertEqual(
            Self.hexString(key.withUnsafeBytes { Data($0) }),
            "5b7e1796bb3c5f1cfc9e0926374a8ec15790357dc130ad90937ad671ba3d22c8"
        )
    }

    /// §2.1 writes the nonce as `HKDF(..., L = 32)[0 .. nonce_len]`, and an
    /// implementer reading that reasonably wonders whether asking HKDF for 12
    /// bytes instead would produce something else — a difference that would show
    /// up only as a silent decryption failure at import. It would not:
    /// RFC 5869's Expand builds `T(1) ‖ T(2) ‖ …` and truncates, so a shorter
    /// output is a PREFIX of a longer one. Both readings agree, and that is
    /// worth pinning rather than leaving each side to discover.
    func test_theSegmentNonceIsThePrefixOfTheThirtyTwoByteExpansion() throws {
        let segmentKey = SymmetricKey(data: Data(repeating: 0x2A, count: 32))
        let nonce = try MemoryExportCrypto.segmentNonce(segmentKey: segmentKey, index: 0)
        XCTAssertEqual(Data(nonce).count, MemoryExportCrypto.nonceBytes)
        XCTAssertEqual(Self.hexString(Data(nonce)), "d0fe1471af26a251fe09b028")

        let twelve = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: segmentKey,
            salt: MemoryExportCrypto.hkdfSalt,
            info: Data("mif1/nonce/0".utf8),
            outputByteCount: 12
        )
        XCTAssertEqual(twelve.withUnsafeBytes { Data($0) }, Data(nonce))

        // `decimal(index)` is ASCII digits with no padding, so consecutive
        // segments of one section get unrelated nonces rather than adjacent
        // ones — and the index is genuinely in the derivation.
        let one = try MemoryExportCrypto.segmentNonce(segmentKey: segmentKey, index: 1)
        XCTAssertNotEqual(Data(one), Data(nonce))
    }

    /// D-0025 ruling 1: the segment is keyed by the BARE name. `00-tombstones`
    /// is the directory, and the two readings fail as a silent decryption error
    /// at import rather than as anything a reader can see.
    func test_theSegmentIsKeyedByTheBareNameNotTheDirectoryName() {
        XCTAssertEqual(MIFSection.tombstones.bareName, "tombstones")
        XCTAssertEqual(MIFSection.tombstoneReceipts.bareName, "tombstone_receipts")
        XCTAssertEqual(MIFSection.auditEvidence.bareName, "audit_evidence")
        XCTAssertEqual(MIFSection.findings.bareName, "findings")
        for section in MIFSection.allCases {
            XCTAssertFalse(section.bareName.contains("-"), section.rawValue)
            XCTAssertTrue(section.rawValue.hasSuffix(section.bareName))
        }

        let bundleKey = MemoryExportCrypto.deterministicBundleKey(seed: "bare")
        let bare = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: bundleKey,
            salt: MemoryExportCrypto.hkdfSalt,
            info: Data("mif1/segment/tombstones".utf8),
            outputByteCount: 32
        )
        XCTAssertEqual(
            MemoryExportCrypto.segmentKey(bundleKey: bundleKey, section: .tombstones),
            bare
        )
    }

    // MARK: - The chunk AAD

    func test_theChunkAADIsSectionSlashIndexAndBindsBothOfThem() throws {
        XCTAssertEqual(
            MemoryExportCrypto.segmentAAD(section: .memories, index: 0),
            Data("memories/0".utf8)
        )
        XCTAssertEqual(MemoryExportCrypto.segmentAAD(section: .bodies, index: 3).count, 8)
        XCTAssertEqual(MemoryExportCrypto.segmentAAD(section: .tombstoneReceipts, index: 11).count, 21)

        // A segment sealed as `memories/0` does not open as `bodies/0`, and does
        // not open at index 1 — which is what stops a segment being moved
        // between sections or reordered inside one.
        let bundleKey = MemoryExportCrypto.deterministicBundleKey(seed: "aad")
        let plaintext = Data("{\"profile\":\"migration\"}\n".utf8)
        let memoriesKey = MemoryExportCrypto.segmentKey(bundleKey: bundleKey, section: .memories)
        let sealed = try MemoryExportCrypto.seal(
            chunk: plaintext,
            section: .memories,
            segmentKey: memoriesKey,
            index: 0
        )
        XCTAssertEqual(
            try MemoryExportCrypto.open(
                sealedChunk: sealed,
                section: .memories,
                segmentKey: memoriesKey,
                index: 0
            ),
            plaintext
        )
        XCTAssertThrowsError(
            try MemoryExportCrypto.open(
                sealedChunk: sealed,
                section: .bodies,
                segmentKey: memoriesKey,
                index: 0
            ),
            "a segment must not open under another section's AAD"
        )
        XCTAssertThrowsError(
            try MemoryExportCrypto.open(
                sealedChunk: sealed,
                section: .memories,
                segmentKey: memoriesKey,
                index: 1
            ),
            "a segment must not open at another index"
        )
    }

    // MARK: - The hash tree

    /// The tree runs across a section's segments, and computing it without
    /// joining them must give the same root — otherwise avoiding that second
    /// full copy of the ciphertext would change the manifest.
    func test_theHashTreeOverSegmentsEqualsTheTreeOverTheirConcatenation() {
        let bundleKey = MemoryExportCrypto.deterministicBundleKey(seed: "tree")
        for sizes in [[0], [1], [10, 10], [4096, 1], [MemoryExportCrypto.hashTreeChunkBytes, 7]] {
            var segments: [Data] = []
            var byte: UInt8 = 1
            for size in sizes {
                segments.append(Data(repeating: byte, count: size))
                byte = byte &+ 17
            }
            let joined = segments.reduce(into: Data()) { $0.append($1) }
            XCTAssertEqual(
                MemoryExportCrypto.hashTreeRoot(bundleKey: bundleKey, segments: segments),
                MemoryExportCrypto.hashTreeRoot(bundleKey: bundleKey, ciphertext: joined),
                "sizes \(sizes)"
            )
        }
    }

    // MARK: - The recipient descriptor

    func test_aDescriptorWhoseKeyIDDoesNotFollowFromItsKeyIsRefused() throws {
        let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey
        let honest = MemoryExportRecipient.keyID(for: publicKey)
        XCTAssertTrue(honest.hasPrefix("rcp_"))
        XCTAssertEqual(honest.count, 36, "rcp_ + 32 hex")

        let good = try MemoryExportRecipient.parse(descriptor: Self.descriptor(
            keyID: honest,
            publicKey: publicKey,
            storeID: "target-store"
        ))
        XCTAssertEqual(good.keyID, honest)
        XCTAssertEqual(good.storeID, "target-store")
        // R4. `manifest.recipient_key_id` IS the `rcp_` id — D-0025 retyped the
        // member to `^rcp_[0-9a-f]{32}$` — and it has to be, because D-0021
        // ruling 1 makes that same string the HPKE `aad`. Emitting
        // `sha256(public_key)` here while sealing under `rcp_…` gave the
        // addressed importer a field it could not open the wrap with.
        XCTAssertEqual(good.manifestKeyID, honest, "the manifest field and the aad are one string")

        XCTAssertThrowsError(
            try MemoryExportRecipient.parse(descriptor: Self.descriptor(
                keyID: "rcp_" + String(repeating: "0", count: 32),
                publicKey: publicKey,
                storeID: "target-store"
            ))
        ) { error in
            guard case MemoryExportRecipient.DescriptorError.keyIDMismatch = error else {
                return XCTFail("expected a key id mismatch, got \(error)")
            }
        }
    }

    func test_aDescriptorMissingAFieldIsRefusedRatherThanDefaulted() {
        let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey
        let encoded = MemoryExportBase64URL.encode(publicKey.rawRepresentation)
        for json in [
            "{\"public_key\":\"\(encoded)\",\"store_id\":\"t\"}",
            "{\"recipient_key_id\":\"\(MemoryExportRecipient.keyID(for: publicKey))\",\"store_id\":\"t\"}",
            "{\"recipient_key_id\":\"rcp_x\",\"public_key\":\"\(encoded)\"}",
            "not json at all"
        ] {
            XCTAssertThrowsError(
                try MemoryExportRecipient.parse(descriptor: Data(json.utf8)),
                json
            )
        }
    }

    func test_base64URLRoundTripsAndIsUnpadded() {
        for length in 0...34 {
            let data = Data((0..<length).map { UInt8($0 &* 7 &+ 3) })
            let encoded = MemoryExportBase64URL.encode(data)
            XCTAssertFalse(encoded.contains("="))
            XCTAssertEqual(MemoryExportBase64URL.decode(encoded), data, "length \(length)")
        }
    }

    // MARK: - Helpers

    private static func hex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var bytes = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func descriptor(
        keyID: String,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        storeID: String
    ) -> Data {
        Data("""
        {"recipient_key_id":"\(keyID)",\
        "public_key":"\(MemoryExportBase64URL.encode(publicKey.rawRepresentation))",\
        "store_id":"\(storeID)"}
        """.utf8)
    }
}
