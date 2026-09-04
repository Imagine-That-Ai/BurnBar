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
                "engineMemoryID"
            ]
        )
    }

    /// The blind-sync field is optional and omitted when nil, so a caller built
    /// before it existed produces byte-identical JSON.
    func testBlindSyncFieldIsOmittedWhenUnset() throws {
        let request = BurnBarProjectMemoryRememberRequest(text: "note", projectPath: "/tmp/project")

        let keys = try encodedKeys(request)
        XCTAssertFalse(keys.contains("engineMemoryID"))
        XCTAssertNil(request.engineMemoryID)
    }

    /// A payload from an older caller decodes with the new field nil, which the
    /// daemon reads as "keep today's behaviour": the `source_kind` column default
    /// (`"code"`), which the cloud lane never replicates.
    func testLegacyPayloadDecodesWithNilBlindSyncField() throws {
        let json = Data(#"{"text":"legacy note","projectPath":"/tmp/project"}"#.utf8)

        let request = try JSONDecoder().decode(BurnBarProjectMemoryRememberRequest.self, from: json)

        XCTAssertEqual(request.text, "legacy note")
        XCTAssertEqual(request.kind, "note")
        XCTAssertEqual(request.scope, "personal")
        XCTAssertEqual(request.confidence, 1.0)
        XCTAssertEqual(request.reviewStatus, .approved)
        XCTAssertNil(request.engineMemoryID)
    }

    func testBlindSyncFieldRoundTrips() throws {
        let engineMemoryID = "mem_" + String(repeating: "b", count: 32)
        let json = Data(
            #"{"text":"prefers ripgrep","engineMemoryID":"\#(engineMemoryID)"}"#.utf8
        )

        let request = try JSONDecoder().decode(BurnBarProjectMemoryRememberRequest.self, from: json)
        XCTAssertEqual(request.engineMemoryID, engineMemoryID)

        let reencoded = try JSONDecoder().decode(
            BurnBarProjectMemoryRememberRequest.self,
            from: try JSONEncoder().encode(request)
        )
        XCTAssertEqual(reencoded, request)
    }
}
