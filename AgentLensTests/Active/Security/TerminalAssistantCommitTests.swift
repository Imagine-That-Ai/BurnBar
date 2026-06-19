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
        try DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: true)
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
        // No crash + no extraction is the success condition here.
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
}
