// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportCrypto — the bundle key, the keyed join digests, the segment
// seal, the recipient wrap, the hash tree and the manifest signature.
//
// The one rule this file exists to enforce: **no keyed field travels** (M-05).
// `content_key`, `body_hmac`, `xdevice_hmac` and `subject_content_key` are
// HKDF'd from the memory core's `user_root_key`; BurnBar has no such key and
// must never be given one. What the exporter emits instead lives INSIDE the
// sealed segment and is meaningless outside one bundle:
//
//   * `body_join_key`     = HMAC(HKDF(bundle_key,"mif1/join/v1"), body)
//   * `body_norm_digest`  = the same HMAC over `normalize(body)`
//
// `body_join_key` is deliberately NOT `sha256(body)`: a raw body hash is a
// dictionary-invertible oracle, and the oracle's own 64-hex `body_ref` never
// enters MIF.
//
// The wrap and the key schedule are §2.1's, byte-precise and closed: "a
// construction not written here is not a MIF bundle". Nothing in this file is
// negotiable, and there is no fallback path below HPKE — D-0021 ruling 1 asks
// for a refusal instead, because two hand-rolled wraps can never be proven
// equal while one RFC with published vectors can.
//
// One profile value is a platform fact rather than a choice: CryptoKit ships no
// XChaCha20, so segments seal under ChaCha20-Poly1305 with a 12-byte nonce.
// §2.1 admits that explicitly — "an exporter emits xchacha20poly1305 + zstd when
// its platform has them and declares what it used otherwise" — and the manifest
// `crypto` object is where the declaration lands.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum MemoryExportCrypto {

    // MARK: - Bundle key

    /// A fresh random content key per export. Every derived value below is
    /// therefore meaningless outside one bundle, which is what lets the join
    /// keys be HMACs rather than hashes.
    public static func randomBundleKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// `--rehearsal --deterministic-nonces`. Compiled out of release builds
    /// rather than merely refused at runtime (review rec 11).
    #if DEBUG
    public static func deterministicBundleKey(seed: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("mif1/rehearsal-seed/v1\u{1F}\(seed)".utf8)))
    }
    #endif

    // MARK: - Derivations

    /// §2.1's constant salt, `mif1-hkdf-v1`'s only one. 26 ASCII bytes, shared
    /// by both derivations in every language.
    public static let hkdfSalt = Data("imaginethat.memory.hkdf.v1".utf8)

    /// The exporter's OWN derivations — the join key and the hash-tree key —
    /// which are BurnBar-internal and named in the manifest rather than in
    /// §2.1. They keep the unsalted shape they had; §2.1 governs `seg_key` and
    /// the nonce, and those go through `derive(salted:)` below.
    public static func derive(from bundleKey: SymmetricKey, info: String, bytes: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: bundleKey,
            info: Data(info.utf8),
            outputByteCount: bytes
        )
    }

    /// `HKDF-SHA256(salt = HKDF_SALT, ikm, info, L)` — the `mif1-hkdf-v1` key
    /// schedule, exactly as §2.1 writes it.
    static func derive(salted ikm: SymmetricKey, info: String, bytes: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: hkdfSalt,
            info: Data(info.utf8),
            outputByteCount: bytes
        )
    }

    static func hmacHex(key: SymmetricKey, data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `body_join_key` — links 05 <-> 06 and binds a verdict to a body.
    public static func bodyJoinKey(bundleKey: SymmetricKey, body: String) -> String {
        hmacHex(key: derive(from: bundleKey, info: "mif1/join/v1"), data: Data(body.utf8))
    }

    /// `body_norm_digest` — the mis-attachment check and the roll-up input.
    public static func bodyNormDigest(bundleKey: SymmetricKey, body: String) -> String {
        hmacHex(key: derive(from: bundleKey, info: "mif1/join/v1"), data: Data(normalize(body).utf8))
    }

    /// The normalisation `body_norm_digest` is taken over. Deliberately modest:
    /// two bodies that differ only in trailing whitespace or line endings are
    /// the same fact, and anything more aggressive would let a real edit hide.
    public static func normalize(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Segment sealing

    /// The AEAD this build seals with, and the nonce length that follows from
    /// it. Declared in `manifest.crypto.aead`, never inferred by a reader.
    public static let aead = "chacha20poly1305"
    public static let nonceBytes = 12
    /// No zstd is vendored here, and §2.1's rule is that silently ignoring a
    /// *declared* codec is what is illegal — declaring `none` is not.
    public static let compression = "none"

    /// `seg_key = HKDF-SHA256(salt = HKDF_SALT, ikm = bundle_key,
    /// info = "mif1/segment/" ‖ section_name, L = 32)`, `section_name` **bare**
    /// per D-0025 ruling 1.
    public static func segmentKey(bundleKey: SymmetricKey, section: MIFSection) -> SymmetricKey {
        derive(salted: bundleKey, info: "mif1/segment/\(section.bareName)", bytes: 32)
    }

    /// `nonce = HKDF-SHA256(salt = HKDF_SALT, ikm = seg_key,
    /// info = "mif1/nonce/" ‖ decimal(index), L = 32)[0 .. nonce_len]`.
    ///
    /// Written the spec's way — expand 32, truncate to `nonce_len` — even
    /// though RFC 5869's Expand is prefix-consistent and asking for 12 directly
    /// gives the same bytes. The test pins that equality, so the two readings a
    /// second implementer might take are known to agree rather than assumed to.
    ///
    /// A derived nonce is safe here and only here: the bundle key is fresh per
    /// bundle, so no `(key, nonce)` pair ever recurs, and it is what makes
    /// `--deterministic-nonces` a seed change rather than a second code path.
    static func segmentNonce(segmentKey: SymmetricKey, index: Int) throws -> ChaChaPoly.Nonce {
        let expanded = derive(salted: segmentKey, info: "mif1/nonce/\(index)", bytes: 32)
        return try expanded.withUnsafeBytes { try ChaChaPoly.Nonce(data: Data($0.prefix(nonceBytes))) }
    }

    /// `aad = UTF-8(section_name ‖ "/" ‖ decimal(segment_index))`, transcribed
    /// from the reference through §2.1. It binds a segment to its section AND
    /// to its position, so a segment cannot be moved between sections or
    /// reordered inside one: `memories/0` does not open as `bodies/0`, and does
    /// not open at index 1.
    static func segmentAAD(section: MIFSection, index: Int) -> Data {
        Data("\(section.bareName)/\(index)".utf8)
    }

    /// Seal one segment of a section.
    public static func seal(
        chunk: Data,
        section: MIFSection,
        segmentKey: SymmetricKey,
        index: Int
    ) throws -> Data {
        try ChaChaPoly.seal(
            chunk,
            using: segmentKey,
            nonce: try segmentNonce(segmentKey: segmentKey, index: index),
            authenticating: segmentAAD(section: section, index: index)
        ).combined
    }

    /// The inverse, for the tests that must read a sealed segment back to prove
    /// what did (and did not) reach it.
    static func open(
        sealedChunk: Data,
        section: MIFSection,
        segmentKey: SymmetricKey,
        index: Int
    ) throws -> Data {
        try ChaChaPoly.open(
            try ChaChaPoly.SealedBox(combined: sealedChunk),
            using: segmentKey,
            authenticating: segmentAAD(section: section, index: index)
        )
    }

    // MARK: - Hash tree

    /// Leaves are `HMAC(HKDF(bundle_key,"mif1/hashtree/v1"), 4 MiB chunk of the
    /// CIPHERTEXT)`, internal nodes `HMAC(left || right)` with last-node
    /// promotion. Keyed AND over ciphertext: the manifest is not a confirmation
    /// oracle over user text, and a section is verified BEFORE it is decrypted.
    public static let hashTreeChunkBytes = 4 * 1024 * 1024

    public static func hashTreeRoot(bundleKey: SymmetricKey, ciphertext: Data) -> String {
        let key = derive(from: bundleKey, info: "mif1/hashtree/v1")
        var level = chunks(of: ciphertext, size: hashTreeChunkBytes).map { chunk in
            Data(HMAC<SHA256>.authenticationCode(for: chunk, using: key))
        }
        if level.isEmpty {
            level = [Data(HMAC<SHA256>.authenticationCode(for: Data(), using: key))]
        }
        while level.count > 1 {
            var next: [Data] = []
            var index = 0
            while index < level.count {
                if index + 1 < level.count {
                    next.append(Data(HMAC<SHA256>.authenticationCode(for: level[index] + level[index + 1], using: key)))
                    index += 2
                } else {
                    // Last-node promotion: an odd node rises unchanged rather
                    // than being paired with itself, which would let a duplicated
                    // final chunk produce the same root.
                    next.append(level[index])
                    index += 1
                }
            }
            level = next
        }
        return level[0].map { String(format: "%02x", $0) }.joined()
    }

    /// Combine per-section subroots into the bundle root, in section order.
    public static func combineSubroots(bundleKey: SymmetricKey, subroots: [String]) -> String {
        let key = derive(from: bundleKey, info: "mif1/hashtree/v1")
        let joined = Data(subroots.joined(separator: "\u{1F}").utf8)
        return HMAC<SHA256>.authenticationCode(for: joined, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func chunks(of data: Data, size: Int) -> [Data] {
        guard data.isEmpty == false else { return [] }
        var result: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            result.append(data[start..<end])
            start = end
        }
        return result
    }

    // MARK: - Recipient wrap

    /// The HPKE `info`: the 15 ASCII bytes §2.1 names.
    public static let keywrapInfo = Data("mif1/keywrap/v1".utf8)
    /// `manifest.crypto.wrap`. `const` in the contract, so a hand-rolled wrap
    /// fails validation rather than being negotiated.
    public static let wrapName = "hpke-base-x25519-hkdf-sha256-chacha20poly1305"
    public static let keyScheduleName = "mif1-hkdf-v1"

    public struct WrappedBundleKey: Sendable, Equatable {
        /// HPKE's 32-byte encapsulated key.
        public var encapsulatedKey: Data
        public var ciphertext: Data
        /// D-0025's `rcp_` id, which is also the seal's AAD.
        public var recipientKeyID: String

        /// `keys/wrapped-bundle-key` — `b64url(enc) ‖ "." ‖ b64url(ct)`, both
        /// unpadded, which is the whole on-disk form.
        public var wireForm: String {
            MemoryExportBase64URL.encode(encapsulatedKey) + "." + MemoryExportBase64URL.encode(ciphertext)
        }
    }

    /// Wrap the bundle key to the importer's static X25519 recipient key.
    ///
    /// RFC 9180 HPKE, mode_base, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 /
    /// ChaCha20Poly1305 — `kem_id 0x0020`, `kdf_id 0x0001`, `aead_id 0x0003`.
    /// The plaintext is the 32-byte bundle key and nothing else; the `aad` is
    /// the UTF-8 `recipient_key_id`, which is what makes a substituted
    /// recipient a decryption failure rather than a silently honoured swap.
    ///
    /// `OpenBurnBarCore`'s deployment floor is macOS 14 / iOS 17, which is
    /// exactly CryptoKit HPKE's floor, so the `#available` D-0021 ruling 1 asks
    /// for is statically satisfied on every platform this package builds for
    /// and writing it would raise an always-true warning. The refusal it guards
    /// is still reachable and still the only alternative: `EXPORT_HPKE_UNAVAILABLE`
    /// below, never a construction of our own.
    public static func wrap(
        bundleKey: SymmetricKey,
        recipient: MemoryExportRecipient
    ) throws -> WrappedBundleKey {
        var sender: HPKE.Sender
        do {
            sender = try HPKE.Sender(
                recipientKey: recipient.publicKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: keywrapInfo
            )
        } catch {
            // The suite is fixed and the key was validated when the descriptor
            // was read, so the only way this fails is a platform that cannot
            // offer the construction. That is a refusal, not a fallback.
            throw MIFExportRefusal.hpkeUnavailable
        }
        let ciphertext = try sender.seal(
            bundleKey.withUnsafeBytes { Data($0) },
            authenticating: Data(recipient.keyID.utf8)
        )
        return WrappedBundleKey(
            encapsulatedKey: sender.encapsulatedKey,
            ciphertext: ciphertext,
            recipientKeyID: recipient.keyID
        )
    }

    // MARK: - Signature

    /// Ed25519 (deterministic, RFC 8032) over `sha256(manifest.json)`.
    public static func sign(manifestBytes: Data, signingKey: Curve25519.Signing.PrivateKey) throws -> Data {
        let digest = Data(SHA256.hash(data: manifestBytes))
        return try signingKey.signature(for: digest)
    }

    /// The exporter device key id shown in the importer's TOFU confirmation.
    public static func deviceKeyID(_ publicKey: Curve25519.Signing.PublicKey) -> String {
        MemoryExportDigest.sha256Hex(publicKey.rawRepresentation)
    }
}
