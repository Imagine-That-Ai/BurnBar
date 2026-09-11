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

    /// Review #2564: `String(Double)` is NOT ECMAScript. The two notations
    /// disagree at every exponent boundary — Swift's plain window is narrower
    /// (it switches at 1e-7 on the low end and prints a zero-padded, signed
    /// exponent in scientific), ECMAScript's runs to n ≤ 21 on the high end
    /// and −6 < n ≤ 0 below. The expected strings below are the ECMAScript
    /// renderings — `(x).toString()` in any JS engine — and the Python
    /// cross-check under them proves each literal parses back to the exact
    /// same double (`json.loads`/`json.dumps` round-trip the bits, which is
    /// the property JCS actually needs across implementations).
    func test_numberLiteralIsECMAScriptAtEveryExponentBoundary() {
        let vectors: [(Double, String)] = [
            // Plain-decimal low boundary: n=−5 stays decimal …
            (1e-6, "0.000001"),
            (1.234e-6, "0.000001234"),
            // … n=−6 switches to scientific, exponent unpadded …
            (1e-7, "1e-7"),
            (-1.5e-7, "-1.5e-7"),
            (Double.leastNonzeroMagnitude, "5e-324"),
            // … interior stays plain …
            (0.1, "0.1"),
            (123.456, "123.456"),
            (1e15, "1000000000000000"),
            (1e20, "100000000000000000000"),
            (1.5e20, "150000000000000000000"),
            (1.2345678901234568e20, "123456789012345680000"),
            // … and n > 21 is scientific with a signed, unpadded exponent.
            (1e21, "1e+21"),
            (1.23e21, "1.23e+21"),
            (-1e21, "-1e+21"),
            (1.7976931348623157e308, "1.7976931348623157e+308")
        ]
        for (value, expected) in vectors {
            XCTAssertEqual(
                MIFCanonicalJSON.numberLiteral(value), expected,
                "ECMAScript renders \(value) as \(expected)"
            )
            // Round-trip: the emitted literal must read back to the identical
            // Double, or the manifest's digest is not portable.
            XCTAssertEqual(
                Double(expected), value,
                "\(expected) must parse back to the same double"
            )
        }
        // Python's repr-style spelling disagrees with ECMAScript's on the
        // boundary rows — `json.dumps(1e-6)` is "1e-06" — which is exactly why
        // the serializer cannot defer to a host language's own printer.
        // The cross-check is therefore on VALUE: every expected literal
        // re-parses to the same bits, whatever spelling another host chose.
        XCTAssertEqual(MIFCanonicalJSON.numberLiteral(1e-6), "0.000001")
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
        // reason: the literal above is well formed
        // swiftlint:disable:next force_unwrapping
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
        XCTAssertNotNil(
            MemoryExportIdentity.tombstoneID(storeID: "s", sourceTable: "t", sourceID: "x")
                .range(of: "^tmb_[0-9a-f]{32}$", options: .regularExpression)
        )
        XCTAssertNotNil(
            MemoryExportIdentity.reviewEventID(storeID: "s", auditSeq: 42)
                .range(of: "^rev_[0-9a-f]{32}$", options: .regularExpression)
        )
        XCTAssertNotNil(
            MemoryExportIdentity.citationID(storeID: "s", provenanceID: "p")
                .range(of: "^cit_[0-9a-f]{32}$", options: .regularExpression)
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
            XCTAssertTrue(message.contains(MIFExportError.recipientRequired.rawValue), message)
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

    /// F-16 and F-17: both verbs are wired now, and both refuse the inputs they
    /// genuinely cannot supply from this side rather than being advertised and
    /// throwing.
    func test_verifyAndP5CheckTakeTheInputsOnlyTheOtherSideHas() throws {
        XCTAssertThrowsError(try MemoryExportCommand.parse(["verify"]))
        let verify = try MemoryExportCommand.parse(["verify", "--bundle", "/tmp/b"])
        XCTAssertEqual(verify.bundle, "/tmp/b")

        // Step 3 is an id-set AND digest diff and step 0(a) is a version gate;
        // none of the three inputs exists on this side, so none gets a default
        // — a p5-check missing one would hold the finding it could not run.
        XCTAssertThrowsError(try MemoryExportCommand.parse(["p5-check"]))
        XCTAssertThrowsError(try MemoryExportCommand.parse(["p5-check", "--target-ids", "/tmp/ids"]))
        XCTAssertThrowsError(try MemoryExportCommand.parse([
            "p5-check", "--target-ids", "/tmp/ids", "--required-version", "1.0.42"
        ]))
        let check = try MemoryExportCommand.parse([
            "p5-check", "--target-ids", "/tmp/ids", "--target-digests", "/tmp/digests",
            "--required-version", "1.0.42"
        ])
        XCTAssertEqual(check.requiredVersion, "1.0.42")
        XCTAssertEqual(check.targetDigests, "/tmp/digests")
        // 0(b) and 0(c) are assertions the operator makes, and an unasserted
        // gate holds rather than passing.
        XCTAssertFalse(check.socketTokenRotated)
        XCTAssertFalse(check.memoryWriteWithdrawn)
        let asserted = try MemoryExportCommand.parse([
            "p5-check", "--target-ids", "/tmp/ids", "--target-digests", "/tmp/d",
            "--required-version", "1.0.42",
            "--socket-token-rotated", "--memory-write-withdrawn"
        ])
        XCTAssertTrue(asserted.socketTokenRotated)
        XCTAssertTrue(asserted.memoryWriteWithdrawn)
    }

    func test_anUnknownVerbOrFlagIsRefused() {
        XCTAssertThrowsError(try MemoryExportCommand.parse(["import"]))
        XCTAssertThrowsError(try MemoryExportCommand.parse(["verify", "--nope"]))
    }
}
