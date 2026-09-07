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
    static let recipientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    var recipient: MemoryExportRecipient {
        MemoryExportRecipient(
            keyID: MemoryExportRecipient.keyID(for: Self.recipientPrivateKey.publicKey),
            publicKey: Self.recipientPrivateKey.publicKey,
            storeID: "target-store-fixture"
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
        XCTAssertEqual(first.contentDigest, second.contentDigest)
        XCTAssertEqual(first.bundleID, second.bundleID)
        XCTAssertEqual(first.determinismDigest, second.determinismDigest)
        XCTAssertEqual(first.report.countsHash, second.report.countsHash)

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
        XCTAssertEqual(dry.contentDigest, real.contentDigest)
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

        // The manifest and the report are the two documents the contract's
        // top-level `oneOf` names.
        let manifest = try json(at: directory.appendingPathComponent("manifest.json"))
        try validator.validate(manifest, against: "#/$defs/manifest")
        let report = try json(at: directory.appendingPathComponent("report.json"))
        try validator.validate(report, against: "#/$defs/reconciliation_report")

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
        XCTAssertFalse(rollups.isEmpty)

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
                tuple.map { key in Self.rollupValue(key, of: record, in: result) }
            }
            XCTAssertEqual(rows.count, rollup["row_count"] as? Int, name)
            XCTAssertEqual(
                MemoryExportBundleWriter.rollupDigest(rows),
                rollup["rollup_digest"] as? String,
                "\(name): the declared tuple does not reproduce the declared digest"
            )
        }
    }

    /// One declared tuple element, resolved the way an importer resolves it.
    /// `memory_id` and `body_norm_digest` are literal fields where the record
    /// has them; a body record has no `memory_id`, so it is reached by the
    /// `body_join_key` join that section 06 exists for, and `provenance_digest`
    /// is derived from the section-07 rows that name the memory.
    private static func rollupValue(
        _ key: String,
        of record: MIFJSON,
        in result: MemoryExportBundleResult
    ) -> String {
        guard case .object(let fields) = record else { return "" }
        if case .string(let value) = fields[key] ?? .null { return value }
        switch key {
        case "memory_id":
            guard case .string(let joinKey) = fields["body_join_key"] ?? .null else { return "" }
            return string("memory_id", ofFirst: result.sectionBuffers[.memories]) {
                if case .string(let candidate) = $0["body_join_key"] ?? .null { return candidate == joinKey }
                return false
            }
        case "provenance_digest":
            guard case .string(let memoryID) = fields["memory_id"] ?? .null else { return "" }
            let hashes = (result.sectionBuffers[.provenance]?.records ?? []).compactMap { citation -> String? in
                guard case .object(let citationFields) = citation,
                      case .string(let owner) = citationFields["memory_id"] ?? .null, owner == memoryID,
                      case .string(let hash) = citationFields["source_content_hash"] ?? .null else { return nil }
                return hash
            }
            return MemoryExportDigest.sha256Hex(hashes.sorted().joined(separator: "\u{1F}"))
        default:
            return ""
        }
    }

    private static func string(
        _ key: String,
        ofFirst buffer: MemoryExportSectionBuffer?,
        where matches: ([String: MIFJSON]) -> Bool
    ) -> String {
        for record in buffer?.records ?? [] {
            guard case .object(let fields) = record, matches(fields) else { continue }
            if case .string(let value) = fields[key] ?? .null { return value }
        }
        return ""
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
            .appendingPathComponent("sections/06-bodies/000.ndjson.seal"))
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
                // swiftlint:disable:next force_unwrapping reason: a literal ISO timestamp
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
        XCTAssertEqual(try table("memory_fact_tombstones").sourceRows, 1, "the synthesized delete tombstone")

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
