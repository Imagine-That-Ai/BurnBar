import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Proves an inbox "Remember this" takes the existing memory authority route:
/// the record lands quarantined-then-approved through the same two audited
/// steps a chat-extracted memory takes, with provenance pointing back at the
/// inbox item and its cited conversations.
@MainActor
final class InboxMemoryApprovalHandlerTests: XCTestCase {
    private var store: ControlPlaneStore!
    private var scope: MemoryScope!
    private var handler: InboxMemoryApprovalHandler!

    override func setUp() async throws {
        try await super.setUp()
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        store = ControlPlaneStore(dbQueue: queue)
        scope = MemoryScope(userID: "user-1", appID: "inbox-app")
        handler = InboxMemoryApprovalHandler(store: store, scope: scope)
    }

    override func tearDown() async throws {
        handler = nil
        store = nil
        scope = nil
        try await super.tearDown()
    }

    private func makeCandidate(
        text: String = "Deploys go through the staging ring before production.",
        kind: String = "decision",
        confidence: Double = 0.8,
        citationConversationIDs: [String] = ["conv-1", "conv-2"]
    ) -> BurnBarInboxMemoryCandidate {
        BurnBarInboxMemoryCandidate(
            id: "cand-1",
            text: text,
            kind: kind,
            confidence: confidence,
            citationConversationIDs: citationConversationIDs
        )
    }

    // MARK: - The approval route

    func testApproveWritesAnApprovedMemoryWithInboxProvenance() async throws {
        try await handler.approve(candidate: makeCandidate(), itemFingerprint: "fp-42")

        let page = try await store.chatMemoryPage(MemoryPageRequest(scope: scope))
        XCTAssertEqual(page.items.count, 1)
        let listed = try XCTUnwrap(page.items.first)
        XCTAssertEqual(listed.reviewStatus, .approved)
        XCTAssertEqual(listed.kind, .event)
        XCTAssertEqual(listed.confidence, 0.8, accuracy: 0.001)

        let fetched = try await store.fetchChatMemoryAuthorityRecord(id: listed.id)
        let memory = try XCTUnwrap(fetched)
        // Two conversation citations plus the synthetic one naming the item.
        XCTAssertEqual(memory.citations.count, 3)
        let ids = Set(memory.citations.map(\.id))
        XCTAssertTrue(ids.contains("ai-inbox:item:fp-42"), "the synthetic citation names the inbox item")
        XCTAssertTrue(ids.contains("ai-inbox:item:fp-42:conv-1"))
        XCTAssertTrue(ids.contains("ai-inbox:item:fp-42:conv-2"))
        XCTAssertTrue(
            memory.citations.allSatisfy { $0.id.hasPrefix(InboxMemoryApprovalHandler.provenancePrefix) },
            "every provenance row is traceable back to the inbox"
        )
        let threadIDs = Set(memory.citations.map(\.threadLogicalID))
        XCTAssertTrue(threadIDs.isSuperset(of: ["conv-1", "conv-2"]))
    }

    func testApproveTrimsWhitespaceBeforeStoring() async throws {
        try await handler.approve(
            candidate: makeCandidate(text: "  The fact, padded.  \n"),
            itemFingerprint: "fp-1"
        )

        let page = try await store.chatMemoryPage(MemoryPageRequest(scope: scope))
        XCTAssertEqual(page.items.count, 1, "a padded-but-real fact still lands")
        XCTAssertEqual(page.items.first?.reviewStatus, .approved)
    }

    func testApproveCapsConversationCitationsAtSixPlusTheSyntheticOne() async throws {
        let manyConversations = (1...9).map { "conv-\($0)" }
        try await handler.approve(
            candidate: makeCandidate(citationConversationIDs: manyConversations),
            itemFingerprint: "fp-cap"
        )

        let page = try await store.chatMemoryPage(MemoryPageRequest(scope: scope))
        let listed = try XCTUnwrap(page.items.first)
        let fetched = try await store.fetchChatMemoryAuthorityRecord(id: listed.id)
        let memory = try XCTUnwrap(fetched)
        XCTAssertEqual(memory.citations.count, 7, "six conversation citations plus the item citation")
    }

    func testEmptyTextThrowsAndWritesNothing() async throws {
        do {
            try await handler.approve(
                candidate: makeCandidate(text: "   \n\t"),
                itemFingerprint: "fp-empty"
            )
            XCTFail("an empty proposal must be rejected")
        } catch let error as InboxMemoryApprovalError {
            XCTAssertEqual(error.errorDescription, "This proposal has no text to remember.")
        }

        let page = try await store.chatMemoryPage(
            MemoryPageRequest(scope: scope, includeQuarantined: true)
        )
        XCTAssertTrue(page.items.isEmpty, "a rejected proposal must not leave a partial row behind")
    }

    // MARK: - Kind mapping

    func testMemoryKindMapsTheAnalystHintsOntoTheTaxonomy() {
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "preference"), .preference)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "decision"), .event)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "event"), .event)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "profile"), .profile)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "relationship"), .relationship)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "convention"), .fact)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "gotcha"), .fact)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "context"), .fact)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "fact"), .fact)
        // Case-insensitive, and unknown hints take the conservative default.
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "Preference"), .preference)
        XCTAssertEqual(InboxMemoryApprovalHandler.memoryKind(for: "something-new"), .fact)
    }

    // MARK: - Hashing

    func testHashIsStableSHA256Hex() {
        XCTAssertEqual(
            InboxMemoryApprovalHandler.hash("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(InboxMemoryApprovalHandler.hash("").count, 64)
        XCTAssertEqual(InboxMemoryApprovalHandler.hash("x"), InboxMemoryApprovalHandler.hash("x"))
        XCTAssertNotEqual(InboxMemoryApprovalHandler.hash("x"), InboxMemoryApprovalHandler.hash("y"))
    }
}
