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
//   #5 With both levers ON, the engine drains and writes; with the extraction gate OFF,
//      nothing is claimed and nothing is written (asserted by the kill-switch leg); with
//      extraction ON but authority writes explicitly OFF, the loop may run but ZERO
//      durable memories are written (asserted by the gate-matrix leg; PR-D FIX #2).
//
// The production path is live after opt-in: durable writes require the AND of two
// independent levers, `memoryExtractionEnabled` (consent + user toggle + fleet gate)
// and `chatMemoryAuthorityWritesEnabledByDefault`. This test keeps both levers on to
// exercise the write path; it never mutates global state.
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
        // `OpenBurnBarMemoryService` conforms to `TransactionalMemoryExtractionServing`
        // at COMPILE TIME (since #602), so `saveChatMessage` selects the atomic enqueue
        // branch, never the async fallback. This typed binding fails to compile if that
        // conformance ever regresses; the atomic commit itself is proven below
        // (`jobRows == 1` in the same write transaction as the chat row). Must-fix #2.
        let _: any TransactionalMemoryExtractionServing = service

        // The engine over the SAME store. It builds a real extractor + LLM client; the HTTP
        // stub answers the OpenAI-compatible /chat/completions the local provider calls.
        // BOTH levers ON: extraction enabled (in `settings`) AND authority writes allowed
        // here, so the worker's authority closure (their AND) permits the
        // durable write this test asserts.
        let engine = MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore(),
            authorityWritesGoLiveEnabled: true
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
        let jobIDValue = try await Self.onlyJobID(queue)
        let jobID = try XCTUnwrap(jobIDValue)
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .succeeded, "job committed to a terminal success")

        // (3) SECRET DROPPED + CLEAN FACT QUARANTINED. Exactly ONE memory persisted (the
        // secret candidate was dropped by the G7 gate, not stored). Deterministic id holds.
        let memoryID = "memory-\(jobID)-0"
        let memoryValue = try await store.fetchChatMemoryAuthorityRecord(id: memoryID)
        let memory = try XCTUnwrap(memoryValue)
        // G1 (frozen MemoryServing contract): bodyRedacted is a SEALED reference, never
        // plaintext at rest. The fact text lives only in the sealed store and is opened
        // transiently. Asserting the ref shape here is the at-rest privacy invariant.
        XCTAssertTrue(memory.bodyRedacted.hasPrefix("memory_body_snapshots:"),
                      "G1: bodyRedacted must be a sealed-snapshot reference, never plaintext")
        let openedBody = try await store.openChatMemoryBody(id: memoryID)
        XCTAssertEqual(openedBody, "User prefers Swift over Python for new services.")
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
        // Gate CLOSED via the EXTRACTION lever: the user toggle is off, so
        // `memoryExtractionEnabled` is false and the engine's `runDrain` short-circuits to
        // `.killSwitchOff` before any pump. Authority writes are forced ON here so this leg
        // isolates the extraction-gate lever (not the authority lever, which the gate-matrix
        // test below exercises).
        let settings = Self.makeSettingsWithExtractionDisabled()
        let service = OpenBurnBarMemoryService(store: store)
        let engine = MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore(),
            authorityWritesGoLiveEnabled: true
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

        let jobIDValue = try await Self.onlyJobID(queue)
        let jobID = try XCTUnwrap(jobIDValue)
        let closedGateStatus = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(closedGateStatus, .pending, "a closed gate must not claim (burn an attempt on) the job")
        let memCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? -1
        }
        XCTAssertEqual(memCount, 0, "nothing written while the kill switch is off")
    }

    // MARK: - Gate-open leg: persisted backlog drains when consent opens after enqueue

    func test_gateOpeningAfterJobEnqueued_launchesDrainForExistingBacklog() async throws {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true)
        let store = ControlPlaneStore(dbQueue: queue)
        let settings = Self.makeIsolatedSettings()
        Self.configureLocalProvider(settings)
        settings.memoryAutomaticExtraction = true
        settings.memoryExtractionRemoteConfigEnabled = true
        XCTAssertFalse(settings.memoryExtractionEnabled, "consent is still closed, so the engine must not claim yet")

        let service = OpenBurnBarMemoryService(store: store)
        let engine = MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore(),
            authorityWritesGoLiveEnabled: true
        )
        XCTAssertNil(engine.lastPumpReport)

        let threadID = "thread-gate-open"
        let terminalID = "msg-gate-open-terminal"
        MemoryActivationHTTPStub.responseJSON = """
        {"memories":[{"text":"User prefers local memory extraction.","kind":"preference","confidence":0.91,"messageId":"\(terminalID)"}]}
        """

        try await dataStore.actor.conversationStore.saveChatMessage(
            ChatMessageRecord(
                id: terminalID,
                role: .assistant,
                content: "Remember that local memory extraction is preferred.",
                timestamp: Date(timeIntervalSince1970: 1_950_000_300)
            ),
            threadID: threadID,
            isTerminalAssistantCommit: true,
            memoryService: service,
            extractionContext: MemoryExtractionContext(
                scope: Self.scope,
                threadLogicalID: "\(threadID)-logical",
                promptVersion: ChatSessionController.memoryPromptVersion
            )
        )

        let jobIDValue = try await Self.onlyJobID(queue)
        let jobID = try XCTUnwrap(jobIDValue)
        let initialStatus = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(initialStatus, .pending)
        XCTAssertEqual(MemoryActivationHTTPStub.requestCount, 0, "closed consent must not call the model")

        settings.memoryConsentGranted = true

        try await Self.waitForJobStatus(.succeeded, jobID: jobID, store: store)
        let chatMemoryCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? -1
        }
        XCTAssertEqual(chatMemoryCount, 1, "opening the gate drains the already-pending backlog")
        XCTAssertEqual(MemoryActivationHTTPStub.requestCount, 1, "the drain was launched by the gate-open notification")
    }

    // MARK: - Gate-matrix leg (PR-D FIX #2): extraction ENABLED + authority OFF => 0 writes
    //
    // This is the regression the original headline test made UNREPRESENTABLE: it set only
    // `memoryExtractionEnabled` (default TRUE) and asserted a durable write, which encoded
    // the two-levers-collapsed-into-one bug as expected behavior. Here extraction is ENABLED
    // but authority writes are explicitly OFF. The worker's authority closure is the AND of
    // the two levers, so it is `true && false == false`:
    // the loop may run, but ZERO durable `agent_memories` rows are written, and crucially the
    // job is NOT silently marked succeeded as if it had written.
    func test_gateMatrix_extractionEnabled_explicitWritesOff_drainsButWritesNothing() async throws {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true)
        let store = ControlPlaneStore(dbQueue: queue)

        // Extraction ENABLED (both G4 sub-levers on) — the LLM round-trip is permitted.
        let settings = Self.makeSettingsWithExtractionEnabled()
        XCTAssertTrue(settings.memoryExtractionEnabled, "extraction lever is ON for this leg")
        // Production authority writes default on; this leg explicitly injects OFF below
        // to keep the safety matrix covered.
        XCTAssertTrue(
            ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault,
            "production authority writes should default on after memory opt-in"
        )
        let service = OpenBurnBarMemoryService(store: store)
        let engine = MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore(),
            authorityWritesGoLiveEnabled: false
        )

        let threadID = "thread-authority-off"
        let terminalID = "msg-authority-off-terminal"
        let now = Date(timeIntervalSince1970: 1_950_000_200)
        // A clean, non-secret candidate that WOULD be stored if the authority lever allowed.
        MemoryActivationHTTPStub.responseJSON = """
        {"memories":[{"text":"User prefers tabs over spaces.","kind":"preference","confidence":0.9,"messageId":"\(terminalID)"}]}
        """

        try await dataStore.actor.conversationStore.saveChatMessage(
            ChatMessageRecord(id: terminalID, role: .assistant, content: "Noted your preference.", timestamp: now),
            threadID: threadID,
            isTerminalAssistantCommit: true,
            memoryService: service,
            extractionContext: MemoryExtractionContext(
                scope: Self.scope,
                threadLogicalID: "\(threadID)-logical",
                promptVersion: ChatSessionController.memoryPromptVersion
            )
        )

        // The outbox still fills atomically — enqueue is never gated, only processing is.
        let jobRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_extraction_jobs") ?? 0
        }
        XCTAssertEqual(jobRows, 1, "enqueue is independent of the authority lever")

        // Drain with extraction ON but authority writes explicitly OFF. `runDrain` passes its own
        // `memoryExtractionEnabled` entry guard (extraction IS enabled), so it builds a pump
        // and ticks the worker — but the worker's pre-claim authority guard (the AND) is
        // false, so it claims NOTHING and the pump reports idle with zero processed.
        let report = await engine.runDrain()
        XCTAssertEqual(report.processed, 0, "no job processed while authority writes are off")
        XCTAssertEqual(report.failed, 0, "and no job spuriously failed either")
        XCTAssertEqual(
            report.stoppedReason, .idle,
            "the worker's authority gate returns idle pre-claim; the pump stops cleanly"
        )
        // The model is NEVER called: the worker short-circuits before the extractor runs, so
        // there is no LLM egress when the authority lever is off (defense against paid calls).
        XCTAssertEqual(MemoryActivationHTTPStub.requestCount, 0, "no LLM egress while authority writes are off")

        // The job is NOT silently succeeded — it stays claimable (`pending`) for a future
        // drain after authority writes are allowed. This is the "does not succeed as if it wrote" half.
        let jobIDValue = try await Self.onlyJobID(queue)
        let jobID = try XCTUnwrap(jobIDValue)
        let authorityOffStatus = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(
            authorityOffStatus, .pending,
            "an off authority lever must not claim or terminally complete the job"
        )

        // ZERO durable memories written — the headline assertion of this regression.
        let chatMemoryCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? -1
        }
        XCTAssertEqual(chatMemoryCount, 0, "extraction ON + authority OFF => ZERO durable memories")
        // The deterministic id that WOULD have been written is absent.
        let wouldBeMemory = try await store.fetchChatMemoryAuthorityRecord(id: "memory-\(jobID)-0")
        XCTAssertNil(wouldBeMemory, "no authority record exists while authority writes are off")
    }

    func test_runDrainSchedulesFollowUpWhenBacklogExceedsPumpCeiling() async throws {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true)
        let store = ControlPlaneStore(dbQueue: queue)
        let settings = Self.makeSettingsWithExtractionEnabled()
        let service = OpenBurnBarMemoryService(store: store)
        let engine = MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore(),
            authorityWritesGoLiveEnabled: true
        )

        MemoryActivationHTTPStub.responseJSON = "{\"memories\":[]}"
        let totalJobs = MemoryExtractionPolicy.maxJobsPerPump + 1
        let now = Date(timeIntervalSince1970: 1_950_001_000)
        for index in 0 ..< totalJobs {
            let threadID = "thread-ceiling-\(index)"
            let messageID = "msg-ceiling-\(index)"
            try await dataStore.actor.conversationStore.saveChatMessage(
                ChatMessageRecord(
                    id: messageID,
                    role: .assistant,
                    content: "Backlog item \(index).",
                    timestamp: now.addingTimeInterval(TimeInterval(index))
                ),
                threadID: threadID,
                isTerminalAssistantCommit: true,
                memoryService: service,
                extractionContext: MemoryExtractionContext(
                    scope: Self.scope,
                    threadLogicalID: "\(threadID)-logical",
                    promptVersion: ChatSessionController.memoryPromptVersion
                )
            )
        }

        let firstReport = await engine.runDrain()
        XCTAssertEqual(firstReport.processed, MemoryExtractionPolicy.maxJobsPerPump)
        XCTAssertEqual(firstReport.stoppedReason, .reachedJobCeiling)

        try await Self.waitForSucceededJobCount(totalJobs, queue: queue)
        let counts = try await Self.jobStatusCounts(queue)
        XCTAssertEqual(counts[MemoryEventStatus.pending.rawValue] ?? 0, 0)
        XCTAssertEqual(counts[MemoryEventStatus.succeeded.rawValue] ?? 0, totalJobs)
        XCTAssertEqual(MemoryActivationHTTPStub.requestCount, totalJobs)
    }

    // MARK: - Fixtures

    private static let scope = MemoryScope(appID: "openburnbar")

    private static var recallRequest: MemoryRecallRequest {
        MemoryRecallRequest(query: "language preference", scope: scope, tokenBudget: 4_000, limit: 5)
    }

    /// An isolated `SettingsManager` (its own ephemeral `UserDefaults`) with both G4
    /// sub-levers of the combined extraction gate (the user toggle AND the Remote Config
    /// fleet switch) flipped ON, and a local-first provider so the stubbed
    /// `/chat/completions` is the path taken. Never touches `.standard` defaults.
    private static func makeSettingsWithExtractionEnabled() -> SettingsManager {
        let settings = makeIsolatedSettings()
        settings.memoryConsentGranted = true             // G0 consent (default OFF)
        settings.memoryAutomaticExtraction = true        // user toggle
        settings.memoryExtractionRemoteConfigEnabled = true  // fleet kill switch
        XCTAssertTrue(settings.memoryExtractionEnabled, "consent + both levers on ⇒ combined gate allows")
        configureLocalProvider(settings)
        return settings
    }

    private static func makeSettingsWithExtractionDisabled() -> SettingsManager {
        let settings = makeIsolatedSettings()
        // Consent is granted so this leg isolates the USER TOGGLE as the disabler:
        // with the toggle off, `memoryExtractionEnabled` is false and the engine
        // claims nothing. This is the "any lever off ⇒ halted" fail-closed leg.
        settings.memoryConsentGranted = true
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

    private static func waitForJobStatus(
        _ expected: MemoryEventStatus,
        jobID: String,
        store: ControlPlaneStore,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastStatus: MemoryEventStatus?
        while Date() < deadline {
            lastStatus = try await store.memoryExtractionJobStatus(id: jobID)
            if lastStatus == expected { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for job \(jobID) to reach \(expected), last status: \(String(describing: lastStatus))")
    }

    private static func waitForSucceededJobCount(
        _ expected: Int,
        queue: DatabaseQueue,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCounts: [String: Int] = [:]
        while Date() < deadline {
            lastCounts = try await jobStatusCounts(queue)
            if lastCounts[MemoryEventStatus.succeeded.rawValue] == expected { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(expected) succeeded jobs, last counts: \(lastCounts)")
    }

    private static func jobStatusCounts(_ queue: DatabaseQueue) async throws -> [String: Int] {
        try await queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT status, COUNT(*) AS count FROM memory_extraction_jobs GROUP BY status"
            )
            var counts: [String: Int] = [:]
            for row in rows {
                guard let status: String = row["status"], let count: Int = row["count"] else {
                    continue
                }
                counts[status] = count
            }
            return counts
        }
    }
}

// MARK: - Local model HTTP stub

/// `URLProtocol` registered on `URLSession.shared` that answers the OpenAI-compatible
/// `/chat/completions` endpoint with a canned assistant message wrapping `responseJSON`.
/// Keeps the end-to-end test hermetic (no real network), mirroring the PR-D1 stub.
private final class MemoryActivationHTTPStub: URLProtocol {
    private static let lock = NSLock()
    // Lock-guarded below; `nonisolated(unsafe)` tells StrictConcurrency the safety is
    // hand-managed (every access goes through `lock`), not a data race.
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _responseJSON = "{\"memories\":[]}"

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
