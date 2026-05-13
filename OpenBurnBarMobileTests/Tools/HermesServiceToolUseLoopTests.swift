import XCTest
import Foundation
import FirebaseAuth
import FirebaseCore
import OpenBurnBarCore
@testable import OpenBurnBarMobile

// MARK: - Hermes Tool Use Loop Integration
//
// Exercises the full Hermes round trip:
//   1. iOS sends a `/v1/chat/completions` request with `tools` advertised.
//   2. Relay streams back an assistant turn carrying `tool_calls[]`.
//   3. iOS executes the tool locally via the catalog.
//   4. iOS re-streams with a `role: "tool"` reply appended.
//   5. Relay streams back the final natural-language answer.
//
// Uses a scripted `FakeToolUseRelayTransport` that returns deterministic
// SSE chunks per turn so we can prove the loop actually appends results
// and stops at the cap.

@MainActor
final class HermesServiceToolUseLoopTests: XCTestCase {

    override class func setUp() {
        if FirebaseApp.app() == nil {
            let options = FirebaseOptions(
                googleAppID: "1:0:ios:0",
                gcmSenderID: "0"
            )
            options.apiKey = "fake"
            options.projectID = "test"
            options.bundleID = Bundle.main.bundleIdentifier ?? "test"
            FirebaseApp.configure(options: options)
        }
    }

    func test_toolUseLoop_executesAtomToolAndProducesFinalAnswer() async throws {
        let relay = FakeToolUseRelayTransport(turns: [
            // Turn 1: assistant emits a tool_call.
            [
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-7","function":{"name":"burnbar_atom_open","arguments":"{\"atom_url\":\"burnbar://window?value=7d\"}"}}]}}]}"#,
                "data: [DONE]"
            ],
            // Turn 2: assistant emits the final natural-language answer.
            [
                #"data: {"choices":[{"delta":{"content":"Opened your 7-day window."}}]}"#,
                "data: [DONE]"
            ]
        ])

        let service = HermesService(
            relayTransport: relay,
            toolCatalog: MobileToolCatalog.default
        )
        let navigator = RecordingNavigator()
        service.setToolAtomNavigator(navigator)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Open my 7-day window")
        try await waitForStreamToFinish(service)

        XCTAssertEqual(relay.streamingPayloads.count, 2,
                       "Expected one upstream call per tool-use iteration")
        XCTAssertEqual(navigator.openCalls.count, 1)
        XCTAssertEqual(navigator.openCalls.first, .window(.sevenDays))

        // After the loop completes, the chat history should contain:
        //   user, assistant(tool_calls), tool(reply), assistant(text).
        XCTAssertEqual(service.messages.count, 4)
        XCTAssertEqual(service.messages[0].role, .user)
        XCTAssertEqual(service.messages[1].role, .assistant)
        XCTAssertEqual(service.messages[1].toolCalls.first?.name, "burnbar_atom_open")
        XCTAssertEqual(service.messages[1].toolCalls.first?.status, "done")
        XCTAssertEqual(service.messages[2].role, .tool)
        XCTAssertNotNil(service.messages[2].toolCallID)
        XCTAssertEqual(service.messages[3].role, .assistant)
        XCTAssertEqual(service.messages[3].text, "Opened your 7-day window.")
        XCTAssertFalse(service.isStreaming)
    }

    func test_toolUseLoop_secondTurnRequestIncludesToolsAndToolReply() async throws {
        let relay = FakeToolUseRelayTransport(turns: [
            [
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-9","function":{"name":"burnbar_runtime_status","arguments":"{}"}}]}}]}"#,
                "data: [DONE]"
            ],
            [
                #"data: {"choices":[{"delta":{"content":"All good — I am hermes."}}]}"#,
                "data: [DONE]"
            ]
        ])

        let service = HermesService(
            relayTransport: relay,
            toolCatalog: MobileToolCatalog.default
        )
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Are you online?")
        try await waitForStreamToFinish(service)

        XCTAssertEqual(relay.streamingPayloads.count, 2)
        let secondBody = try XCTUnwrap(relay.streamingPayloads[1].body)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        )
        XCTAssertNotNil(payload["tools"], "follow-up turn must still advertise tools")
        let wireMessages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        // Expected wire shape: system, user, assistant(tool_calls), tool.
        let roles = wireMessages.compactMap { $0["role"] as? String }
        XCTAssertEqual(roles.suffix(2), ["assistant", "tool"])
        let assistantTurn = wireMessages.first { $0["role"] as? String == "assistant" }
        XCTAssertNotNil(assistantTurn?["tool_calls"])
        let toolTurn = wireMessages.first { $0["role"] as? String == "tool" }
        XCTAssertEqual(toolTurn?["tool_call_id"] as? String, "call-9")
        XCTAssertNotNil(toolTurn?["content"] as? String)
    }

    func test_toolUseLoop_stopsAtIterationCap() async throws {
        // Six turns of tool calls — every turn the model asks for another
        // tool. The service must stop at the iteration cap (5) and leave
        // the user with the pills "done" rather than recursing forever.
        var turns: [[String]] = []
        for _ in 0..<10 {
            turns.append([
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-loop","function":{"name":"burnbar_runtime_status","arguments":"{}"}}]}}]}"#,
                "data: [DONE]"
            ])
        }
        let relay = FakeToolUseRelayTransport(turns: turns)
        let service = HermesService(
            relayTransport: relay,
            toolCatalog: MobileToolCatalog.default
        )
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Stress test")
        try await waitForStreamToFinish(service)

        XCTAssertLessThanOrEqual(relay.streamingPayloads.count, 6,
                                 "Should stop after the iteration cap (≤ initial + 5 follow-ups)")
        XCTAssertFalse(service.isStreaming)
    }

    func test_emptyCatalog_omitsToolsKeyAndDoesNotLoop() async throws {
        let relay = FakeToolUseRelayTransport(turns: [
            [
                #"data: {"choices":[{"delta":{"content":"Hi there"}}]}"#,
                "data: [DONE]"
            ]
        ])
        let service = HermesService(
            relayTransport: relay,
            toolCatalog: MobileToolCatalog(tools: [])
        )
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Hello")
        try await waitForStreamToFinish(service)

        XCTAssertEqual(relay.streamingPayloads.count, 1)
        let body = try XCTUnwrap(relay.streamingPayloads.first?.body)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertNil(payload["tools"], "empty catalog must omit the tools key")
    }

    // MARK: - Helpers

    private func relayConnection() -> HermesConnectionRecord {
        HermesConnectionRecord(
            id: "relay-mac",
            displayName: "Mac (relay)",
            mode: .relayLink,
            status: .online,
            relayPublicKey: "AAAA",
            relayKeyVersion: 1,
            relayEncryption: "xchacha20-poly1305",
            capabilities: ["chat_completions"]
        )
    }

    /// Polls the service until streaming completes or a deadline passes.
    /// Uses small sleeps so the SSE callbacks have time to fan out
    /// through `MainActor.run`. 10s ceiling is generous — fakes finish
    /// in milliseconds.
    private func waitForStreamToFinish(
        _ service: HermesService,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while service.isStreaming && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(service.isStreaming, "service should not be streaming after \(timeout)s")
    }
}

// MARK: - Fakes

/// Plays back a pre-scripted set of SSE events per `sendStreaming` call.
/// `turns[0]` answers the first iteration, `turns[1]` the second, etc.
/// If more iterations are attempted than scripts provided, the
/// transport returns `[DONE]` immediately so tests never hang waiting
/// for a missing turn.
@MainActor
private final class FakeToolUseRelayTransport: HermesRelayTransporting {
    var unaryResponses: [HermesRelayOperation: Data] = [
        .models: Data(#"{"data":[{"id":"hermes-test","owned_by":"hermes"}]}"#.utf8)
    ]
    private(set) var unaryPayloads: [HermesRelayPayload] = []
    private(set) var streamingPayloads: [HermesRelayPayload] = []
    private var turns: [[String]]

    init(turns: [[String]]) {
        self.turns = turns
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        unaryPayloads.append(payload)
        return unaryResponses[payload.operation] ?? Data()
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        streamingPayloads.append(payload)
        let events = turns.isEmpty ? ["data: [DONE]"] : turns.removeFirst()
        for event in events {
            onSSEEvent(event)
        }
    }
}

@MainActor
private final class RecordingNavigator: HermesAtomNavigator {
    var openCalls: [HermesAtom] = []
    func open(_ atom: HermesAtom) {
        openCalls.append(atom)
    }
}
