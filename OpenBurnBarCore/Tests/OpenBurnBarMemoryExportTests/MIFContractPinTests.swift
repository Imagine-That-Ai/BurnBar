// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFContractPinTests — the vendored contract's provenance, pinned.
//
// PROVENANCE OF `Contracts/mif-v1.schema.json`
// -------------------------------------------
//   Source repo:    Po'dex, memory-consolidation-gauntlet branch
//   Source path:    docs/memory/contracts/mif-v1.schema.json
//   Source commit:  e591e7c8e8a71fdd50a562f4d63f14e30e13462b
//                   ("docs(memory): Q-30 — D-0033: project identity is the DDL
//                    pair; the narrow reason vocabularies close")
//   sha256:         1107c3ec56feb70fa704f49d97f3ac9cf098ea3d97b89afc13e04858db1be487
//   Copied:         2026-09-07, byte for byte, no local edit of any kind
//   Contract level: MIF v1, minor 2 [D-0021]
//
// Re-vendored from a008cdef… (commit 3332bd5b, Q-24) — two contract passes in
// one file, both additive, so `mif_minor` stays 2 and a bundle written against
// the old copy still validates:
//   * Q-26 closed the hold vocabulary (D-0031 ruling 3): `hold_reason` stops
//     being a bare enum and becomes an `anyOf` of the closed enum plus the
//     closed `INVARIANT_FAILED:<inv>` pattern branch, gaining
//     `RECIPIENT_MISMATCH` and `BUNDLE_CLOCK_SKEW`. The held-report test
//     validates a held bundle so this `anyOf` is exercised, not merely
//     implemented — an `anyOf` no failing instance ever touches is the
//     fail-open mode this pin exists to prevent.
//   * Q-30 closed the narrow reason vocabularies (D-0033 ruling 2):
//     `skipped_reason` gains four sync-slice values, `rejected_reason` gains
//     the two retirement cases, and `record_project` gains the optional
//     `project_id` + `fingerprint` DDL pair (together or neither).
//
// D-0021 ruling 5 requires the Po'dex copy and this one to be byte-identical
// "with the sha256 pinned by a test on each side". This is that test. It exists
// because the two copies drifted inside one working day and NEITHER side said
// so: the exporter's own in-process validator kept passing, because it was
// validating against the stale copy — so a missing required `crypto` object and
// a stale vendored schema hid each other (review F-1 and F-6).
//
// A failure here means one of two things, and they are fixed differently:
//   * the vendored file was edited locally — revert it, the contract is not
//     ours to change; or
//   * the contract moved — re-copy it, update the three lines above, and expect
//     the keyword audit below to name anything the evaluator cannot yet check.
//
// The licence question for vendoring an interchange schema into an AGPL
// codebase is D-0021 ruling 5's open counsel item, recorded and not decided
// here.

import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import OpenBurnBarMemoryExport

final class MIFContractPinTests: XCTestCase {

    private static let pinnedSHA256 =
        "1107c3ec56feb70fa704f49d97f3ac9cf098ea3d97b89afc13e04858db1be487"

    private func contractData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "mif-v1.schema", withExtension: "json"),
            "the embedded contract copy is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    func test_theVendoredContractIsTheCommitTheHeaderNames() throws {
        let data = try contractData()
        XCTAssertEqual(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            Self.pinnedSHA256,
            "the vendored mif-v1.schema.json is not the file this suite pins. Either it was edited "
                + "locally (revert it) or the contract moved (re-copy it and update the provenance "
                + "header in this file)."
        )
    }

    func test_theVendoredContractIsMIFMinorTwo() throws {
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try contractData()) as? [String: Any]
        )
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let manifest = try XCTUnwrap(defs["manifest"] as? [String: Any])
        let required = try XCTUnwrap(manifest["required"] as? [String])
        XCTAssertTrue(required.contains("crypto"), "minor 2 makes `crypto` required on every manifest")

        // The three interchange fields D-0021 ruling 4 adds. Their presence in
        // the vendored copy is what lets the record builders emit them.
        let memory = try XCTUnwrap(defs["record_memory"] as? [String: Any])
        XCTAssertNotNil((memory["properties"] as? [String: Any])?["source_memory_id"])
        let tombstone = try XCTUnwrap(defs["record_tombstone"] as? [String: Any])
        XCTAssertNotNil((tombstone["properties"] as? [String: Any])?["scope_kind"])
        let body = try XCTUnwrap(defs["record_body"] as? [String: Any])
        let recoveredFrom = try XCTUnwrap(
            ((body["properties"] as? [String: Any])?["recovered_from"] as? [String: Any])?["enum"] as? [String]
        )
        XCTAssertTrue(recoveredFrom.contains(MIFRecoveredFrom.memoryQuarantineBodies.rawValue))
        XCTAssertEqual(Set(recoveredFrom), Set(MIFRecoveredFrom.allCases.map(\.rawValue)))
    }

    /// The evaluator's unknown-keyword guard only fires on nodes an instance
    /// reaches. This walks the contract document itself, so a keyword under an
    /// optional field no fixture populates is caught too — which is what makes
    /// "a contract that grows a keyword turns the suite red" true rather than
    /// aspirational.
    func test_theEvaluatorImplementsEveryKeywordTheContractUsesAnywhere() throws {
        let validator = try MIFSchemaValidator(schemaData: try contractData())
        let unimplemented = validator.auditKeywords()
        XCTAssertTrue(
            unimplemented.isEmpty,
            "the contract uses keywords this evaluator does not implement: "
                + unimplemented.map { "\($0.pointer) → \($0.keyword)" }.joined(separator: ", ")
        )
    }

    /// The audit is only worth having if it can fail. Feed it a schema that
    /// uses a keyword nobody implements and check it says so — and that the
    /// keyword is found under an OPTIONAL property, which is precisely the
    /// position `check` could not see.
    func test_theKeywordAuditFindsAnUnimplementedKeywordUnderAnUnvisitedProperty() throws {
        let schema = """
        {"$defs":{"thing":{"type":"object",
          "properties":{"never_populated":{"type":"string","multipleOf":3}}}}}
        """
        let validator = try MIFSchemaValidator(schemaData: Data(schema.utf8))
        let found = validator.auditKeywords()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.keyword, "multipleOf")

        // And the instance-driven guard genuinely cannot: an object without the
        // property validates clean.
        XCTAssertNoThrow(try validator.validate(["other": "value"], against: "#/$defs/thing"))
    }
}
