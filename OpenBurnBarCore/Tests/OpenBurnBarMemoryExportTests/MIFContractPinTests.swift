// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFContractPinTests — the vendored contract's provenance, pinned.
//
// PROVENANCE OF `Contracts/mif-v1.schema.json`
// -------------------------------------------
//   Source repo:    Po'dex, memory-consolidation-gauntlet branch
//   Source path:    docs/memory/contracts/mif-v1.schema.json
//   Source commit:  3332bd5b750e41e398e752e42daca294e79a47db
//                   ("docs(memory): Q-24 — the exporter's two refusals are both
//                    in the contract, and a randomized signature is not a broken
//                    determinism claim")
//   sha256:         a008cdefcdf9d90d5936674cb6ab3c686fdba6047395f4fe639d7f6ea1132723
//   Copied:         2026-09-07, byte for byte, no local edit of any kind
//   Contract level: MIF v1, minor 2 [D-0021]
//
// Re-vendored from fc1a4a2678… (commit 439c8d3d, D-0018) — three contract
// passes in one file:
//   * D-0025 retyped `manifest.recipient_key_id` from `hex64_null` to
//     `recipient_key_id_null` (`^rcp_[0-9a-f]{32}$`) and added
//     `EXPORT_RECIPIENT_REQUIRED`. The stale typing was the exporter's only
//     schema failure at HEAD and an interop break, because `aad =
//     recipient_key_id` (review R4);
//   * Q-16 added `reconciliation_report.{write_lease_taken,
//     staging_files_created, clients_drained}`, Q-18 `record_tombstone`'s five
//     `retired_*` members and their `dependentRequired`;
//   * Q-24 added `EXPORT_HPKE_UNAVAILABLE`, so `MIFExportError`'s two refusal codes
//     are now both in the contract's closed set.
// Every move was additive, so `mif_minor` stays 2 and a bundle written against
// the old copy still validates.
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
        "a008cdefcdf9d90d5936674cb6ab3c686fdba6047395f4fe639d7f6ea1132723"

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
