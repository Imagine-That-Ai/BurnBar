import BurnBarCore
import Foundation
import GRDB
import XCTest

@testable import BurnBar

// MARK: - Chat Session Controller Orchestrator Test Support (M4)

/// Shared setup + helpers for the M4 orchestrator chat-mode test classes
/// (`ChatSessionControllerOrchestratorTests` and
/// `ChatSessionControllerDeliveryFlowTests`). Splitting the delivery-flow
/// tests into their own class keeps both classes under the 500-line
/// type_body_length lint budget while this base case preserves the shared
/// setup helpers in one place.
///
/// The deterministic PATH-shim fake CLI (`tools/burnbar-fake-cli.py`) is the
/// required M4 fixture: it emits the canonical proposal shape, deterministic
/// snapshot-derived answers, slow streams, and injection text — no live
/// model anywhere.
@MainActor
class ChatSessionControllerOrchestratorTestCase: XCTestCase {

    var store: DataStore!
    var socketURL: URL!
    var shimDir: URL!
    var scratchDir: URL!
    var sandboxHome: URL!
    var recordedDirectives: [BurnBarFleetDirective] = []
    var directiveRecordCalls = 0

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
    func freshSnapshot() -> BurnBarFleetSnapshot {
        FleetTestFixtures.makeSnapshot(generatedAt: Date())
    }

    func makeFakeCLIBridge(mode: String) -> CLIBridge {
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

    func makeController(
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

    func lastAssistantMessage(_ controller: ChatSessionController) -> ChatMessageRecord? {
        controller.messages.last { $0.role == .assistant }
    }

    /// Waits for the async stream task to finish (send() returns before the
    /// stream completes). The machine can be under heavy load (other agents
    /// build concurrently — documented flake condition with load averages
    /// above 20), so the timeout is generous.
    func waitForStream(_ controller: ChatSessionController, timeout: TimeInterval = 45) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.isStreaming, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until the last assistant message carries the given flag (the
    /// stream completion block persists the message asynchronously).
    func waitForLastMessage(
        _ controller: ChatSessionController,
        cancelled: Bool,
        timeout: TimeInterval = 45
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lastAssistantMessage(controller)?.cancelled == cancelled {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until the controller reaches (or leaves) the streaming state.
    /// Used instead of fixed sleeps so cancellation-race tests stay
    /// deterministic under heavy machine load (documented flake condition).
    func waitForStreaming(
        _ controller: ChatSessionController,
        shouldStream: Bool,
        timeout: TimeInterval = 45
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if controller.isStreaming == shouldStream {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until the last assistant message carries a proposal (the stream
    /// completion block attaches the parsed proposal asynchronously). On
    /// timeout the controller state AND the fake CLI's scratch log are
    /// surfaced so a refusal path (stale/daemon-down/CLI-unavailable) or a
    /// never-invoked/hung CLI is immediately identifiable.
    func waitForProposal(_ controller: ChatSessionController, timeout: TimeInterval = 45) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lastAssistantMessage(controller)?.proposalJSON != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let last = lastAssistantMessage(controller)
        let logURL = scratchDir.appendingPathComponent("fake-cli.log")
        let logContents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log file)"
        XCTFail(
            "waitForProposal timed out; isStreaming=\(controller.isStreaming) "
                + "activeStreamMessageId=\(controller.activeStreamMessageId ?? "nil") "
                + "messageCount=\(controller.messages.count) "
                + "lastAssistant=\(last.map { "cancelled=\($0.cancelled) proposal=\($0.proposalJSON != nil) content=\($0.content.prefix(200))" } ?? "nil") "
                + "streamError=\(controller.streamError ?? "nil") "
                + "fakeCLILog=\(logContents.replacingOccurrences(of: "\n", with: " | "))"
        )
    }

    /// Waits until the message with the given id satisfies the predicate
    /// (stream completion blocks update messages asynchronously).
    func waitForMessage(
        _ controller: ChatSessionController,
        id: String,
        predicate: @escaping (ChatMessageRecord) -> Bool,
        timeout: TimeInterval = 45
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let message = controller.messages.first(where: { $0.id == id }), predicate(message) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
