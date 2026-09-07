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
            recipientPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey,
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
        try XCTSkipUnless(
            MemoryExportGateRunner.shared.isAvailable(),
            "the shared secret corpus did not load in this test bundle"
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
        let opened = try ChaChaPoly.open(
            try ChaChaPoly.SealedBox(combined: sealed),
            using: MemoryExportCrypto.segmentKey(
                bundleKey: MemoryExportCrypto.deterministicBundleKey(seed: "gate"),
                section: .bodies
            )
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

    // MARK: - Delta

    func test_deltaCarriesOnlyAuditRowsAboveTheWatermark() throws {
        let snapshot = try MemoryExportFixtureStore.snapshot(try makeStore())
        let key = MemoryExportCrypto.deterministicBundleKey(seed: "delta")
        let full = try makeExporter().export(snapshot, mode: .full, to: nil, bundleKey: key)
        let delta = try makeExporter().export(
            snapshot,
            mode: .delta(sinceAuditSeq: snapshot.auditHeadSeq),
            to: nil,
            bundleKey: key
        )
        XCTAssertNotEqual(full.contentDigest, delta.contentDigest)
        // The delete sits at or below the watermark, so the delta neither
        // carries it nor trips the delete obligation.
        XCTAssertEqual(delta.report.deleteWithoutTombstoneSynthesized, 0)
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
