import XCTest
@testable import OpenBurnBarCore

// MARK: - Hermes Square Phase C Tests
//
// Covers plan §6.6 + §6.10 seams: mini-program host call validation
// + CSP construction, rollback scope/planner logic.

final class HermesSquareMiniProgramHostTests: XCTestCase {

    private func validCall() -> MiniProgramHostCall {
        MiniProgramHostCall(
            action: .dispatch,
            correlationID: "abc",
            payload: ["prompt": "Hello"],
            agentURI: "agent://third-party/foo/scout",
            cardURI: "card://scout/dispatch"
        )
    }

    func testValidCallPasses() throws {
        try MiniProgramHostCallValidator.validate(
            validCall(),
            installedAgentURIs: ["agent://third-party/foo/scout"]
        )
    }

    func testUnauthorisedAgentRejected() {
        XCTAssertThrowsError(
            try MiniProgramHostCallValidator.validate(
                validCall(),
                installedAgentURIs: []
            )
        ) { error in
            guard case MiniProgramHostCallValidator.ValidationError.unauthorisedAgent = error else {
                XCTFail("Expected unauthorisedAgent; got \(error)")
                return
            }
        }
    }

    func testEmptyAgentURIRejected() {
        let call = MiniProgramHostCall(
            action: .dispatch,
            correlationID: "x",
            payload: [:],
            agentURI: "",
            cardURI: "card://x"
        )
        XCTAssertThrowsError(
            try MiniProgramHostCallValidator.validate(call, installedAgentURIs: ["agent://x"])
        ) { error in
            guard case MiniProgramHostCallValidator.ValidationError.missingAgentURI = error else {
                XCTFail("Expected missingAgentURI; got \(error)")
                return
            }
        }
    }

    func testOversizedPayloadRejected() {
        let huge = String(repeating: "x", count: 50_000)
        let call = MiniProgramHostCall(
            action: .dispatch,
            correlationID: "x",
            payload: ["bulk": huge],
            agentURI: "agent://foo/bar",
            cardURI: "card://x"
        )
        XCTAssertThrowsError(
            try MiniProgramHostCallValidator.validate(call, installedAgentURIs: ["agent://foo/bar"])
        ) { error in
            guard case MiniProgramHostCallValidator.ValidationError.payloadTooLarge = error else {
                XCTFail("Expected payloadTooLarge; got \(error)")
                return
            }
        }
    }

    func testCSPLocksToSandboxOrigin() {
        let csp = MiniProgramHostCallValidator.contentSecurityPolicy(
            sandboxURL: "https://example.com/mini-prog/v1/index.html"
        )
        XCTAssertTrue(csp.contains("https://example.com"))
        XCTAssertTrue(csp.contains("frame-ancestors 'none'"))
        XCTAssertTrue(csp.contains("object-src 'none'"))
    }

    func testAllPrimitivesEnumeratedAndStable() {
        XCTAssertEqual(
            MiniProgramHostPrimitive.allCases.map(\.rawValue).sorted(),
            ["approve", "delegate", "dispatch", "fork", "forward", "pin", "rollback", "subscribe"]
        )
    }
}

final class HermesSquareRollbackTests: XCTestCase {

    private func snapshot(_ seq: Int, files: [String]) -> RollbackSnapshot {
        RollbackSnapshot(
            id: "s\(seq)",
            sessionID: "session-1",
            sequence: seq,
            takenAt: Date(timeIntervalSince1970: TimeInterval(seq * 1000)),
            actionLabel: "Action \(seq)",
            touchedFiles: files
        )
    }

    func testFullSessionReturnsAllInDescendingOrder() {
        let snapshots = [snapshot(1, files: ["a"]), snapshot(2, files: ["b"]), snapshot(3, files: ["c"])]
        let restored = RollbackPlanner.snapshotsToRestore(all: snapshots, scope: .fullSession)
        XCTAssertEqual(restored.map(\.sequence), [3, 2, 1])
    }

    func testSingleFileReturnsNewestSnapshotTouchingTheFile() {
        let snapshots = [
            snapshot(1, files: ["foo.swift"]),
            snapshot(2, files: ["bar.swift"]),
            snapshot(3, files: ["foo.swift", "baz.swift"])
        ]
        let restored = RollbackPlanner.snapshotsToRestore(all: snapshots, scope: .singleFile(path: "foo.swift"))
        XCTAssertEqual(restored.map(\.sequence), [3])
    }

    func testLastNReturnsNHighestSequences() {
        let snapshots = (1...5).map { snapshot($0, files: ["f"]) }
        let restored = RollbackPlanner.snapshotsToRestore(all: snapshots, scope: .lastN(count: 2))
        XCTAssertEqual(restored.map(\.sequence), [5, 4])
    }

    func testLastNWithZeroReturnsEmpty() {
        let snapshots = (1...3).map { snapshot($0, files: ["f"]) }
        let restored = RollbackPlanner.snapshotsToRestore(all: snapshots, scope: .lastN(count: 0))
        XCTAssertTrue(restored.isEmpty)
    }

    func testRollbackScopeRoundTripsThroughCodable() throws {
        let scopes: [RollbackScope] = [.fullSession, .singleFile(path: "src/foo.swift"), .lastN(count: 3)]
        for scope in scopes {
            let data = try JSONEncoder().encode(scope)
            let decoded = try JSONDecoder().decode(RollbackScope.self, from: data)
            switch (scope, decoded) {
            case (.fullSession, .fullSession): break
            case (.singleFile(let a), .singleFile(let b)) where a == b: break
            case (.lastN(let a), .lastN(let b)) where a == b: break
            default:
                XCTFail("Round-trip mismatch for \(scope) → \(decoded)")
            }
        }
    }

    func testRollbackRequestPreservesStatusAndScope() throws {
        let request = RollbackRequest(
            sessionID: "abc",
            scope: .singleFile(path: "src/x.swift"),
            requestedBy: "iPhone",
            status: .pending
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RollbackRequest.self, from: data)
        XCTAssertEqual(decoded.sessionID, request.sessionID)
        XCTAssertEqual(decoded.status, .pending)
        if case .singleFile(let path) = decoded.scope {
            XCTAssertEqual(path, "src/x.swift")
        } else {
            XCTFail("Expected singleFile scope")
        }
    }
}
