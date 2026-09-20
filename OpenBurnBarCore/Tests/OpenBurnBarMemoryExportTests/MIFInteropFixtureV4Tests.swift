// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFInteropFixtureV4Tests — interop-fixture-v4, the bundle interop run 2 takes.
//
// Built through the public library API with fixed keys — a fixed recipient
// pair, a fixed export signing key, `deterministicBundleKey(seed:
// "interop-fixture-v4")` and a fixed clock — so it regenerates byte for byte
// except `keys/wrapped-bundle-key` (HPKE's random encapsulation) and
// `manifest.sig` (CryptoKit's randomized Ed25519), the two artefacts §2's
// determinism claim excludes.
//
// Run 1's `bnd_95ee02b1…` was superseded whole by v3's `bnd_0a52fbab…`; v3 is
// superseded whole by v4 below. What moved: Q-56's `chunk_sha256` inside
// `hashtree.json` (the `segments.sha256.json` sidecar is gone) and I-74's
// `edk_` + 32-hex `exporter_device_key_id`. `content_digest` binds the
// manifest and the tree root and nothing else in the tree file, so the chunk
// hashes move no digest — the new `bundle_id` is the device-key change's.
// The recipient store id is v3's fictitious importer store, unchanged, so run
// 2 presents the store v3 named.

import Foundation
import GRDB
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import OpenBurnBarMemoryExport

final class MIFInteropFixtureV4Tests: XCTestCase {

    /// Fixed recipient pair: the interop importer holds the private half.
    private static let recipientSeed = Data(repeating: 0x44, count: 32)
    /// Fixed export signing key. Its id is `deviceKeyID` below, `edk_` + 32 hex.
    private static let signingSeed = Data(repeating: 0x53, count: 32)
    /// v3's fictitious importer store, unchanged into v4.
    private static let importerStoreID = "sto_86de0b1a69f22aced2b305dd108a0508"

    private func keypair() throws -> MemoryExportRecipient.Keypair {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.recipientSeed)
        return MemoryExportRecipient.Keypair(
            recipient: MemoryExportRecipient(
                keyID: MemoryExportRecipient.keyID(for: privateKey.publicKey),
                publicKey: privateKey.publicKey,
                storeID: Self.importerStoreID
            ),
            privateKey: privateKey
        )
    }

    private func recipient() throws -> MemoryExportRecipient {
        try keypair().recipient
    }

    private func signingKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: Self.signingSeed)
    }

    /// The v4 store: a proven human approve, a proven human rejection, a
    /// label-only approval, a daemon `code` row, a forgotten memory (which
    /// leaves as a tombstone) and a `memory.delete` of a quarantined row
    /// (which synthesizes one).
    private func makeStore() throws -> DatabaseQueue {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "proven-human",
                body: "Fewer, fatter PRs.",
                reviewStatus: "approved",
                updatedAt: "2026-01-02T00:00:00.000Z"
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.approve",
                projectID: "chat:user-1",
                subjectID: "proven-human",
                labels: ["memory_id:proven-human", "review_status:approved", "source_kind:chat"],
                ts: "2026-01-02T00:00:00.000Z"
            )
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "proven-rejection",
                body: "Ship it on Friday.",
                reviewStatus: "rejected",
                updatedAt: "2026-01-03T00:00:00.000Z"
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.reject",
                projectID: "chat:user-1",
                subjectID: "proven-rejection",
                labels: ["memory_id:proven-rejection", "review_status:rejected", "source_kind:chat"],
                ts: "2026-01-03T00:00:00.000Z"
            )
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "label-only",
                body: "Approved by a migration, not a person.",
                reviewStatus: "approved"
            )
            try MemoryExportFixtureStore.insertDaemonMemory(
                db,
                id: "mem_" + String(repeating: "e", count: 32),
                body: "The Linux lane is the only cfg(linux) gate.",
                projectID: "proj-1"
            )
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "forgotten-but-bodied",
                body: "A memory the user asked to forget.",
                reviewStatus: "forgotten"
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.delete",
                projectID: "chat:user-1",
                subjectID: "deleted-quarantined",
                labels: ["memory_id:deleted-quarantined", "source_kind:chat"],
                ts: "2026-01-04T00:00:00.000Z"
            )
            // One project input row and one citation for the proven memory, so
            // sections 04 and 07 are covered the way run 1's fixture covered
            // them. The exporter carries fingerprint inputs only; the importer
            // computes `project_id` (§3 row for section 04).
            try db.execute(
                sql: """
                INSERT INTO pcm_projects
                    (project_id, identity_version, identity_fingerprint, project_name,
                     primary_path, created_at, updated_at)
                VALUES ('proj-1', 1, '', 'proj-1', '/tmp/proj-1',
                        '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO memory_provenance
                    (id, memory_id, source_kind, thread_logical_id, message_id, role,
                     authored_at, content_hash, occurrence, xdevice_hmac, citation_state, created_at)
                VALUES ('cit-1', 'proven-human', 'chat_message', 'thread-1', 'msg-1', 'human',
                        '2026-01-02T00:00:00.000Z', 'hash', 0, 'hmac', 'unknown',
                        '2026-01-02T00:00:00.000Z')
                """
            )
        }
        return queue
    }

    private func json(at url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    /// interop-fixture-v4, pinned. Five memories in (one `forgotten` → a
    /// tombstone, one proven human rejection), 4 memory records, 4 bodies, 1
    /// project, 1 citation, 3 audit rows, 3 findings; 11 sections, 11 segment
    /// files. Every value below was produced by this builder — nothing here
    /// is a value the exporter printed and was then asked to reproduce, which
    /// is why the builder uses fixed keys throughout.
    func test_interopFixtureV4IsPinned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-v4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try export(to: directory)

        // I-76: the two proven verdicts leave signed under the device key
        // with CryptoKit's randomized Ed25519, so the identity moves on every
        // export and no identity value is pinned here — v5 carries the interop
        // identity now. What this pins is the shape and the self-consistency:
        // `bundle_id` is `bnd_` plus the digest's first 32 hex, and the files
        // carry the identity the result computed.
        XCTAssertEqual(result.bundleID, "bnd_" + result.contentDigest.prefix(32))

        let manifest = try XCTUnwrap(try json(at: directory.appendingPathComponent("manifest.json")) as? [String: Any])
        XCTAssertEqual(manifest["bundle_id"] as? String, result.bundleID)
        XCTAssertEqual(manifest["content_digest"] as? String, result.contentDigest)
        let manifestTree = try XCTUnwrap(manifest["hashtree"] as? [String: Any])
        XCTAssertEqual(manifest["recipient_key_id"] as? String, "rcp_34a31a0d016fad9b86b70ba95f4b21b7")
        XCTAssertEqual(manifest["recipient_store_id"] as? String, Self.importerStoreID)
        // I-74: the pinned `edk_` + 32-hex shape, in both files that carry it.
        XCTAssertEqual(manifest["exporter_device_key_id"] as? String, "edk_f993bf2661c8a80d1ec098a49f6fb01d")
        let report = try XCTUnwrap(try json(at: directory.appendingPathComponent("report.json")) as? [String: Any])
        XCTAssertEqual(
            (report["bundle"] as? [String: Any])?["exporter_device_key_id"] as? String,
            "edk_f993bf2661c8a80d1ec098a49f6fb01d"
        )
        XCTAssertEqual(report["decision"] as? String, "exported")
        XCTAssertEqual((report["tables"] as? [[String: Any]])?.count, 15, "every section has a lane")

        // The contents, per section.
        let headers = try XCTUnwrap(manifest["sections"] as? [[String: Any]])
        let rowsBySection = Dictionary(
            uniqueKeysWithValues: headers.map {
                (($0["name"] as? String ?? "?", ($0["row_count"] as? Int ?? -1)))
            }
        )
        XCTAssertEqual(rowsBySection, [
            "00-tombstones": 2, "01-tombstone_receipts": 0, "02-review_events": 2,
            "03-supersessions": 0, "04-projects": 1, "05-memories": 4,
            "06-bodies": 4, "07-provenance": 1, "08-embeddings": 0,
            "09-audit_evidence": 3, "10-findings": 3
        ])
        XCTAssertEqual(
            headers.compactMap({ $0["segments"] as? Int }).reduce(0, +), 11,
            "one segment file per section at fixture scale"
        )

        // Q-56: the per-chunk hashes live in the tree file, keyed by section
        // id; every fixture segment is one chunk, and the sidecar is gone.
        let tree = try XCTUnwrap(try json(at: directory.appendingPathComponent("hashtree.json")) as? [String: Any])
        XCTAssertEqual(tree["root"] as? String, manifestTree["root"] as? String, "one root, carried twice")
        let chunkSHA = try XCTUnwrap(tree["chunk_sha256"] as? [String: [String]])
        XCTAssertEqual(Set(chunkSHA.keys), Set(MIFSection.allCases.map(\.rawValue)))
        for section in MIFSection.allCases {
            XCTAssertEqual(chunkSHA[section.rawValue]?.count, 1, "\(section.rawValue)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("segments.sha256.json").path
            ),
            "Q-60: no sidecar beside the tree file"
        )

        // The three contract documents validate, and `verify` is intact with
        // a verified signature — what run 2's importer will open.
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        try validator.validate(manifest, against: "#/$defs/manifest")
        try validator.validate(report, against: "#/$defs/reconciliation_report")
        try validator.validate(tree, against: "#/$defs/hashtree_file")
        // I-76: both review events leave signed, and both signatures verify
        // under the device key over the §2 record-02 preimage.
        let events = try XCTUnwrap(result.sectionBuffers[.reviewEvents]?.records)
        XCTAssertEqual(events.count, 2, "v4's proven approve and proven rejection")
        for event in events {
            guard case .object(let members) = event,
                  case .string(let signature) = members["event_signature"]
            else {
                XCTFail("a proven verdict leaves signed")
                return
            }
            XCTAssertTrue(
                MemoryExportCrypto.verifyReviewEventSignature(
                    event, signature: signature,
                    publicKey: try signingKey().publicKey
                ),
                "the event signature verifies over the record-02 preimage"
            )
        }

        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: try signingKey().publicKey,
            recipient: try recipient()
        )
        XCTAssertTrue(verification.isIntact, verification.problems.joined(separator: "; "))
        XCTAssertTrue(verification.signatureVerified)
        XCTAssertEqual(verification.checksRun.count, 10)

        // Run 2's handoff. With `MIF_V4_DUMP_DIR` set, the bundle lands in
        // `<dir>/fixture-bundle` and both key halves in `<dir>/fixture-keys`
        // (`recipient.json` + the `0600` `recipient-secret.json` the importer
        // opens the wrap with) — the two commands §11's recipe names, through
        // the same fixed keys this test pins.
        if let dump = ProcessInfo.processInfo.environment["MIF_V4_DUMP_DIR"] {
            let root = URL(fileURLWithPath: dump)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bundleOut = root.appendingPathComponent("fixture-bundle")
            try? FileManager.default.removeItem(at: bundleOut)
            try FileManager.default.copyItem(at: directory, to: bundleOut)
            _ = try MemoryExportRecipient.writeKeypair(
                try keypair(),
                to: root.appendingPathComponent("fixture-keys")
            )
        }
    }

    /// The fixture regenerates in structure: the same store through the same
    /// fixed keys yields the same records and the same determinism digest —
    /// while the bundle identity moves with I-76's randomized event
    /// signatures (the wrap and the manifest signature excepted beside them,
    /// per §2's determinism claim).
    func test_interopFixtureV4Regenerates() throws {
        let first = try export(to: nil, seed: "interop-fixture-v4")
        let second = try export(to: nil, seed: "interop-fixture-v4")
        XCTAssertEqual(first.determinismDigest, second.determinismDigest)
        XCTAssertEqual(first.report.countsHash, second.report.countsHash)
        XCTAssertEqual(
            redactedSectionRecords(first.sectionBuffers),
            redactedSectionRecords(second.sectionBuffers),
            "the same store exports the same records but for signature bytes"
        )
    }

    private func export(to directory: URL?, seed: String = "interop-fixture-v4") throws -> MemoryExportBundleResult {
        let exporter = MemoryExporter(
            storeID: "store-fixture-v4",
            storeFingerprint: String(repeating: "4", count: 64),
            sourceVersion: "1.0.41",
            userID: "user-1",
            recipient: try recipient(),
            signingKey: try signingKey(),
            options: MemoryExportOptions(
                enabled: true,
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

    private func contractData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "mif-v1.schema", withExtension: "json"),
            "the embedded contract copy is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }
}
