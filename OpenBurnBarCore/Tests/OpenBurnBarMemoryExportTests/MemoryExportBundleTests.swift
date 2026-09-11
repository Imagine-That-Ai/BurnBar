// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportBundleTests — the bundle end to end: determinism, schema
// validation, dry-run parity, the delete obligation, and the gate.

import Foundation
import GRDB
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import OpenBurnBarMemoryExport

final class MemoryExportBundleTests: XCTestCase {

    private let storeID = "store-fixture-1"
    private let fingerprint = String(repeating: "1", count: 64)
    /// One fixed recipient for the whole suite. `recipient_store_id` is a
    /// deterministic manifest field now that it names the TARGET store rather
    /// than the producer, so the determinism tests need it stable.
    private static let recipientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    private var recipient: MemoryExportRecipient {
        MemoryExportRecipient(
            keyID: MemoryExportRecipient.keyID(for: Self.recipientPrivateKey.publicKey),
            publicKey: Self.recipientPrivateKey.publicKey,
            // A store id of the DDL's own shape: `sto_` + 32 lowercase hex (M-10).
            storeID: "sto_" + String(repeating: "b", count: 32)
        )
    }

    // MARK: - Fixture

    /// One store carrying every fixture the release owes: a proven human
    /// approve, a mutated body under a verdict, a daemon `code` row, a
    /// label-only approval, a broken chain link, both body conventions, an
    /// orphan body, and a `memory.delete` of a quarantined row.
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
            // An orphan body: a snapshot row no authority row references.
            try db.execute(
                sql: """
                INSERT INTO memory_body_snapshots
                    (id, memory_id, body_ref, snapshot_json, body_hash, source_kind, created_at, updated_at)
                VALUES ('orphan', 'orphan-memory', 'memory_body_snapshots:orphan',
                        '{"body":"nobody points here"}', 'x', 'chat',
                        '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """
            )
            // A hard DELETE of a quarantined row writes only an audit row.
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.delete",
                projectID: "chat:user-1",
                subjectID: "deleted-quarantined",
                labels: ["memory_id:deleted-quarantined", "source_kind:chat"],
                ts: "2026-01-04T00:00:00.000Z"
            )
        }
        return queue
    }

    private func makeExporter(gate: MemoryExportGateRunner = .alwaysAllow) -> MemoryExporter {
        MemoryExporter(
            storeID: storeID,
            storeFingerprint: fingerprint,
            sourceVersion: "1.0.41",
            userID: "user-1",
            recipient: recipient,
            signingKey: Curve25519.Signing.PrivateKey(),
            options: MemoryExportOptions(
                enabled: true,
                gate: gate,
                now: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
    }

    // MARK: - Determinism

    func test_sameDatabaseProducesTheSameBundleDigest() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        let exporter = makeExporter()
        let key = MemoryExportCrypto.deterministicBundleKey(seed: "determinism")

        let first = try exporter.export(snapshot, mode: .full, to: nil, bundleKey: key)
        let second = try exporter.export(snapshot, mode: .full, to: nil, bundleKey: key)
        // I-76's randomized event signatures move the bundle identity on
        // every export, so sameness is the determinism digest, the counts and
        // the records minus signature bytes — never the identity itself.
        XCTAssertEqual(first.determinismDigest, second.determinismDigest)
        XCTAssertEqual(first.report.countsHash, second.report.countsHash)
        XCTAssertEqual(
            redactedSectionRecords(first.sectionBuffers),
            redactedSectionRecords(second.sectionBuffers),
            "the same database exports the same records but for signature bytes"
        )

        // A DIFFERENT bundle key changes the digest, and that is correct rather
        // than a determinism failure: `body_join_key` and `body_norm_digest` are
        // HMACs under the bundle key, so they live in the plaintext the digest
        // covers. Determinism is per-key, which is exactly why `--rehearsal
        // --deterministic-nonces` derives the key from a fixture seed. The
        // COUNTS, which carry no keyed value, stay identical.
        let other = try exporter.export(
            snapshot,
            mode: .full,
            to: nil,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "another")
        )
        XCTAssertNotEqual(first.contentDigest, other.contentDigest)
        XCTAssertEqual(first.report.countsHash, other.report.countsHash)
    }

    func test_dryRunMatchesTheRealRunCountForCount() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        let exporter = makeExporter()
        let key = MemoryExportCrypto.deterministicBundleKey(seed: "dry-run")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let dry = try exporter.export(snapshot, mode: .dryRun, to: directory, bundleKey: key)
        let real = try exporter.export(snapshot, mode: .full, to: directory, bundleKey: key)

        XCTAssertEqual(dry.report.countsHash, real.report.countsHash)
        // The identity moves with I-76's randomized event signatures, so the
        // dry run and the real run agree on the determinism digest and the
        // records minus signature bytes instead.
        XCTAssertEqual(dry.determinismDigest, real.determinismDigest)
        XCTAssertEqual(
            redactedSectionRecords(dry.sectionBuffers),
            redactedSectionRecords(real.sectionBuffers),
            "dry and real runs classify the same records"
        )
        XCTAssertNil(dry.bundleURL, "a dry run writes no bundle")
        XCTAssertNotNil(real.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.json").path))
    }

    // MARK: - Schema validation

    func test_everyEmittedRecordValidatesAgainstTheContract() throws {
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = MemoryExportCrypto.deterministicBundleKey(seed: "schema")
        let result = try makeExporter().export(snapshot, mode: .full, to: directory, bundleKey: key)

        // The THREE documents the contract's top-level `oneOf` names — the
        // third is `hashtree.json`, which D-0039 ruling 8 typed because the one
        // artefact whose whole purpose is to be checked was the one artefact
        // nothing checked.
        let manifest = try json(at: directory.appendingPathComponent("manifest.json"))
        try validator.validate(manifest, against: "#/$defs/manifest")
        let report = try json(at: directory.appendingPathComponent("report.json"))
        try validator.validate(report, against: "#/$defs/reconciliation_report")
        let tree = try json(at: directory.appendingPathComponent("hashtree.json"))
        try validator.validate(tree, against: "#/$defs/hashtree_file")
        // …and Q-56's unkeyed per-chunk hashes live INSIDE that document as
        // `chunk_sha256`, keyed by section id exactly as `subroots` is — one
        // file per concept, so the `segments.sha256.json` sidecar is gone and
        // Q-60's closed directory refuses a bundle still carrying one.
        let treeObject = try XCTUnwrap(tree as? [String: Any])
        let chunkSHA = try XCTUnwrap(treeObject["chunk_sha256"] as? [String: [String]])
        XCTAssertEqual(Set(chunkSHA.keys), Set(MIFSection.allCases.map(\.rawValue)), "one entry per section")
        for section in MIFSection.allCases {
            XCTAssertFalse(
                try XCTUnwrap(chunkSHA[section.rawValue]).isEmpty,
                "\(section.rawValue) seals at least one segment, so at least one chunk"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("segments.sha256.json").path
            ),
            "the sidecar is gone; hashtree.json carries chunk_sha256 instead"
        )

        // Every section's records, against the pointer `section_record_map`
        // names for that section.
        for section in MIFSection.allCases {
            let plaintext = MemoryExportBundleWriter.ndjson(sectionBuffer(result, section: section))
            for (index, line) in String(decoding: plaintext, as: UTF8.self).split(separator: "\n").enumerated() {
                let record = try JSONSerialization.jsonObject(with: Data(line.utf8))
                XCTAssertNoThrow(
                    try validator.validate(record, against: section.recordTypePointer),
                    "\(section.rawValue) record \(index)"
                )
            }
        }
        // §10: the validator must be proven to have RUN. A schema gate that
        // silently no-ops reads exactly like one that passes.
        XCTAssertGreaterThan(validator.assertionsEvaluated, 500)
    }

    func test_aRecordCarryingAKeyedFieldIsRejected() throws {
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        // M-05: `content_key` is HKDF'd from the core's user_root_key and must
        // never appear in a bundle. `additionalProperties: false` is what makes
        // that checkable rather than aspirational.
        var record = try XCTUnwrap(sampleMemoryRecord() as? [String: Any])
        record["content_key"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try validator.validate(record, against: "#/$defs/record_memory"))
    }

    func test_anApprovedRecordWithoutHumanOriginIsRejected() throws {
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        var record = try XCTUnwrap(sampleMemoryRecord() as? [String: Any])
        record["review_status"] = "approved"
        record["origin_kind"] = "import"
        XCTAssertThrowsError(try validator.validate(record, against: "#/$defs/record_memory"))
    }

    /// `required` and `enum` are both implemented, and until now neither was
    /// mutated by any test — so a regression in either would have gone
    /// unnoticed while the suite stayed green.
    func test_aRecordMissingARequiredFieldIsRejected() throws {
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        var record = try XCTUnwrap(sampleMemoryRecord() as? [String: Any])
        record.removeValue(forKey: "memory_id")
        XCTAssertThrowsError(try validator.validate(record, against: "#/$defs/record_memory")) { error in
            XCTAssertTrue("\(error)".contains("missing required property 'memory_id'"), "\(error)")
        }
    }

    /// The Linux runner refuses every fixture export with `sourceIntegrityFailed`, which means
    /// `PRAGMA quick_check` on the freshly migrated in-memory store answered something other
    /// than `ok` there. This pins the expectation and, when it fails, names the actual answer.
    func test_theMigratedInMemoryFixtureStorePassesQuickCheck() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        XCTAssertEqual(
            snapshot.sourceQuickCheck,
            "ok",
            "PRAGMA quick_check answered: \(snapshot.sourceQuickCheck)"
        )
    }

    func test_aRecordWithAValueOutsideAClosedSetIsRejected() throws {
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        var record = try XCTUnwrap(sampleMemoryRecord() as? [String: Any])
        record["dedup_partition"] = "not_a_lane"
        XCTAssertThrowsError(try validator.validate(record, against: "#/$defs/record_memory")) { error in
            XCTAssertTrue("\(error)".contains("closed set"), "\(error)")
        }
    }

    /// MIF minor 2's `source_memory_id` is the contract's first `maxLength`, and
    /// re-vendoring it is what turned the evaluator's unknown-keyword guard red
    /// until the keyword landed (review F-6).
    func test_aSourceMemoryIDLongerThanTheContractAllowsIsRejected() throws {
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        var record = try XCTUnwrap(sampleMemoryRecord() as? [String: Any])
        record["source_memory_id"] = String(repeating: "x", count: 257)
        XCTAssertThrowsError(try validator.validate(record, against: "#/$defs/record_memory")) { error in
            XCTAssertTrue("\(error)".contains("maxLength"), "\(error)")
        }
        record["source_memory_id"] = String(repeating: "x", count: 256)
        XCTAssertNoThrow(try validator.validate(record, against: "#/$defs/record_memory"))
    }

    /// F-3. `manifest.rollups[].tuple` is what a conforming importer recomputes
    /// from post-apply, and it HOLDS on `ROLLUP_DIGEST_MISMATCH`. One hardcoded
    /// triple was declared for every section while 05 and 06 digest different
    /// third values, so an importer that did the recompute failed on 06 for
    /// every bundle this exporter had ever produced.
    func test_eachSectionDeclaresTheTupleItActuallyDigested() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        var exporter = makeExporter()
        exporter.options.carryOrphans = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try exporter.export(
            snapshot,
            mode: .full,
            to: directory,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "rollups")
        )

        let manifest = try XCTUnwrap(try json(at: directory.appendingPathComponent("manifest.json")) as? [String: Any])
        let rollups = try XCTUnwrap(manifest["rollups"] as? [[String: Any]])
        // D-0039 ruling 6: all eleven, and every section header carries the
        // same digest. Eight of them used to be absent, which is what made
        // `ROLLUP_DIGEST_MISMATCH` unreachable for those sections (M-12).
        XCTAssertEqual(rollups.count, MIFSection.allCases.count)
        let headers = try XCTUnwrap(manifest["sections"] as? [[String: Any]])
        for header in headers {
            let name = try XCTUnwrap(header["name"] as? String)
            let digest = try XCTUnwrap(header["rollup_digest"] as? String, "\(name) declares none")
            XCTAssertEqual(digest.count, 64, name)
            XCTAssertEqual(
                digest,
                rollups.first { $0["section"] as? String == name }?["rollup_digest"] as? String,
                "\(name): the header and rollups[] disagree"
            )
        }

        for rollup in rollups {
            let name = try XCTUnwrap(rollup["section"] as? String)
            let section = try XCTUnwrap(MIFSection(rawValue: name))
            let tuple = try XCTUnwrap(rollup["tuple"] as? [String])
            XCTAssertEqual(tuple, section.rollupTuple, name)

            // Recompute the digest the way an IMPORTER would: resolve each
            // declared name against the bundle's own records, joining across
            // sections exactly where the importer has to. If the tuple named a
            // value the bundle cannot reproduce, this is where it would hold.
            let rows = (result.sectionBuffers[section]?.records ?? []).map { record in
                tuple.map { key in Self.rollupValue(key, of: record) }
            }
            XCTAssertEqual(rows.count, rollup["row_count"] as? Int, name)
            XCTAssertEqual(
                MemoryExportBundleWriter.rollupDigest(rows),
                rollup["rollup_digest"] as? String,
                "\(name): the declared tuple does not reproduce the declared digest"
            )
        }
    }

    /// One declared tuple element, resolved the way an importer resolves it:
    /// a member lookup on the record, keeping the JSON TYPE — Q-51 (ii) orders
    /// numbers numerically and nulls first, so a stringified `byte_len` would
    /// sort and digest differently. An absent member is `null` (Q-51 (iii)),
    /// never a skipped row, and an EMPTY declared name is the literal empty
    /// string, which is section 04's third leg and nothing else.
    private static func rollupValue(_ key: String, of record: MIFJSON) -> MIFJSON {
        guard case .object(let fields) = record else { return .null }
        return key.isEmpty ? .string("") : (fields[key] ?? .null)
    }

    // MARK: - D-0031: roll-up order and encoding, the one root

    /// The digest is over the tuples sorted MEMBER BY MEMBER — Q-51 (i) and
    /// (ii) — as the JCS encoding of the array of arrays, so row emission order
    /// cannot move it.
    ///
    /// "Ordered by the tuple's first member" is not an order when two rows share
    /// one, which is the defect this replaced: two implementations sorting a tie
    /// differently produce different digests from the same rows, and the
    /// importer holds `ROLLUP_DIGEST_MISMATCH` with nothing to diagnose.
    func test_rollupDigestSortsMemberByMemberInJSONValueOrder() {
        let shuffled: [[MIFJSON]] = [
            [.string("mem_b"), .string("jk_b"), .string("nd_b")],
            [.string("mem_a"), .string("jk_a"), .string("nd_a")]
        ]
        let ordered: [[MIFJSON]] = [
            [.string("mem_a"), .string("jk_a"), .string("nd_a")],
            [.string("mem_b"), .string("jk_b"), .string("nd_b")]
        ]
        XCTAssertEqual(
            MemoryExportBundleWriter.rollupDigest(shuffled),
            MemoryExportBundleWriter.rollupDigest(ordered)
        )
        XCTAssertEqual(
            MemoryExportBundleWriter.rollupDigest(ordered),
            MemoryExportDigest.sha256Hex(Data(#"[["mem_a","jk_a","nd_a"],["mem_b","jk_b","nd_b"]]"#.utf8))
        )

        // A tie on the first member is decided by the second, and on the second
        // by the third: the whole point of (i).
        let tied: [[MIFJSON]] = [
            [.string("t"), .string("peer-b"), .int(2)],
            [.string("t"), .string("peer-a"), .int(9)]
        ]
        XCTAssertEqual(
            MemoryExportBundleWriter.rollupDigest(tied),
            MemoryExportDigest.sha256Hex(Data(#"[["t","peer-a",9],["t","peer-b",2]]"#.utf8))
        )

        // (ii) null first, then booleans, then numbers NUMERICALLY, then
        // strings. `10` before `9` would be the string reading.
        let typed: [[MIFJSON]] = [
            [.string("s"), .int(10)],
            [.string("s"), .int(9)],
            [.null, .int(0)],
            [.string("s"), .bool(true)]
        ]
        XCTAssertEqual(
            MemoryExportBundleWriter.rollupDigest(typed),
            MemoryExportDigest.sha256Hex(Data(#"[[null,0],["s",true],["s",9],["s",10]]"#.utf8))
        )

        // (iii) an absent member is null and a shorter tuple sorts first.
        XCTAssertTrue(MemoryExportBundleWriter.precedes([.string("a")], [.string("a"), .null]))

        // The declared tuples are the ruling's, in the ruling's order.
        XCTAssertEqual(MIFSection.memories.rollupTuple, ["memory_id", "body_join_key", "body_norm_digest"])
        XCTAssertEqual(MIFSection.reviewEvents.rollupTuple, ["event_id", "memory_id", "to_status"])
        XCTAssertEqual(MIFSection.bodies.rollupTuple, ["body_join_key", "body_norm_digest", "byte_len"])
        XCTAssertEqual(MIFSection.findings.rollupTuple, ["code", "severity", "count", "detail"])
        XCTAssertEqual(MIFSection.projects.rollupTuple, ["project_id", "fingerprint", ""])
    }

    /// Q-51's rule that every tuple names members the SCHEMA defines, checked
    /// against the vendored contract rather than against this file's memory of
    /// it. A tuple naming a member no record type has is a digest of nulls —
    /// which is how eight sections came to have no honest digest at all.
    func test_everyRollupTupleNamesMembersTheContractDefines() throws {
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try contractData()) as? [String: Any]
        )
        for section in MIFSection.allCases {
            let pointer = section.recordTypePointer.replacingOccurrences(of: "#/$defs/", with: "")
            let properties = try XCTUnwrap(
                ((schema["$defs"] as? [String: Any])?[pointer] as? [String: Any])?["properties"]
                    as? [String: Any],
                pointer
            )
            for member in section.rollupTuple where member.isEmpty == false {
                XCTAssertNotNil(
                    properties[member],
                    "\(section.rawValue): `\(member)` is not a member of \(pointer)"
                )
            }
        }
    }

    // MARK: - The delete obligation and the gate

    func test_deleteOfAQuarantinedRowSynthesizesATombstone() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        let result = try makeExporter().export(
            snapshot,
            mode: .dryRun,
            to: nil,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "delete")
        )
        // Without this the row would live in the target forever while every
        // count balanced.
        XCTAssertEqual(result.report.deleteWithoutTombstoneSynthesized, 1)
        XCTAssertTrue(result.report.findings.contains { $0.code == .deleteWithoutTombstoneSynthesized })
    }

    func test_aSecretInABodyIsHeldAndNeverCarriedVerbatim() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        // A synthetic, obviously-fake credential shape. The point is the gate's
        // classification, not the value.
        let secret = "sk-ant-api03-" + String(repeating: "A", count: 80)
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(db, id: "S1", body: "The key is \(secret) and it rotates.")
        }
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        // NOT `XCTSkipUnless`. This is the strongest security assertion in the
        // suite, and XCTest counts a skip as a pass — so on a machine where the
        // corpus resource does not resolve, the green run proved nothing, which
        // is the same fail-open shape §6 refuses for `python3 -c 'import
        // jsonschema'`. The corpus is a `Bundle.module` resource of a target
        // this one depends on: absent, it is a packaging defect, not a fact
        // about the machine (review F-15).
        XCTAssertTrue(
            MemoryExportGateRunner.shared.isAvailable(),
            "the shared secret corpus must load in this test bundle; a skip here would hide "
                + "the one assertion that proves a credential never reaches a sealed body"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try makeExporter(gate: .shared).export(
            snapshot,
            mode: .full,
            to: directory,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "gate")
        )
        let tally = result.report.gateClasses
        XCTAssertEqual(tally.total, 1, "no class drops a row")
        XCTAssertEqual(tally.total, result.report.gateClasses.reject + tally.redact + tally.hold)
        XCTAssertTrue(result.report.findings.contains { $0.code == .secretGateHeld })

        // The sealed body must not contain the credential. Reading it back
        // through the segment key is the only way to prove that.
        let sealed = try Data(contentsOf: directory
            .appendingPathComponent("sections/06-bodies/00000.seg"))
        let opened = try MemoryExportCrypto.open(
            sealedChunk: sealed,
            section: .bodies,
            segmentKey: MemoryExportCrypto.segmentKey(
                bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "gate"),
                section: .bodies
            ),
            index: 0
        )
        XCTAssertFalse(String(decoding: opened, as: UTF8.self).contains(secret))
    }

    func test_anUnavailableGateRefusesTheExportRatherThanRedactingEverything() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        XCTAssertThrowsError(
            try makeExporter(gate: .unavailable).export(snapshot, mode: .dryRun, to: nil)
        ) { error in
            XCTAssertEqual(error as? MemoryExporterError, .held([.gateUnavailable]))
        }
    }

    func test_theFeatureFlagIsOffByDefault() throws {
        XCTAssertFalse(MemoryExportFeatureFlag.isEnabled { _ in nil })
        XCTAssertFalse(MemoryExportFeatureFlag.isEnabled { _ in "maybe" })
        XCTAssertTrue(MemoryExportFeatureFlag.isEnabled { _ in "true" })

        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        var exporter = makeExporter()
        exporter.options.enabled = false
        XCTAssertThrowsError(try exporter.export(snapshot, mode: .dryRun, to: nil)) { error in
            XCTAssertEqual(error as? MemoryExporterError, .featureDisabled)
        }
    }

    // MARK: - Orphans

    func test_orphansAreCountedAlwaysAndCarriedOnlyWhenAsked() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        let key = MemoryExportCrypto.deterministicBundleKey(seed: "orphans")

        let notCarried = try makeExporter().export(snapshot, mode: .dryRun, to: nil, bundleKey: key)
        XCTAssertEqual(notCarried.report.orphanBodies, 1, "an orphan is ALWAYS counted")
        XCTAssertTrue(notCarried.report.findings.contains { $0.code == .orphanBody })
        let carriedByDefault = notCarried.sectionBuffers[.memories]?.records.count ?? 0

        var exporter = makeExporter()
        exporter.options.carryOrphans = true
        let carried = try exporter.export(snapshot, mode: .dryRun, to: nil, bundleKey: key)
        XCTAssertEqual(carried.report.orphanBodies, 1)
        // A carried orphan BECOMES a synthetic row — it cannot exist in the
        // target any other way, and the record says so.
        XCTAssertEqual(carried.sectionBuffers[.memories]?.records.count, carriedByDefault + 1)

        let validator = try MIFSchemaValidator(schemaData: try contractData())
        for section in [MIFSection.memories, .bodies, .provenance] {
            let plaintext = MemoryExportBundleWriter.ndjson(sectionBuffer(carried, section: section))
            for line in String(decoding: plaintext, as: UTF8.self).split(separator: "\n") {
                let record = try JSONSerialization.jsonObject(with: Data(line.utf8))
                XCTAssertNoThrow(
                    try validator.validate(record, against: section.recordTypePointer),
                    "a synthetic orphan record must satisfy the same contract"
                )
            }
        }
    }

    /// F-2, the one that corrupts truth. A `forgotten` row leaves as a section-00
    /// tombstone and never appears in 05 — but its `memory_body_snapshots` row
    /// survives the forget, and it was counted as an orphan because the
    /// referenced-set was only written inside the resolved-body path. With
    /// `--carry-orphans` that orphan was then re-minted as a synthetic
    /// `quarantined` memory under the SAME canonical id the tombstone names, and
    /// because sections apply in rank order the tombstone landed first and the
    /// memory after it. The forget was undone, and every count balanced.
    func test_aForgottenMemoryStaysForgottenEvenWithCarryOrphans() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "forgotten-but-bodied",
                body: "A thing the user asked to forget.",
                reviewStatus: "forgotten"
            )
        }
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        var exporter = makeExporter()
        exporter.options.carryOrphans = true
        let result = try exporter.export(
            snapshot,
            mode: .full,
            to: nil,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "forget")
        )

        let tombstoned = Set(
            (result.sectionBuffers[.tombstones]?.records ?? []).compactMap { record -> String? in
                guard case .object(let fields) = record,
                      case .string(let id) = fields["subject_memory_id"] ?? .null else { return nil }
                return id
            }
        )
        XCTAssertEqual(tombstoned.count, 1, "the forgotten row leaves as a tombstone")

        let carried = Set(
            (result.sectionBuffers[.memories]?.records ?? []).compactMap { record -> String? in
                guard case .object(let fields) = record,
                      case .string(let id) = fields["memory_id"] ?? .null else { return nil }
                return id
            }
        )
        XCTAssertTrue(
            carried.isDisjoint(with: tombstoned),
            "a tombstoned id must never also arrive as a memory: sections apply in rank order, "
                + "so the memory would land after the tombstone and undo the forget"
        )
        XCTAssertTrue(result.report.noResurrectedTombstone)

        // The body row is not an orphan at all: an authority row references it.
        // Orphanhood is a fact about `agent_memories`, not about whether this
        // export happened to resolve a body from the row.
        XCTAssertEqual(result.report.orphanBodies, 0)
    }

    /// F-4. `manifest.not_exported` is the per-reason SUM over every logical
    /// table's own not-exported **source rows** — §10's closed sum is per table
    /// (`source_rows == exported + Σ not_exported[reason]`), and the manifest
    /// carries the roll-up of those sums. So one forgotten memory contributes
    /// TWO rows, in two tables: the `agent_memories` row and the
    /// `memory_body_snapshots` row that was left behind by the forget. It is a
    /// row count, and never a count of the records the bundle carries — which is
    /// one tombstone.
    ///
    /// The review read `forgotten_to_tombstone: 2` as a record count and found
    /// one tombstone. Both numbers are right; this test pins which is which, and
    /// `verify` now names `not_exported` when the manifest and the report
    /// disagree about it.
    func test_notExportedCountsSourceRowsAcrossTablesNotRecords() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "forgotten-but-bodied",
                body: "A thing the user asked to forget.",
                reviewStatus: "forgotten"
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try makeExporter().export(
            try MemoryExportFixtureStore.snapshot(queue),
            mode: .full,
            to: directory,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "not-exported")
        )

        // One tombstone RECORD in the bundle.
        XCTAssertEqual(result.sectionBuffers[.tombstones]?.records.count, 1)

        // Two source ROWS not exported, in two tables, each balancing its own
        // closed sum.
        let byTable = Dictionary(uniqueKeysWithValues: result.report.tables.map { ($0.name, $0) })
        XCTAssertEqual(byTable["agent_memories"]?.notExported[.forgottenToTombstone], 1)
        XCTAssertEqual(byTable["memory_body_snapshots"]?.notExported[.forgottenToTombstone], 1)
        for name in ["agent_memories", "memory_body_snapshots"] {
            XCTAssertTrue(try XCTUnwrap(byTable[name]).isBalanced, "\(name) balances over its own source rows")
        }

        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        let notExported = try XCTUnwrap(manifest["not_exported"] as? [String: Int])
        XCTAssertEqual(
            notExported["forgotten_to_tombstone"],
            2,
            "the manifest sums the tables' source rows: agent_memories 1 + memory_body_snapshots 1"
        )

        // And the two documents agree, which is what makes the number checkable
        // on the wire rather than merely declared.
        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: nil,
            recipient: recipient
        )
        XCTAssertFalse(
            verification.problems.contains { $0.contains("not_exported") },
            verification.problems.joined(separator: "; ")
        )
    }

    /// The same store WITHOUT the forget: the row is carried, so the fix did not
    /// simply stop carrying things.
    func test_theSameRowIsCarriedWhenItWasNeverForgotten() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "forgotten-but-bodied",
                body: "A thing the user asked to forget.",
                reviewStatus: "quarantined"
            )
        }
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        var exporter = makeExporter()
        exporter.options.carryOrphans = true
        let result = try exporter.export(
            snapshot,
            mode: .full,
            to: nil,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "kept")
        )
        XCTAssertEqual(result.sectionBuffers[.memories]?.records.count, 1)
        XCTAssertEqual(result.report.orphanBodies, 0)
    }

    // MARK: - Delta

    /// The old version of this test asserted a digest INEQUALITY and one zero
    /// count, and both held with the memory window fully open — which is why
    /// F-4 stayed green while every delta was a full export. It counts rows now.
    func test_aDeltaCarriesOnlyRowsAboveBothHalvesOfTheWindow() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        let key = MemoryExportCrypto.deterministicBundleKey(seed: "delta")
        let full = try makeExporter().export(snapshot, mode: .full, to: nil, bundleKey: key)
        XCTAssertGreaterThan(full.sectionBuffers[.memories]?.records.count ?? 0, 1)

        // Everything in the fixture is at or below both halves of this window,
        // so a real delta carries no memory at all.
        let watermark = Int(Date(timeIntervalSince1970: 4_102_444_800).timeIntervalSince1970 * 1000)
        let empty = try makeExporter().export(
            snapshot,
            mode: .delta(sinceAuditSeq: snapshot.auditHeadSeq, sinceUpdatedAtMS: watermark),
            to: nil,
            bundleKey: key
        )
        XCTAssertEqual(empty.sectionBuffers[.memories]?.records.count, 0, "a delta past the head carries nothing")
        XCTAssertEqual(empty.report.deleteWithoutTombstoneSynthesized, 0)
        let outOfWindow = empty.report.tables
            .first { $0.name == "agent_memories" }?
            .notExported[.outOfWindow] ?? 0
        XCTAssertEqual(outOfWindow, snapshot.memories.count, "every row is recorded as out of window")

        // And a window that opens just before the newest row carries exactly it.
        // `label-only` and the daemon row sit at 2026-01-01; `proven-human` was
        // updated a day later.
        let dayOne = MemoryExportTimestamp.parse("2026-01-01T12:00:00.000Z")
        let one = try makeExporter().export(
            snapshot,
            mode: .delta(
                sinceAuditSeq: snapshot.auditHeadSeq,
                // reason: a literal ISO timestamp
                // swiftlint:disable:next force_unwrapping
                sinceUpdatedAtMS: Int((dayOne!.timeIntervalSince1970 * 1000).rounded())
            ),
            to: nil,
            bundleKey: key
        )
        let carried = (one.sectionBuffers[.memories]?.records ?? []).compactMap { record -> String? in
            guard case .object(let fields) = record,
                  case .string(let id) = fields["memory_id"] ?? .null else { return nil }
            return id
        }
        XCTAssertEqual(carried.count, 1, "only the row updated after the watermark")
        XCTAssertEqual(
            carried.first,
            MemoryExportIdentity.canonicalMemoryID("proven-human", storeID: storeID)
        )
    }

    /// M-20, and F-10. A delta drops audit rows at or below the watermark, but a
    /// carried row proven `human` cites one by `audit_seq`, and the importer
    /// verifies that seq exists in section 09, re-hashes it, and REFUSES the
    /// human claim otherwise. Dropping it downgrades exactly the verdicts the
    /// migration exists to preserve.
    func test_aDeltaKeepsTheAuditRowItsOwnReviewEventNames() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        // A window that excludes every audit row, but whose memory half still
        // carries `proven-human` — the exact shape that lost the evidence.
        let dayOne = try XCTUnwrap(MemoryExportTimestamp.parse("2026-01-01T12:00:00.000Z"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try makeExporter().export(
            snapshot,
            mode: .delta(
                sinceAuditSeq: snapshot.auditHeadSeq,
                sinceUpdatedAtMS: Int((dayOne.timeIntervalSince1970 * 1000).rounded())
            ),
            to: directory,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "m20")
        )
        XCTAssertEqual(result.report.auditProvenHuman, 1)

        let cited = (result.sectionBuffers[.memories]?.records ?? []).compactMap { record -> Int? in
            guard case .object(let fields) = record,
                  case .int(let seq) = fields["verdict_audit_seq"] ?? .null else { return nil }
            return seq
        }
        XCTAssertEqual(cited.count, 1)
        let carriedSeqs = Set((result.sectionBuffers[.auditEvidence]?.records ?? []).compactMap { record -> Int? in
            guard case .object(let fields) = record,
                  case .int(let seq) = fields["peer_seq"] ?? .null else { return nil }
            return seq
        })
        XCTAssertTrue(
            carriedSeqs.isSuperset(of: cited),
            "section 09 must carry every audit_seq a human-origin row names, window or no window"
        )
        // And the manifest marks 09 `required: true` the moment any record claims
        // human origin, so an importer that does not know the section refuses
        // the bundle rather than applying an unproven verdict.
        let manifest = try XCTUnwrap(try json(at: directory.appendingPathComponent("manifest.json")) as? [String: Any])
        let headers = try XCTUnwrap(manifest["sections"] as? [[String: Any]])
        let nine = try XCTUnwrap(headers.first { $0["name"] as? String == MIFSection.auditEvidence.rawValue })
        XCTAssertEqual(nine["required"] as? Bool, true)
        XCTAssertEqual(nine["row_count"] as? Int, carriedSeqs.count)
    }

    // MARK: - Reconciliation

    /// F-18. `source_rows` used to be incremented after the fact — once per
    /// supersession edge, once per path alias, once per carried orphan — so it
    /// stopped meaning "rows in the source table" and the closed sum was closed
    /// by construction rather than checked. It also counted every body that
    /// reached section 06 against `memory_body_snapshots`, including bodies
    /// recovered from two other tables, so that row did NOT balance and the
    /// fixture bundle was `held` the whole time without a test noticing.
    func test_everyTableBalancesOverItsOwnSourceRows() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        var exporter = makeExporter()
        exporter.options.carryOrphans = true
        let result = try exporter.export(
            snapshot,
            mode: .full,
            to: nil,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "reconcile")
        )

        for table in result.report.tables {
            XCTAssertTrue(
                table.isBalanced,
                "\(table.name): \(table.sourceRows) source rows vs \(table.exported) exported "
                    + "+ \(table.notExported) + \(table.rejected)"
            )
        }
        XCTAssertTrue(result.report.reconciles)
        XCTAssertEqual(result.report.decision, .exported)

        func table(_ name: String) throws -> MemoryExportTableReconciliation {
            try XCTUnwrap(result.report.tables.first { $0.name == name })
        }
        // The numbers are the source tables' own row counts, unadjusted.
        XCTAssertEqual(try table("agent_memories").sourceRows, snapshot.memories.count)
        XCTAssertEqual(try table("memory_body_snapshots").sourceRows, snapshot.bodySnapshots.count)
        // R3. The fixture inserts NO `memory_fact_tombstones` row, and this
        // used to read 1 because the synthesized delete tombstone bumped both
        // sides of that table's sum on one edge. The delete lane is its own
        // logical table now, counted over the `memory.delete` audit rows.
        XCTAssertEqual(try table("memory_fact_tombstones").sourceRows, 0, "the fixture writes none")
        XCTAssertEqual(try table("memory_audit.delete").sourceRows, 1)
        XCTAssertEqual(try table("memory_audit.delete").exported, 1, "the synthesized delete tombstone")

        // A carried orphan is a `memory_body_snapshots` row that was exported,
        // and a synthetic section-05 record. It is not an `agent_memories` row,
        // and it no longer pretends to be one.
        XCTAssertEqual(result.report.syntheticOrphanMemories, 1)
        XCTAssertEqual(
            result.report.memoriesOut,
            (result.sectionBuffers[.memories]?.records.count ?? 0),
            "memories_out is what section 05 carries"
        )
        // Edges and aliases have their own rows now, whether or not this fixture
        // exercises them.
        XCTAssertNotNil(result.report.tables.first { $0.name == "agent_memories.superseded_by" })
        XCTAssertNotNil(result.report.tables.first { $0.name == "pcm_project_aliases" })
    }

    /// A rehearsal bundle is addressed to NO store, and D-0039 ruling 7's
    /// pattern is what makes that visible: `recipient_store_id` is the `null`
    /// the member admits rather than a `sto_` id no store holds.
    ///
    /// `--rehearsal` mints a throwaway recipient and discards the private half,
    /// so the bundle cannot be imported anywhere and `report.json` says so. Its
    /// store id used to be the literal `rehearsal:no-target-store`, which the
    /// re-vendored contract rejects — and minting one would be a bundle
    /// claiming a target that does not exist.
    func test_aRehearsalBundleNamesNoRecipientStore() throws {
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        var exporter = makeExporter()
        exporter.recipient = MemoryExportRecipient.rehearsalThrowaway()
        exporter.options.rehearsal = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try exporter.export(
            try MemoryExportFixtureStore.snapshot(try makeStore()),
            mode: .full,
            to: directory,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "rehearsal-store")
        )

        let manifest = try XCTUnwrap(
            try json(at: directory.appendingPathComponent("manifest.json")) as? [String: Any]
        )
        XCTAssertTrue(manifest["recipient_store_id"] is NSNull, "addressed to no store")
        XCTAssertEqual(manifest["rehearsal"] as? Bool, true)
        try validator.validate(manifest, against: "#/$defs/manifest")
        XCTAssertTrue(result.report.recipientIsRehearsalThrowaway)

        // …and `verify` does not complain about a store id that is not there.
        // (No signing key is passed, so it reports the signature it cannot
        // check; the assertion below is about the store id alone.)
        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: directory,
            signingPublicKey: nil
        )
        XCTAssertFalse(
            verification.problems.contains { $0.contains("recipient_store_id") },
            "\(verification.problems)"
        )
    }

    /// M-8 + D-0039 ruling 5: §10's closed sum covers all ELEVEN sections.
    ///
    /// Interop run 1 found three sections carrying rows that no lane in
    /// `report.json.tables[]` mentioned — 00 (a forgotten memory's tombstone,
    /// while both tombstone tables reported `exported: 0`), 02 (one review
    /// event) and 09 (two audit rows) — plus 01 and 10, which the fixture
    /// happened not to exercise. §10's identity is a sum over lanes, so a
    /// carried row outside every lane is a row no sum covers, which is exactly
    /// what the identity exists to forbid.
    ///
    /// Every record now names its lane as it is appended, and this reads that
    /// attribution back off the buffers: nothing carried is unattributed,
    /// nothing writes into a section its lane does not declare, and every
    /// section has at least one lane in the report.
    func test_everyCarriedRowBelongsToALaneAndEverySectionHasOne() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        var exporter = makeExporter()
        exporter.options.carryOrphans = true
        let result = try exporter.export(
            snapshot,
            mode: .full,
            to: nil,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "lanes")
        )
        XCTAssertEqual(result.report.decision, .exported, "the coverage identity holds")

        let declared = Set(result.report.tables.map(\.lane))
        for section in MIFSection.allCases {
            XCTAssertFalse(section.lanes.isEmpty, "\(section.rawValue) has no lane at all")
            for lane in section.lanes {
                XCTAssertTrue(
                    declared.contains(lane),
                    "\(section.rawValue): report.json does not carry lane \(lane.rawValue)"
                )
            }
            let buffer = try XCTUnwrap(result.sectionBuffers[section])
            XCTAssertEqual(
                buffer.attribution.values.reduce(0, +),
                buffer.records.count,
                "\(section.rawValue): every carried row is attributed to a lane"
            )
            for lane in buffer.attribution.keys {
                XCTAssertTrue(
                    lane.sections.contains(section),
                    "\(lane.rawValue) wrote into \(section.rawValue), which it does not declare"
                )
            }
        }

        // The five sections that had no lane, by their own numbers.
        func rows(_ section: MIFSection) throws -> Int {
            try XCTUnwrap(result.sectionBuffers[section]).records.count
        }
        func lane(_ lane: MIFReconciliationLane) throws -> MemoryExportTableReconciliation {
            try XCTUnwrap(result.report.tables.first { $0.lane == lane })
        }
        // 00: the fixture's tombstone comes from the forget path and from the
        // `memory.delete` audit row, and the two lanes account for both.
        XCTAssertGreaterThan(try rows(.tombstones), 0)
        XCTAssertEqual(
            try lane(.agentMemoriesForgotten).exported
                + lane(.memoryFactTombstones).exported
                + lane(.memorySourceTombstones).exported
                + lane(.memoryAuditDelete).exported,
            try rows(.tombstones)
        )
        // The forget path's source rows are the same rows `agent_memories`
        // reports as `forgotten_to_tombstone` — one obligation seen from both
        // sides, which is what keeps the second lane from inventing rows.
        XCTAssertEqual(
            try lane(.agentMemoriesForgotten).sourceRows,
            try lane(.agentMemories).notExported[.forgottenToTombstone] ?? 0
        )
        // 02: one proven human verdict, from one `memory.reject` audit row.
        XCTAssertEqual(try lane(.memoryAuditReview).exported, try rows(.reviewEvents))
        XCTAssertGreaterThan(try lane(.memoryAuditReview).sourceRows, 0)
        // 09: the audit rows themselves.
        XCTAssertEqual(try lane(.memoryAudit).exported, try rows(.auditEvidence))
        XCTAssertEqual(try lane(.memoryAudit).sourceRows, snapshot.auditRows.count)
        // 01 and 10.
        XCTAssertEqual(try lane(.memoryFactTombstoneReceipts).exported, try rows(.tombstoneReceipts))
        XCTAssertEqual(try lane(.reportFindings).exported, try rows(.findings))
        XCTAssertEqual(try lane(.reportFindings).sourceRows, result.report.findings.count)
        XCTAssertEqual(try lane(.embeddingVersions).exported, try rows(.embeddings))

        // And every lane still balances over its OWN source rows: a lane added
        // to close the coverage identity must not close it by inventing rows.
        for table in result.report.tables {
            XCTAssertTrue(table.isBalanced, "\(table.name) does not balance")
        }

        // Interop run 1's section-00 case exactly: a store whose ONLY tombstone
        // comes from the forget path, so both tombstone tables report
        // `exported: 0` while section 00 carries a row. That row belonged to no
        // lane; it belongs to this one.
        let forgetting = try MemoryExportFixtureStore.makeQueue()
        try forgetting.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "forgotten-row",
                body: "A fact the user asked to forget.",
                reviewStatus: "forgotten"
            )
        }
        let forgotten = try makeExporter().export(
            try MemoryExportFixtureStore.snapshot(forgetting),
            mode: .full,
            to: nil,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "forget-lane")
        )
        let tombstones = try XCTUnwrap(forgotten.sectionBuffers[.tombstones])
        XCTAssertEqual(tombstones.records.count, 1)
        XCTAssertEqual(tombstones.attribution[.agentMemoriesForgotten], 1)
        XCTAssertEqual(forgotten.sectionBuffers[.memories]?.records.count, 0, "a forget is not a memory")

        func forgottenLane(_ lane: MIFReconciliationLane) throws -> MemoryExportTableReconciliation {
            try XCTUnwrap(forgotten.report.tables.first { $0.lane == lane })
        }
        XCTAssertEqual(try forgottenLane(.memoryFactTombstones).exported, 0)
        XCTAssertEqual(try forgottenLane(.memorySourceTombstones).exported, 0)
        XCTAssertEqual(try forgottenLane(.memoryAuditDelete).exported, 0)
        XCTAssertEqual(try forgottenLane(.agentMemoriesForgotten).sourceRows, 1)
        XCTAssertEqual(try forgottenLane(.agentMemoriesForgotten).exported, 1)
        XCTAssertEqual(forgotten.report.decision, .exported)
    }

    /// R3. A row the reader COUNTED and the export never saw.
    ///
    /// The reader takes `SELECT COUNT(*)` on its own edge, before the rows; a
    /// concurrent `DELETE` between the two leaves the export one row short. The
    /// shortfall is deliberately given NO bucket — a bucket would close the sum
    /// again, which is exactly how `balanced` became true for any input — so the
    /// table fails its closed sum, a `source_unreadable` finding names it, and
    /// the bundle is `held` rather than `exported`.
    ///
    /// The delete is simulated by handing the exporter the count the reader
    /// would have taken a moment earlier, because both halves happen inside one
    /// GRDB read transaction and a fixture cannot slip a writer between them.
    func test_aRowCountedByTheReaderAndMissingFromTheRowsFailsTheClosedSum() throws {
        var snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        XCTAssertEqual(
            snapshot.sourceRowCounts["agent_memories"],
            snapshot.memories.count,
            "the reader's count and its rows agree on an undisturbed store"
        )
        snapshot.sourceRowCounts["agent_memories"] = snapshot.memories.count + 1

        let result = try makeExporter().export(
            snapshot,
            mode: .full,
            to: nil,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "vanished")
        )
        let memories = try XCTUnwrap(result.report.tables.first { $0.name == "agent_memories" })
        XCTAssertFalse(memories.isBalanced, "the closed sum is short by the vanished row")
        XCTAssertEqual(memories.sourceRows, memories.accountedRows + 1)
        XCTAssertFalse(result.report.reconciles)
        XCTAssertEqual(result.report.decision, .held)
        XCTAssertTrue(result.report.holdReasons.contains(.reconciliationMismatch))
        XCTAssertTrue(
            result.report.findings.contains { $0.code == .sourceUnreadable },
            "the report names the table that did not balance"
        )
        // And it reaches the artefact a reader actually opens.
        guard case .object(let json) = result.report.json,
              case .array(let tables) = json["tables"] ?? .null else {
            XCTFail("the report has no tables array")
            return
        }
        XCTAssertTrue(tables.contains { table in
            guard case .object(let fields) = table,
                  case .string("agent_memories") = fields["name"] ?? .null else { return false }
            return fields["balanced"] == .bool(false)
        }, "report.json carries balanced: false for agent_memories")

        // And the HELD report validates: its `hold_reasons` exercise the
        // re-vendored `hold_reason` anyOf (Q-26), which an always-clean
        // fixture bundle never reaches — an anyOf no failing instance ever
        // touches is the fail-open mode the pin test exists to prevent.
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        let heldReport = try JSONSerialization.jsonObject(
            with: Data(MIFCanonicalJSON.serialize(result.report.json).utf8)
        )
        XCTAssertNoThrow(
            try validator.validate(heldReport, against: "#/$defs/reconciliation_report"),
            "a held report's RECONCILIATION_MISMATCH must satisfy the contract's hold vocabulary"
        )
    }

    /// F-12. `lost.csv` names a row by its CANONICAL id, and that id used to
    /// appear nowhere else in the bundle — the mapping was only recorded in the
    /// resolved-body path, which an unreconstructible row never reaches. The
    /// operator could not map the name back to the oracle row, which is the
    /// entire purpose of naming it (M-29).
    func test_everyRewrittenIDIsInTheIDMapIncludingLostAndTombstonedRows() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            // An app-lane row (UUID id, so always rewritten) with no body row at
            // all: unreconstructible, and named in lost.csv.
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "78E5A7B2-0000-4000-8000-000000000001",
                body: "never stored",
                writeBodySnapshot: false
            )
            // A forgotten row, whose tombstone subject is rewritten too.
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "78E5A7B2-0000-4000-8000-000000000002",
                body: "forgotten",
                reviewStatus: "forgotten"
            )
        }
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try makeExporter().export(
            snapshot,
            mode: .full,
            to: directory,
            bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "idmap")
        )
        XCTAssertEqual(result.report.bodiesUnreconstructible, 1)

        let idMap = try String(contentsOf: directory.appendingPathComponent("id-map.csv"), encoding: .utf8)
        let mapped = Set(idMap.split(separator: "\n").dropFirst().compactMap { line -> String? in
            line.split(separator: ",").last.map(String.init)
        })
        let lost = try String(contentsOf: directory.appendingPathComponent("lost.csv"), encoding: .utf8)
        let lostIDs = Set(lost.split(separator: "\n").dropFirst().compactMap { line -> String? in
            line.split(separator: ",").first.map(String.init)
        })
        XCTAssertEqual(lostIDs.count, 1)
        XCTAssertTrue(lostIDs.isSubset(of: mapped), "a lost id must be mappable back to its oracle row")

        let tombstoned = Set((result.sectionBuffers[.tombstones]?.records ?? []).compactMap { record -> String? in
            guard case .object(let fields) = record,
                  case .string(let id) = fields["subject_memory_id"] ?? .null else { return nil }
            return id
        })
        XCTAssertEqual(tombstoned.count, 1)
        XCTAssertTrue(tombstoned.isSubset(of: mapped), "a rewritten tombstone subject is a rewrite too")
    }

    // MARK: - Helpers

    private func contractData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "mif-v1.schema", withExtension: "json"),
            "the embedded contract copy is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    private func json(at url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
    }

    private func sectionBuffer(_ result: MemoryExportBundleResult, section: MIFSection) -> MemoryExportSectionBuffer {
        result.sectionBuffers[section] ?? MemoryExportSectionBuffer(section: section)
    }

    /// One valid `record_memory`, as Foundation JSON, so a test can mutate a
    /// single field and prove the contract catches it.
    private func sampleMemoryRecord() throws -> Any {
        let record = MemoryExportRecords.memoryRecord(
            memory: MemoryExportMemoryRow(
                id: "mem_" + String(repeating: "f", count: 32),
                projectID: "chat:user-1",
                bodyRef: "memory_body_snapshots:memory-x",
                validFrom: "2026-01-01T00:00:00.000Z",
                createdAt: "2026-01-01T00:00:00.000Z",
                updatedAt: "2026-01-01T00:00:00.000Z",
                userID: "user-1",
                appID: "app-1"
            ),
            classification: MemoryExportClassifier.classify(MemoryExportClassifierInput(
                memory: MemoryExportMemoryRow(
                    id: "mem_" + String(repeating: "f", count: 32),
                    projectID: "chat:user-1",
                    bodyRef: "memory_body_snapshots:memory-x",
                    validFrom: "2026-01-01T00:00:00.000Z",
                    createdAt: "2026-01-01T00:00:00.000Z",
                    updatedAt: "2026-01-01T00:00:00.000Z",
                    userID: "user-1",
                    appID: "app-1"
                )
            )),
            body: MemoryExportResolvedBody(
                body: "a body",
                convention: .snapshotSlug,
                integrity: .verified,
                recoveredFrom: .memoryBodySnapshots,
                findings: [],
                fromQuarantineStore: false
            ),
            gate: .clean("a body"),
            context: MemoryExportRecordContext(
                storeID: storeID,
                userID: "user-1",
                bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "sample")
            ),
            scope: MemoryExportScope(
                kind: .user,
                key: "user-1",
                userID: "user-1",
                projectFingerprint: nil,
                isPseudoProject: true
            )
        )
        return try JSONSerialization.jsonObject(with: MIFCanonicalJSON.data(record))
    }
}
