import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// F-4: memory settings toggle + Remote Config fleet kill switch (G4) + reset.
///
/// Invariants under test:
///  - **Gate (G4):** extraction is enabled only when the user toggle is ON *and*
///    the Remote Config kill switch has not disabled it (fail-closed).
///  - **Reset:** "Reset memory" routes through backend `deleteAll(scope:)` and
///    never touches canonical chat data.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class MemorySettingsAndKillSwitchTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    private func makeInMemoryStore() throws -> DataStoreCoordinator {
        try DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: true)
    }

    // MARK: - Pure gate

    func testGateEnabledWhenBothLeversOn() {
        XCTAssertTrue(MemoryExtractionGate.isEnabled(automaticExtraction: true, remoteConfigEnabled: true))
    }

    func testGateDisabledWhenUserToggleOff() {
        XCTAssertFalse(MemoryExtractionGate.isEnabled(automaticExtraction: false, remoteConfigEnabled: true))
    }

    func testGateDisabledWhenRemoteConfigKills() {
        XCTAssertFalse(MemoryExtractionGate.isEnabled(automaticExtraction: true, remoteConfigEnabled: false))
    }

    func testGateDisabledWhenBothOff() {
        XCTAssertFalse(MemoryExtractionGate.isEnabled(automaticExtraction: false, remoteConfigEnabled: false))
    }

    // MARK: - SettingsManager defaults + levers

    func testSettingsDefaultsAreExtractionOn() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        XCTAssertTrue(settings.memoryAutomaticExtraction, "User toggle defaults ON.")
        XCTAssertFalse(settings.memoryHighRecallPerReply, "High-recall sub-toggle defaults OFF.")
        XCTAssertTrue(settings.memoryExtractionRemoteConfigEnabled, "RC kill switch defaults allowed (true).")
        XCTAssertTrue(settings.memoryExtractionEnabled, "Combined gate defaults enabled.")
    }

    func testUserToggleDisablesGate() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.memoryAutomaticExtraction = false
        XCTAssertFalse(settings.memoryExtractionEnabled)
    }

    func testRemoteConfigKillSwitchDisablesGate() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.memoryExtractionRemoteConfigEnabled = false
        XCTAssertFalse(settings.memoryExtractionEnabled, "A fleet kill switch must halt extraction even if the user toggle is ON.")
    }

    func testChatControllerUsesCombinedGateForExtractionService() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        let controller = ChatSessionController(
            dataStore: try makeInMemoryStore(),
            settingsManager: settings,
            memoryService: FakeMemoryService(seeded: false)
        )

        XCTAssertNotNil(controller.memoryServiceForExtraction)
        settings.memoryAutomaticExtraction = false
        XCTAssertNil(controller.memoryServiceForExtraction)
        settings.memoryAutomaticExtraction = true
        settings.memoryExtractionRemoteConfigEnabled = false
        XCTAssertNil(controller.memoryServiceForExtraction)
    }

    func testUserTogglePersistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.memoryAutomaticExtraction = false
        settings.memoryHighRecallPerReply = true
        // The coordinator debounces writes (~100 ms); flush synchronously so the
        // reloaded instance observes the persisted values.
        settings.persistence.flush()

        let reloaded = SettingsManager(defaults: defaults)
        XCTAssertFalse(reloaded.memoryAutomaticExtraction)
        XCTAssertTrue(reloaded.memoryHighRecallPerReply)
    }

    // MARK: - Reset memory (two-phase forget via deleteAll)

    func testResetAllMemoriesCallsDeleteAll() async throws {
        let fake = FakeMemoryService(seeded: true)
        let scope = MemoryScope(userID: "fixture-user", appID: "openburnbar")
        let before = try await fake.getAll(MemoryPageRequest(scope: scope, page: 1, pageSize: 50, includeQuarantined: true)).total
        XCTAssertGreaterThan(before, 0)

        let service = MemorySettingsService()
        let eventID = try await service.resetAllMemories(memoryService: fake, scope: scope)
        XCTAssertNotNil(eventID, "Reset must return the backend delete event id.")

        let after = try await fake.getAll(MemoryPageRequest(scope: scope, page: 1, pageSize: 50, includeQuarantined: true)).total
        XCTAssertEqual(after, 0, "deleteAll(scope:) must remove every memory in the scope.")
    }

    func testResetAllMemoriesNilServiceIsNoOp() async throws {
        let service = MemorySettingsService()
        let eventID = try await service.resetAllMemories(memoryService: nil, scope: MemoryScope(appID: "openburnbar"))
        XCTAssertNil(eventID, "With no backend wired, reset is a graceful no-op (nil event id).")
    }

    func testResetScopeIncludesSignedInUser() {
        let scope = MemorySettingsService.resetScope(userID: " user-123 ")
        XCTAssertEqual(scope.userID, "user-123")
        XCTAssertEqual(scope.appID, "openburnbar")
    }

    func testResetWaitsForBackendEventCompletion() async throws {
        let service = MemorySettingsService()
        let memory = DelayedDeleteMemoryService(statuses: [.pending, .running, .succeeded])
        let eventID = try await service.resetAllMemories(
            memoryService: memory,
            scope: MemoryScope(userID: "user-123", appID: "openburnbar")
        )

        XCTAssertEqual(eventID, "evt_delayed_delete")
        XCTAssertEqual(memory.statusPollCount, 3)
    }

    func testResetThrowsWhenBackendEventDoesNotComplete() async throws {
        let service = MemorySettingsService()
        let memory = DelayedDeleteMemoryService(statuses: [.running, .running, .running, .running, .running, .running])

        do {
            _ = try await service.resetAllMemories(
                memoryService: memory,
                scope: MemoryScope(userID: "user-123", appID: "openburnbar")
            )
            XCTFail("Expected reset to fail while backend event is still running.")
        } catch let error as MemorySettingsService.ResetError {
            XCTAssertEqual(error.localizedDescription, "Memory reset did not complete; backend event status is running.")
        }
    }

    func testResetMemoryLeavesChatDataUntouched() async throws {
        let store = try makeInMemoryStore()
        let fake = FakeMemoryService(seeded: true)

        // Seed canonical chat data in a thread.
        let userMsg = ChatMessageRecord(role: .user, content: "Remember my preference.")
        let assistant = ChatMessageRecord(role: .assistant, content: "Got it.")
        try await store.saveChatMessage(userMsg, threadID: "thread-chat-1")
        try await store.saveChatMessage(assistant, threadID: "thread-chat-1")

        // Reset memory (deletes only from the memory store).
        let service = MemorySettingsService()
        _ = try await service.resetAllMemories(memoryService: fake, scope: MemoryScope(userID: "fixture-user", appID: "openburnbar"))

        // Canonical chat data must be intact.
        let chats = try await store.fetchChatMessages(threadID: "thread-chat-1")
        XCTAssertEqual(chats.count, 2, "Reset memory must not touch chat transcripts.")
    }
}

private final class DelayedDeleteMemoryService: MemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [MemoryEventStatus]
    private var _statusPollCount = 0

    init(statuses: [MemoryEventStatus]) {
        self.statuses = statuses
    }

    var statusPollCount: Int {
        lock.withLock { _statusPollCount }
    }

    func deleteAll(scope: MemoryScope) async throws -> MemoryEventID {
        "evt_delayed_delete"
    }

    func eventStatus(_ id: MemoryEventID) async throws -> MemoryEventStatus {
        lock.withLock {
            _statusPollCount += 1
            guard statuses.count > 1 else { return statuses.first ?? .succeeded }
            return statuses.removeFirst()
        }
    }

    func add(_ request: MemoryAddRequest) async throws -> MemoryEventID { "evt_unused_add" }
    func update(id: MemoryID, _ patch: MemoryPatch) async throws -> MemoryEventID { "evt_unused_update" }
    func delete(id: MemoryID) async throws -> MemoryEventID { "evt_unused_delete" }
    func search(_ query: MemoryQuery) async throws -> [Memory] { [] }
    func get(id: MemoryID) async throws -> Memory? { nil }
    func getAll(_ page: MemoryPageRequest) async throws -> MemoryPage {
        MemoryPage(items: [], page: page.page, pageSize: page.pageSize, total: 0)
    }
    func listEntities() async throws -> [MemoryEntity] { [] }
    func recallForPrompt(_ request: MemoryRecallRequest) async throws -> [MemorySnippet] { [] }
    func approve(id: MemoryID) async throws -> MemoryEventID { "evt_unused_approve" }
    func reject(id: MemoryID) async throws -> MemoryEventID { "evt_unused_reject" }
    func enqueueExtraction(_ intent: ExtractionIntent) async throws {}
}
