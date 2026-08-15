import BurnBarCore
import Foundation
import GRDB
import XCTest

@testable import BurnBar

// MARK: - Chat Session Controller Orchestrator Tests (M4)

/// M4 orchestrator chat-mode tests (VAL-ORCH-006/007/008/009/010/011/012/013/
/// 022/023/024/025/031/032/035). The deterministic PATH-shim fake CLI
/// (`tools/burnbar-fake-cli.py`) is the required M4 fixture: it emits the
/// canonical proposal shape, deterministic snapshot-derived answers, slow
/// streams, and injection text — no live model anywhere.
@MainActor
final class ChatSessionControllerOrchestratorTests: XCTestCase {

    private var store: DataStore!
    private var socketURL: URL!
    private var shimDir: URL!
    private var scratchDir: URL!
    private var sandboxHome: URL!
    private var recordedDirectives: [BurnBarFleetDirective] = []
    private var directiveRecordCalls = 0

    override func setUp() async throws {
        try await super.setUp()
        let queue = try DatabaseQueue(path: ":memory:")
        store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        socketURL = URL(fileURLWithPath: "/tmp/burnbar-chat-tests/daemon.sock")

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-chat-tests-\(UUID().uuidString)", isDirectory: true)
        shimDir = base.appendingPathComponent("shim", isDirectory: true)
        scratchDir = base.appendingPathComponent("scratch", isDirectory: true)
        sandboxHome = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tools/burnbar-fake-cli.py")
        try FileManager.default.createSymbolicLink(
            at: shimDir.appendingPathComponent("claude"),
            withDestinationURL: fixture
        )
        try FileManager.default.createSymbolicLink(
            at: shimDir.appendingPathComponent("codex"),
            withDestinationURL: fixture
        )
    }

    override func tearDown() async throws {
        recordedDirectives = []
        directiveRecordCalls = 0
        store = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A fresh snapshot (generatedAt = now) so tests that are not about
    /// staleness never trip the 2×cadence stale gate.
    private func freshSnapshot() -> BurnBarFleetSnapshot {
        FleetTestFixtures.makeSnapshot(generatedAt: Date())
    }

    private func makeFakeCLIBridge(mode: String) -> CLIBridge {
        CLIBridge(
            environment: [
                // The shim dir first, then /usr/bin so the fake CLI's
                // `#!/usr/bin/env python3` shebang resolves (the script uses
                // stdlib only). The shim dir is prepended again by
                // enrichedProcessEnvironment, so the fake CLI is always the
                // resolved `claude`/`codex`.
                "PATH": shimDir.path + ":/usr/bin",
                "HOME": sandboxHome.path,
                "BURNBAR_FAKE_CLI_SCRATCH": scratchDir.path,
                "BURNBAR_FAKE_CLI_MODE": mode
            ],
            homeDirectory: sandboxHome.path,
            executableSearchDirectories: [shimDir.path]
        )
    }

    private func makeController(
        snapshot: BurnBarFleetSnapshot,
        designation: BurnBarOrchestratorDesignation = .burnBarManaged,
        cliBridge: CLIBridge? = nil,
        cliAllowed: Bool = true,
        now: @escaping () -> Date = { Date() },
        deliveryChannelProvider: @escaping (BurnBarFleetAgentID?) -> BurnBarFleetDirectiveChannel? = { _ in nil }
    ) -> ChatSessionController {
        let fleetService = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in snapshot },
            now: now
        )
        return ChatSessionController(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            fleetService: fleetService,
            cliBridge: cliBridge,
            orchestratorStateProvider: { _ in
                BurnBarOrchestratorState(designation: designation, setAt: Date(), pendingDirectives: 0)
            },
            directiveRecordProvider: { [weak self] directive, _ in
                self?.recordedDirectives.append(directive)
                self?.directiveRecordCalls += 1
                return directive
            },
            deliveryChannelProvider: deliveryChannelProvider,
            cliAssistantAllowedProvider: { cliAllowed }
        )
    }

    private func lastAssistantMessage(_ controller: ChatSessionController) -> ChatMessageRecord? {
        controller.messages.last { $0.role == .assistant }
    }

    /// Waits for the async stream task to finish (send() returns before the
    /// stream completes). The machine can be under heavy load (other agents
    /// build concurrently), so the timeout is generous.
    private func waitForStream(_ controller: ChatSessionController, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.isStreaming, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until the last assistant message carries the given flag (the
    /// stream completion block persists the message asynchronously).
    private func waitForLastMessage(
        _ controller: ChatSessionController,
        cancelled: Bool,
        timeout: TimeInterval = 15
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lastAssistantMessage(controller)?.cancelled == cancelled {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until the last assistant message carries a proposal (the stream
    /// completion block attaches the parsed proposal asynchronously).
    private func waitForProposal(_ controller: ChatSessionController, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lastAssistantMessage(controller)?.proposalJSON != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

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
    // MARK: - Delivery flow (VAL-ORCH-014/030/037)

    /// A stub channel that records deliveries and returns a scripted outcome.
    private final class StubDeliveryChannel: BurnBarFleetDirectiveChannel, @unchecked Sendable {
        var outcome: BurnBarFleetDeliveryOutcome
        var deliveredDirectives: [BurnBarFleetDirective] = []
        init(outcome: BurnBarFleetDeliveryOutcome) {
            self.outcome = outcome
        }
        var channelName: String { "hermes" }
        func supports(targetAgent: BurnBarFleetAgentID) -> Bool {
            targetAgent == .hermes
        }
        func deliver(_ directive: BurnBarFleetDirective) async -> BurnBarFleetDeliveryOutcome {
            deliveredDirectives.append(directive)
            return outcome
        }
    }

    private func waitForDeliveryState(
        _ controller: ChatSessionController,
        _ expected: ChatDeliveryState,
        timeout: TimeInterval = 15
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lastAssistantMessage(controller)?.deliveryState == expected {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_approvalDeliversThroughHermesChannelAndRecordsDelivered() async throws {
        let snapshot = freshSnapshot()
        let channel = StubDeliveryChannel(outcome: .delivered)
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            deliveryChannelProvider: { target in
                guard target == .hermes else { return nil }
                return channel
            }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))

        controller.approveProposal(messageID: last.id)
        // Approval is recorded BEFORE delivery: the approved record exists
        // with decidedAt, and the card shows delivering then delivered.
        XCTAssertEqual(directiveRecordCalls, 1)
        let approved = try XCTUnwrap(recordedDirectives.first)
        guard case .approved = approved.state else {
            return XCTFail("expected approved record, got \(approved.state)")
        }
        XCTAssertNotNil(approved.decidedAt)

        await waitForDeliveryState(controller, .delivered)
        XCTAssertEqual(channel.deliveredDirectives.count, 1, "the channel received exactly one delivery")
        XCTAssertEqual(channel.deliveredDirectives.first?.id, "m4-proposal-001")
        // The terminal record is written with deliveryChannel "hermes".
        XCTAssertEqual(directiveRecordCalls, 2, "approved + delivered records")
        let terminal = try XCTUnwrap(recordedDirectives.last)
        XCTAssertEqual(terminal.state, .delivered)
        XCTAssertEqual(terminal.deliveryChannel, "hermes")
        XCTAssertEqual(terminal.decidedAt, approved.decidedAt, "decidedAt preserved across delivery")
    }

    func test_gatewayFailureProducesTypedFailedRecordAndRetry() async throws {
        let snapshot = freshSnapshot()
        let channel = StubDeliveryChannel(outcome: .failed(reason: "hermes gateway unreachable: boom"))
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            deliveryChannelProvider: { target in
                guard target == .hermes else { return nil }
                return channel
            }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))

        controller.approveProposal(messageID: last.id)
        await waitForDeliveryState(controller, .failed(reason: "hermes gateway unreachable: boom"))
        let failed = try XCTUnwrap(recordedDirectives.last)
        guard case .failed(let reason) = failed.state else {
            return XCTFail("expected failed record, got \(failed.state)")
        }
        XCTAssertTrue(reason.contains("boom"))
        XCTAssertEqual(failed.deliveryChannel, "hermes")

        // The documented single user-action retry: the channel is invoked
        // again only on explicit retry — no silent background loop.
        XCTAssertEqual(channel.deliveredDirectives.count, 1)
        channel.outcome = .delivered
        controller.retryDelivery(messageID: last.id)
        await waitForDeliveryState(controller, .delivered)
        XCTAssertEqual(channel.deliveredDirectives.count, 2, "retry is a single user action")
        let terminal = try XCTUnwrap(recordedDirectives.last)
        XCTAssertEqual(terminal.state, .delivered)
        XCTAssertEqual(terminal.decidedAt, failed.decidedAt, "retry preserves the original decidedAt")
    }

    func test_unsupportedAgentHonestDegradesNoSideEffects() async throws {
        // The canonical proposal targets hermes, but the channel provider
        // resolves no channel for it (e.g. branch B or a missing gateway):
        // the record stays approved, the card shows typed unsupported, and
        // no channel call or terminal record occurs (VAL-ORCH-037).
        let snapshot = freshSnapshot()
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            deliveryChannelProvider: { _ in nil }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))

        controller.approveProposal(messageID: last.id)
        await waitForDeliveryState(controller, .unsupported(reason: "no documented writable channel for hermes"))
        XCTAssertEqual(directiveRecordCalls, 1, "only the approved record — no terminal record")
        let approved = try XCTUnwrap(recordedDirectives.first)
        guard case .approved = approved.state else {
            return XCTFail("record must stay approved, got \(approved.state)")
        }
        XCTAssertEqual(lastAssistantMessage(controller)?.proposalDecision, .approved)
    }

    func test_dismissedProposalNeverDelivered() async throws {
        let snapshot = freshSnapshot()
        let channel = StubDeliveryChannel(outcome: .delivered)
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            deliveryChannelProvider: { target in
                guard target == .hermes else { return nil }
                return channel
            }
        )
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
            return XCTFail("expected dismissed record, got \(recorded.state)")
        }
        XCTAssertTrue(channel.deliveredDirectives.isEmpty, "a dismissed directive is never delivered")
        XCTAssertNil(lastAssistantMessage(controller)?.deliveryState, "no delivery state on a dismissed card")
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
