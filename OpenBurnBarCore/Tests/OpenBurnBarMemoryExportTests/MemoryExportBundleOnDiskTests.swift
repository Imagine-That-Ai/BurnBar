// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportBundleOnDiskTests — the artefact, as an artefact: how many files
// a section is written as, and what `verify` can prove about them without a key.

import Foundation
import GRDB
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import OpenBurnBarMemoryExport

final class MemoryExportBundleOnDiskTests: XCTestCase {

    private let storeID = "store-fixture-disk"
    private static let recipientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    private static let signingKey = Curve25519.Signing.PrivateKey()

    private var recipient: MemoryExportRecipient {
        MemoryExportRecipient(
            keyID: MemoryExportRecipient.keyID(for: Self.recipientPrivateKey.publicKey),
            publicKey: Self.recipientPrivateKey.publicKey,
            storeID: "target-store-fixture"
        )
    }

    private func makeStore() throws -> DatabaseQueue {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            for index in 0..<12 {
                try MemoryExportFixtureStore.insertAppMemory(
                    db,
                    id: String(format: "row-%02d", index),
                    body: "Body number \(index), long enough to make the section worth rotating."
                )
            }
        }
        return queue
    }

    private func export(
        maxSectionBytes: Int,
        to directory: URL,
        seed: String
    ) throws -> MemoryExportBundleResult {
        let exporter = MemoryExporter(
            storeID: storeID,
            storeFingerprint: String(repeating: "2", count: 64),
            sourceVersion: "1.0.41",
            userID: "user-1",
            recipient: recipient,
            signingKey: Self.signingKey,
            options: MemoryExportOptions(
                enabled: true,
                maxSectionBytes: maxSectionBytes,
                gate: .alwaysAllow,
                now: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        return try exporter.export(
            try MemoryExportFixtureStore.snapshot(try makeStore()),
            mode: .full,
            to: directory,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: seed)
        )
    }

    // MARK: - Rotation (F-14)

    /// `--max-section-bytes` was the chunk size and nothing else: every sealed
    /// chunk was appended into one `Data` and written as a single
    /// `00000.seg`, so there was never a second segment file however large
    /// a section grew. `segments` then reported the CIPHERTEXT re-chunked at the
    /// same number, a boundary that corresponded to nothing on disk.
    func test_aSectionRotatesIntoOneFilePerSealedSegment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try export(maxSectionBytes: 512, to: directory, seed: "rotate")

        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        let headers = try XCTUnwrap(manifest["sections"] as? [[String: Any]])
        let bodies = try XCTUnwrap(headers.first { $0["name"] as? String == MIFSection.bodies.rawValue })
        let declared = try XCTUnwrap(bodies["segments"] as? Int)
        XCTAssertGreaterThan(declared, 1, "a 512-byte rotation must split twelve bodies")

        // The declared count is a count of FILES, and their sizes sum to the
        // declared `bytes`.
        let sectionDirectory = directory
            .appendingPathComponent("sections")
            .appendingPathComponent(MIFSection.bodies.rawValue)
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: sectionDirectory.path).sorted()
        XCTAssertEqual(onDisk.count, declared)
        XCTAssertEqual(onDisk.first, "00000.seg")
        var total = 0
        for (index, name) in onDisk.enumerated() {
            XCTAssertEqual(name, String(format: "%05d.seg", index))
            let data = try Data(contentsOf: sectionDirectory.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(data.count, 512, "a segment must not exceed the rotation size")
            total += data.count
        }
        XCTAssertEqual(total, bodies["bytes"] as? Int)

        // Each file is a sealed segment in its own right, opening only at its
        // own index — the filename and the cryptographic position are the same
        // number by construction.
        let key = MemoryExportCrypto.segmentKey(
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "rotate"),
            section: .bodies
        )
        var rejoined = ""
        for index in 0..<declared {
            let data = try Data(
                contentsOf: sectionDirectory.appendingPathComponent(String(format: "%05d.seg", index))
            )
            let opened = try MemoryExportCrypto.open(
                sealedChunk: data,
                section: .bodies,
                segmentKey: key,
                index: index
            )
            rejoined += String(decoding: opened, as: UTF8.self)
            if index > 0 {
                XCTAssertThrowsError(
                    try MemoryExportCrypto.open(sealedChunk: data, section: .bodies, segmentKey: key, index: 0),
                    "segment \(index) must not open at index 0"
                )
            }
        }
        // The segments rejoin into exactly the section's NDJSON, so rotation
        // splits the stream rather than losing part of it.
        let expected = MemoryExportBundleWriter.ndjson(
            try XCTUnwrap(result.sectionBuffers[.bodies])
        )
        XCTAssertEqual(rejoined, String(decoding: expected, as: UTF8.self))
    }

    func test_anUnrotatedSectionIsStillOneFileNamedZeroZeroZero() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try export(maxSectionBytes: 256 * 1024 * 1024, to: directory, seed: "single")

        for section in MIFSection.allCases {
            let files = try FileManager.default.contentsOfDirectory(
                atPath: directory
                    .appendingPathComponent("sections")
                    .appendingPathComponent(section.rawValue)
                    .path
            )
            XCTAssertEqual(files, ["00000.seg"], section.rawValue)
        }
    }

    /// F-3. Three of the eleven sections are empty in every fixture bundle
    /// (`01-tombstone_receipts`, `03-supersessions`, `08-embeddings`), and each
    /// declared `{bytes: 0, segments: 1}` over a **0-byte** `00000.seg`. A
    /// ChaCha20-Poly1305 segment is never shorter than its 12-byte nonce and
    /// 16-byte tag, so an importer that opens every segment the manifest
    /// declares failed on three sections of every bundle while one that
    /// special-cased `bytes == 0` did not.
    ///
    /// An empty section now seals the empty string: one real segment, 28 bytes,
    /// which opens to zero plaintext bytes and therefore to zero records. The
    /// other option the review offered — `{bytes: 0, segments: 0}` and no file —
    /// the contract cannot express: `section_header.segments` is `{"type":
    /// "integer", "minimum": 1}` at the vendored HEAD.
    func test_anEmptySectionSealsTheEmptyStringRatherThanAZeroByteFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try export(maxSectionBytes: 256 * 1024 * 1024, to: directory, seed: "empty-sections")

        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        let headers = try XCTUnwrap(manifest["sections"] as? [[String: Any]])
        var empties = 0
        for header in headers {
            let name = try XCTUnwrap(header["name"] as? String)
            let section = try XCTUnwrap(MIFSection(rawValue: name))
            guard header["row_count"] as? Int == 0 else { continue }
            empties += 1
            XCTAssertEqual(header["segments"] as? Int, 1, "\(name) declares its one segment")
            XCTAssertEqual(
                header["bytes"] as? Int,
                MemoryExportCrypto.sealOverheadBytes,
                "\(name): an empty section is the sealed empty string, nonce + tag"
            )
            let file = directory
                .appendingPathComponent("sections")
                .appendingPathComponent(name)
                .appendingPathComponent("00000.seg")
            let sealed = try Data(contentsOf: file)
            XCTAssertEqual(sealed.count, MemoryExportCrypto.sealOverheadBytes)
            // And it OPENS — the whole point. Zero plaintext bytes, so the
            // section holds no records, which is what `row_count: 0` says.
            let opened = try MemoryExportCrypto.open(
                sealedChunk: sealed,
                section: section,
                segmentKey: MemoryExportCrypto.segmentKey(
                    bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "empty-sections"),
                    section: section
                ),
                index: 0
            )
            XCTAssertTrue(opened.isEmpty, "\(name) opens to zero plaintext bytes")
        }
        XCTAssertGreaterThanOrEqual(empties, 3, "the fixture has at least three empty sections")

        // `verify` accepts it, and would have named a 0-byte file.
        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: Self.signingKey.publicKey,
            recipient: recipient
        )
        XCTAssertTrue(verification.isIntact, verification.problems.joined(separator: "; "))
        XCTAssertEqual(result.report.decision, .exported)

        try Data().write(to: directory.appendingPathComponent("sections/08-embeddings/00000.seg"))
        let truncated = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: Self.signingKey.publicKey,
            recipient: recipient
        )
        XCTAssertTrue(
            truncated.problems.contains { $0.contains("shorter than an AEAD seal") },
            "a 0-byte segment is named, got: \(truncated.problems)"
        )
    }

    // MARK: - The recipient binding (R4)

    /// D-0021 ruling 1 makes `recipient_key_id` the HPKE `aad`, and D-0025
    /// makes it the `rcp_` id. So `manifest.recipient_key_id` is not merely
    /// typed by the schema — it is the string an importer must feed the wrap.
    ///
    /// The manifest used to carry `sha256(public_key)` while the wrap was sealed
    /// under `rcp_<first 32 hex of it>`: the sole schema failure at HEAD, and a
    /// bundle the addressed store could not open, because an importer reading
    /// the manifest field as the aad has the wrong bytes.
    func test_theManifestNamesTheKeyIDTheWrapWasSealedUnder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try export(maxSectionBytes: 256 * 1024 * 1024, to: directory, seed: "recipient")

        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        let declared = try XCTUnwrap(manifest["recipient_key_id"] as? String)
        XCTAssertEqual(
            declared.range(of: "^rcp_[0-9a-f]{32}$", options: .regularExpression),
            declared.startIndex..<declared.endIndex,
            "D-0025's id grammar, which the vendored contract now types"
        )
        XCTAssertEqual(declared, recipient.keyID)
        XCTAssertEqual(manifest["recipient_store_id"] as? String, "target-store-fixture")

        // And it opens the wrap — the only test of this field that would have
        // caught the old value.
        let wire = try String(
            contentsOf: directory.appendingPathComponent("keys/wrapped-bundle-key"),
            encoding: .utf8
        )
        let parts = wire.split(separator: ".", omittingEmptySubsequences: false)
        var opener = try HPKE.Recipient(
            privateKey: Self.recipientPrivateKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: MemoryExportCrypto.keywrapInfo,
            encapsulatedKey: try XCTUnwrap(MemoryExportBase64URL.decode(String(parts[0])))
        )
        let unwrapped = try opener.open(
            try XCTUnwrap(MemoryExportBase64URL.decode(String(parts[1]))),
            authenticating: Data(declared.utf8)
        )
        XCTAssertEqual(
            SymmetricKey(data: unwrapped),
            MemoryExportCrypto.deterministicBundleKey(seed: "recipient"),
            "the manifest's id is the aad the bundle key was actually sealed under"
        )
    }

    // MARK: - D-0031: the root is carried once

    /// `manifest.hashtree.root` IS the root, it is an input to
    /// `content_digest`, and `hashtree.json`'s copy is the same bytes — no
    /// second construction anywhere. A bundle whose two roots disagree is
    /// rejected before a section is opened.
    func test_theHashTreeRootIsComputedOnceAndCarriedTwice() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try export(maxSectionBytes: 256 * 1024 * 1024, to: directory, seed: "root-once")

        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
        )
        let manifestTree = try XCTUnwrap(manifest["hashtree"] as? [String: Any])
        let manifestRoot = try XCTUnwrap(manifestTree["root"] as? String)
        let tree = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("hashtree.json"))) as? [String: Any]
        )
        XCTAssertEqual(tree["root"] as? String, manifestRoot, "one root, carried twice")
        XCTAssertEqual(result.contentDigest.count, 64)
        // And the root binds the digest: the same store under another key has
        // another root and another digest (the keyed tree moves), while the
        // unkeyed sidecar still verifies — determinism is claimed on the
        // digest, not on keyed values.
        XCTAssertNotEqual(result.contentDigest, String(repeating: "0", count: 64))
    }

    // MARK: - Determinism, on disk

    /// The determinism tests export `to: nil`, so byte identity was only ever
    /// asserted indirectly through a digest. This exports the same store twice,
    /// with the same bundle key and the same clock, and compares the artefacts
    /// file by file.
    ///
    /// Every artefact matches except two, and §2's determinism claim excludes
    /// exactly those two — it is claimed on the manifest MINUS `{created_at_ms,
    /// recipient_key_id, wrapped key, signature}`:
    ///
    ///   * `keys/wrapped-bundle-key`, because HPKE's encapsulated key is random
    ///     (§2.1 says so, and says it costs nothing);
    ///   * `manifest.sig`, because CryptoKit's Ed25519 is **randomized**, not
    ///     the deterministic RFC 8032 signing §2's parenthetical names. This
    ///     test is the evidence: one key, identical bytes, two signatures. Both
    ///     verify, and D-BB-E-5 records the departure.
    ///
    /// The ciphertext IS identical, because the segment nonces are derived from
    /// the bundle key rather than drawn.
    func test_twoExportsWithOneKeyDifferOnlyInTheWrapAndTheSignature() throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("mif-\(UUID().uuidString)")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("mif-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        _ = try export(maxSectionBytes: 512, to: first, seed: "determinism-disk")
        _ = try export(maxSectionBytes: 512, to: second, seed: "determinism-disk")

        let files = try Self.relativeFiles(in: first)
        XCTAssertEqual(files, try Self.relativeFiles(in: second), "the two bundles hold the same files")
        XCTAssertTrue(files.contains("manifest.json"))
        XCTAssertTrue(files.contains("manifest.sig"))
        XCTAssertTrue(files.contains("hashtree.json"))
        XCTAssertTrue(files.contains("keys/wrapped-bundle-key"))

        var differing: [String] = []
        for name in files {
            let lhs = try Data(contentsOf: first.appendingPathComponent(name))
            let rhs = try Data(contentsOf: second.appendingPathComponent(name))
            if lhs != rhs { differing.append(name) }
        }
        XCTAssertEqual(
            differing,
            ["keys/wrapped-bundle-key", "manifest.sig"],
            "only the two artefacts §2's determinism claim already excludes"
        )

        // A randomized signature is still a valid one, over the same raw
        // digest bytes — D-0031: the file is b64url text, not 64 raw bytes.
        let manifestData = try Data(contentsOf: first.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let digest = try XCTUnwrap(manifest["content_digest"] as? String)
        for root in [first, second] {
            let sigData = try Data(contentsOf: root.appendingPathComponent("manifest.sig"))
            let sigText = String(decoding: sigData, as: UTF8.self)
            XCTAssertEqual(sigData.count, 86, "b64url of 64 signature bytes, unpadded")
            XCTAssertTrue(
                MemoryExportCrypto.verifySignature(
                    sigText: sigText,
                    contentDigest: digest,
                    publicKey: Self.signingKey.publicKey
                ),
                "both signatures verify against the same content digest"
            )
        }
    }

    /// Across two DIFFERENT bundle keys, `counts_hash` is the one thing that
    /// still matches — it carries no keyed value, while `content_digest` covers
    /// plaintext holding `body_join_key` and `body_norm_digest`, which are HMACs
    /// under that key.
    func test_twoExportsWithDifferentKeysAgreeOnTheCountsAndNothingElse() throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("mif-\(UUID().uuidString)")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("mif-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let left = try export(maxSectionBytes: 512, to: first, seed: "key-a")
        let right = try export(maxSectionBytes: 512, to: second, seed: "key-b")

        XCTAssertEqual(left.report.countsHash, right.report.countsHash)
        XCTAssertNotEqual(left.contentDigest, right.contentDigest)
        for name in ["manifest.json", "hashtree.json", "sections/06-bodies/00000.seg"] {
            XCTAssertNotEqual(
                try Data(contentsOf: first.appendingPathComponent(name)),
                try Data(contentsOf: second.appendingPathComponent(name)),
                name
            )
        }
    }

    // MARK: - verify (F-16)

    func test_verifyAcceptsAWholeBundleAndNamesWhatItDidNotCheck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try export(maxSectionBytes: 512, to: directory, seed: "verify")

        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: Self.signingKey.publicKey,
            recipient: recipient
        )
        XCTAssertTrue(verification.isIntact, verification.problems.joined(separator: "; "))
        XCTAssertTrue(verification.signatureVerified)
        XCTAssertEqual(verification.recipientStoreID, "target-store-fixture")
        XCTAssertGreaterThanOrEqual(verification.checksRun.count, 5)

        let rendered = MemoryExportBundleVerifier.format(verification, at: directory)
        XCTAssertTrue(rendered.contains("not checked: the plaintext"))
    }

    /// The four corruptions an operator's own disk most plausibly produces. Each
    /// one was undetectable on this side before — `verify` returned a sentence
    /// pointing at the importer.
    func test_verifyCatchesEachCorruptionABundleCanSufferOnDisk() throws {
        func bundle(_ seed: String, _ corrupt: (URL) throws -> Void) throws -> MemoryExportVerification {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mif-\(UUID().uuidString)")
            _ = try export(maxSectionBytes: 512, to: directory, seed: seed)
            try corrupt(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            return try MemoryExportBundleVerifier.verify(
                bundleAt: directory,
                signingPublicKey: Self.signingKey.publicKey,
                recipient: recipient
            )
        }

        // 1. The signed value edited after signing. D-0031 signs the 32 raw
        //    bytes of `content_digest`, not the manifest file — so this flips a
        //    hex digit of the digest itself, the thing the signature covers.
        //    A bare metadata edit is caught too, one check further down: the
        //    digest is the manifest's own members, so it no longer reproduces
        //    (F-1, and the six-member test below).
        let edited = try bundle("edited") { url in
            let path = url.appendingPathComponent("manifest.json")
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
            )
            var digest = try XCTUnwrap(manifest["content_digest"] as? String)
            digest.replaceSubrange(digest.startIndex...digest.startIndex, with: digest.first == "0" ? "1" : "0")
            manifest["content_digest"] = digest
            try JSONSerialization.data(withJSONObject: manifest).write(to: path)
        }
        XCTAssertFalse(edited.signatureVerified)
        XCTAssertTrue(edited.problems.contains { $0.contains("manifest.sig does not verify") })

        // 2. A segment file deleted — the partly-copied bundle.
        let truncated = try bundle("truncated") { url in
            try FileManager.default.removeItem(
                at: url.appendingPathComponent("sections/06-bodies/00001.seg")
            )
        }
        XCTAssertTrue(truncated.problems.contains { $0.contains("segment 1 is missing") })

        // 3. `hashtree.json` swapped for a plausible-looking one.
        let retree = try bundle("retree") { url in
            let path = url.appendingPathComponent("hashtree.json")
            var text = try String(contentsOf: path, encoding: .utf8)
            text = text.replacingOccurrences(of: "\"root\":\"", with: "\"root\":\"0")
            try Data(text.utf8).write(to: path)
        }
        XCTAssertTrue(retree.problems.contains { $0.contains("hashtree.json's root disagrees") })

        // 4. The wrapped key mangled, so nobody could ever open the bundle.
        let unopenable = try bundle("unopenable") { url in
            try Data("not-a-wrapped-key".utf8)
                .write(to: url.appendingPathComponent("keys/wrapped-bundle-key"))
        }
        XCTAssertTrue(unopenable.problems.contains { $0.contains("b64url(enc)") })
    }

    /// R5 — the corruption `verify` could not see: one flipped bit mid-file,
    /// at the same size, so the manifest's `bytes` count still agrees. Before,
    /// `isIntact` stayed true with no problems; now the unkeyed per-chunk
    /// sidecar names the segment file and the chunk (with its byte offset).
    func test_verifyDetectsAModifiedSegmentAndNamesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try export(maxSectionBytes: 512, to: directory, seed: "bitflip")

        let victim = directory.appendingPathComponent("sections/06-bodies/00001.seg")
        var bytes = try Data(contentsOf: victim)
        XCTAssertGreaterThan(bytes.count, 32, "the victim segment must be long enough to flip mid-file")
        bytes[17] ^= 0x01
        try bytes.write(to: victim)

        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: Self.signingKey.publicKey,
            recipient: recipient
        )
        XCTAssertFalse(verification.isIntact, "a one-bit flip must fail verification")
        XCTAssertTrue(
            verification.problems.contains {
                $0.contains("sections/06-bodies/00001.seg") && $0.contains("chunk 0")
            },
            "the problem names the segment and chunk, got: \(verification.problems)"
        )
        // The size check still agrees — this failure is the content check's alone.
        XCTAssertFalse(verification.problems.contains { $0.contains("bytes on disk") })
        XCTAssertTrue(verification.checksRun.contains { $0.contains("segment_sha256") })
    }

    /// The substituted-recipient check, run against the artefact on disk rather
    /// than against the exporter's memory of what it sealed.
    func test_verifyRefusesABundleAddressedToSomebodyElse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try export(maxSectionBytes: 512, to: directory, seed: "substituted")

        let stranger = Curve25519.KeyAgreement.PrivateKey().publicKey
        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: Self.signingKey.publicKey,
            recipient: MemoryExportRecipient(
                keyID: MemoryExportRecipient.keyID(for: stranger),
                publicKey: stranger,
                storeID: "some-other-store"
            )
        )
        XCTAssertFalse(verification.isIntact)
        XCTAssertTrue(verification.problems.contains { $0.contains("different recipient key") })
        XCTAssertTrue(verification.problems.contains { $0.contains("different target store") })
    }
    // MARK: - content_digest binds the manifest (F-1)

    /// §2, the determinism claim: "Determinism is claimed on `content_digest`
    /// and on the manifest minus `{created_at_ms, recipient_key_id, wrapped
    /// key, signature}`", and D-0031 ruling 1 signs the digest *because* of it:
    /// "the digest already binds the manifest minus the four excluded members".
    ///
    /// So the digest has to be recomputable from `manifest.json` itself. It used
    /// to be `sha256(JCS({<section>: sha256(plaintext), …, hashtree_root}))`,
    /// which bound the section plaintexts and the tree and nothing else — the
    /// crypto profile, the recipient binding and every count were rewritable on
    /// the wire under a signature that still verified.
    func test_theContentDigestIsTheManifestMinusItsExcludedMembers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try export(maxSectionBytes: 512, to: directory, seed: "digest-preimage")

        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let parsed = try XCTUnwrap(MIFCanonicalJSON.parse(manifestData))
        XCTAssertEqual(
            MemoryExportManifestDigest.digest(of: parsed),
            result.contentDigest,
            "the digest is recomputable from the manifest on disk"
        )

        // The preimage is the manifest minus exactly four members: §2's two that
        // a manifest carries, plus the two a digest cannot bind because they are
        // derived from it.
        guard case .object(let preimage) = MemoryExportManifestDigest.preimage(parsed),
              case .object(let all) = parsed else { return XCTFail("the manifest is a JSON object") }
        XCTAssertEqual(
            Set(all.keys).subtracting(preimage.keys),
            ["created_at_ms", "recipient_key_id", "bundle_id", "content_digest"]
        )
        for member in ["crypto", "recipient_store_id", "user_id", "not_exported", "rollups", "hashtree", "sections"] {
            XCTAssertNotNil(preimage[member], "\(member) is inside the signature")
        }
        // D-0031: the root is an input to `content_digest` — here, as a member
        // of the manifest the digest is taken over.
        guard case .object(let tree)? = preimage["hashtree"] else { return XCTFail("no hashtree member") }
        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try Data(contentsOf: directory.appendingPathComponent("hashtree.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(tree["root"], .string(try XCTUnwrap(sidecar["root"] as? String)))

        // And the claim is about MEMBERS, not bytes: a manifest reformatted by
        // another JSON writer still reproduces its digest, which is why
        // re-canonicalising is the check rather than hashing the file.
        let reformatted = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any]),
            options: [.prettyPrinted]
        )
        XCTAssertEqual(MemoryExportManifestDigest.digest(ofManifestBytes: reformatted), result.contentDigest)
    }

    /// The review's own six edits, one bundle each. Every one of them left
    /// `intact=true signature_verified=true checks=6 problems=[]` before:
    /// the declared crypto profile, the recipient binding D-0025 ruling 2 exists
    /// to make checkable, and the roll-up digest M-19 exists to make swaps
    /// visible were all rewritable under a valid signature.
    func test_editingAnyManifestMemberTheSignatureCoversFailsVerify() throws {
        // Each case: what to change, and the member name `verify` can also NAME
        // from a second witness inside the bundle (nil where the bundle carries
        // only one copy of the fact — those are caught by the digest and named
        // by it as a group).
        let edits: [(name: String, edit: (inout [String: Any]) -> Void, named: String?)] = [
            ("recipient_store_id", { $0["recipient_store_id"] = "attacker-store" }, "different target store"),
            ("crypto.aead", { manifest in
                var crypto = manifest["crypto"] as? [String: Any] ?? [:]
                crypto["aead"] = "xchacha20poly1305"
                manifest["crypto"] = crypto
            }, nil),
            ("user_id", { $0["user_id"] = "someone-else" }, nil),
            ("not_exported", { $0["not_exported"] = ["forgotten_to_tombstone": 99, "out_of_window": 41] }, nil),
            ("sections[5].row_count", { manifest in
                var sections = manifest["sections"] as? [[String: Any]] ?? []
                sections[5]["row_count"] = 999
                manifest["sections"] = sections
            }, "row_count"),
            ("rollups[0].rollup_digest", { manifest in
                var rollups = manifest["rollups"] as? [[String: Any]] ?? []
                rollups[0]["rollup_digest"] = String(repeating: "0", count: 64)
                manifest["rollups"] = rollups
            }, "rollups[0].rollup_digest")
        ]

        for (name, edit, named) in edits {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mif-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try export(maxSectionBytes: 512, to: directory, seed: "tamper")

            let path = directory.appendingPathComponent("manifest.json")
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Data(contentsOf: path)) as? [String: Any]
            )
            edit(&manifest)
            try JSONSerialization.data(withJSONObject: manifest).write(to: path)

            let verification = try MemoryExportBundleVerifier.verify(
                bundleAt: directory,
                signingPublicKey: Self.signingKey.publicKey,
                recipient: recipient
            )
            XCTAssertFalse(verification.isIntact, "editing \(name) must fail verification")
            XCTAssertTrue(
                verification.problems.contains {
                    $0.contains("does not reproduce its declared content_digest")
                },
                "editing \(name) must break the digest, got: \(verification.problems)"
            )
            // The signature still verifies — it always did, and that is the
            // point: it signs the digest, and the digest is now the manifest.
            XCTAssertTrue(verification.signatureVerified, "\(name): the signature is over the declared digest")
            if let named {
                XCTAssertTrue(
                    verification.problems.contains { $0.contains(named) },
                    "editing \(name) must be NAMED, got: \(verification.problems)"
                )
            }
        }
    }

    private static func relativeFiles(in root: URL) throws -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var names: [String] = []
        for case let path as String in walker {
            var isDirectory: ObjCBool = false
            let full = root.appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue == false {
                names.append(path)
            }
        }
        return names.sorted()
    }
}
