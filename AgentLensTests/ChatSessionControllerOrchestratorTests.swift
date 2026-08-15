import BurnBarCore
import Foundation
import XCTest

@testable import BurnBar

// MARK: - Chat Session Controller Orchestrator Tests (M4)

/// M4 orchestrator chat-mode tests (VAL-ORCH-006/007/008/009/010/011/012/013/
/// 022/023/024/025/031/032/035). The deterministic PATH-shim fake CLI
/// (`tools/burnbar-fake-cli.py`) is the required M4 fixture: it emits the
/// canonical proposal shape, deterministic snapshot-derived answers, slow
/// streams, and injection text — no live model anywhere.
///
/// Setup + helpers live in `ChatSessionControllerOrchestratorTestCase`; the
/// delivery-flow tests live in `ChatSessionControllerDeliveryFlowTests` so
/// both classes stay under the 500-line type_body_length lint budget.
@MainActor
final class ChatSessionControllerOrchestratorTests: ChatSessionControllerOrchestratorTestCase {

    // MARK: - Mode switch + per-thread persistence (VAL-ORCH-024)

    func test_modeSwitchPersistsPerThreadAndSurvivesRelaunch() {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot)
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        XCTAssertEqual(controller.mode, .orchestrator)

        // Simulate app relaunch: a fresh controller over the same store
        // restores the per-thread mode.
        let relaunched = makeController(snapshot: snapshot)
        relaunched.loadPersistedMessages()
        XCTAssertEqual(relaunched.mode, .orchestrator)
    }

    func test_midThreadModeSwitchKeepsHistoryAndAppliesPromptPerMessage() async {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "answer"))
        controller.startNewChatThread()

        // Analyst send (consent on, CLI present) — history preserved.
        controller.inputText = "hello analyst"
        await controller.send()
        await waitForStream(controller)
        XCTAssertTrue(controller.messages.contains { $0.role == .user && $0.content == "hello analyst" })

        // Switch to orchestrator mid-thread: history intact.
        controller.setMode(.orchestrator)
        XCTAssertEqual(controller.messages.count, 2, "history preserved across the mode switch")
        // Orchestrator send uses the fleet prompt (fake CLI answers from the
        // injected snapshot section).
        controller.inputText = "who is running right now?"
        await controller.send()
        await waitForStream(controller)
        let last = lastAssistantMessage(controller)
        XCTAssertNotNil(last)
        XCTAssertTrue(last?.content.contains("Running agents") == true, "got: \(last?.content ?? "nil")")
    }

    // MARK: - No designation → typed unavailable (VAL-ORCH-035)

    func test_noDesignationProducesTypedUnavailableState_noCLI_noSideEffects() async {
        let snapshot = freshSnapshot()
        let cliBridge = makeFakeCLIBridge(mode: "proposal")
        let controller = makeController(
            snapshot: snapshot,
            designation: .none,
            cliBridge: cliBridge
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "who is running?"
        await controller.send()

        let last = lastAssistantMessage(controller)
        XCTAssertNotNil(last)
        XCTAssertTrue(
            last?.content.contains("No orchestrator is designated") == true,
            "got: \(last?.content ?? "nil")"
        )
        XCTAssertNil(cliBridge.detectedBackend, "no CLI may be invoked without a designation")
        XCTAssertEqual(directiveRecordCalls, 0, "no directive record side effect")
        XCTAssertFalse(controller.messages.contains { $0.proposalJSON != nil })
    }

    // MARK: - Privacy consent gate (VAL-ORCH-010)

    func test_privacyConsentGateRefusesWithoutSpawningCLI() async {
        let snapshot = freshSnapshot()
        let cliBridge = makeFakeCLIBridge(mode: "proposal")
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: cliBridge,
            cliAllowed: false
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "who is running?"
        await controller.send()

        let last = lastAssistantMessage(controller)
        XCTAssertNotNil(last)
        XCTAssertTrue(last?.content.contains("Local CLI assistant is off") == true)
        XCTAssertNil(cliBridge.detectedBackend, "consent gate must never spawn a CLI")
        XCTAssertEqual(directiveRecordCalls, 0)
    }

    // MARK: - CLI unavailable → typed error (VAL-ORCH-022)

    func test_cliUnavailableProducesTypedErrorNeverFabricatedAnswer() async {
        let snapshot = freshSnapshot()
        // A CLIBridge with an empty search path: no claude/codex resolvable.
        let cliBridge = CLIBridge(
            environment: ["PATH": "/nonexistent", "HOME": sandboxHome.path],
            homeDirectory: sandboxHome.path,
            executableSearchDirectories: ["/nonexistent"]
        )
        let controller = makeController(snapshot: snapshot, cliBridge: cliBridge)
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "who is running?"
        await controller.send()

        let last = lastAssistantMessage(controller)
        XCTAssertNotNil(last)
        XCTAssertTrue(
            last?.content.contains("Orchestrator unavailable") == true,
            "got: \(last?.content ?? "nil")"
        )
        XCTAssertFalse(last?.content.contains("Running agents") == true, "never a fabricated answer")
        XCTAssertEqual(directiveRecordCalls, 0)
    }

    // MARK: - Daemon down / stale context honesty (VAL-ORCH-025)

    func test_daemonDownProducesTypedDegradedState() async {
        let snapshot = freshSnapshot()
        let fleetService = FleetService(socketURL: socketURL) { _ in snapshot }
        let controller = ChatSessionController(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            fleetService: fleetService,
            cliBridge: makeFakeCLIBridge(mode: "answer"),
            orchestratorStateProvider: { _ in
                throw BurnBarFleetClientError.daemonUnavailable("connect failed")
            },
            directiveRecordProvider: { [weak self] directive, _ in
                self?.recordedDirectives.append(directive)
                self?.directiveRecordCalls += 1
                return directive
            },
            deliveryChannelProvider: { _ in nil },
            cliAssistantAllowedProvider: { true }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "who is running?"
        await controller.send()

        let last = lastAssistantMessage(controller)
        XCTAssertNotNil(last)
        XCTAssertTrue(
            last?.content.contains("daemon is unreachable") == true,
            "got: \(last?.content ?? "nil")"
        )
        XCTAssertEqual(directiveRecordCalls, 0)
    }

    func test_staleSnapshotProducesTypedRefusalNeverStaleAsCurrent() async {
        let snapshot = FleetTestFixtures.makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_752_000_000),
            cadenceSeconds: 15
        )
        // now = generatedAt + 100s > 2×15s → stale.
        let now = Date(timeIntervalSince1970: 1_752_000_000 + 100)
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "answer"),
            now: { now }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "who is running?"
        await controller.send()

        let last = lastAssistantMessage(controller)
        XCTAssertNotNil(last)
        XCTAssertTrue(
            last?.content.contains("stale") == true,
            "got: \(last?.content ?? "nil")"
        )
        XCTAssertFalse(last?.content.contains("Running agents") == true, "stale numbers never presented as current")
    }

    // MARK: - Deterministic proposal flow (VAL-ORCH-011/012/013)

    func test_canonicalProposalRendersAndApprovalRecordsDecidedAt() async throws {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "proposal"))
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)

        let last = lastAssistantMessage(controller)
        XCTAssertNotNil(last)
        let proposalJSON = try XCTUnwrap(last?.proposalJSON, "proposal must be attached to the message")
        XCTAssertTrue(proposalJSON.contains("m4-proposal-001"))
        XCTAssertTrue(proposalJSON.contains("askStatus"))
        XCTAssertTrue(proposalJSON.contains("hermes"))
        XCTAssertTrue(proposalJSON.contains("Report current status"))
        // The proposal line is never rendered as assistant text.
        XCTAssertFalse(last?.content.contains("burnbar_directive_proposal") == true)
        // Pre-decision: no record exists (VAL-ORCH-011).
        XCTAssertEqual(directiveRecordCalls, 0)

        // Approve: records approved with decidedAt (VAL-ORCH-012).
        controller.approveProposal(messageID: last!.id)
        XCTAssertEqual(directiveRecordCalls, 1)
        let recorded = try XCTUnwrap(recordedDirectives.first)
        XCTAssertEqual(recorded.id, "m4-proposal-001")
        XCTAssertEqual(recorded.kind, .askStatus)
        XCTAssertEqual(recorded.targetAgent, .hermes)
        XCTAssertEqual(recorded.payload, "Report current status")
        guard case .approved = recorded.state else {
            return XCTFail("expected approved state, got \(recorded.state)")
        }
        XCTAssertNotNil(recorded.decidedAt, "approval must record decidedAt")
        XCTAssertEqual(lastAssistantMessage(controller)?.proposalDecision, .approved)
    }

    func test_dismissRecordsDismissedNeverDelivered() async throws {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "proposal"))
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)

        let last = try XCTUnwrap(lastAssistantMessage(controller))
        controller.dismissProposal(messageID: last.id)
        XCTAssertEqual(directiveRecordCalls, 1)
        let recorded = try XCTUnwrap(recordedDirectives.first)
        guard case .dismissed = recorded.state else {
            return XCTFail("expected dismissed state, got \(recorded.state)")
        }
        XCTAssertNotNil(recorded.decidedAt)
        XCTAssertEqual(lastAssistantMessage(controller)?.proposalDecision, .dismissed)
    }

    func test_doubleApproveIsIdempotent() async throws {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "proposal"))
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)

        let last = try XCTUnwrap(lastAssistantMessage(controller))
        controller.approveProposal(messageID: last.id)
        controller.approveProposal(messageID: last.id)
        XCTAssertEqual(directiveRecordCalls, 1, "double-approve must be idempotent")
    }

    func test_approveWhileDaemonDownIsTypedFailureNoPhantomRecord() async throws {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "proposal"))
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))

        // Daemon goes down: the record provider now throws.
        let failingController = ChatSessionController(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            fleetService: FleetService(socketURL: socketURL) { _ in snapshot },
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            orchestratorStateProvider: { _ in
                BurnBarOrchestratorState(designation: .burnBarManaged, setAt: Date(), pendingDirectives: 0)
            },
            directiveRecordProvider: { _, _ in
                throw BurnBarFleetClientError.daemonUnavailable("connect failed")
            },
            deliveryChannelProvider: { _ in nil },
            cliAssistantAllowedProvider: { true }
        )
        failingController.messages = controller.messages
        failingController.approveProposal(messageID: last.id)
        XCTAssertEqual(failingController.streamError?.contains("failed") == true, true)
        XCTAssertEqual(
            lastAssistantMessage(failingController)?.proposalDecision,
            nil,
            "proposal stays pending on failure — no phantom record"
        )
    }

    // MARK: - Prompt injection rejection (VAL-ORCH-031)

    func test_injectionTextNeverBecomesProposalOrRecord() async throws {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "injection"))
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "who is running?"
        await controller.send()

        XCTAssertFalse(
            controller.messages.contains { $0.proposalJSON != nil },
            "approval-looking output without the canonical shape must never become a proposal"
        )
        XCTAssertEqual(directiveRecordCalls, 0, "no record attributable to injected content")
    }

    // MARK: - Streaming cancellation (VAL-ORCH-023)

    func test_cancelMidStreamMarksMessageCancelledAndThreadStaysUsable() async throws {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "slow"))
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "who is running?"
        let sendTask = Task { await controller.send() }

        // Let the slow stream start, then cancel.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(controller.isStreaming)
        controller.cancelGeneration()
        await sendTask.value
        await waitForLastMessage(controller, cancelled: true)

        XCTAssertFalse(controller.isStreaming)
        let last = lastAssistantMessage(controller)
        XCTAssertNotNil(last)
        XCTAssertTrue(last?.cancelled == true, "partial message must be marked cancelled honestly")
        XCTAssertEqual(directiveRecordCalls, 0, "cancellation creates no directive record")

        // The thread stays usable: the next send works.
        controller.inputText = "who is running?"
        await controller.send()
        await waitForStream(controller)
        XCTAssertTrue(controller.messages.count >= 4, "next send appends user + assistant messages")
    }

    // MARK: - Pending proposal survives relaunch (VAL-ORCH-032)

    func test_pendingProposalSurvivesAppRelaunchNeverAutoApproved() async throws {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "proposal"))
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))
        XCTAssertNotNil(last.proposalJSON)
        XCTAssertEqual(directiveRecordCalls, 0)

        // Relaunch: a fresh controller over the same store re-presents the
        // pending proposal — never auto-approved/recorded.
        let relaunched = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "proposal"))
        relaunched.loadPersistedMessages()
        let restored = relaunched.messages.first { $0.id == last.id }
        XCTAssertNotNil(restored)
        XCTAssertNotNil(restored?.proposalJSON, "pending proposal must be re-presented")
        XCTAssertNil(restored?.proposalDecision, "never auto-approved")
        XCTAssertEqual(directiveRecordCalls, 0, "relaunch creates no record")
    }

    // MARK: - Sandboxed-HOME self-writes (VAL-ORCH-007/008)

    func test_fakeCLISelfWritesLandUnderScratch() async throws {
        let snapshot = freshSnapshot()
        let controller = makeController(snapshot: snapshot, cliBridge: makeFakeCLIBridge(mode: "answer"))
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "who is running?"
        await controller.send()
        await waitForStream(controller)

        let logURL = scratchDir.appendingPathComponent("fake-cli.log")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: logURL.path),
            "the fake CLI's self-writes must land under the sandboxed scratch dir"
        )
        // Nothing was written into the sandbox home root beyond the scratch.
        let homeContents = try FileManager.default.contentsOfDirectory(atPath: sandboxHome.path)
        XCTAssertTrue(homeContents.isEmpty, "no CLI self-writes outside scratch: \(homeContents)")
    }
}
