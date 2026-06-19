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
