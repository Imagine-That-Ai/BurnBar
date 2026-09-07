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

    /// D-0039 ruling 10's fourth value, **V4**, over the minimal manifest
    /// `MEMORY_MIGRATION_SPEC.md` §2 publishes member for member.
    ///
    /// The manifest below is that block copied verbatim and parsed, rather than
    /// rebuilt from Swift literals: a vector whose input is retyped is a vector
    /// that drifts from the document it is supposed to agree with. It is a
    /// VECTOR, not a bundle — one section header instead of eleven, a crypto
    /// profile this build does not seal with — and it carries V3 as its
    /// `hashtree.root`, so an implementation that folds the subroots
    /// differently fails V4 too. The two numbers chain deliberately.
    ///
    /// The preimage is 1,763 bytes and `sha256` of it ALONE is
    /// `048e80ad…` — the document calls that a bisection point rather than a
    /// contract value, and it is what this exporter used to publish before
    /// D-0039 ruling 1 appended the tree root's 32 raw bytes.
    func test_vectorTheContentDigestOfTheSpecsMinimalManifest() throws {
        let manifest = try XCTUnwrap(MIFCanonicalJSON.parse(Data(Self.vectorManifestJSON.utf8)))

        let preimage = MIFCanonicalJSON.data(MemoryExportManifestDigest.preimage(manifest))
        XCTAssertEqual(preimage.count, 1_763)
        XCTAssertEqual(
            MemoryExportDigest.sha256Hex(preimage),
            "048e80ad60cbe665719037942fe3029c3425f9afb29d1022c0988ba6ecb1440f",
            "the JCS alone, before the root is appended"
        )

        let v4 = MemoryExportManifestDigest.digest(of: manifest)
        XCTAssertEqual(v4, "cc7c8866b05adf30d64bc74b85700dbef667c377880ba9f914b0db74d01a8cd6")
        XCTAssertEqual(MemoryExportIdentity.bundleID(contentDigest: v4), "bnd_cc7c8866b05adf30d64bc74b85700dbe")

        // The document is self-consistent, and this reads its own declarations
        // back rather than trusting the two constants above.
        guard case .object(let fields) = manifest else { return XCTFail("not an object") }
        XCTAssertEqual(fields["content_digest"], .string(v4))
        XCTAssertEqual(fields["bundle_id"], .string("bnd_" + v4.prefix(32)))
        XCTAssertEqual(
            fields["hashtree"].flatMap { tree -> MIFJSON? in
                guard case .object(let members) = tree else { return nil }
                return members["root"]
            },
            .string("5446dab5850a3e16851fc9d13baff4856a93b1a40e230f65e51ff6a83ddcfbef"),
            "V4's manifest carries V3, which is what chains the two"
        )

        // The suffix is the ROOT's 32 RAW bytes and not its 64 characters,
        // which is the one way a second implementation could read the ruling
        // and land on a different number.
        let root = try XCTUnwrap(MemoryExportManifestDigest.hashtreeRoot(of: manifest))
        XCTAssertNotEqual(MemoryExportDigest.sha256Hex(preimage + Data(root.utf8)), v4)

        // And the exclusion is a property of the preimage: moving either
        // excluded member leaves V4 where it is, moving a covered one does not.
        var moved = manifest
        if case .object(var members) = moved {
            members["created_at_ms"] = .int(1_780_000_000_000)
            members["recipient_key_id"] = .string("rcp_" + String(repeating: "f", count: 32))
            moved = .object(members)
        }
        XCTAssertEqual(MemoryExportManifestDigest.digest(of: moved), v4)

        var edited = manifest
        if case .object(var members) = edited {
            members["user_id"] = .string("usr_00000000000000000000000000000000")
            edited = .object(members)
        }
        XCTAssertNotEqual(MemoryExportManifestDigest.digest(of: edited), v4)
    }

    /// `MEMORY_MIGRATION_SPEC.md` §2's minimal manifest, verbatim.
    private static let vectorManifestJSON = """
        {
          "mif_version": 1, "mif_minor": 2, "profile": "migration",
          "bundle_id": "bnd_cc7c8866b05adf30d64bc74b85700dbe",
          "producer_store_id": "sto_11111111111111111111111111111111",
          "producer_device_id": "dev_22222222222222222222222222222222",
          "user_id": "usr_33333333333333333333333333333333",
          "created_at_ms": 1788739200000,
          "window": { "from_lamport": 0, "to_lamport": 0 },
          "schema_version": 1,
          "sections": [ { "name": "05-memories", "rank": 5, "required": true, "mergeable": true,
                          "row_count": 1, "record_type": "#/$defs/record_memory",
                          "subroot": "cc511923ff13160176ec59580d1211f8ee8759d6442f33b43287d8ac1133b2e7",
                          "bytes": 1024, "segments": 1,
                          "rollup_digest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } ],
          "min_importer_mif_version": 1,
          "content_digest": "cc7c8866b05adf30d64bc74b85700dbef667c377880ba9f914b0db74d01a8cd6",
          "crypto": { "aead": "xchacha20poly1305", "compression": "zstd",
                      "wrap": "hpke-base-x25519-hkdf-sha256-chacha20poly1305",
                      "key_schedule": "mif1-hkdf-v1" },
          "hashtree": { "alg": "hmac-sha256", "over": "ciphertext", "chunk_bytes": 4194304,
                        "root": "5446dab5850a3e16851fc9d13baff4856a93b1a40e230f65e51ff6a83ddcfbef",
                        "key_derivation": "HKDF(bundle_key,'mif1/hashtree/v1')" },
          "determinism": { "canonicalization": "JCS", "sort_keys": {} },
          "rehearsal": false,
          "source": { "product": "OpenBurnBar", "version": "1.4.0", "build_kind": "rehearsal_fixture",
                      "store_kind": "authority",
                      "store_fingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                      "platform": "macos", "keyed": true },
          "source_integrity": "ok", "concurrent_writes": false, "partial_sources": [],
          "not_exported": {}, "export_mode": "full", "snapshot_mode": "sqlcipher_export",
          "recipient_key_id": "rcp_44444444444444444444444444444444",
          "recipient_store_id": "sto_55555555555555555555555555555555",
          "exporter_device_key_id": "edk_66666666666666666666666666666666",
          "rollups": [ { "section": "05-memories",
                         "tuple": ["memory_id", "body_join_key", "body_norm_digest"],
                         "rollup_digest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                         "row_count": 1 } ],
          "findings_summary": {}
        }
        """
}
