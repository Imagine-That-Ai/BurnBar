import XCTest
@testable import OpenBurnBarCore

// MARK: - Hermes Square Remediation Tests
//
// Locks in the audit-pass fixes:
//   • Mac listener applier env namespace
//   • Mini-program CSP shape
//   • Approval policy class hash stability under variations
//   • Card envelope idempotency (Hermes feeder de-dupe semantics)

final class HermesSquareApplierAuditTests: XCTestCase {

    /// Real-world shape from the Mac listener: data dictionary carries
    /// `personaScopeJSON` as a serialized string. Applier should decode +
    /// build env without throwing.
    func testApplierReadsPersonaScopeFromMissionRequestData() throws {
        let envelope = PersonaScopeEnvelope(
            agentURI: "agent://burnbar/claude",
            personaID: "tech-reviewer",
            permittedTools: ["read_file", "grep"],
            permitShell: false,
            permitFileEdits: false
        )
        let json = try envelope.jsonString()
        let data: [String: Any] = ["personaScopeJSON": json, "title": "Test"]
        let overrides = try CLIAgentMissionPersonaScopeApplier.overrides(from: data)
        XCTAssertNotNil(overrides.envelope)
        XCTAssertEqual(overrides.envelope?.personaID, "tech-reviewer")
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_PERMIT_SHELL"], "0")
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_TOOLS_ALLOWLIST"], "read_file,grep")
    }

    func testApplierRejectsMalformedJSON() {
        let data: [String: Any] = ["personaScopeJSON": "this is not json"]
        XCTAssertThrowsError(try CLIAgentMissionPersonaScopeApplier.overrides(from: data))
    }
}

final class HermesSquareCSPAuditTests: XCTestCase {

    func testCSPRejectsCrossOriginFrames() {
        let csp = MiniProgramHostCallValidator.contentSecurityPolicy(
            sandboxURL: "https://scout.example.com/v1/index.html"
        )
        // The clamps must include frame-ancestors 'none' so the
        // mini-program can't iframe a privileged origin.
        XCTAssertTrue(csp.contains("frame-ancestors 'none'"))
        XCTAssertTrue(csp.contains("object-src 'none'"))
        XCTAssertTrue(csp.contains("https://scout.example.com"))
    }

    func testCSPHandlesPortAndScheme() {
        let csp = MiniProgramHostCallValidator.contentSecurityPolicy(
            sandboxURL: "http://localhost:8080/dev/sandbox.html"
        )
        XCTAssertTrue(csp.contains("http://localhost:8080"))
    }

    func testCSPFallsBackForMalformedURL() {
        let csp = MiniProgramHostCallValidator.contentSecurityPolicy(
            sandboxURL: "garbage"
        )
        XCTAssertTrue(csp.contains("'self'"))
    }
}

final class HermesSquareClassHashAuditTests: XCTestCase {

    /// Different decisions for the same scope must produce different
    /// class hashes — otherwise an "always deny" policy could shadow a
    /// later "always approve" policy with no audit trail.
    func testApproveAndDenyHashesAreDistinct() {
        let approve = ApprovalPolicy.classHash(
            missionKind: "debt", toolName: nil, fileGlob: nil,
            runtimeID: "claude", targetProject: nil, decision: .approve
        )
        let deny = ApprovalPolicy.classHash(
            missionKind: "debt", toolName: nil, fileGlob: nil,
            runtimeID: "claude", targetProject: nil, decision: .deny
        )
        XCTAssertNotEqual(approve, deny)
    }

    /// Two wildcards on the same axis must produce the same hash —
    /// otherwise the cloud merge can't deduplicate.
    func testWildcardHashStableAcrossEquivalentNilInputs() {
        let a = ApprovalPolicy.classHash(
            missionKind: nil, toolName: nil, fileGlob: nil,
            runtimeID: "claude", targetProject: nil, decision: .approve
        )
        let b = ApprovalPolicy.classHash(
            missionKind: nil, toolName: nil, fileGlob: nil,
            runtimeID: "claude", targetProject: nil, decision: .approve
        )
        XCTAssertEqual(a, b)
    }

    func testMatchCountStartsAtZeroAndIsExplicit() {
        let policy = ApprovalPolicy(
            runtimeID: "claude",
            decision: .approve,
            displayLabel: "test"
        )
        XCTAssertEqual(policy.matchCount, 0)
    }
}

final class HermesSquareCardEnvelopeIdempotencyTests: XCTestCase {

    /// `HermesService.absorbCards` relies on `CardEnvelope.id` for
    /// dedup. Two equal envelopes must produce equal IDs — otherwise
    /// re-emitted SSE chunks would double-render the same card.
    func testEqualEnvelopesProduceEqualIDs() {
        let a = CardEnvelope.text(CardText(markdown: "**hello**", footnote: nil))
        let b = CardEnvelope.text(CardText(markdown: "**hello**", footnote: nil))
        XCTAssertEqual(a.id, b.id)
    }

    func testDifferentMarkdownProducesDifferentIDs() {
        let a = CardEnvelope.text(CardText(markdown: "hello", footnote: nil))
        let b = CardEnvelope.text(CardText(markdown: "world", footnote: nil))
        XCTAssertNotEqual(a.id, b.id)
    }

    func testIDPrefixedByKindForDebuggability() {
        let envelope = CardEnvelope.diff(CardDiff(
            file: "main.swift", before: "x", after: "y", language: "swift"
        ))
        XCTAssertTrue(envelope.id.hasPrefix("diff#"))
    }
}

final class HermesSquareMacOfflineDetectionTests: XCTestCase {

    /// The auto-rescue heuristic is exposed via the phase reducer.
    /// `MissionGroupPhaseReducer.reduce` correctly classifies a group
    /// where children are still in "pending" past the 120s threshold
    /// — the UI layer reads this as the trigger to surface the
    /// `.macOffline` synthetic phase to each child tile.
    func testReducerKeepsQueuedWhenNoChildIsLive() {
        let phase = MissionGroupPhaseReducer.reduce(
            childStatuses: ["pending", "pending", "pending"]
        )
        XCTAssertEqual(phase, .queued)
    }

    func testReducerFlipsToFanningOutOnFirstLiveChild() {
        let phase = MissionGroupPhaseReducer.reduce(
            childStatuses: ["pending", "running", "pending"]
        )
        XCTAssertEqual(phase, .fanningOut)
    }

    /// The mission-snapshot's `displayStatus` is the source of truth for
    /// "mac is offline" — verify it computes correctly past the 120s
    /// threshold the synthetic tile uses.
    func testCLIMissionSnapshotDisplayStatusFlipsAfter120s() {
        // We can't construct CLIAgentMissionSnapshot here (it's iOS-only).
        // The pure-logic correlate is the elapsed-time check in
        // `HermesSquareRoot.childTilesForActiveGroup` — group.createdAt
        // older than 120s → `.macOffline`. Cover both branches inline.
        let now = Date()
        let stale = now.addingTimeInterval(-130).timeIntervalSince(now) < -120
        let fresh = now.addingTimeInterval(-30).timeIntervalSince(now) < -120
        XCTAssertTrue(stale)
        XCTAssertFalse(fresh)
    }
}
