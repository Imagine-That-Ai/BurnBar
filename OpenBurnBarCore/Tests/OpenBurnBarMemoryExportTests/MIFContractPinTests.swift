// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFContractPinTests — the vendored contract's provenance, pinned.
//
// PROVENANCE OF `Contracts/mif-v1.schema.json`
// -------------------------------------------
//   Source repo:    Po'dex, memory-consolidation-gauntlet branch
//   Source path:    docs/memory/contracts/mif-v1.schema.json
//   Source commit:  d456c4678648a772e00eb027e9bf6e55c8c49b50
//                   ("docs(memory): enforce record_project's identity pair
//                    (audit B F-2)")
//   sha256:         810fc38bee7ee91676819b7526938aacfe4f4e5a27fad8a1da15b6db9516b1aa
//   Copied:         2026-09-07, byte for byte, no local edit of any kind
//   Contract level: MIF v1, minor 2 [D-0021]
//
// Re-vendored from 1107c3ec… (commit e591e7c8, Q-30) at the end of the third
// review's fix pass — the document's seventh pass put `record_project`'s
// identity pair under `dependentRequired` both ways plus two `if`/`then`
// branches, so D-0033 ruling 1's "together or not at all" is ENFORCED rather
// than stated in a `$comment`. Additive as a constraint, not as a member, so
// `mif_minor` stays 2; BB-E emits the inputs-only form (neither `project_id`
// nor `fingerprint`, D-BB-E's §3 row for section 04), which satisfies every new
// branch vacuously, and the evaluator already implements all three keywords —
// so this re-vendor is a digest move and nothing else. The out-of-process
// validation was re-run against this copy: 20 instances, 0 failing assertions.
//
// Before that, from a008cdef… (commit 3332bd5b, Q-24) — two contract passes in
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
        "810fc38bee7ee91676819b7526938aacfe4f4e5a27fad8a1da15b6db9516b1aa"

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
