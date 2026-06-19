import XCTest
import CryptoKit
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - PR-D3 headline END-TO-END memory-activation test
//
// Proves the whole loop is closed: a terminal chat commit enqueues an extraction job
// THROUGH THE TRANSACTIONAL (atomic-outbox) BRANCH → the `MemoryExtractionEngine` drains
// it via a REAL `ChatTranscriptExtractor` over a stubbed local model → a secret-bearing
// candidate is DROPPED by the G7 gate → a clean fact is stored QUARANTINED with the
// worker-stamped scope and deterministic id → the human APPROVES it → `recallChatMemory-
// Snippets` returns it → its citation resolves to a real `chat_messages.id`.
//
// This is the §4 "headline proof the loop is closed" from the integrated build plan. It
// also nails the PR-D3 must-fixes that are otherwise only structural:
//   #1 ONE shared `ControlPlaneStore` backs the service (enqueue) AND the engine (drain).
//   #2 The enqueue takes the TRANSACTIONAL branch: it commits inside the same db write as
//      the chat message (no second store, no post-write dual-write).
//   #3 Architectural guard: the engine's only durable-write path is the worker's
//      preflight/quarantine; a clean fact lands `.quarantined`, NEVER `.approved`, even
//      though the model proposed `.approved` — the worker overrode it.
//   #5 With the gate ON, the engine drains; with it OFF, nothing is claimed and nothing is
//      written (asserted by the kill-switch leg).
//
// THE FEATURE SHIPS OFF. This test forces BOTH levers ON explicitly to exercise the
// dormant machinery, mirroring the PR-D1 / PR-D2 tests. It never mutates global state.
@MainActor
final class MemoryActivationEndToEndTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MemoryActivationHTTPStub.reset()
        URLProtocol.registerClass(MemoryActivationHTTPStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MemoryActivationHTTPStub.self)
        MemoryActivationHTTPStub.reset()
        super.tearDown()
    }

    // MARK: - The headline end-to-end proof

    func test_endToEnd_transactionalEnqueue_engineDrains_secretDropped_factQuarantined_approved_recallResolvesCitation() async throws {
        // One queue → one DataStore → ONE shared ControlPlaneStore (must-fix #1).
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true)
        let store = ControlPlaneStore(dbQueue: queue)
        let settings = Self.makeSettingsWithExtractionEnabled()

        // The service wired through the TRANSACTIONAL slot, sharing `store` with the engine.
        let service = OpenBurnBarMemoryService(store: store)
        // Sanity: the service really conforms to the transactional protocol, so the atomic
        // branch (not the async fallback) is selected by `saveChatMessage`.
        XCTAssertNotNil(
            service as? any TransactionalMemoryExtractionServing,
            "OpenBurnBarMemoryService must take the transactional enqueue branch (must-fix #2)"
        )

        // The engine over the SAME store. It builds a real extractor + LLM client; the HTTP
        // stub answers the OpenAI-compatible /chat/completions the local provider calls.
        let engine = MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore()
        )

        // The terminal assistant message that triggers extraction. Its id is the job's
        // citation anchor; the stubbed model cites it, so the worker can recompute provenance.
        let threadID = "thread-e2e-d3"
        let terminalID = "msg-e2e-d3-terminal"
        let terminalBody = "Remember that I prefer Swift over Python for new services."
        let now = Date(timeIntervalSince1970: 1_950_000_000)

        // Stub: one CLEAN candidate (cites the terminal message) + one SECRET candidate (a
        // live-looking Anthropic key) that the G7 gate MUST drop.
        MemoryActivationHTTPStub.responseJSON = """
        {"memories":[
          {"text":"User prefers Swift over Python for new services.","kind":"preference","confidence":0.92,"messageId":"\(terminalID)"},
          {"text":"api key sk-ant-deadbeefdeadbeefdeadbeef0001","kind":"fact","confidence":0.9,"messageId":"\(terminalID)"}
        ]}
        """

        // (1) ENQUEUE THROUGH THE TRANSACTIONAL BRANCH. We drive the production seam
        // `ConversationStore.saveChatMessage(..., isTerminalAssistantCommit: true,
        // memoryService: service, ...)`, which writes the chat row AND the extraction-outbox
        // row in ONE transaction. This is the real atomic-outbox path, not a hand-rolled
        // enqueue.
        let assistant = ChatMessageRecord(
            id: terminalID,
            role: .assistant,
            content: terminalBody,
            timestamp: now
        )
        try await dataStore.actor.conversationStore.saveChatMessage(
            assistant,
            threadID: threadID,
            isTerminalAssistantCommit: true,
            memoryService: service,
            extractionContext: MemoryExtractionContext(
                scope: Self.scope,
                threadLogicalID: "\(threadID)-logical",
                promptVersion: ChatSessionController.memoryPromptVersion
            )
        )

        // The chat row and the outbox row both landed in the same commit.
        let (chatRows, jobRows) = try await queue.read { db -> (Int, Int) in
            let chat = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages WHERE id = ?", arguments: [terminalID]) ?? 0
            let jobs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_extraction_jobs") ?? 0
            return (chat, jobs)
        }
        XCTAssertEqual(chatRows, 1, "terminal chat message persisted")
        XCTAssertEqual(jobRows, 1, "extraction job enqueued atomically in the same transaction")

        // (2) ENGINE DRAINS. With both levers on, `runDrain` claims + processes the job via
        // the real extractor → stubbed model → G7 drop → worker provenance recompute.
        let report = await engine.runDrain()
        XCTAssertEqual(report.processed, 1, "the single enqueued job was processed")
        XCTAssertEqual(report.failed, 0, "the job succeeded (no transient fault)")
        XCTAssertTrue(MemoryActivationHTTPStub.requestCount >= 1, "the real extractor called the (stubbed) model")

        // The job is terminal-succeeded.
        let jobID = try await XCTUnwrapAsync(Self.onlyJobID(queue))
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .succeeded, "job committed to a terminal success")

        // (3) SECRET DROPPED + CLEAN FACT QUARANTINED. Exactly ONE memory persisted (the
        // secret candidate was dropped by the G7 gate, not stored). Deterministic id holds.
        let memoryID = "memory-\(jobID)-0"
        let memory = try await XCTUnwrapAsync(store.fetchChatMemoryAuthorityRecord(id: memoryID))
        XCTAssertEqual(memory.bodyRedacted, "User prefers Swift over Python for new services.")
        XCTAssertEqual(memory.kind, .preference)
        // Must-fix #3: the worker forced `.quarantined`, overriding the model's `.approved`.
        XCTAssertEqual(memory.reviewStatus, .quarantined, "the worker quarantines; it never trusts the model's review status")
        // Worker stamps the job's scope, not anything the model supplied.
        XCTAssertEqual(memory.scope, Self.scope, "the fact carries the worker-stamped (job) scope")

        // No second memory row exists for index 1 (the dropped secret).
        let droppedSecret = try await store.fetchChatMemoryAuthorityRecord(id: "memory-\(jobID)-1")
        XCTAssertNil(droppedSecret, "the secret-bearing candidate was DROPPED, never stored")
        let totalChatMemories = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? -1
        }
        XCTAssertEqual(totalChatMemories, 1, "exactly one clean fact stored; the secret never persisted")

        // The fact is INVISIBLE to recall while quarantined (the recall gate is `.approved`).
        let preApproval = try await store.recallChatMemorySnippets(Self.recallRequest)
        XCTAssertTrue(preApproval.isEmpty, "a quarantined memory must not be recallable")

        // (4) APPROVE → RECALL RETURNS IT → CITATION RESOLVES TO A REAL messageID.
        let approved = try await store.setChatMemoryReviewStatus(id: memoryID, status: .approved)
        XCTAssertTrue(approved, "approval flips the review status")

        let snippets = try await store.recallChatMemorySnippets(Self.recallRequest)
        XCTAssertEqual(snippets.count, 1, "the approved fact is now recallable")
        let snippet = try XCTUnwrap(snippets.first)
        XCTAssertEqual(snippet.memoryID, memoryID)
        XCTAssertEqual(snippet.text, "User prefers Swift over Python for new services.")

        // The citation leg: the worker rebuilt the citation from the cited SOURCE message, so
        // its `messageID` is the real terminal chat row, and it resolves back to that row.
        let citation = try XCTUnwrap(snippet.citations.first, "the recalled snippet carries its worker-stamped citation")
        XCTAssertEqual(citation.messageID, terminalID, "citation points at the real terminal message id")
        XCTAssertEqual(citation.role, "assistant", "role comes from the authoritative source row, not the model")
        // The content hash binds the SOURCE message body (must-fix #3), not the memory body.
        let expectedHash = SHA256.hash(data: Data(terminalBody.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(citation.contentHash, expectedHash, "content hash binds the cited source body")
        // Resolution: the citation's messageID maps to a real, citable chat row on the thread.
        let resolved = try await store.fetchChatProvenanceSourceMessage(
            threadID: threadID,
            messageID: try XCTUnwrap(citation.messageID)
        )
        XCTAssertEqual(resolved?.id, terminalID, "the citation resolves to the real source message")
        XCTAssertEqual(resolved?.body, terminalBody)
    }

    // MARK: - Kill-switch leg: gate OFF ⇒ engine claims nothing, writes nothing

    func test_endToEnd_killSwitchOff_drainsNothing_andWritesNothing() async throws {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true)
        let store = ControlPlaneStore(dbQueue: queue)
        // Gate CLOSED: the user toggle is off (the combined gate defaults ON, so we flip
        // the toggle off to halt extraction — the fail-closed "either lever off" leg).
        let settings = Self.makeSettingsWithExtractionDisabled()
        let service = OpenBurnBarMemoryService(store: store)
        let engine = MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore()
        )

        let threadID = "thread-off"
        let terminalID = "msg-off-terminal"
        let now = Date(timeIntervalSince1970: 1_950_000_100)
        MemoryActivationHTTPStub.responseJSON = """
        {"memories":[{"text":"Should never be stored.","kind":"fact","messageId":"\(terminalID)"}]}
        """

        try await dataStore.actor.conversationStore.saveChatMessage(
            ChatMessageRecord(id: terminalID, role: .assistant, content: "Anything.", timestamp: now),
            threadID: threadID,
            isTerminalAssistantCommit: true,
            memoryService: service,
            extractionContext: MemoryExtractionContext(
                scope: Self.scope,
                threadLogicalID: "\(threadID)-logical",
                promptVersion: ChatSessionController.memoryPromptVersion
            )
        )

        // The job still enqueues atomically (the enqueue is not gated — only processing is).
        let jobRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_extraction_jobs") ?? 0
        }
        XCTAssertEqual(jobRows, 1, "enqueue is independent of the kill switch (atomic outbox always fills)")

        // Drain with the gate OFF: returns the kill-switch reason, claims nothing, never
        // calls the model, and writes no memory.
        let report = await engine.runDrain()
        XCTAssertEqual(report.processed, 0)
        XCTAssertEqual(report.stoppedReason, .killSwitchOff)
        XCTAssertEqual(MemoryActivationHTTPStub.requestCount, 0, "no LLM egress when extraction is off")

        let jobID = try await XCTUnwrapAsync(Self.onlyJobID(queue))
        XCTAssertEqual(try await store.memoryExtractionJobStatus(id: jobID), .pending, "a closed gate must not claim (burn an attempt on) the job")
        let memCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? -1
        }
        XCTAssertEqual(memCount, 0, "nothing written while the kill switch is off")
    }

    // MARK: - Fixtures

    private static let scope = MemoryScope(appID: "openburnbar")

    private static var recallRequest: MemoryRecallRequest {
        MemoryRecallRequest(query: "language preference", scope: scope, limit: 5, tokenBudget: 4_000)
    }

    /// An isolated `SettingsManager` (its own ephemeral `UserDefaults`) with BOTH levers of
    /// the combined extraction gate flipped ON, and a local-first provider so the stubbed
    /// `/chat/completions` is the path taken. Never touches `.standard` defaults.
    private static func makeSettingsWithExtractionEnabled() -> SettingsManager {
        let settings = makeIsolatedSettings()
        settings.memoryAutomaticExtraction = true        // user toggle
        settings.memoryExtractionRemoteConfigEnabled = true  // fleet kill switch
        XCTAssertTrue(settings.memoryExtractionEnabled, "both levers on ⇒ combined gate allows")
        configureLocalProvider(settings)
        return settings
    }

    private static func makeSettingsWithExtractionDisabled() -> SettingsManager {
        let settings = makeIsolatedSettings()
        // The combined gate defaults ON (both sub-levers default true), so close it
        // explicitly: with the user toggle off, `memoryExtractionEnabled` is false and the
        // engine claims nothing. This is the "either lever off ⇒ halted" fail-closed leg.
        settings.memoryAutomaticExtraction = false
        XCTAssertFalse(settings.memoryExtractionEnabled, "user toggle off ⇒ combined gate closed")
        configureLocalProvider(settings)
        return settings
    }

    private static func makeIsolatedSettings() -> SettingsManager {
        let suite = "memory-e2e-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return SettingsManager(defaults: defaults)
    }

    /// Point the summary-derived provider settings at a local (mlx) endpoint the HTTP stub
    /// answers, with a generous cap so the cost gate never blocks the stubbed call. The
    /// engine forces local-first regardless, so the cloud tail is never reached here.
    private static func configureLocalProvider(_ settings: SettingsManager) {
        settings.setSummaryProviderOrder([.mlx])
        settings.summaryMLXBaseURL = "http://127.0.0.1:9999"
        settings.summaryMLXModel = "test-model"
        settings.summaryDailyCapUSD = 100
        settings.summaryRequestTimeoutSeconds = 5
    }

    /// The single enqueued job's id (the outbox holds exactly one row in these tests).
    private static func onlyJobID(_ queue: DatabaseQueue) async throws -> String? {
        try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM memory_extraction_jobs LIMIT 1")
        }
    }

    /// `XCTUnwrap` for an async-throwing optional (XCTest's is sync-only).
    private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let value = try await expression()
        return try XCTUnwrap(value, file: file, line: line)
    }
}

// MARK: - Local model HTTP stub

/// `URLProtocol` registered on `URLSession.shared` that answers the OpenAI-compatible
/// `/chat/completions` endpoint with a canned assistant message wrapping `responseJSON`.
/// Keeps the end-to-end test hermetic (no real network), mirroring the PR-D1 stub.
private final class MemoryActivationHTTPStub: URLProtocol {
    private static let lock = NSLock()
    private static var _requestCount = 0
    private static var _responseJSON = "{\"memories\":[]}"

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    static var responseJSON: String {
        get { lock.lock(); defer { lock.unlock() }; return _responseJSON }
        set { lock.lock(); _responseJSON = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock(); _requestCount = 0; _responseJSON = "{\"memories\":[]}"; lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("chat/completions") ?? false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._requestCount += 1; let json = Self._responseJSON; Self.lock.unlock()

        let escaped = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let envelope = """
        {"choices":[{"message":{"role":"assistant","content":"\(escaped)"}}]}
        """
        let data = Data(envelope.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
