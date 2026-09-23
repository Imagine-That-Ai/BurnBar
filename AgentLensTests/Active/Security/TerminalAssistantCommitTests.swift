import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// F-0: terminal assistant-commit extraction trigger + `send()` reentrancy sentinel.
///
/// Two invariants under test:
///  - **G3 (trigger from persistence, not UI state):** extraction fires exactly once
///    from the `saveChatMessage` chokepoint for a terminal, non-empty assistant
///    commit — and never for non-terminal / empty / user / nil-service paths.
///  - **Reentrancy:** the synchronous `sendInFlight` sentinel rejects a second
///    `send()` in the pre-`isStreaming` await window and always resets on return.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class TerminalAssistantCommitTests: XCTestCase {

    // MARK: - Helpers

    private func makeInMemoryStore() throws -> DataStoreCoordinator {
        let queue = try DatabaseQueue()
        return try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            chatWriter: LocalChatHistoryWriter(dbQueue: queue)
        )
    }

    private func memoryCount(in fake: FakeMemoryService) async throws -> Int {
        let page = try await fake.getAll(
            MemoryPageRequest(scope: MemoryScope(appID: "openburnbar"), page: 1, pageSize: 200, includeQuarantined: true)
        )
        return page.total
    }

    private func makeAssistant(_ content: String = "Here is the answer.") -> ChatMessageRecord {
        ChatMessageRecord(role: .assistant, content: content)
    }

    private func makeContext(threadLogicalID: String = "thread-logical-1") -> MemoryExtractionContext {
        MemoryExtractionContext(
            scope: MemoryScope(appID: "openburnbar"),
            threadLogicalID: threadLogicalID,
            promptVersion: ChatSessionController.memoryPromptVersion
        )
    }

    // MARK: - Chokepoint: terminal assistant commit fires extraction (G3)

    func testTerminalAssistantCommitFiresExtraction() async throws {
        let store = try makeInMemoryStore()
        let fake = FakeMemoryService(seeded: false)
        let assistant = makeAssistant()
        try await store.saveChatMessage(
            assistant,
            threadID: "thread-1",
            isTerminalAssistantCommit: true,
            memoryService: fake,
            extractionContext: makeContext()
        )
        let total = try await memoryCount(in: fake)
        XCTAssertEqual(total, 1, "A terminal, non-empty assistant commit must enqueue exactly one extraction.")
    }

    func testNonTerminalCommitDoesNotExtract() async throws {
        let store = try makeInMemoryStore()
        let fake = FakeMemoryService(seeded: false)
        try await store.saveChatMessage(
            makeAssistant(),
            threadID: "thread-1",
            isTerminalAssistantCommit: false,
            memoryService: fake,
            extractionContext: makeContext()
        )
        let total = try await memoryCount(in: fake)
        XCTAssertEqual(total, 0)
    }

    func testEmptyAssistantContentDoesNotExtract() async throws {
        let store = try makeInMemoryStore()
        let fake = FakeMemoryService(seeded: false)
        try await store.saveChatMessage(
            makeAssistant(""),
            threadID: "thread-1",
            isTerminalAssistantCommit: true,
            memoryService: fake,
            extractionContext: makeContext()
        )
        let total = try await memoryCount(in: fake)
        XCTAssertEqual(total, 0, "An empty (e.g. cancelled) assistant commit must not extract.")
    }

    func testUserRoleDoesNotExtract() async throws {
        let store = try makeInMemoryStore()
        let fake = FakeMemoryService(seeded: false)
        let user = ChatMessageRecord(role: .user, content: "Tell me about X.")
        try await store.saveChatMessage(
            user,
            threadID: "thread-1",
            isTerminalAssistantCommit: true,
            memoryService: fake,
            extractionContext: makeContext()
        )
        let total = try await memoryCount(in: fake)
        XCTAssertEqual(total, 0, "Only assistant turns are extraction targets.")
    }

    func testNilMemoryServiceIsNoOp() async throws {
        let store = try makeInMemoryStore()
        // No service wired (production today): the chokepoint must be a silent no-op.
        try await store.saveChatMessage(
            makeAssistant(),
            threadID: "thread-1",
            isTerminalAssistantCommit: true,
            memoryService: nil,
            extractionContext: makeContext()
        )
        let messages = try await store.fetchChatMessages(threadID: "thread-1")
        XCTAssertEqual(messages.map(\.content), ["Here is the answer."])
    }

    func testNilExtractionContextIsNoOp() async throws {
        let store = try makeInMemoryStore()
        let fake = FakeMemoryService(seeded: false)
        try await store.saveChatMessage(
            makeAssistant(),
            threadID: "thread-1",
            isTerminalAssistantCommit: true,
            memoryService: fake,
            extractionContext: nil
        )
        let total = try await memoryCount(in: fake)
        XCTAssertEqual(total, 0)
    }

    func testEnqueueObservesPersistedChatRow() async throws {
        // Wave 2.1: the atomic in-transaction enqueue is gone with the local
        // write (the daemon persists the row over RPC). The surviving G3 proof
        // is ordering — the enqueue fires after the write commits, so the
        // enqueued intent always names a persisted row.
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            chatWriter: LocalChatHistoryWriter(dbQueue: queue)
        )
        let memory = RecordingMemoryService(dbQueue: queue)
        let assistant = makeAssistant()

        try await store.saveChatMessage(
            assistant,
            threadID: "thread-1",
            isTerminalAssistantCommit: true,
            memoryService: memory,
            extractionContext: makeContext()
        )

        XCTAssertEqual(memory.enqueuedIntents.map(\.messageID), [assistant.id])
        XCTAssertEqual(memory.chatRowsObservedAtEnqueue, [1], "The extraction enqueue must fire after the chat write commits, naming a persisted row.")
    }

    func testFailedChatWriteEnqueuesNothing() async throws {
        // A failed write (daemon unreachable in production) must not enqueue:
        // the intent would name a row that was never persisted.
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            chatWriter: ThrowingChatHistoryWriter()
        )
        let memory = RecordingMemoryService(dbQueue: queue)

        do {
            try await store.saveChatMessage(
                makeAssistant(),
                threadID: "thread-1",
                isTerminalAssistantCommit: true,
                memoryService: memory,
                extractionContext: makeContext()
            )
            XCTFail("A throwing writer must propagate the write failure.")
        } catch is ThrowingChatHistoryWriter.Boom {
        }
        XCTAssertTrue(memory.enqueuedIntents.isEmpty, "No enqueue may fire for a chat write that failed.")
    }

    // MARK: - Idempotency key (deterministic, backend dedup surface)

    func testIdempotencyKeyIsDeterministic() {
        let a = MemoryExtraction.idempotencyKey(threadLogicalID: "t1", messageID: "m1", promptVersion: "v1")
        let b = MemoryExtraction.idempotencyKey(threadLogicalID: "t1", messageID: "m1", promptVersion: "v1")
        XCTAssertEqual(a, b, "Same inputs must yield the same idempotency key for backend dedup.")
    }

    func testIdempotencyKeyDiffersByMessageID() {
        let a = MemoryExtraction.idempotencyKey(threadLogicalID: "t1", messageID: "m1", promptVersion: "v1")
        let b = MemoryExtraction.idempotencyKey(threadLogicalID: "t1", messageID: "m2", promptVersion: "v1")
        XCTAssertNotEqual(a, b)
    }

    func testIdempotencyKeyDiffersByPromptVersion() {
        let a = MemoryExtraction.idempotencyKey(threadLogicalID: "t1", messageID: "m1", promptVersion: "v1")
        let b = MemoryExtraction.idempotencyKey(threadLogicalID: "t1", messageID: "m1", promptVersion: "v2")
        XCTAssertNotEqual(a, b, "A new prompt version is a distinct extraction event.")
    }

    func testIdempotencyKeyIs64CharHex() {
        let key = MemoryExtraction.idempotencyKey(threadLogicalID: "t1", messageID: "m1", promptVersion: "v1")
        XCTAssertEqual(key.count, 64, "HMAC-SHA256 hex digest is 64 chars.")
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit }, "Idempotency key must be lowercase hex.")
    }

    // MARK: - Reentrancy sentinel (sendInFlight)

    func testSendInFlightGuardRejectsConcurrentSend() async throws {
        let store = try makeInMemoryStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
        let settings = SettingsManager(defaults: defaults)
        settings.cliAssistantAllowed = false
        let controller = ChatSessionController(dataStore: store, settingsManager: settings)

        // Simulate a send already in the pre-isStreaming await window.
        controller.sendInFlight = true
        controller.inputText = "hello"
        await controller.send()

        XCTAssertTrue(controller.messages.isEmpty, "A send arriving while another is in-flight must be rejected before appending any turn.")
        XCTAssertTrue(controller.sendInFlight, "A rejected send must not clear a sentinel owned by the in-flight send; its own defer clears it on return.")
        XCTAssertNil(
            controller.streamError,
            "A rejected duplicate send must not poison the active stream's terminal error state."
        )
    }

    func testSendInFlightGuardPreservesExistingStreamOutcomeState() async throws {
        let store = try makeInMemoryStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
        let settings = SettingsManager(defaults: defaults)
        settings.cliAssistantAllowed = false
        let controller = ChatSessionController(dataStore: store, settingsManager: settings)

        controller.sendInFlight = true
        controller.streamError = "active stream outcome"
        controller.inputText = "hello"

        await controller.send()

        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(controller.sendInFlight)
        XCTAssertEqual(
            controller.streamError,
            "active stream outcome",
            "A duplicate send rejection must preserve the stream outcome owned by the active send."
        )
    }

    func testSendResetsSentinelOnEarlyReturn() async throws {
        let store = try makeInMemoryStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
        let settings = SettingsManager(defaults: defaults)
        settings.cliAssistantAllowed = false
        let controller = ChatSessionController(dataStore: store, settingsManager: settings)
        controller.chatBackend = .codex

        controller.inputText = "hello"
        await controller.send()

        XCTAssertFalse(controller.sendInFlight, "defer must reset sendInFlight on every return path (no deadlock).")
        let userTurns = controller.messages.filter { $0.role == .user }.count
        XCTAssertEqual(userTurns, 1, "A single send must append exactly one user turn.")
    }

    func testEmptyInputDoesNotSetSentinel() async throws {
        let store = try makeInMemoryStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
        let settings = SettingsManager(defaults: defaults)
        let controller = ChatSessionController(dataStore: store, settingsManager: settings)

        controller.inputText = "   "
        await controller.send()

        XCTAssertFalse(controller.sendInFlight)
        XCTAssertTrue(controller.messages.isEmpty)
    }

    // MARK: - Extraction context shape

    func testMakeMemoryExtractionContextIsStable() async throws {
        let store = try makeInMemoryStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
        let controller = ChatSessionController(dataStore: store, settingsManager: SettingsManager(defaults: defaults))
        controller.activeThreadID = "thread-xyz"

        let ctx = controller.makeMemoryExtractionContext()
        XCTAssertEqual(ctx.scope.appID, "openburnbar")
        XCTAssertNil(ctx.scope.userID, "v1 does not trust a client-supplied userID; backend resolves it.")
        XCTAssertEqual(ctx.threadLogicalID, "thread-xyz")
        XCTAssertEqual(ctx.promptVersion, ChatSessionController.memoryPromptVersion)
    }
    // MARK: - Production memory service enqueues via the async API (Wave 2.1)

    func testRealMemoryServiceEnqueuesExactlyOneIdempotencyKeyedJob() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStoreCoordinator(databaseQueue: queue, runMigrations: true)
        let service = OpenBurnBarMemoryService(store: ControlPlaneStore(dbQueue: queue, memoryAuthorityWriter: LocalMemoryAuthorityWriter(dbQueue: queue)))

        let intent = ExtractionIntent(
            threadID: "t1",
            threadLogicalID: "t1",
            messageID: "m1",
            scope: MemoryScope(appID: "openburnbar"),
            promptVersion: "v1",
            idempotencyKey: MemoryExtraction.idempotencyKey(threadLogicalID: "t1", messageID: "m1", promptVersion: "v1")
        )

        // The chokepoint calls the async API after the chat RPC succeeds; a
        // re-save after a crash between the two collapses to one job.
        try await service.enqueueExtraction(intent)
        try await service.enqueueExtraction(intent)
        let jobCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM memory_extraction_jobs") ?? -1
        }
        XCTAssertEqual(jobCount, 1, "Repeat enqueues under one idempotency key must collapse to one job.")
    }
}

/// Wave 2.1 replacement for the old transactional fake: records async enqueues
/// and reads back the chat row at enqueue time, proving the enqueue fires
/// after the write commits.
private final class RecordingMemoryService: MemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private let dbQueue: any DatabaseWriter
    private var _enqueuedIntents: [ExtractionIntent] = []
    private var _chatRowsObservedAtEnqueue: [Int] = []

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    var enqueuedIntents: [ExtractionIntent] {
        lock.withLock { _enqueuedIntents }
    }

    var chatRowsObservedAtEnqueue: [Int] {
        lock.withLock { _chatRowsObservedAtEnqueue }
    }

    func enqueueExtraction(_ intent: ExtractionIntent) async throws {
        let rowCount = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(1) FROM chat_messages WHERE id = ?",
                arguments: [intent.messageID]
            ) ?? 0
        }
        lock.withLock {
            _enqueuedIntents.append(intent)
            _chatRowsObservedAtEnqueue.append(rowCount)
        }
    }

    func add(_ request: MemoryAddRequest) async throws -> MemoryEventID { "evt_unused_add" }
    func update(id: MemoryID, _ patch: MemoryPatch) async throws -> MemoryEventID { "evt_unused_update" }
    func delete(id: MemoryID) async throws -> MemoryEventID { "evt_unused_delete" }
    func deleteAll(scope: MemoryScope) async throws -> MemoryEventID { "evt_unused_delete_all" }
    func eventStatus(_ id: MemoryEventID) async throws -> MemoryEventStatus { .succeeded }
    func search(_ query: MemoryQuery) async throws -> [Memory] { [] }
    func get(id: MemoryID) async throws -> Memory? { nil }
    func getAll(_ page: MemoryPageRequest) async throws -> MemoryPage {
        MemoryPage(items: [], page: page.page, pageSize: page.pageSize, total: 0)
    }
    func listEntities() async throws -> [MemoryEntity] { [] }
    func recallForPrompt(_ request: MemoryRecallRequest) async throws -> [MemorySnippet] { [] }
    func approve(id: MemoryID) async throws -> MemoryEventID { "evt_unused_approve" }
    func reject(id: MemoryID) async throws -> MemoryEventID { "evt_unused_reject" }
}
