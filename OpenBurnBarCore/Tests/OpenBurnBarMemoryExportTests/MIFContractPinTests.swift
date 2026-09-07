// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFContractPinTests — the vendored contract's provenance, pinned.
//
// PROVENANCE OF `Contracts/mif-v1.schema.json`
// -------------------------------------------
//   Source repo:    Po'dex, memory-consolidation-gauntlet branch
//   Source path:    docs/memory/contracts/mif-v1.schema.json
//   Source commit:  3739ad37e6db7649398c98fcbd3df7f8c7d229ff
//                   ("docs(memory): byte-pin the last four interop values,
//                    D-0039 into MIF (Q-53)")
//   sha256:         9c84b3bd8dd4711ae55acdfd1de7df9d4f72f690fdb20c4aea1e882119f6eef7
//   Copied:         2026-09-07, byte for byte, no local edit of any kind
//   Contract level: MIF v1, minor 2 [D-0021]
//
// Re-vendored from 810fc38b… (commit d456c467) after interop run 1, and this
// one is NOT additive — D-0039 says so itself, and four exporter changes ride
// with it:
//   * `section_header.rollup_digest` is REQUIRED on all eleven sections and
//     typed `hex64` rather than `hex64_null` [ruling 6]. Every tuple is
//     computable after Q-51's reconciliation, so the writer emits eleven
//     digests where it emitted two, and a bundle written before this no longer
//     validates. That is the intended effect: nullable is what made
//     `ROLLUP_DIGEST_MISMATCH` unreachable for eight sections while their
//     counts balanced.
//   * `$defs/hashtree_file` types `hashtree.json` and joins the top-level
//     `oneOf` [ruling 8]. It is `additionalProperties: false`, so R5's unkeyed
//     per-chunk sidecar moved out of that file into `segments.sha256.json`
//     (D-BB-E-17).
//   * `recipient_store_id` gains the DDL's pattern [ruling 7].
//   * `hold_reason` gains `MANIFEST_INVALID` and its parameterised
//     `MANIFEST_INVALID:<path>` branch [ruling 6].
// The out-of-process validation was re-run against this copy on
// interop-fixture-v3: manifest, report, hashtree.json, 11 section headers and
// every record, 0 failing assertions.
//
// Before that, from 1107c3ec… (commit e591e7c8, Q-30) at the end of the third
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
        "9c84b3bd8dd4711ae55acdfd1de7df9d4f72f690fdb20c4aea1e882119f6eef7"

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

    /// The four narrowings the Q-53 re-vendor brought, each one a thing this
    /// exporter had to change rather than a comment it could carry.
    func test_theVendoredContractCarriesTheQ53Narrowings() throws {
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try contractData()) as? [String: Any]
        )
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])

        // Ruling 6: required on all eleven, and not nullable.
        let header = try XCTUnwrap(defs["section_header"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(header["required"] as? [String]).contains("rollup_digest"))
        XCTAssertEqual(
            ((header["properties"] as? [String: Any])?["rollup_digest"] as? [String: Any])?["$ref"]
                as? String,
            "#/$defs/hex64"
        )

        // Ruling 8: `hashtree.json` is typed, and it is one of the three
        // documents the top-level `oneOf` admits.
        let tree = try XCTUnwrap(defs["hashtree_file"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap(tree["required"] as? [String])),
            ["alg", "leaf_key_derivation", "subroots", "root"]
        )
        XCTAssertEqual(tree["additionalProperties"] as? Bool, false, "the R5 sidecar cannot live here")
        let admitted = try XCTUnwrap(schema["oneOf"] as? [[String: String]])
        XCTAssertTrue(admitted.contains { $0["$ref"] == "#/$defs/hashtree_file" })

        // Ruling 7: the DDL's store id.
        let manifest = try XCTUnwrap(defs["manifest"] as? [String: Any])
        XCTAssertEqual(
            ((manifest["properties"] as? [String: Any])?["recipient_store_id"] as? [String: Any])?["pattern"]
                as? String,
            "^sto_[0-9a-f]{32}$"
        )

        // Ruling 6's other half: a manifest defect is a HELD REPORT, so the
        // hold vocabulary has a name for it — and this build's mirror of that
        // vocabulary carries it.
        let holdReason = try XCTUnwrap(defs["hold_reason"] as? [String: Any])
        let branches = try XCTUnwrap(holdReason["anyOf"] as? [[String: Any]])
        let closed = branches.compactMap { $0["enum"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(closed.contains(MIFHoldReason.manifestInvalid.rawValue))
        for reason in MIFHoldReason.allCases {
            XCTAssertTrue(closed.contains(reason.rawValue), "\(reason.rawValue) is not in the contract")
        }
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
