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
}
