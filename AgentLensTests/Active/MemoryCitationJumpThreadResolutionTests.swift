import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// E1 (citation jump): the data-layer contract the cross-thread citation jump
/// leans on — `DataStore.threadID(forChatMessageID:)`.
///
/// Memory recall is app-wide (`recallChatMemorySnippets` carries no thread
/// predicate), so a citation's `messageID` usually points at a row in a thread
/// other than the one on screen. `ChatSessionController.jumpToMemoryCitation`
/// resolves that owning thread here, opens it, then scrolls. These tests pin the
/// two behaviours the navigation depends on:
///   - a message saved in thread B resolves to thread B (cross-thread, the
///     dominant case), distinct from the legacy/default thread; and
///   - an unknown id resolves to `nil` so the caller fails closed (navigates
///     nowhere) rather than opening an empty thread.
@MainActor
final class MemoryCitationJumpThreadResolutionTests: XCTestCase {

    private func makeInMemoryStore() throws -> DataStoreCoordinator {
        try DataStoreCoordinator.makeInMemoryForTesting()
    }

    func test_threadIDForChatMessageID_resolvesOwningThread_crossThread() async throws {
        let store = try makeInMemoryStore()

        let threadA = try await store.createChatThread()
        let threadB = try await store.createChatThread()
        XCTAssertNotEqual(threadA, threadB)

        let inThreadA = ChatMessageRecord(role: .user, content: "Question in A")
        let citedInThreadB = ChatMessageRecord(role: .assistant, content: "Answer the memory cites")
        try await store.saveChatMessage(inThreadA, threadID: threadA)
        try await store.saveChatMessage(citedInThreadB, threadID: threadB)

        // The cited row lives in B; resolution must return B even though A also
        // exists — proving the lookup is per-message, not "current thread".
        let resolved = try await store.threadID(forChatMessageID: citedInThreadB.id)
        XCTAssertEqual(resolved, threadB)

        // And the sibling row resolves to its own thread, not the other one.
        let resolvedA = try await store.threadID(forChatMessageID: inThreadA.id)
        XCTAssertEqual(resolvedA, threadA)
    }

    func test_threadIDForChatMessageID_unknownID_returnsNil_failClosed() async throws {
        let store = try makeInMemoryStore()
        let thread = try await store.createChatThread()
        try await store.saveChatMessage(
            ChatMessageRecord(role: .user, content: "present"),
            threadID: thread
        )

        // A hard-deleted / never-existed source must resolve to nil so the jump
        // navigates nowhere rather than to an empty thread.
        let resolved = try await store.threadID(forChatMessageID: "no-such-message-id")
        XCTAssertNil(resolved)
    }
}
