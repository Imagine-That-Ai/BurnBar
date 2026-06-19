import XCTest
import OpenBurnBarCore

final class FakeMemoryServiceTests: XCTestCase {
    func test_searchAndRecallRespectScopeAndUpdatedText() async throws {
        let service = FakeMemoryService(seeded: false)
        _ = try await service.add(
            MemoryAddRequest(
                text: "User A prefers concise answers.",
                scope: MemoryScope(userID: "user-a"),
                confidence: 0.9,
                reviewStatus: .approved
            )
        )
        _ = try await service.add(
            MemoryAddRequest(
                text: "User B prefers detailed answers.",
                scope: MemoryScope(userID: "user-b"),
                confidence: 0.95,
                reviewStatus: .approved
            )
        )

        let searchResults = try await service.search(MemoryQuery(text: "prefers", scope: MemoryScope(userID: "user-a")))
        XCTAssertEqual(searchResults.map(\.scope.userID), ["user-a"])
        guard let memoryID = searchResults.first?.id else {
            XCTFail("Expected a user-a memory.")
            return
        }

        _ = try await service.update(id: memoryID, MemoryPatch(text: "User A prefers direct answers."))
        let snippets = try await service.recallForPrompt(
            MemoryRecallRequest(query: "preference", scope: MemoryScope(userID: "user-a"), tokenBudget: 128)
        )

        XCTAssertEqual(snippets.map(\.text), ["User A prefers direct answers."])
    }

    func test_enqueueExtractionIsIdempotentOnIdempotencyKey() async throws {
        let service = FakeMemoryService(seeded: false)
        let intent = ExtractionIntent(
            threadID: "thread-1",
            threadLogicalID: "thread-logical-1",
            messageID: "message-1",
            scope: MemoryScope(userID: "user-a"),
            promptVersion: "test-v1",
            idempotencyKey: "idem-1"
        )

        try await service.enqueueExtraction(intent)
        try await service.enqueueExtraction(intent)

        let page = try await service.getAll(
            MemoryPageRequest(scope: MemoryScope(userID: "user-a"), includeQuarantined: true)
        )
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.items.first?.citations.first?.id, "cite_idem-1")
    }
}
