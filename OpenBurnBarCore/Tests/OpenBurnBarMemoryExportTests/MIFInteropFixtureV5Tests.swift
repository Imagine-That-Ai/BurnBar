// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFInteropFixtureV5Tests — interop-fixture-v5, the bundle interop run 3 takes.
//
// Built through the public library API with fixed keys — a fixed recipient
// pair, a fixed export signing key, `deterministicBundleKey(seed:
// "interop-fixture-v5")` and a fixed clock — so it regenerates byte for byte
// except `keys/wrapped-bundle-key` (HPKE's random encapsulation),
// `manifest.sig` (CryptoKit's randomized Ed25519) and the section-02
// `event_signature` bytes (randomized per signing call under the same key),
// the three artefacts §2's determinism claim excludes.
//
// v4's `bnd_07d85c76…` is superseded whole by v5 below. What moved:
// I-76's per-verdict signatures — the two proven human verdicts leave signed
// under the device key over the §2 record-02 preimage (`signing_key_id` is
// the same `edk_f993…` id v4 pinned), and their `from_status` stays null for
// the first verdict, which the importer's nullable read takes as
// `quarantined`. Section bytes change, so the tree root, `content_digest`
// and `bundle_id` all move; the store, the keys and every other section are
// v4's.
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

final class MIFInteropFixtureV5Tests: XCTestCase {

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
            // Run 3: the target is a fresh store with an empty tag vocabulary,
            // and a row carrying a tag the target never approved is refused by
            // design — so the fixture rows travel untagged. (`insertMemoryRow`
            // tags every row `fixture`; that marker is unit-test scaffolding,
            // not wire content.)
            try db.execute(sql: "UPDATE agent_memories SET tags_json = '[]'")
        }
        return queue
    }

    private func json(at url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    /// interop-fixture-v5, pinned in structure, not in identity. Five memories
    /// in (one `forgotten` → a tombstone, one proven human rejection),
    /// 4 memory records, 4 bodies, 1 project, 1 citation, 3 audit rows,
    /// 3 findings; 11 sections, 11 segment files. Identity
    /// (`bundle_id`/`content_digest`/tree root) is deliberately NOT pinned:
    /// the I-76 verdict signatures use CryptoKit's randomized Ed25519 (the
    /// Q-24 exclusion, extended to section 02 by the spec), so two exports of
    /// this store carry different signature bytes — both verifying — and the
    /// identity moves with them. What pins drift instead: every unsigned byte
    /// (all sections but 02, all key ids, all counts), the schema validation,
    /// the bundle verifier, and the signature self-checks below. Every
    /// non-signature value was produced by this builder through fixed keys.
    func test_interopFixtureV5IsPinned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-v5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try export(to: directory)

        let manifest = try XCTUnwrap(try json(at: directory.appendingPathComponent("manifest.json")) as? [String: Any])
        let manifestTree = try XCTUnwrap(manifest["hashtree"] as? [String: Any])
        // Consistency, not identity: the id follows the digest, the root is
        // carried twice, and the digest is what the verifier recomputes.
        XCTAssertEqual(result.bundleID, "bnd_" + String(result.contentDigest.prefix(32)))
        XCTAssertEqual(
            manifest["bundle_id"] as? String, result.bundleID,
            "the manifest carries the identity the builder returned"
        )
        XCTAssertEqual(
            manifest["content_digest"] as? String, result.contentDigest
        )
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

        // I-76: both proven human verdicts leave signed under the device key,
        // over the §2 record-02 preimage — read back through the sealed
        // segment, the way the importer will read them, not from memory.
        let bundleKey = MemoryExportCrypto.deterministicBundleKey(
            seed: "interop-fixture-v5"
        )
        let segURL = directory
            .appendingPathComponent("sections/02-review_events/00000.seg")
        let sealed = try Data(contentsOf: segURL)
        let opened = try MemoryExportCrypto.open(
            sealedChunk: sealed,
            section: .reviewEvents,
            segmentKey: MemoryExportCrypto.segmentKey(
                bundleKey: bundleKey, section: .reviewEvents
            ),
            index: 0
        )
        let events = try XCTUnwrap(String(data: opened, encoding: .utf8))
            .split(separator: "\n")
            .map {
                try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data($0.utf8))
                        as? [String: Any]
                )
            }
        XCTAssertEqual(events.count, 2, "the two proven human verdicts")
        let devicePublicKey = try signingKey().publicKey
        let expectedKeyID = MemoryExportCrypto.deviceKeyID(devicePublicKey)
        XCTAssertEqual(
            expectedKeyID, "edk_f993bf2661c8a80d1ec098a49f6fb01d",
            "v5 signs under v4's fixed device key"
        )
        var sawNullFromStatus = false
        for event in events {
            let signature = try XCTUnwrap(
                event["event_signature"] as? String,
                "a proven human verdict leaves signed"
            )
            XCTAssertFalse(signature.isEmpty)
            XCTAssertEqual(
                event["signing_key_id"] as? String, expectedKeyID
            )
            if event["from_status"] is NSNull { sawNullFromStatus = true }
            // The self-check: re-derive the preimage from the carried record
            // and verify under the fixed public key, through the same two
            // functions the exporter signed with.
            let recordData = try JSONSerialization.data(
                withJSONObject: event, options: [.sortedKeys]
            )
            let record = try XCTUnwrap(MIFCanonicalJSON.parse(recordData))
            XCTAssertTrue(
                MemoryExportCrypto.verifyReviewEventSignature(
                    record, signature: signature, publicKey: devicePublicKey
                ),
                "the carried verdict verifies under the device key"
            )
        }
        XCTAssertTrue(
            sawNullFromStatus,
            "a first verdict carries from_status null — the importer's "
                + "nullable read (I-76) takes it as quarantined"
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
        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: try signingKey().publicKey,
            recipient: try recipient()
        )
        XCTAssertTrue(verification.isIntact, verification.problems.joined(separator: "; "))
        XCTAssertTrue(verification.signatureVerified)
        XCTAssertEqual(verification.checksRun.count, 10)

        // Run 2's handoff. With `MIF_V5_DUMP_DIR` set, the bundle lands in
        // `<dir>/fixture-bundle` and both key halves in `<dir>/fixture-keys`
        // (`recipient.json` + the `0600` `recipient-secret.json` the importer
        // opens the wrap with) — the two commands §11's recipe names, through
        // the same fixed keys this test pins.
        if let dump = ProcessInfo.processInfo.environment["MIF_V5_DUMP_DIR"] {
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

    /// The fixture regenerates in structure: two exports of the same store
    /// through the same fixed keys carry byte-identical unsigned bytes — every
    /// section but 02, the manifest's unsigned members, the report — while the
    /// two section-02 segments differ ONLY in their signature bytes, both
    /// verifying under the fixed device key. (§2's determinism claim excludes
    /// the randomized signature bytes, manifest plus section 02; the identity
    /// moves with them and is not compared.)
    func test_interopFixtureV5RegeneratesInStructure() throws {
        let firstDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-v5a-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: firstDir) }
        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-v5b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: secondDir) }
        _ = try export(to: firstDir, seed: "interop-fixture-v5")
        _ = try export(to: secondDir, seed: "interop-fixture-v5")

        let fm = FileManager.default
        func filesOnly(at dir: URL) throws -> [String] {
            try fm.subpathsOfDirectory(atPath: dir.path).filter { relative in
                var isDirectory: ObjCBool = false
                return fm.fileExists(
                    atPath: dir.appendingPathComponent(relative).path,
                    isDirectory: &isDirectory
                ) && !isDirectory.boolValue
            }.sorted()
        }
        let firstFiles = try filesOnly(at: firstDir)
        let secondFiles = try filesOnly(at: secondDir)
        // Same shape, modulo the two artefacts §2 excludes from determinism.
        XCTAssertEqual(
            firstFiles.filter({ $0 != "manifest.sig" && !$0.hasPrefix("keys/") }),
            secondFiles.filter({ $0 != "manifest.sig" && !$0.hasPrefix("keys/") })
        )
        for relative in firstFiles {
            if relative == "manifest.sig" || relative.hasPrefix("keys/")
                || relative == "manifest.json" || relative == "hashtree.json"
                || relative.hasPrefix("sections/02-review_events") {
                continue
            }
            if relative == "report.json" {
                // The report mirrors the bundle identity, which randomness
                // moves: compare everything but the two identity members.
                func redactedReport(at dir: URL) throws -> MIFJSON {
                    let data = try Data(contentsOf: dir.appendingPathComponent(relative))
                    guard case .object(var top) = MIFCanonicalJSON.parse(data),
                          case .object(var bundle) = top["bundle"] else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    bundle.removeValue(forKey: "bundle_id")
                    bundle.removeValue(forKey: "content_digest")
                    top["bundle"] = .object(bundle)
                    return .object(top)
                }
                XCTAssertEqual(
                    try redactedReport(at: firstDir),
                    try redactedReport(at: secondDir),
                    "report.json is byte-stable across exports but for identity"
                )
                continue
            }
            let a = try Data(contentsOf: firstDir.appendingPathComponent(relative))
            let b = try Data(contentsOf: secondDir.appendingPathComponent(relative))
            XCTAssertEqual(a, b, "\(relative) is byte-stable across exports")
        }
        // Section 02 decrypts in both exports; the records agree on every
        // member but the signature, and both signatures verify.
        let bundleKey = MemoryExportCrypto.deterministicBundleKey(
            seed: "interop-fixture-v5"
        )
        let segKey = MemoryExportCrypto.segmentKey(
            bundleKey: bundleKey, section: .reviewEvents
        )
        var plaintexts: [String] = []
        for dir in [firstDir, secondDir] {
            let sealed = try Data(contentsOf: dir.appendingPathComponent(
                "sections/02-review_events/00000.seg"
            ))
            let opened = try MemoryExportCrypto.open(
                sealedChunk: sealed, section: .reviewEvents,
                segmentKey: segKey, index: 0
            )
            let text = try XCTUnwrap(String(data: opened, encoding: .utf8))
            plaintexts.append(text)
            for line in text.split(separator: "\n") {
                let event = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any]
                )
                let signature = try XCTUnwrap(event["event_signature"] as? String)
                let recordData = try JSONSerialization.data(
                    withJSONObject: event, options: [.sortedKeys]
                )
                let record = try XCTUnwrap(MIFCanonicalJSON.parse(recordData))
                XCTAssertTrue(
                    MemoryExportCrypto.verifyReviewEventSignature(
                        record, signature: signature,
                        publicKey: try signingKey().publicKey
                    )
                )
            }
        }
        let withoutSignatures: [[[String: Any]]] = try plaintexts.map { text in
            try text.split(separator: "\n").map { line -> [String: Any] in
                var event = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any]
                )
                event.removeValue(forKey: "event_signature")
                return event
            }
        }
        XCTAssertEqual(
            withoutSignatures[0].count, withoutSignatures[1].count
        )
        for (a, b) in zip(withoutSignatures[0], withoutSignatures[1]) {
            XCTAssertEqual(
                NSDictionary(dictionary: a), NSDictionary(dictionary: b),
                "unsigned verdict members are byte-stable across exports"
            )
        }
    }

    private func export(to directory: URL?, seed: String = "interop-fixture-v5") throws -> MemoryExportBundleResult {
        let exporter = MemoryExporter(
            storeID: "store-fixture-v5",
            storeFingerprint: String(repeating: "4", count: 64),
            sourceVersion: "1.0.41",
            userID: "user-1",
            recipient: try recipient(),
            signingKey: try signingKey(),
            options: MemoryExportOptions(
                enabled: true,
                gate: .alwaysAllow,
                now: Date(timeIntervalSince1970: 1_767_571_200)
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
