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

    func testAgentSpoofingRejectedEvenWhenBothAgentsAreInstalled() {
        XCTAssertThrowsError(
            try MiniProgramHostCallValidator.validate(
                validCall(),
                installedAgentURIs: [
                    "agent://third-party/foo/scout",
                    "agent://third-party/foo/other"
                ],
                expectedAgentURI: "agent://third-party/foo/other"
            )
        ) { error in
            guard case MiniProgramHostCallValidator.ValidationError.agentMismatch = error else {
                XCTFail("Expected agentMismatch; got \(error)")
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
            guard case MiniProgramHostCallValidator.ValidationError.fieldTooLarge(let field, _, _) = error else {
                XCTFail("Expected fieldTooLarge; got \(error)")
                return
            }
            XCTAssertEqual(field, "payload.bulk")
        }
    }

    func testRawBridgePayloadCapCoversWholeEnvelope() {
        let huge = Data(repeating: 0x61, count: MiniProgramHostCallValidator.maxCallPayloadBytes + 1)
        XCTAssertThrowsError(try MiniProgramHostCallValidator.validateRawBridgePayload(huge)) { error in
            guard case MiniProgramHostCallValidator.ValidationError.payloadTooLarge = error else {
                XCTFail("Expected payloadTooLarge; got \(error)")
                return
            }
        }
    }

    func testRawBridgeMessageRejectsOversizedStringsBeforeSerialization() {
        let body: [String: Any] = [
            "action": "dispatch",
            "correlationID": String(repeating: "x", count: MiniProgramHostCallValidator.maxCorrelationIDBytes + 1),
            "payload": ["prompt": "hello"],
            "agentURI": "agent://third-party/foo/scout",
            "cardURI": "card://scout/dispatch"
        ]
        XCTAssertThrowsError(try MiniProgramHostCallValidator.validateRawBridgeMessageBody(body)) { error in
            guard case MiniProgramHostCallValidator.ValidationError.fieldTooLarge(let field, _, _) = error else {
                XCTFail("Expected fieldTooLarge; got \(error)")
                return
            }
            XCTAssertEqual(field, "correlationID")
        }
    }

    func testRateLimiterAppliesPerActionWindow() {
        var limiter = MiniProgramHostBridgeRateLimiter(maxCallsPerAction: 2, windowSeconds: 10)
        XCTAssertTrue(limiter.allow(.dispatch, at: 100))
        XCTAssertTrue(limiter.allow(.dispatch, at: 101))
        XCTAssertFalse(limiter.allow(.dispatch, at: 102))
        XCTAssertTrue(limiter.allow(.approve, at: 103))
        XCTAssertTrue(limiter.allow(.dispatch, at: 111))
    }

    func testCSPLocksToSandboxOrigin() {
        let policy = MiniProgramHostCallValidator.approvedSandboxPolicy(
            sandboxURL: "https://example.com/mini-prog/v1/index.html",
            approvedOrigins: ["https://example.com"]
        )
        let csp = MiniProgramHostCallValidator.contentSecurityPolicy(policy: policy)
        XCTAssertTrue(csp.contains("https://example.com"))
        XCTAssertTrue(csp.contains("frame-ancestors 'none'"))
        XCTAssertTrue(csp.contains("object-src 'none'"))
        XCTAssertTrue(csp.contains("form-action 'none'"))
        XCTAssertTrue(csp.contains("worker-src 'none'"))
    }

    func testBridgeOriginMustMatchSandboxOrigin() {
        let policy = MiniProgramHostCallValidator.approvedSandboxPolicy(
            sandboxURL: "https://example.com/mini/index.html",
            approvedOrigins: ["https://example.com"]
        )!
        XCTAssertTrue(MiniProgramHostCallValidator.isAllowedBridgeOrigin(
            currentURL: URL(string: "https://example.com/mini/a.html")!,
            policy: policy
        ))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedBridgeOrigin(
            currentURL: URL(string: "https://evil.example/mini/a.html")!,
            policy: policy
        ))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedBridgeOrigin(
            currentURL: URL(string: "http://example.com/mini/a.html")!,
            policy: policy
        ))
    }

    func testSandboxURLRequiresIndependentApproval() {
        XCTAssertTrue(MiniProgramHostCallValidator.isAllowedSandboxURL(
            URL(string: "https://example.com/card.html")!,
            approvedOrigins: ["https://example.com"]
        ))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedSandboxURL(
            URL(string: "https://attacker.example/card.html")!,
            approvedOrigins: ["https://example.com"]
        ))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedSandboxURL(
            URL(string: "http://example.com/card.html")!,
            approvedOrigins: ["http://example.com"]
        ))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedSandboxURL(
            URL(string: "https://token@example.com/card.html")!,
            approvedOrigins: ["https://example.com"]
        ))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedSandboxURL(URL(string: "data:text/html,hi")!))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedSandboxURL(URL(string: "javascript:alert(1)")!))
    }

    func testSandboxURLAllowsExplicitLoopbackLocalDevelopment() {
        XCTAssertTrue(MiniProgramHostCallValidator.isAllowedSandboxURL(
            URL(string: "http://127.0.0.1:8787/card.html")!,
            approvedOrigins: [],
            allowLocalDevelopment: true
        ))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedSandboxURL(
            URL(string: "http://example.com/card.html")!,
            approvedOrigins: [],
            allowLocalDevelopment: true
        ))
    }

    func testFileSandboxRequiresApprovedPackageDirectory() {
        let packageDirectory = URL(fileURLWithPath: "/tmp/openburnbar-mini-package", isDirectory: true)
        let packageFile = packageDirectory.appendingPathComponent("index.html")
        let outsideFile = URL(fileURLWithPath: "/tmp/outside.html")
        XCTAssertTrue(MiniProgramHostCallValidator.isAllowedSandboxURL(
            packageFile,
            approvedOrigins: [],
            approvedPackageDirectoryURLs: [packageDirectory]
        ))
        XCTAssertFalse(MiniProgramHostCallValidator.isAllowedSandboxURL(
            outsideFile,
            approvedOrigins: [],
            approvedPackageDirectoryURLs: [packageDirectory]
        ))
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
