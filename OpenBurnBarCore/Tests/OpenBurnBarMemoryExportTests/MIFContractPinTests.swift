// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFContractPinTests — the vendored contract's provenance, pinned.
//
// PROVENANCE OF `Contracts/mif-v1.schema.json`
// -------------------------------------------
//   Source repo:    Po'dex, memory-consolidation-gauntlet branch
//   Source path:    docs/memory/contracts/mif-v1.schema.json
//   Source commit:  439c8d3d425a46b2895c20050eca3bf3d508a90e
//                   ("docs(memory): apply D-0018 — the human-verdict key drops
//                    the clamp; ±72 h moves to admission")
//   sha256:         fc1a4a267809272ab9fd5e21449b72b055505301e285bab13eba5ecc57be2228
//   Copied:         2026-09-07, byte for byte, no local edit of any kind
//   Contract level: MIF v1, minor 2 [D-0021]
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
        "fc1a4a267809272ab9fd5e21449b72b055505301e285bab13eba5ecc57be2228"

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
