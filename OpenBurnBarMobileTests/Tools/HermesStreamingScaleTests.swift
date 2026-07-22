import XCTest
import Foundation
import FirebaseCore
import OpenBurnBarCore
@testable import OpenBurnBarMobile

// MARK: - Hermes Streaming Scale / Bounded-Work Tests
//
// remediation(chat-streaming-o2): the streaming append path used to do O(n)
// work per SSE chunk over the growing message state (per-token transcript
// commits, per-fragment tool-argument re-summarisation, unthrottled
// reasoning commits), making a full stream O(n²). These tests stream large
// synthetic completions (thousands of chunks) through the same scripted
// relay-transport pattern as `HermesServiceToolUseLoopTests` and assert BOTH
// correctness at scale (nothing dropped, duplicated, or reordered) and
// bounded per-chunk work (the number of transcript commits stays orders of
// magnitude below the chunk count, guarding the ~80ms commit throttle).
//
// The commit counter (`HermesService.streamedTranscriptCommitCount`) counts
// every staged-message commit applied to the visible transcript. With the
// throttle in place a synchronous synthetic stream commits once for the
// first chunk plus at most one commit per elapsed 80ms window plus a handful
// of structural commits — the thresholds below leave an order of magnitude
// of headroom over the slowest plausible CI run while still failing loudly
// if anyone restores per-token commits.

@MainActor
final class HermesStreamingScaleTests: XCTestCase {

    override static func setUp() {
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

    // MARK: - Visible text at scale

    func test_largeTextStream_isCorrect_andCommitsAreBounded() async throws {
        let chunkCount = 3_000
        var chunks: [String] = []
        var expected = ""
        chunks.reserveCapacity(chunkCount + 1)
        for index in 0..<chunkCount {
            let token = "tok\(index) "
            expected += token
            chunks.append(Self.contentChunk(token))
        }
        chunks.append("data: [DONE]")

        let relay = FakeScriptedRelayTransport(turns: [chunks])
        let service = HermesService(
            relayTransport: relay,
            toolCatalog: MobileToolCatalog(tools: [])
        )
        XCTAssertTrue(service.selectConnection(Self.relayConnection(), refresh: false))

        service.sendMessage("Stream a long reply")
        try await Self.waitForStreamToFinish(service)

        XCTAssertEqual(relay.streamingPayloads.count, 1)
        XCTAssertEqual(service.messages.count, 2)
        XCTAssertEqual(service.messages[0].role, .user)
        let assistant = try XCTUnwrap(service.messages.last)
        XCTAssertEqual(assistant.role, .assistant)
        // Correctness at scale: every chunk present, in order, exactly once.
        XCTAssertEqual(assistant.text, expected)
        XCTAssertFalse(assistant.isStreaming)
        XCTAssertNotNil(assistant.responseCompletedAt, "finalizeResponseMetrics must have run")
        XCTAssertFalse(service.isStreaming)

        // Bounded per-chunk work: the ~80ms commit throttle must keep
        // transcript commits far below one-per-chunk. Headroom: even a CI
        // run where the whole synthetic stream takes 20+ seconds stays
        // under chunkCount / 10.
        XCTAssertGreaterThanOrEqual(service.streamedTranscriptCommitCount, 1)
        XCTAssertLessThanOrEqual(
            service.streamedTranscriptCommitCount,
            chunkCount / 10,
            "per-chunk transcript commits regressed — the streaming commit throttle is not bounding work"
        )
    }

    // MARK: - Cumulative-mode streams still replace (fast-path guard)

    func test_cumulativeStream_replacesInsteadOfDuplicating() async throws {
        // Some servers re-send the full accumulated text per chunk. The
        // O(1) length gate in front of the `hasPrefix` cumulative detector
        // must preserve the replace semantics (and duplicate chunks must
        // stay no-ops).
        let chunks = [
            Self.contentChunk("Hello"),
            Self.contentChunk("Hello"),          // duplicate → no-op
            Self.contentChunk("Hello, wor"),      // cumulative → replace
            Self.contentChunk("Hello, world!"),   // cumulative → replace
            "data: [DONE]"
        ]
        let relay = FakeScriptedRelayTransport(turns: [chunks])
        let service = HermesService(
            relayTransport: relay,
            toolCatalog: MobileToolCatalog(tools: [])
        )
        XCTAssertTrue(service.selectConnection(Self.relayConnection(), refresh: false))

        service.sendMessage("Cumulative")
        try await Self.waitForStreamToFinish(service)

        XCTAssertEqual(service.messages.last?.text, "Hello, world!")
    }

    // MARK: - Reasoning channel at scale

    func test_largeReasoningOnlyStream_hoistsFullReasoning_andCommitsAreBounded() async throws {
        let chunkCount = 1_200
        var chunks: [String] = []
        var expected = ""
        for index in 0..<chunkCount {
            let token = "think\(index) "
            expected += token
            chunks.append(Self.reasoningChunk(token))
        }
        chunks.append("data: [DONE]")

        let relay = FakeScriptedRelayTransport(turns: [chunks])
        let service = HermesService(
            relayTransport: relay,
            toolCatalog: MobileToolCatalog(tools: [])
        )
        XCTAssertTrue(service.selectConnection(Self.relayConnection(), refresh: false))

        service.sendMessage("Think hard")
        try await Self.waitForStreamToFinish(service)

        let assistant = try XCTUnwrap(service.messages.last)
        // Reasoning-only turns hoist the full reasoning channel into the
        // visible text at finalize — the throttled staging must not lose a
        // single chunk.
        XCTAssertEqual(assistant.text, expected.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(assistant.outcome, .reasoningFallback)
        XCTAssertLessThanOrEqual(
            service.streamedTranscriptCommitCount,
            chunkCount / 10,
            "reasoning-channel commits regressed — reasoning deltas must pace through the same throttle as text"
        )
    }

    // MARK: - Tool-call argument fragments at scale

    func test_largeToolArgumentStream_accumulatesExactArguments_andCommitsAreBounded() async throws {
        // One tool call whose JSON arguments arrive as ~800 fragments. The
        // engine must accumulate the exact argument string, derive the
        // human-readable detail from the FULL arguments at finalize, and
        // stay throttled while the fragments stream (the old path re-ran
        // the JSON/regex summarizer over the whole accumulated string per
        // fragment — O(n²)).
        let path = "/tmp/burnbar/" + String(repeating: "segment/", count: 300) + "file.txt"
        let fullArguments = "{\"path\":\"\(path)\"}"
        let fragmentSize = 8
        var fragments: [String] = []
        var remaining = Substring(fullArguments)
        while !remaining.isEmpty {
            fragments.append(String(remaining.prefix(fragmentSize)))
            remaining = remaining.dropFirst(fragmentSize)
        }
        XCTAssertGreaterThan(fragments.count, 300)

        var chunks: [String] = []
        for (index, fragment) in fragments.enumerated() {
            chunks.append(try Self.toolCallChunk(
                fragment: fragment,
                includeName: index == 0
            ))
        }
        chunks.append("data: [DONE]")

        let relay = FakeScriptedRelayTransport(turns: [chunks])
        // Empty catalog: the turn records the tool call but never enters the
        // execution loop, keeping this a pure streaming-accumulation test.
        let service = HermesService(
            relayTransport: relay,
            toolCatalog: MobileToolCatalog(tools: [])
        )
        XCTAssertTrue(service.selectConnection(Self.relayConnection(), refresh: false))

        service.sendMessage("Read a file")
        try await Self.waitForStreamToFinish(service)

        let assistant = try XCTUnwrap(service.messages.last)
        let call = try XCTUnwrap(assistant.toolCalls.first)
        XCTAssertEqual(call.arguments, fullArguments, "argument fragments must concatenate losslessly")
        XCTAssertEqual(call.status, "done")
        XCTAssertEqual(
            call.detail,
            String(path.prefix(200)),
            "finalize must re-summarize detail from the FULL argument string"
        )
        XCTAssertLessThanOrEqual(
            service.streamedTranscriptCommitCount,
            fragments.count / 5,
            "tool-argument fragments must not commit (or re-summarize) per fragment"
        )
    }

    // MARK: - Helpers

    private static func contentChunk(_ text: String) -> String {
        chunk(delta: ["content": text])
    }

    private static func reasoningChunk(_ text: String) -> String {
        chunk(delta: ["reasoning_content": text])
    }

    private static func chunk(delta: [String: Any]) -> String {
        let object: [String: Any] = ["choices": [["delta": delta]]]
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return "data: " + String(decoding: data, as: UTF8.self)
        } catch {
            preconditionFailure("Hermes streaming fixture must be JSON-serializable: \(error)")
        }
    }

    private static func toolCallChunk(fragment: String, includeName: Bool) throws -> String {
        var function: [String: Any] = ["arguments": fragment]
        if includeName {
            function["name"] = "read_file"
        }
        let object: [String: Any] = [
            "choices": [[
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call-args-1",
                        "function": function
                    ]]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return "data: " + String(decoding: data, as: UTF8.self)
    }

    private static func relayConnection() -> HermesConnectionRecord {
        HermesConnectionRecord(
            id: "relay-mac",
            displayName: "Mac (relay)",
            mode: .relayLink,
            status: .online,
            relayPublicKey: HermesRelayCrypto.generatePrivateKey().publicKeyBase64,
            relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3,
            relayEncryption: HermesRelayCrypto.relayEncryptionV3,
            capabilities: ["chat_completions"]
        )
    }

    /// Polls the service until streaming completes or a deadline passes.
    /// Mirrors `HermesServiceToolUseLoopTests.waitForStreamToFinish`.
    private static func waitForStreamToFinish(
        _ service: HermesService,
        timeout: TimeInterval = 30
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while service.isStreaming && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(service.isStreaming, "service should not be streaming after \(timeout)s")
    }
}

// MARK: - Fakes

/// Plays back a pre-scripted set of SSE events per `sendStreaming` call —
/// the same shape as `FakeToolUseRelayTransport` in
/// `HermesServiceToolUseLoopTests` (duplicated because that fake is
/// file-private by design).
@MainActor
private final class FakeScriptedRelayTransport: HermesRelayTransporting {
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
