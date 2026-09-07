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
    /// `000.ndjson.seal`, so there was never a second segment file however large
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
        XCTAssertEqual(onDisk.first, "000.ndjson.seal")
        var total = 0
        for (index, name) in onDisk.enumerated() {
            XCTAssertEqual(name, String(format: "%03d.ndjson.seal", index))
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
                contentsOf: sectionDirectory.appendingPathComponent(String(format: "%03d.ndjson.seal", index))
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
            XCTAssertEqual(files, ["000.ndjson.seal"], section.rawValue)
        }
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

        // A randomized signature is still a valid one, over the same manifest.
        let manifest = try Data(contentsOf: first.appendingPathComponent("manifest.json"))
        let digest = Data(SHA256.hash(data: manifest))
        for root in [first, second] {
            let signature = try Data(contentsOf: root.appendingPathComponent("manifest.sig"))
            XCTAssertTrue(
                Self.signingKey.publicKey.isValidSignature(signature, for: digest),
                "both signatures verify against the same manifest"
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
        for name in ["manifest.json", "hashtree.json", "sections/06-bodies/000.ndjson.seal"] {
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

        // 1. A manifest edited after signing.
        let edited = try bundle("edited") { url in
            let path = url.appendingPathComponent("manifest.json")
            var text = try String(contentsOf: path, encoding: .utf8)
            text = text.replacingOccurrences(of: "\"rehearsal\":false", with: "\"rehearsal\":true")
            try Data(text.utf8).write(to: path)
        }
        XCTAssertFalse(edited.signatureVerified)
        XCTAssertTrue(edited.problems.contains { $0.contains("manifest.sig does not verify") })

        // 2. A segment file deleted — the partly-copied bundle.
        let truncated = try bundle("truncated") { url in
            try FileManager.default.removeItem(
                at: url.appendingPathComponent("sections/06-bodies/001.ndjson.seal")
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
