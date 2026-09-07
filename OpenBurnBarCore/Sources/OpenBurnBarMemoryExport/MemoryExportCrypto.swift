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
// Deviations from §2's prose, each recorded in `docs/MEMORY_EXPORT_MIF.md`:
// segments are sealed with ChaCha20-Poly1305 (CryptoKit ships no XChaCha20) and
// the recipient wrap is a hand-rolled DHKEM(X25519, HKDF-SHA256) + AEAD rather
// than an HPKE library call.

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

    public static func derive(from bundleKey: SymmetricKey, info: String, bytes: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: bundleKey,
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

    /// Per-section key: `HKDF(bundle_key, "mif1/segment/" + name)`.
    public static func segmentKey(bundleKey: SymmetricKey, section: MIFSection) -> SymmetricKey {
        derive(from: bundleKey, info: "mif1/segment/\(section.rawValue)")
    }

    /// Seal one chunk. The nonce is DERIVED from the segment key and the chunk
    /// index rather than drawn at random: the bundle key is fresh per export and
    /// each (segment, chunk) is sealed exactly once, so derivation gives the
    /// same uniqueness guarantee without a random source, and it is what makes
    /// `--deterministic-nonces` a seed change rather than a code path.
    public static func seal(chunk: Data, segmentKey: SymmetricKey, index: Int) throws -> Data {
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: segmentKey,
            info: Data("mif1/nonce/v1\u{1F}\(index)".utf8),
            outputByteCount: 12
        )
        let nonce = try nonceKey.withUnsafeBytes { try ChaChaPoly.Nonce(data: Data($0)) }
        return try ChaChaPoly.seal(chunk, using: segmentKey, nonce: nonce).combined
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

    public struct WrappedBundleKey: Sendable, Equatable {
        /// The ephemeral X25519 public key ("enc" in HPKE terms).
        public var ephemeralPublicKey: Data
        public var ciphertext: Data
        /// `sha256(recipient pubkey)`.
        public var recipientKeyID: String
    }

    /// Wrap the bundle key to the importer's static X25519 recipient key.
    ///
    /// This is DHKEM(X25519, HKDF-SHA256) + ChaCha20-Poly1305 written out by
    /// hand rather than an `HPKE` call, because `HPKE` carries availability
    /// annotations this target does not want to inherit. It is the same shape:
    /// ephemeral key, DH, HKDF over the shared secret bound to both public keys,
    /// AEAD over the payload.
    public static func wrap(
        bundleKey: SymmetricKey,
        recipientPublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> WrappedBundleKey {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let encapsulated = ephemeral.publicKey.rawRepresentation
        let wrapKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: encapsulated + recipientPublicKey.rawRepresentation,
            sharedInfo: Data("mif1/wrap/v1".utf8),
            outputByteCount: 32
        )
        let payload = bundleKey.withUnsafeBytes { Data($0) }
        let sealed = try ChaChaPoly.seal(payload, using: wrapKey)
        return WrappedBundleKey(
            ephemeralPublicKey: encapsulated,
            ciphertext: sealed.combined,
            recipientKeyID: MemoryExportDigest.sha256Hex(recipientPublicKey.rawRepresentation)
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
