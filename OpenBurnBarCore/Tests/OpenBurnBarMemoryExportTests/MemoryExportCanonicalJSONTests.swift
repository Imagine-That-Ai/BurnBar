// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportCanonicalJSONTests — JCS, the CLI surface, and the timestamp
// parser the whole classifier depends on.

import Foundation
import XCTest
@testable import OpenBurnBarMemoryExport

final class MemoryExportCanonicalJSONTests: XCTestCase {

    // MARK: - JCS

    func test_keysAreSortedAndWhitespaceIsAbsent() {
        let value = MIFJSON.object([
            "b": .int(2),
            "a": .string("x"),
            "C": .bool(true)
        ])
        XCTAssertEqual(MIFCanonicalJSON.serialize(value), #"{"C":true,"a":"x","b":2}"#)
    }

    func test_integralDoublesLoseTheirTrailingPointZero() {
        // ECMAScript's Number#toString, which JCS defers to, renders 1 — not
        // "1.0" as Swift's own description does.
        XCTAssertEqual(MIFCanonicalJSON.numberLiteral(1), "1")
        XCTAssertEqual(MIFCanonicalJSON.numberLiteral(0.75), "0.75")
        XCTAssertEqual(MIFCanonicalJSON.numberLiteral(-0), "0")
    }

    func test_controlCharactersAndQuotesEscapePerRFC8785() {
        let text = "a\"b\\c\nd" + String(UnicodeScalar(1))
        let expected = "\"a\\\"b\\\\c\\nd\\u0001\""
        XCTAssertEqual(MIFCanonicalJSON.serialize(.string(text)), expected)
    }

    func test_serialisationIsStableAcrossRuns() {
        // Swift dictionaries hash-seed per process, so a serializer that leaked
        // iteration order would be caught here only across runs — the sort is
        // what makes it stable WITHIN one too.
        let value = MIFJSON.object(Dictionary(
            uniqueKeysWithValues: (0..<64).map { ("key\($0)", MIFJSON.int($0)) }
        ))
        XCTAssertEqual(MIFCanonicalJSON.serialize(value), MIFCanonicalJSON.serialize(value))
    }

    // MARK: - Timestamps

    /// `memory_audit.ts` is ISO-8601 with a `T` and a `Z`; GRDB binds a `Date`
    /// as `"YYYY-MM-DD HH:MM:SS.SSS"` with a space and no zone. Both are in the
    /// same store, and a parser that reads one and not the other would break
    /// conjunct 6 the wrong way.
    func test_bothWriterFormatsParseToTheSameInstant() {
        let iso = MemoryExportTimestamp.parse("2026-01-02T03:04:05.678Z")
        let grdb = MemoryExportTimestamp.parse("2026-01-02 03:04:05.678")
        XCTAssertNotNil(iso)
        XCTAssertEqual(iso, grdb)
        XCTAssertEqual(MemoryExportTimestamp.milliseconds("2026-01-02T03:04:05.678Z"), 1_767_323_045_678)
    }

    func test_aMissingFractionAndAnOffsetAreBothHandled() {
        XCTAssertEqual(
            MemoryExportTimestamp.parse("2026-01-02T03:04:05Z"),
            MemoryExportTimestamp.parse("2026-01-02T03:04:05.000Z")
        )
        XCTAssertEqual(
            MemoryExportTimestamp.parse("2026-01-02T05:04:05+02:00"),
            MemoryExportTimestamp.parse("2026-01-02T03:04:05Z")
        )
        XCTAssertNil(MemoryExportTimestamp.parse("not a date"))
        XCTAssertNil(MemoryExportTimestamp.parse(nil))
    }

    func test_roundTripThroughTheAppsOwnFormat() {
        let text = "2026-09-07T01:02:03.456Z"
        // swiftlint:disable:next force_unwrapping reason: the literal above is well formed
        XCTAssertEqual(MemoryExportTimestamp.string(MemoryExportTimestamp.parse(text)!), text)
    }

    // MARK: - Identity

    func test_aConformingOracleIdTravelsVerbatim() {
        let id = "mem_" + String(repeating: "a", count: 32)
        XCTAssertEqual(MemoryExportIdentity.canonicalMemoryID(id, storeID: "s"), id)
    }

    /// The app lane mints `UUID().uuidString`, which the contract's
    /// `^mem_[0-9a-f]{32}$` rejects. Canonicalisation is deterministic and
    /// store-scoped, and every rewrite is named in `id-map.csv`.
    func test_aUUIDIdIsCanonicalisedDeterministically() {
        let raw = "6C4A1F9E-6B60-4A6E-9F71-3C6C6E2C7E7A"
        let first = MemoryExportIdentity.canonicalMemoryID(raw, storeID: "store-1")
        XCTAssertEqual(first, MemoryExportIdentity.canonicalMemoryID(raw, storeID: "store-1"))
        XCTAssertTrue(MemoryExportIdentity.isCanonicalMemoryID(first))
        XCTAssertNotEqual(first, MemoryExportIdentity.canonicalMemoryID(raw, storeID: "store-2"))
    }

    func test_derivedIdsMatchTheShapesTheContractPins() {
        XCTAssertTrue(
            MemoryExportIdentity.tombstoneID(storeID: "s", sourceTable: "t", sourceID: "x")
                .range(of: "^tmb_[0-9a-f]{32}$", options: .regularExpression) != nil
        )
        XCTAssertTrue(
            MemoryExportIdentity.reviewEventID(storeID: "s", auditSeq: 42)
                .range(of: "^rev_[0-9a-f]{32}$", options: .regularExpression) != nil
        )
        XCTAssertTrue(
            MemoryExportIdentity.citationID(storeID: "s", provenanceID: "p")
                .range(of: "^cit_[0-9a-f]{32}$", options: .regularExpression) != nil
        )
    }

    // MARK: - CLI

    func test_theVerbsAndFlagsParse() throws {
        let command = try MemoryExportCommand.parse([
            "export", "--out", "/tmp/bundle", "--recipient", "/tmp/recipient.json",
            "--since-audit-seq", "4120", "--since-updated-at-ms", "1767225600000",
            "--snapshot", "sqlcipher_export", "--json"
        ])
        XCTAssertEqual(command.verb, .export)
        XCTAssertEqual(command.out, "/tmp/bundle")
        XCTAssertEqual(command.snapshot, .sqlcipherExport)
        XCTAssertEqual(command.mode, .delta(sinceAuditSeq: 4_120, sinceUpdatedAtMS: 1_767_225_600_000))
        XCTAssertTrue(command.json)
    }

    /// §5's delta predicate has two halves, so half of it is a refusal rather
    /// than a full export wearing a delta's manifest (review F-4).
    func test_aDeltaNeedsBothHalvesOfItsWindow() {
        for half in [["--since-audit-seq", "10"], ["--since-updated-at-ms", "1767225600000"]] {
            XCTAssertThrowsError(
                try MemoryExportCommand.parse(
                    ["export", "--out", "/tmp/b", "--recipient", "/tmp/r.json", "--allow-long-read"] + half
                ),
                half.joined(separator: " ")
            )
        }
    }

    func test_exportNeedsAnOutputAndReadTxnNeedsAskingFor() {
        XCTAssertThrowsError(try MemoryExportCommand.parse(["export"]))
        // read_txn pins the WAL against a live 8.4 GB file, so it is never the
        // silent fallback — and a dry run holds it just as long, so it asks too.
        XCTAssertThrowsError(try MemoryExportCommand.parse([
            "export", "--out", "/tmp/b", "--recipient", "/tmp/r.json", "--snapshot", "read_txn"
        ]))
        XCTAssertThrowsError(try MemoryExportCommand.parse([
            "export", "--recipient", "/tmp/r.json", "--dry-run", "--snapshot", "read_txn"
        ]))
        XCTAssertNoThrow(try MemoryExportCommand.parse([
            "export", "--out", "/tmp/b", "--recipient", "/tmp/r.json",
            "--snapshot", "read_txn", "--allow-long-read"
        ]))
    }

    /// D-0025 ruling 3. A sealed bundle whose content key exists nowhere used
    /// to be writable, and the operator was told "written to: …" (review F-8).
    func test_anExportWithNoRecipientIsRefused() {
        XCTAssertThrowsError(
            try MemoryExportCommand.parse(["export", "--out", "/tmp/b", "--allow-long-read"])
        ) { error in
            guard case MemoryExportCommandError.usage(let message) = error else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains(MIFExportRefusal.recipientRequired.rawValue), message)
        }
        // Rehearsal is the one exception, and it mints a throwaway recipient
        // that report.json names.
        XCTAssertNoThrow(
            try MemoryExportCommand.parse(["export", "--out", "/tmp/b", "--rehearsal", "--allow-long-read"])
        )
        // export-status and verify take no recipient: neither seals anything.
        XCTAssertNoThrow(try MemoryExportCommand.parse(["export-status"]))
    }

    func test_anUnreadableSourceIsRecordedRatherThanSkippedSilently() throws {
        let command = try MemoryExportCommand.parse([
            "export", "--out", "/tmp/b", "--recipient", "/tmp/r.json",
            "--source", "all", "--dry-run", "--allow-long-read"
        ])
        XCTAssertEqual(command.unreadableSources.count, 2)
        XCTAssertTrue(command.unreadableSources.contains { $0.source == "cloud" })
    }

    func test_deterministicNoncesRequireRehearsal() {
        XCTAssertThrowsError(
            try MemoryExportCommand.parse([
                "export", "--out", "/tmp/b", "--recipient", "/tmp/r.json",
                "--dry-run", "--allow-long-read", "--deterministic-nonces"
            ])
        )
        XCTAssertNoThrow(
            try MemoryExportCommand.parse([
                "export", "--out", "/tmp/b", "--dry-run", "--allow-long-read",
                "--rehearsal", "--deterministic-nonces"
            ])
        )
    }

    func test_anUnknownVerbOrFlagIsRefused() {
        XCTAssertThrowsError(try MemoryExportCommand.parse(["import"]))
        XCTAssertThrowsError(try MemoryExportCommand.parse(["verify", "--nope"]))
    }
}
