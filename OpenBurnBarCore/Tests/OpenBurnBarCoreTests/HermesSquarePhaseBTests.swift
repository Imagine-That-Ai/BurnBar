import XCTest
@testable import OpenBurnBarCore

// MARK: - Hermes Square Phase B Tests
//
// Covers the pure-logic seams from plan §6.4 + §6.5 + §6.8 + §6.9:
//   • Composer queue ordering + state transitions
//   • Approval policy match / classHash + glob
//   • Mission group payload round-trip
//   • Persona scope env build

final class HermesSquareComposerQueueTests: XCTestCase {

    func testEnqueueAssignsSequentialNumbers() {
        var q: [QueuedTurn] = []
        q.append(QueuedTurn(text: "a", sequence: 0))
        q.append(QueuedTurn(text: "b", sequence: 1))
        q.append(QueuedTurn(text: "c", sequence: 2))
        q.resequenced()
        XCTAssertEqual(q.map(\.sequence), [0, 1, 2])
    }

    func testNextPendingPicksLowestSequence() {
        var q = [
            QueuedTurn(text: "b", sequence: 1, state: .pending),
            QueuedTurn(text: "a", sequence: 0, state: .completed),
            QueuedTurn(text: "c", sequence: 2, state: .pending)
        ]
        q.resequenced()
        XCTAssertEqual(q.nextPending?.text, "b")
    }

    func testIsTerminalCoversAllTerminalStates() {
        XCTAssertTrue(QueuedTurn.State.completed.isTerminal)
        XCTAssertTrue(QueuedTurn.State.cancelled.isTerminal)
        XCTAssertTrue(QueuedTurn.State.failed(reasonHash: 0).isTerminal)
        XCTAssertFalse(QueuedTurn.State.pending.isTerminal)
        XCTAssertFalse(QueuedTurn.State.inFlight.isTerminal)
    }

    func testQueuedTurnRoundTripsThroughCodable() throws {
        let original = QueuedTurn(
            text: "do the thing",
            attachmentIDs: ["att-1"],
            sequence: 3,
            state: .failed(reasonHash: 42)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueuedTurn.self, from: encoded)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.attachmentIDs, original.attachmentIDs)
        XCTAssertEqual(decoded.sequence, original.sequence)
        XCTAssertEqual(decoded.state, original.state)
    }
}

final class HermesSquareApprovalPolicyTests: XCTestCase {

    func testWildcardPolicyMatchesAnyAsk() {
        let policy = ApprovalPolicy(decision: .approve, displayLabel: "All approvals")
        let ask = ApprovalAskClassifier(runtimeID: "claude")
        XCTAssertNotNil(ask.resolve(against: [policy]))
    }

    func testRuntimeScopedPolicyOnlyMatchesItsRuntime() {
        let claudePolicy = ApprovalPolicy(
            runtimeID: "claude", decision: .approve,
            displayLabel: "Always for Claude"
        )
        let claudeAsk = ApprovalAskClassifier(runtimeID: "claude")
        let codexAsk = ApprovalAskClassifier(runtimeID: "codex")
        XCTAssertNotNil(claudeAsk.resolve(against: [claudePolicy]))
        XCTAssertNil(codexAsk.resolve(against: [claudePolicy]))
    }

    func testGlobMatchesFilePath() {
        XCTAssertTrue(ApprovalPolicy.matchGlob("docs/**", path: "docs/intro.md"))
        XCTAssertTrue(ApprovalPolicy.matchGlob("**/*.md", path: "src/foo/bar.md"))
        XCTAssertFalse(ApprovalPolicy.matchGlob("docs/*", path: "docs/nested/intro.md"))
        XCTAssertTrue(ApprovalPolicy.matchGlob("README*", path: "README.md"))
    }

    func testFileGlobPolicyOnlyMatchesPaths() {
        let policy = ApprovalPolicy(
            fileGlob: "docs/**", decision: .approve,
            displayLabel: "Docs edits"
        )
        let docAsk = ApprovalAskClassifier(filePath: "docs/intro.md")
        let srcAsk = ApprovalAskClassifier(filePath: "src/main.swift")
        XCTAssertNotNil(docAsk.resolve(against: [policy]))
        XCTAssertNil(srcAsk.resolve(against: [policy]))
    }

    func testExpiredPolicyDoesNotMatch() {
        let policy = ApprovalPolicy(
            runtimeID: "claude",
            decision: .approve,
            displayLabel: "Expired",
            createdAt: Date(timeIntervalSinceNow: -3600),
            expiresAt: Date(timeIntervalSinceNow: -1)
        )
        let ask = ApprovalAskClassifier(runtimeID: "claude")
        XCTAssertNil(ask.resolve(against: [policy]))
    }

    func testClassHashIsStableAcrossEquivalentInputs() {
        let a = ApprovalPolicy.classHash(
            missionKind: "creative", toolName: nil, fileGlob: nil,
            runtimeID: "claude", targetProject: nil, decision: .approve
        )
        let b = ApprovalPolicy.classHash(
            missionKind: "creative", toolName: nil, fileGlob: nil,
            runtimeID: "claude", targetProject: nil, decision: .approve
        )
        XCTAssertEqual(a, b)
    }
}

final class HermesSquarePersonaScopeApplierTests: XCTestCase {

    func testEnvelopeBuildsBurnBarPersonaEnvNamespace() throws {
        let env = CLIAgentMissionPersonaScopeApplier.buildEnvironment(
            from: PersonaScopeEnvelope(
                agentURI: "agent://burnbar/claude",
                personaID: "tech-reviewer",
                systemPromptAdditions: "Be terse.",
                permittedTools: ["read_file", "grep"],
                permittedFileGlobs: ["src/**"],
                permittedShellPrefixes: ["git log"],
                permitShell: false,
                permitFileEdits: false,
                temperatureOverride: 0.1,
                preferredModel: "claude-sonnet-4-6"
            )
        )
        XCTAssertEqual(env["BURNBAR_PERSONA_ID"], "tech-reviewer")
        XCTAssertEqual(env["BURNBAR_PERSONA_AGENT_URI"], "agent://burnbar/claude")
        XCTAssertEqual(env["BURNBAR_PERSONA_PERMIT_SHELL"], "0")
        XCTAssertEqual(env["BURNBAR_PERSONA_PERMIT_FILE_EDITS"], "0")
        XCTAssertEqual(env["BURNBAR_PERSONA_TOOLS_ALLOWLIST"], "read_file,grep")
        XCTAssertEqual(env["BURNBAR_PERSONA_SYSTEM_PROMPT"], "Be terse.")
        XCTAssertEqual(env["BURNBAR_PERSONA_MODEL"], "claude-sonnet-4-6")
        XCTAssertNotNil(env["BURNBAR_PERSONA_TEMPERATURE"])
    }

    func testEmptyRequestProducesEmptyOverrides() throws {
        let overrides = try CLIAgentMissionPersonaScopeApplier.overrides(from: [:])
        XCTAssertNil(overrides.envelope)
        XCTAssertTrue(overrides.extraEnvironment.isEmpty)
    }

    func testValidJSONInRequestDecodesAndProducesEnv() throws {
        let envelope = PersonaScopeEnvelope(
            agentURI: "agent://burnbar/claude",
            personaID: "tech-reviewer",
            permittedTools: ["read_file"],
            permitShell: false,
            permitFileEdits: false
        )
        let raw = try envelope.jsonString()
        let overrides = try CLIAgentMissionPersonaScopeApplier.overrides(
            from: ["personaScopeJSON": raw]
        )
        XCTAssertNotNil(overrides.envelope)
        XCTAssertEqual(overrides.envelope?.personaID, "tech-reviewer")
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_PERMIT_SHELL"], "0")
    }
}
