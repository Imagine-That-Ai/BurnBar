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
//   * `body_join_key`     = HMAC(K_join, canonical body bytes)
//   * `body_norm_digest`  = HMAC(K_join, UTF-8(normalize(body)))
//
// with `K_join = HKDF-SHA256(salt = HKDF_SALT, ikm = bundle_key,
// info = "mif1/join/v1", L = 32)` — D-0038 as amended, and D-0039 ruling 3.
// The two values differ BY CONSTRUCTION: one is keyed over the exact stored
// bytes (so a body record reproduces its own join key), the other over the
// schema's `normalize`. They used to be equal on every row of every bundle,
// which made section 05's `(memory_id, body_join_key, body_norm_digest)`
// roll-up two members wide instead of three (M-7).
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

/// Errors from the exporter's own crypto preconditions.
public enum MemoryExportCryptoError: Error, Equatable {
    /// `manifest.content_digest` is not 64 hex characters, so there are no 32
    /// raw bytes to sign. A corrupt manifest must refuse, never sign garbage.
    case malformedContentDigest
}

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

    /// `HKDF-SHA256(salt = HKDF_SALT, ikm, info, L)` — the `mif1-hkdf-v1` key
    /// schedule, exactly as §2.1 writes it. Every derivation in MIF goes
    /// through it, the join key included: an unsalted HKDF for one value was
    /// M-5 of interop run 1, and a workspace with one salt constant cannot
    /// spell it two ways.
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

    /// `K_join = HKDF-SHA256(salt = HKDF_SALT, ikm = bundle_key,
    /// info = "mif1/join/v1", L = 32)` [D-0038 as amended, D-0039 ruling 3].
    /// One key for both body digests, and the same salt as every other
    /// derivation in the schedule.
    static func joinKey(bundleKey: SymmetricKey) -> SymmetricKey {
        derive(salted: bundleKey, info: "mif1/join/v1", bytes: 32)
    }

    /// The **canonical body bytes**: the body exactly as the bundle carries it,
    /// UTF-8, with no normalisation of any kind.
    ///
    /// D-0038's amendment is explicit about why — "the join must reproduce the
    /// body". `record_body.body` is the base64url of these bytes, so a reader
    /// that decodes the record and re-HMACs it gets `body_join_key` back; a
    /// normalised preimage would make the join key uncheckable from the record
    /// that carries it.
    public static func canonicalBodyBytes(_ body: String) -> Data { Data(body.utf8) }

    /// `body_join_key = HMAC-SHA256(K_join, canonical body bytes)` — links
    /// 05 <-> 06 and binds a verdict to a body. Content-keyed and carrying no
    /// `memory_id`, so two memories with identical bodies share one body
    /// record, which is the join's purpose.
    public static func bodyJoinKey(bundleKey: SymmetricKey, body: String) -> String {
        hmacHex(key: joinKey(bundleKey: bundleKey), data: canonicalBodyBytes(body))
    }

    /// `body_norm_digest = HMAC-SHA256(K_join, UTF-8(normalize(body)))` — the
    /// mis-attachment check and the third member of section 05's roll-up tuple.
    public static func bodyNormDigest(bundleKey: SymmetricKey, body: String) -> String {
        hmacHex(key: joinKey(bundleKey: bundleKey), data: Data(normalize(body).utf8))
    }

    /// `normalize`, and there is exactly one: `MEMORY_SCHEMA.md` §0.1's, the
    /// same function `content_key` is taken over —
    ///
    ///     NFKC -> casefold -> collapse runs of whitespace to one U+0020
    ///          -> strip trailing `.,;:!?`
    ///
    /// D-0038's first ruling minted a second, gentler one (CRLF folding and a
    /// trim) and its amendment withdrew it minutes later: "the schema already
    /// defines `normalize`". This is that definition and nothing else.
    ///
    /// Two readings the wording leaves open are settled here by the D-0038
    /// vector `"Hello\r\n  world  \r\n"` -> `"hello world"`: collapsing a run
    /// of whitespace also removes a LEADING or TRAILING run (otherwise the
    /// vector would end in a space), and the trailing-punctuation strip takes
    /// the whole run rather than one character. Both are pinned by tests
    /// against values computed outside this code.
    ///
    /// `folding(options: .caseInsensitive)` is genuine Unicode case folding,
    /// not `lowercased()`: it agrees with Python's `str.casefold()` byte for
    /// byte on the cases where the two differ (`"Straße"` and `"STRASSE"` both
    /// fold to `"strasse"`), which is what makes a Swift exporter and a Rust
    /// importer able to agree on a digest.
    public static func normalize(_ body: String) -> String {
        let folded = body
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: nil)
        var collapsed = Substring(folded.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        while let last = collapsed.last, trailingPunctuation.contains(last) {
            collapsed = collapsed.dropLast()
        }
        return String(collapsed)
    }

    /// §0.1's five characters, in one place so the set cannot drift.
    static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    // MARK: - Segment sealing

    /// The AEAD this build seals with, and the nonce length that follows from
    /// it. Declared in `manifest.crypto.aead`, never inferred by a reader.
    public static let aead = "chacha20poly1305"
    public static let nonceBytes = 12
    /// Poly1305's tag, the only thing appended to a segment's ciphertext.
    public static let tagBytes = 16
    /// What one sealed segment adds to its plaintext: the 16-byte Poly1305 tag,
    /// and nothing else.
    ///
    /// The nonce is DERIVED (`segmentNonce` below, §2.1) and therefore never
    /// travels: a reader recomputes it from the segment key and the segment
    /// index, which are both things it already has. CryptoKit's
    /// `ChaChaPoly.SealedBox.combined` prefixes the 12 nonce bytes, and writing
    /// that was M-4 of interop run 1 — the importer derived the nonce per spec,
    /// found the ciphertext shifted by 12 bytes and could open nothing. A
    /// segment is `ciphertext ‖ tag`, so an empty section's segment is exactly
    /// 16 bytes.
    public static let sealOverheadBytes = tagBytes
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
        // `.combined` is deliberately NOT used: it prepends the nonce, and
        // §2.1 says the nonce is derived and says it twice. What travels is the
        // ciphertext and its tag, in that order — the concatenation every AEAD
        // implementation can rebuild a sealed box from without a convention.
        let box = try ChaChaPoly.seal(
            chunk,
            using: segmentKey,
            nonce: try segmentNonce(segmentKey: segmentKey, index: index),
            authenticating: segmentAAD(section: section, index: index)
        )
        return box.ciphertext + box.tag
    }

    /// The inverse, for the tests that must read a sealed segment back to prove
    /// what did (and did not) reach it.
    static func open(
        sealedChunk: Data,
        section: MIFSection,
        segmentKey: SymmetricKey,
        index: Int
    ) throws -> Data {
        // The nonce is not in the file; it is re-derived from the same two
        // inputs the sealer used. A reader that looked for it in the first 12
        // bytes would be reading ciphertext.
        let tagStart = sealedChunk.index(sealedChunk.endIndex, offsetBy: -tagBytes)
        let box = try ChaChaPoly.SealedBox(
            nonce: try segmentNonce(segmentKey: segmentKey, index: index),
            ciphertext: sealedChunk[sealedChunk.startIndex..<tagStart],
            tag: sealedChunk[tagStart...]
        )
        return try ChaChaPoly.open(
            box,
            using: segmentKey,
            authenticating: segmentAAD(section: section, index: index)
        )
    }

    // MARK: - Hash tree

    /// D-0031 ruling 1, byte-pinned: one key, one salt, two domain-separated
    /// messages, in both profiles:
    ///
    /// ```
    /// ht_key = HKDF-SHA256(salt = HKDF_SALT, ikm = bundle_key, info = "mif1/hashtree/v1", L = 32)
    /// leaf   = HMAC-SHA256(ht_key, 0x00 ‖ chunk)          chunk = 4 MiB of the CIPHERTEXT segment
    /// fold   = HMAC-SHA256(ht_key, 0x01 ‖ left ‖ right)   with last-node promotion
    /// ```
    ///
    /// `HKDF_SALT` is §2.1's `"imaginethat.memory.hkdf.v1"` — the SAME salt as
    /// `seg_key` and the nonce, so this implementation carries one salt
    /// constant and not two. The two prefix bytes are the point: without them a
    /// 64-byte leaf and a two-leaf fold are the same message under the same
    /// key. Keyed AND over ciphertext: the manifest is not a confirmation
    /// oracle over user text, and a section is verified BEFORE it is decrypted.
    public static let hashTreeChunkBytes = 4 * 1024 * 1024

    /// The leaf domain byte: `HMAC(ht_key, 0x00 ‖ chunk)`.
    static let hashTreeLeafDomain = Data([0x00])
    /// The fold domain byte: `HMAC(ht_key, 0x01 ‖ left ‖ right)`.
    static let hashTreeFoldDomain = Data([0x01])

    public static func hashTreeRoot(bundleKey: SymmetricKey, ciphertext: Data) -> String {
        hashTreeRoot(bundleKey: bundleKey, segments: [ciphertext])
    }

    /// The same tree over a section's SEGMENTS, without concatenating them.
    ///
    /// A section is written as one file per sealed segment, and its 4 MiB
    /// leaves run across that sequence — so joining the segments into one
    /// `Data` just to chunk it again would hold a second full copy of the
    /// section's ciphertext at the one point in the export where memory is
    /// already the constraint (§2's ≤ 512 MiB, and F-14).
    public static func hashTreeRoot(bundleKey: SymmetricKey, segments: [Data]) -> String {
        let key = derive(salted: bundleKey, info: "mif1/hashtree/v1", bytes: 32)
        var level: [Data] = []
        var leaf = Data()
        leaf.reserveCapacity(hashTreeChunkBytes)
        for segment in segments {
            var offset = segment.startIndex
            while offset < segment.endIndex {
                let take = min(hashTreeChunkBytes - leaf.count, segment.distance(from: offset, to: segment.endIndex))
                let end = segment.index(offset, offsetBy: take)
                leaf.append(segment[offset..<end])
                offset = end
                if leaf.count == hashTreeChunkBytes {
                    level.append(Data(HMAC<SHA256>.authenticationCode(for: hashTreeLeafDomain + leaf, using: key)))
                    leaf.removeAll(keepingCapacity: true)
                }
            }
        }
        if leaf.isEmpty == false {
            level.append(Data(HMAC<SHA256>.authenticationCode(for: hashTreeLeafDomain + leaf, using: key)))
        }
        if level.isEmpty {
            level = [Data(HMAC<SHA256>.authenticationCode(for: hashTreeLeafDomain + Data(), using: key))]
        }
        return fold(level, key: key).map { String(format: "%02x", $0) }.joined()
    }

    /// §2's `fold = HMAC-SHA256(ht_key, 0x01 ‖ left ‖ right)   with last-node
    /// promotion`, over raw 32-byte nodes. One implementation, used for the
    /// leaves of a section and for the section subroots alike, because two
    /// spellings of one fold is how Wave 13 produced bundles that verified
    /// against neither side.
    static func fold(_ nodes: [Data], key: SymmetricKey) -> Data {
        var level = nodes
        while level.count > 1 {
            var next: [Data] = []
            var index = 0
            while index < level.count {
                if index + 1 < level.count {
                    next.append(Data(HMAC<SHA256>.authenticationCode(
                        for: hashTreeFoldDomain + level[index] + level[index + 1],
                        using: key
                    )))
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
        return level.first ?? Data(repeating: 0, count: 32)
    }

    /// Combine per-section subroots into the bundle root, in section order.
    /// D-0031 computes the root once and carries it once: this is that one
    /// computation, over the same salted key as the tree itself.
    ///
    /// It is **the same fold as the tree below it** — §2's `fold =
    /// HMAC-SHA256(ht_key, 0x01 ‖ left ‖ right)   with last-node promotion` —
    /// applied pairwise to the RAW 32-byte subroots in section order, with an
    /// odd tail carried up unchanged. Until F-2 this joined the subroots as
    /// ASCII hex separated by U+001F and HMAC'd the result: a construction
    /// D-0031 does not describe, which an importer folding per ruling 1 could
    /// only disagree with — a different root, a different `content_digest` and a
    /// different bundle identity for the same bytes. Nothing pinned it, either:
    /// mutating the separator left 113 tests green. The vector in
    /// `MemoryExportCryptoTests` pins it to a VALUE now, computed outside this
    /// code path.
    public static func combineSubroots(bundleKey: SymmetricKey, subroots: [String]) -> String {
        let key = derive(salted: bundleKey, info: "mif1/hashtree/v1", bytes: 32)
        // A subroot the writer could not supply is 32 zero bytes — the same
        // placeholder the section header carries — and never a node dropped from
        // the tree, which would change the fold's SHAPE and not just a value.
        let nodes = subroots.map { MemoryExportCrypto.hexToData($0) ?? Data(repeating: 0, count: 32) }
        return fold(nodes, key: key).map { String(format: "%02x", $0) }.joined()
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
            throw MIFExportError.hpkeUnavailable
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

    /// D-0031 ruling 1: Ed25519 over the 32 RAW bytes of
    /// `manifest.content_digest` — the digest hex-decoded, not its 64 ASCII
    /// characters and not `sha256(manifest.json)` — rendered base64url
    /// unpadded like every other binary in the format. `content_digest`
    /// already binds the manifest minus the excluded members, so signing it
    /// signs the manifest at a fixed 32-byte length no canonicaliser can move.
    public static func sign(contentDigest: String, signingKey: Curve25519.Signing.PrivateKey) throws -> String {
        guard contentDigest.count == 64,
              let raw = hexToData(contentDigest) else {
            throw MemoryExportCryptoError.malformedContentDigest
        }
        return MemoryExportBase64URL.encode(try signingKey.signature(for: raw))
    }

    /// Hex-decode a digest into its raw bytes. Internal so the verifier shares
    /// the exact preimage the signer signed — two spellings of "the 32 raw
    /// bytes" is how interop breaks.
    static func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Verify a `manifest.sig` rendering against the manifest's
    /// `content_digest`: the exact inverse of `sign`, so a test that signs and
    /// verifies through these two functions proves the file's preimage.
    public static func verifySignature(sigText: String, contentDigest: String, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard let raw = hexToData(contentDigest),
              let signature = MemoryExportBase64URL.decode(sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: raw)
    }

    /// The exporter device key id shown in the importer's TOFU confirmation.
    public static func deviceKeyID(_ publicKey: Curve25519.Signing.PublicKey) -> String {
        MemoryExportDigest.sha256Hex(publicKey.rawRepresentation)
    }
}
