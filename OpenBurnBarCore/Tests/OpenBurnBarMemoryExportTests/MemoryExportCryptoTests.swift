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

    /// M-4 of interop run 1: a sealed segment is `ciphertext ‖ tag` and the
    /// nonce is NOT in it.
    ///
    /// The exporter used to write CryptoKit's `ChaChaPoly.SealedBox.combined`,
    /// which prefixes the 12 nonce bytes. §2.1 derives the nonce and says so
    /// twice, so the Rust importer derived it, read the ciphertext 12 bytes off
    /// and could open nothing — the 28-byte empty segments were the tell. This
    /// pins the framing by LENGTH and by the derived-nonce open, so a return to
    /// `.combined` is a failure here rather than at the next interop run.
    func test_aSealedSegmentIsCiphertextAndTagWithNoPrependedNonce() throws {
        let bundleKey = MemoryExportCrypto.deterministicBundleKey(seed: "framing")
        let key = MemoryExportCrypto.segmentKey(bundleKey: bundleKey, section: .memories)
        let plaintext = Data("{\"id\":\"mem-00\"}\n".utf8)
        let sealed = try MemoryExportCrypto.seal(
            chunk: plaintext,
            section: .memories,
            segmentKey: key,
            index: 0
        )

        // Exactly the tag is added. 28 bytes of overhead would be the nonce
        // riding along.
        XCTAssertEqual(sealed.count, plaintext.count + MemoryExportCrypto.tagBytes)
        XCTAssertEqual(MemoryExportCrypto.sealOverheadBytes, MemoryExportCrypto.tagBytes)

        // And the segment does not START with the nonce, which is the byte-level
        // form of the same claim.
        let nonce = Data(try MemoryExportCrypto.segmentNonce(segmentKey: key, index: 0))
        XCTAssertNotEqual(sealed.prefix(MemoryExportCrypto.nonceBytes), nonce)

        // A reader that DERIVES the nonce opens it, which is what the importer
        // does.
        let box = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonce),
            ciphertext: sealed.prefix(sealed.count - MemoryExportCrypto.tagBytes),
            tag: sealed.suffix(MemoryExportCrypto.tagBytes)
        )
        XCTAssertEqual(
            try ChaChaPoly.open(box, using: key, authenticating: Data("memories/0".utf8)),
            plaintext
        )
        XCTAssertEqual(
            try MemoryExportCrypto.open(sealedChunk: sealed, section: .memories, segmentKey: key, index: 0),
            plaintext
        )

        // The old framing is not merely different, it is unreadable to a spec
        // reader: `combined` parsed out of these bytes takes the first 12 as a
        // nonce they are not.
        let asCombined = try? ChaChaPoly.SealedBox(combined: sealed)
        if let asCombined {
            XCTAssertThrowsError(
                try ChaChaPoly.open(asCombined, using: key, authenticating: Data("memories/0".utf8))
            )
        }
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

    // MARK: - The body join key and `normalize`

    /// M-5 + D-0039 ruling 3: `K_join` is derived with the WORKSPACE SALT, like
    /// every other key in `mif1-hkdf-v1`.
    ///
    /// The exporter used to derive this one value with an unsalted HKDF, which
    /// migration §2 permitted by naming no salt at all — so the importer, which
    /// salts, computed a different key for the same body and the join could
    /// never have matched across the boundary. The salted derivation is
    /// recomputed here from `HKDF<SHA256>` directly, so this fails if the
    /// argument is dropped again.
    func test_theJoinKeyIsDerivedWithTheWorkspaceSalt() {
        let bundleKey = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let salted = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: bundleKey,
            salt: MemoryExportCrypto.hkdfSalt,
            info: Data("mif1/join/v1".utf8),
            outputByteCount: 32
        )
        XCTAssertEqual(MemoryExportCrypto.joinKey(bundleKey: bundleKey), salted)

        let unsalted = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: bundleKey,
            info: Data("mif1/join/v1".utf8),
            outputByteCount: 32
        )
        XCTAssertNotEqual(MemoryExportCrypto.joinKey(bundleKey: bundleKey), unsalted)
    }

    /// M-7: `body_join_key` and `body_norm_digest` differ BY CONSTRUCTION.
    ///
    /// Both were one construction over one preimage, so all five memory rows of
    /// the interop fixture carried the same value twice and section 05's
    /// three-member roll-up tuple was two members wide — a body/verdict swap it
    /// claims to catch would have balanced. The join key is over the exact
    /// stored bytes; the digest is over `normalize`. They coincide only for a
    /// body that is already its own normal form, so this drives one that is not
    /// AND one that is.
    func test_theJoinKeyAndTheNormDigestAreNotTheSameValue() {
        let bundleKey = MemoryExportCrypto.deterministicBundleKey(seed: "join-vs-norm")
        let body = "Hello\r\n  world  \r\n"
        XCTAssertNotEqual(
            MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: body),
            MemoryExportCrypto.bodyNormDigest(bundleKey: bundleKey, body: body)
        )

        // The join key is over the CANONICAL bytes, so a reader that b64url-
        // decodes `record_body.body` and re-HMACs it reproduces the field.
        XCTAssertEqual(
            MemoryExportCrypto.canonicalBodyBytes(body),
            Data(body.utf8)
        )
        XCTAssertEqual(
            MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: body),
            Self.hexString(Data(HMAC<SHA256>.authenticationCode(
                for: Data(body.utf8),
                using: MemoryExportCrypto.joinKey(bundleKey: bundleKey)
            )))
        )

        // A body that IS its own normal form is the one case where the two
        // agree, and that is a property of the body rather than of the code.
        let alreadyNormal = "hello world"
        XCTAssertEqual(MemoryExportCrypto.normalize(alreadyNormal), alreadyNormal)
        XCTAssertEqual(
            MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: alreadyNormal),
            MemoryExportCrypto.bodyNormDigest(bundleKey: bundleKey, body: alreadyNormal)
        )

        // And two memories with identical bodies share one join key — the whole
        // point of a content-keyed join, and what a `memory_id` in the preimage
        // would destroy.
        XCTAssertEqual(
            MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: body),
            MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: "Hello\r\n  world  \r\n")
        )
    }

    /// `normalize` is `MEMORY_SCHEMA.md` §0.1's, and only that one: NFKC ->
    /// casefold -> collapse whitespace runs to one U+0020 -> strip trailing
    /// `.,;:!?`.
    ///
    /// Every expectation below was computed with CPython
    /// (`unicodedata.normalize("NFKC", s).casefold()`, `" ".join(s.split())`,
    /// `rstrip(".,;:!?")`) and is byte-identical there — including the two
    /// cases where a `lowercased()` implementation would diverge from a
    /// case-FOLDING one, which is the difference a second language would find
    /// the hard way.
    func test_normalizeIsTheSchemasAndAgreesWithAnIndependentImplementation() {
        XCTAssertEqual(MemoryExportCrypto.normalize("Hello\r\n  world  \r\n"), "hello world")
        // Casefold, not lowercase: "ß" folds to "ss", so these two are the same
        // fact. `lowercased()` leaves "straße" and fails this line.
        XCTAssertEqual(MemoryExportCrypto.normalize("Straße"), "strasse")
        XCTAssertEqual(MemoryExportCrypto.normalize("STRASSE"), "strasse")
        // NFKC: the ligature and the fullwidth forms are compatibility
        // equivalents, and it runs BEFORE the fold.
        XCTAssertEqual(MemoryExportCrypto.normalize("\u{FB01}le"), "file")
        XCTAssertEqual(MemoryExportCrypto.normalize("\u{FF28}\u{FF45}\u{FF4C}\u{FF4C}\u{FF4F}"), "hello")
        // NFKC maps NBSP to U+0020, so it collapses like any other whitespace.
        XCTAssertEqual(MemoryExportCrypto.normalize("a\u{00A0}b"), "a b")
        // The trailing strip takes the whole run, and only the five characters
        // §0.1 names.
        XCTAssertEqual(MemoryExportCrypto.normalize("Hi!!?"), "hi")
        XCTAssertEqual(MemoryExportCrypto.normalize("a-b-"), "a-b-")
        // Interior whitespace collapses to exactly one space; the ends lose it.
        XCTAssertEqual(MemoryExportCrypto.normalize("  a \t\n b  "), "a b")
        XCTAssertEqual(MemoryExportCrypto.normalize(""), "")
        XCTAssertEqual(MemoryExportCrypto.normalize("   "), "")
        // İ (U+0130) folds to "i" + U+0307, which is where a naive lowercase
        // and a fold part company in a locale-sensitive implementation.
        XCTAssertEqual(MemoryExportCrypto.normalize("\u{0130}stanbul"), "i\u{0307}stanbul")
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

    // MARK: - D-0031: the hash tree's key and domains, the signature preimage

    /// The tree is `HKDF-SHA256(salt = "imaginethat.memory.hkdf.v1",
    /// bundle_key, "mif1/hashtree/v1")` with `0x00` leaves and `0x01` folds —
    /// recomputed here straight from CryptoKit, outside the code path, so a
    /// drift in the salt, the info string or either domain byte goes red. A
    /// single small segment is one leaf, so its root IS the leaf.
    func test_theHashTreeLeafIsHMACOver00ChunkUnderTheSaltedKey() {
        let bundleKey = MemoryExportCrypto.deterministicBundleKey(seed: "domains")
        let chunk = Data("a ciphertext chunk".utf8)
        let htKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: bundleKey,
            salt: Data("imaginethat.memory.hkdf.v1".utf8),
            info: Data("mif1/hashtree/v1".utf8),
            outputByteCount: 32
        )
        let leaf = Data(HMAC<SHA256>.authenticationCode(for: Data([0x00]) + chunk, using: htKey))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            MemoryExportCrypto.hashTreeRoot(bundleKey: bundleKey, segments: [chunk]),
            leaf
        )
        // And the fold domain differs from the leaf domain: without the bytes
        // a 64-byte leaf and a two-leaf fold would be the same message.
        let fold = Data(HMAC<SHA256>.authenticationCode(
            for: Data([0x01]) + Data(repeating: 0, count: 32) + Data(repeating: 1, count: 32),
            using: htKey
        )).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(leaf, fold)
    }

    /// **The bundle root, pinned to a VALUE** (review F-2).
    ///
    /// D-0031 ruling 1 pins one tree — leaves `HMAC(key, 0x00 ‖ chunk)`, fold
    /// `HMAC(key, 0x01 ‖ l ‖ r)` with last-node promotion — and the bundle root
    /// is that same fold applied to the eleven raw 32-byte section subroots in
    /// section order. BB-E used to join them as ASCII hex separated by U+001F
    /// and HMAC the result: an importer folding per ruling 1 got a different
    /// root, a different `content_digest` and a different bundle identity for
    /// the same bytes, and **nothing pinned it** — mutating the separator left
    /// the whole suite green.
    ///
    /// The inputs below are the ones REVIEW-BB-EXPORTER-3 recomputed
    /// independently, in Python, from the fixture bundle's own `.seg` files and
    /// bundle key (§1 F-2's table). The expected root is the value that
    /// reference produced. So this test pins the construction against a number
    /// computed outside this code base, not against itself: change the order,
    /// the domain byte, the promotion rule or the raw-vs-hex reading and it goes
    /// red.
    func test_theBundleRootIsTheD0031FoldOverTheRawSubroots() throws {
        let bundleKey = SymmetricKey(data: try XCTUnwrap(
            MemoryExportBase64URL.decode("AkjLhaevat16vaJtPq_HtjWNJq_rguGBB-j98aMsZio")
        ))
        let subroots = [
            "96813e36f8bf3b73edfb143bfc839bc462902ea369bdb6a114a32422f5548e84", // 00-tombstones
            "169c18299c5bb6b07abd3097da9f8c7576b171285f6f83eb986d824f45ad94f9", // 01-tombstone_receipts
            "233209ea857e188b9b82a83f1061ca9ffe8b00fcb8bb4e254788ef0e49742876", // 02-review_events
            "169c18299c5bb6b07abd3097da9f8c7576b171285f6f83eb986d824f45ad94f9", // 03-supersessions
            "68351a04b23eea5102c8408b04e189ef5f02cb72373060db5e2a1ef5d4256e8b", // 04-projects
            "538d9703e7632882330bd472c1e1370ac771ccf584e328adfc43e5ef0c654562", // 05-memories
            "419a1a984224a0bd6a28c91d837cf209ed79af4ec1fad7429ce1de59665ecb16", // 06-bodies
            "d17e5e7d72f55ba72025c8c8e367687cdd303e7e6901f509757592947a3663ca", // 07-provenance
            "169c18299c5bb6b07abd3097da9f8c7576b171285f6f83eb986d824f45ad94f9", // 08-embeddings
            "2a0ae9ab788e38b363a7821d309291492a37d27a2edb8ff5ee1a231ebbd05a8e", // 09-audit_evidence
            "306227b25aa4ab9462d333e2802732bd48de98403c31e0c210e6e05db1e36c65"  // 10-findings
        ]
        XCTAssertEqual(subroots.count, MIFSection.allCases.count, "one subroot per section, in section order")
        XCTAssertEqual(
            MemoryExportCrypto.combineSubroots(bundleKey: bundleKey, subroots: subroots),
            "a3d921051628f1000c197c95684542e80f313b0614b50fe0c9126f6b23136964"
        )
        // The value the pre-F-2 join produced for the same inputs, kept so the
        // regression is a comparison rather than a memory.
        XCTAssertNotEqual(
            MemoryExportCrypto.combineSubroots(bundleKey: bundleKey, subroots: subroots),
            "e9bdcabd192d93607f8bdcd91d27e1f61e6881f7db33905898d22d2d7585f697"
        )

        // Eleven is odd at three of the four levels, so the odd-tail rule is
        // exercised by the vector above; here it is stated as a property. A
        // node that rises unchanged is not re-HMAC'd, and order is part of the
        // construction.
        let swapped = Array(subroots.reversed())
        XCTAssertNotEqual(
            MemoryExportCrypto.combineSubroots(bundleKey: bundleKey, subroots: swapped),
            MemoryExportCrypto.combineSubroots(bundleKey: bundleKey, subroots: subroots),
            "section order is part of the root"
        )
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: bundleKey,
            salt: Data("imaginethat.memory.hkdf.v1".utf8),
            info: Data("mif1/hashtree/v1".utf8),
            outputByteCount: 32
        )
        let single = Data(repeating: 7, count: 32)
        XCTAssertEqual(
            MemoryExportCrypto.fold([single], key: key),
            single,
            "one node folds to itself — last-node promotion, not a self-pair"
        )
        let pair = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]) + single + single, using: key))
        XCTAssertEqual(MemoryExportCrypto.fold([single, single], key: key), pair)
        XCTAssertEqual(
            MemoryExportCrypto.fold([single, single, single], key: key),
            Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]) + pair + single, using: key)),
            "an odd tail is carried up unchanged and folded at the next level"
        )
    }

    /// `manifest.sig` is Ed25519 over the 32 RAW bytes of `content_digest`,
    /// rendered b64url unpadded — not over the 64 ASCII hex characters and not
    /// over the manifest file. Signing the hex instead would sign 64 different
    /// bytes; this test proves which one verifies.
    func test_theManifestSignatureIsOverTheRawDigestBytes() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let digest = String(repeating: "ab", count: 32)
        let sigText = try MemoryExportCrypto.sign(contentDigest: digest, signingKey: signingKey)
        XCTAssertTrue(
            MemoryExportCrypto.verifySignature(
                sigText: sigText,
                contentDigest: digest,
                publicKey: signingKey.publicKey
            )
        )
        // The ASCII hex does NOT verify as the preimage.
        let hexAsBytes = Data(digest.utf8)
        let rawSig = try XCTUnwrap(MemoryExportBase64URL.decode(sigText))
        XCTAssertFalse(signingKey.publicKey.isValidSignature(rawSig, for: hexAsBytes))
        // Neither does a neighbouring digest, nor garbage.
        XCTAssertFalse(MemoryExportCrypto.verifySignature(
            sigText: sigText,
            contentDigest: "cb" + digest.dropFirst(2),
            publicKey: signingKey.publicKey
        ))
        XCTAssertThrowsError(try MemoryExportCrypto.sign(contentDigest: "not-hex", signingKey: signingKey)) {
            XCTAssertEqual($0 as? MemoryExportCryptoError, .malformedContentDigest)
        }
    }

    // MARK: - The recipient descriptor

    /// The interop fixture's missing half (D-0021 ruling 6). `--rehearsal` mints
    /// a recipient and **discards the private half by design**, so a rehearsal
    /// bundle is sealed to a key nobody holds — correct for a rehearsal, useless
    /// as a courier fixture, and refused by an importer as a rehearsal bundle
    /// besides. `recipient-keypair` writes both halves: the descriptor an
    /// ordinary `--recipient` export takes, and the private key the importer
    /// opens the wrap with.
    func test_aGeneratedRecipientKeypairWritesADescriptorItsPrivateHalfCanOpen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let keypair = MemoryExportRecipient.generateKeypair(storeID: "importer-store-fixture")
        let written = try MemoryExportRecipient.writeKeypair(keypair, to: directory)

        // The descriptor is the D-0025 three-field file, and it parses through
        // the same reader `--recipient` uses — id recomputed from the key.
        let parsed = try MemoryExportRecipient.parse(descriptor: try Data(contentsOf: written.descriptor))
        XCTAssertEqual(parsed.keyID, keypair.recipient.keyID)
        XCTAssertEqual(parsed.keyID, MemoryExportRecipient.keyID(for: keypair.privateKey.publicKey))
        XCTAssertEqual(parsed.storeID, "importer-store-fixture")
        XCTAssertFalse(parsed.isRehearsalThrowaway, "a fixture recipient is not a rehearsal throwaway")

        // The private half is beside it, at 0600, and it is the half that opens
        // a bundle sealed to the descriptor — which is the whole point.
        let attributes = try FileManager.default.attributesOfItem(atPath: written.secret.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let secret = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: written.secret)) as? [String: Any]
        )
        let rawPrivate = try XCTUnwrap(
            MemoryExportBase64URL.decode(try XCTUnwrap(secret["recipient_private_key_b64url"] as? String))
        )
        let recovered = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivate)

        let bundleKey = MemoryExportCrypto.randomBundleKey()
        let wrapped = try MemoryExportCrypto.wrap(bundleKey: bundleKey, recipient: parsed)
        var receiver = try HPKE.Recipient(
            privateKey: recovered,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: MemoryExportCrypto.keywrapInfo,
            encapsulatedKey: wrapped.encapsulatedKey
        )
        XCTAssertEqual(
            try receiver.open(wrapped.ciphertext, authenticating: Data(parsed.keyID.utf8)),
            bundleKey.withUnsafeBytes { Data($0) },
            "the fixture's private half opens a bundle sealed to its own descriptor"
        )

        // And the descriptor carries nothing else: it is the three fields
        // D-0025 names, so it is byte-comparable with what an importer prints.
        let descriptor = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: written.descriptor)) as? [String: Any]
        )
        XCTAssertEqual(Set(descriptor.keys), ["recipient_key_id", "public_key", "store_id"])
    }

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
