// SPDX-License-Identifier: AGPL-3.0-only
//
// Wire pins for `daemon.memory.remember`. The request struct is the IPC
// boundary between the Memory MCP engine (Python) and the signed daemon, so
// its field set is a contract, not an implementation detail: a field added
// without updating this file is an accident, and a field whose absence stops
// meaning "the old default" is a silent break for every already-shipped
// caller.

import XCTest
@testable import OpenBurnBarKernel

final class BurnBarProjectMemoryRememberContractTests: XCTestCase {
    private func encodedKeys(_ request: BurnBarProjectMemoryRememberRequest) throws -> Set<String> {
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    func testRememberRequestFieldSetIsFrozen() throws {
        let request = BurnBarProjectMemoryRememberRequest(
            text: "ripgrep beats find here",
            projectPath: "/tmp/project",
            kind: "gotcha",
            scope: "project",
            tags: ["search"],
            confidence: 0.9,
            sourcePath: "docs/search.md",
            reviewStatus: .approved,
            sourceKind: "agent",
            engineMemoryID: "mem_" + String(repeating: "a", count: 32)
        )

        XCTAssertEqual(
            try encodedKeys(request),
            [
                "text",
                "projectPath",
                "kind",
                "scope",
                "tags",
                "confidence",
                "sourcePath",
                "reviewStatus",
                "sourceKind",
                "engineMemoryID"
            ]
        )
    }

    /// Both blind-sync fields are optional and omitted when nil, so a caller
    /// built before they existed produces byte-identical JSON.
    func testBlindSyncFieldsAreOmittedWhenUnset() throws {
        let request = BurnBarProjectMemoryRememberRequest(text: "note", projectPath: "/tmp/project")

        let keys = try encodedKeys(request)
        XCTAssertFalse(keys.contains("sourceKind"))
        XCTAssertFalse(keys.contains("engineMemoryID"))
        XCTAssertNil(request.sourceKind)
        XCTAssertNil(request.engineMemoryID)
    }

    /// A payload from an older caller decodes with the new fields nil, which
    /// the daemon reads as "keep today's behaviour" — the `source_kind` column
    /// default (`"code"`) and a daemon-derived memory id.
    func testLegacyPayloadDecodesWithNilBlindSyncFields() throws {
        let json = Data(#"{"text":"legacy note","projectPath":"/tmp/project"}"#.utf8)

        let request = try JSONDecoder().decode(BurnBarProjectMemoryRememberRequest.self, from: json)

        XCTAssertEqual(request.text, "legacy note")
        XCTAssertEqual(request.kind, "note")
        XCTAssertEqual(request.scope, "personal")
        XCTAssertEqual(request.confidence, 1.0)
        XCTAssertEqual(request.reviewStatus, .approved)
        XCTAssertNil(request.sourceKind)
        XCTAssertNil(request.engineMemoryID)
    }

    func testBlindSyncFieldsRoundTrip() throws {
        let engineMemoryID = "mem_" + String(repeating: "b", count: 32)
        let json = Data(
            #"{"text":"prefers ripgrep","sourceKind":"agent","engineMemoryID":"\#(engineMemoryID)"}"#.utf8
        )

        let request = try JSONDecoder().decode(BurnBarProjectMemoryRememberRequest.self, from: json)
        XCTAssertEqual(request.sourceKind, "agent")
        XCTAssertEqual(request.engineMemoryID, engineMemoryID)

        let reencoded = try JSONDecoder().decode(
            BurnBarProjectMemoryRememberRequest.self,
            from: try JSONEncoder().encode(request)
        )
        XCTAssertEqual(reencoded, request)
    }
}
