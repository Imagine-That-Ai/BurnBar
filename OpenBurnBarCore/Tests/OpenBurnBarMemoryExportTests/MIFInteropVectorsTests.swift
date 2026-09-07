// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFInteropVectorsTests — D-0039 ruling 10, the interop contract as numbers.
//
// "for a fixed bundle key `0x01…01`, fixed eleven subroots (`sha256("sec-NN")`),
// and the D-0038 body — the join key, the norm digest, the bundle root, and the
// `content_digest` of a minimal manifest; three implementations agree on
// numbers."
//
// Every hex value below was computed OUTSIDE this code, by a Python script
// standing in for a second implementation (`hmac`, `hashlib`, `unicodedata`,
// `base64`; RFC 5869 HKDF written out, JCS written out). Nothing here is a
// value this exporter printed and was then asked to reproduce — that is the one
// thing a test vector must not be, and it is why interop run 1 found four
// constructions that each side computed differently while both were "verified"
// against themselves.
//
// The same numbers are pinned in `docs/MEMORY_EXPORT_MIF.md` §12 and belong in
// the migration spec's §2 for the importer and the generator to pin as well.

import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import OpenBurnBarMemoryExport

final class MIFInteropVectorsTests: XCTestCase {

    /// The fixed bundle key D-0039 ruling 10 names: 32 bytes of `0x01`.
    private let bundleKey = SymmetricKey(data: Data(repeating: 0x01, count: 32))

    /// D-0038's body, and the exact 18 bytes it is.
    ///
    /// (The decision's amendment calls them "those exact 17 bytes"; the string
    /// is 5 + 2 + 2 + 5 + 2 + 2 = 18 UTF-8 bytes, and the count is asserted here
    /// so the document pass pins the byte string rather than the arithmetic.)
    private let body = "Hello\r\n  world  \r\n"

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The body: K_join, the join key, the norm digest, the encoding

    func test_vectorTheBodyKeysUnderBundleKey0x01() {
        XCTAssertEqual(Array(body.utf8).count, 18, "the canonical bytes")
        XCTAssertEqual(
            hex(Data(body.utf8)),
            "48656c6c6f0d0a2020776f726c6420200d0a",
            "Hello CR LF SP SP world SP SP CR LF"
        )

        // K_join = HKDF-SHA256(salt = "imaginethat.memory.hkdf.v1",
        //                      ikm = bundle_key, info = "mif1/join/v1", L = 32)
        XCTAssertEqual(
            hex(MemoryExportCrypto.joinKey(bundleKey: bundleKey).withUnsafeBytes { Data($0) }),
            "132ca0a501d425ba4b6b32ce3cd27b2417c93a7edca4bc3d67d6fb529fce1a56"
        )

        // normalize(body) — MEMORY_SCHEMA.md §0.1, and D-0038's amendment pins
        // the result as a STRING as well as a digest.
        XCTAssertEqual(MemoryExportCrypto.normalize(body), "hello world")

        // body_join_key = HMAC-SHA256(K_join, canonical body bytes)
        XCTAssertEqual(
            MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: body),
            "d1b8f1b83089cc28ff2b5f3e4b390fb8b4756f2e4bbf355eba3e2f702cce4d04"
        )

        // body_norm_digest = HMAC-SHA256(K_join, UTF-8(normalize(body)))
        XCTAssertEqual(
            MemoryExportCrypto.bodyNormDigest(bundleKey: bundleKey, body: body),
            "11aad28d73db37d69b5894ee2c16b82d91244816e96fb006d61b47d09a760d1d"
        )

        // The two differ by construction (M-7), which is the property section
        // 05's roll-up tuple depends on.
        XCTAssertNotEqual(
            MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: body),
            MemoryExportCrypto.bodyNormDigest(bundleKey: bundleKey, body: body)
        )

        // record_body.body = base64url, unpadded, of the canonical bytes (M-6).
        XCTAssertEqual(
            MemoryExportBase64URL.encode(MemoryExportCrypto.canonicalBodyBytes(body)),
            "SGVsbG8NCiAgd29ybGQgIA0K"
        )
    }

    // MARK: - The tree: ht_key, the eleven subroots, the bundle root

    /// D-0039 ruling 2: the bundle root is D-0031 ruling 1's fold over the RAW
    /// 32-byte subroots in section order. The importer's hex re-leafing is
    /// withdrawn, and the difference is a different bundle identity for the same
    /// bytes — so it is pinned to a number rather than to a sentence (M-3).
    func test_vectorTheBundleRootOverElevenSubroots() {
        let subroots = (0..<11).map { index in
            MemoryExportDigest.sha256Hex(String(format: "sec-%02d", index))
        }
        XCTAssertEqual(subroots.count, MIFSection.allCases.count)
        XCTAssertEqual(subroots[0], "a69a0f3b6f4801b0e876b64217e3e88b02e940fa4284abbb15cfbf030eade1eb")
        XCTAssertEqual(subroots[5], "cc511923ff13160176ec59580d1211f8ee8759d6442f33b43287d8ac1133b2e7")
        XCTAssertEqual(subroots[10], "7b35ef65925c6a650fae4a9b0152173f30e5c0d8022a379270fe20ef9349d781")

        // ht_key = HKDF-SHA256(salt = HKDF_SALT, ikm = bundle_key,
        //                      info = "mif1/hashtree/v1", L = 32)
        let treeKey = MemoryExportCrypto.derive(salted: bundleKey, info: "mif1/hashtree/v1", bytes: 32)
        XCTAssertEqual(
            hex(treeKey.withUnsafeBytes { Data($0) }),
            "2cfb783a9d3dd7d703db9714ec529f6b93bd07c07e4e6d25271aa2007cd29d40"
        )

        XCTAssertEqual(
            MemoryExportCrypto.combineSubroots(bundleKey: bundleKey, subroots: subroots),
            "5446dab5850a3e16851fc9d13baff4856a93b1a40e230f65e51ff6a83ddcfbef"
        )
    }

    // MARK: - The manifest: content_digest and the bundle id

    /// D-0039 ruling 10's fourth value, over the minimal manifest defined in
    /// `docs/MEMORY_EXPORT_MIF.md` §12 — eight members, one of them the bundle
    /// root above, and the four the digest excludes present so that the
    /// exclusion is exercised rather than assumed.
    ///
    /// **A discrepancy this test records rather than resolves.** D-0039 ruling 1
    /// writes the preimage as `sha256(JCS(manifest minus the four) ‖
    /// hashtree_root_raw32)` and calls it "the exporter's form" — but the
    /// exporter has never appended the raw root, and it is the exporter's form
    /// that reproduced `95ee02b1…` for interop run 1's fixture. The root is
    /// already inside the JCS through `hashtree.root`, so the concatenation adds
    /// nothing but a second spelling. This pins the implemented form and states
    /// the other value, so the document pass can settle it against one number
    /// instead of a sentence:
    ///
    ///     sha256(JCS(preimage))            63a06c3d…   <- this build, and the
    ///                                                     value below
    ///     sha256(JCS(preimage) ‖ root32)   6d08ba85…   <- ruling 1 read literally
    func test_vectorTheContentDigestOfTheMinimalManifest() {
        let root = "5446dab5850a3e16851fc9d13baff4856a93b1a40e230f65e51ff6a83ddcfbef"
        let manifest = MIFJSON.object([
            "bundle_id": .string("bnd_" + String(repeating: "0", count: 32)),
            "content_digest": .string(String(repeating: "0", count: 64)),
            "created_at_ms": .int(1_770_000_000_000),
            "recipient_key_id": .string("rcp_a364a736169c5781e983f011125569db"),
            "mif_version": .int(MIFFormatVersion.major),
            "mif_minor": .int(MIFFormatVersion.minor),
            "profile": .string(MIFProfile.migration.rawValue),
            "producer_store_id": .string("burnbar-vector-store"),
            "user_id": .string("user-1"),
            "recipient_store_id": .string("sto_a3275b6eabd68d815d60a61e1eee24e2"),
            "hashtree": .object([
                "alg": .string("hmac-sha256"),
                "over": .string("ciphertext"),
                "chunk_bytes": .int(MemoryExportCrypto.hashTreeChunkBytes),
                "root": .string(root),
                "key_derivation": .string("HKDF(bundle_key,'mif1/hashtree/v1')")
            ])
        ])

        // The JCS preimage, byte for byte — sorted keys, no whitespace, and the
        // four excluded members gone.
        let preimage = MIFCanonicalJSON.serialize(MemoryExportManifestDigest.preimage(manifest))
        XCTAssertEqual(
            preimage,
            #"{"hashtree":{"alg":"hmac-sha256","chunk_bytes":4194304,"#
                + #""key_derivation":"HKDF(bundle_key,'mif1/hashtree/v1')","over":"ciphertext","#
                + #""root":"\#(root)"},"mif_minor":2,"mif_version":1,"#
                + #""producer_store_id":"burnbar-vector-store","profile":"migration","#
                + #""recipient_store_id":"sto_a3275b6eabd68d815d60a61e1eee24e2","user_id":"user-1"}"#
        )
        XCTAssertEqual(preimage.utf8.count, 379)

        let digest = MemoryExportManifestDigest.digest(of: manifest)
        XCTAssertEqual(digest, "63a06c3d060ae06a5580f92b2355e3dc9e159380e874b6dc30339dc5e195308e")
        XCTAssertEqual(
            MemoryExportIdentity.bundleID(contentDigest: digest),
            "bnd_63a06c3d060ae06a5580f92b2355e3dc"
        )

        // The exclusion is a property of the preimage, not of these values:
        // moving either excluded member leaves the digest where it is.
        var moved = manifest
        if case .object(var fields) = moved {
            fields["created_at_ms"] = .int(1_780_000_000_000)
            fields["recipient_key_id"] = .string("rcp_" + String(repeating: "f", count: 32))
            moved = .object(fields)
        }
        XCTAssertEqual(MemoryExportManifestDigest.digest(of: moved), digest)

        // …and a member that IS covered moves it.
        var edited = manifest
        if case .object(var fields) = edited {
            fields["user_id"] = .string("user-2")
            edited = .object(fields)
        }
        XCTAssertNotEqual(MemoryExportManifestDigest.digest(of: edited), digest)
    }
}
