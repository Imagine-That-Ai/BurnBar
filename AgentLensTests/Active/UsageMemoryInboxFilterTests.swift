import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// U7 of the usage-memory program: the memory review inbox serves usage
/// memories (`.safariAsk` / `.agentSession`) alongside chat through the same
/// approve/reject/forget machinery. These tests drive the REAL
/// `ControlPlaneStore` over an in-memory database, wired to
/// `MemoryReviewInboxModel` exactly the way `MemoryReviewInboxHost` wires it,
/// and pin:
///  1. the source-filter axis (`.all` unions every kind, each chip narrows to
///     its own kind, and `.chat` is byte-identical to the pre-U7 chat-only
///     inbox),
///  2. review actions on a usage row mutate only that row (chat untouched),
///  3. forget hard-deletes with the PR1 semantics (row + snapshot + provenance
///     gone; approved rows leave a fact tombstone), and
///  4. the pending count sums chat + usage kinds.
@MainActor
final class UsageMemoryInboxFilterTests: XCTestCase {

    private let scope = MemoryScope(userID: "user-1")

    private func makeStore() throws -> (DatabaseQueue, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (queue, ControlPlaneStore(dbQueue: queue))
    }

    /// Mirrors `MemoryReviewInboxHost`'s closure wiring over the real store.
    private func makeModel(
        store: ControlPlaneStore,
        sourceFilter: MemoryReviewInboxModel.SourceFilter = .all
    ) -> MemoryReviewInboxModel {
        MemoryReviewInboxModel(
            scope: scope,
            sourceFilter: sourceFilter,
            loadPage: { request, sourceKinds in
                try await store.memoryPage(request, sourceKinds: sourceKinds)
            },
            openBody: { id in try await store.openChatMemoryBody(id: id) },
            setStatus: { id, status, sourceKinds in
                try await store.setMemoryReviewStatus(id: id, status: status, sourceKinds: sourceKinds)
            },
            forget: { id, sourceKinds in
                try await store.deleteMemoryAuthorityRecord(id: id, sourceKinds: sourceKinds)
            }
        )
    }

    /// Seeds one quarantined row per served source kind, newest-first as
    /// chat > safariAsk > agentSession so page order is deterministic.
    private func seedOneRowPerKind(store: ControlPlaneStore) async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: "Prefers dark mode in every editor.", kind: .preference, scope: scope),
            id: "mem-chat",
            now: base.addingTimeInterval(300),
            enabled: true
        )
        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Asks about GRDB migrations across sessions.",
                kind: .fact,
                scope: scope,
                citations: [
                    MemoryCitation(
                        id: "cite-safari",
                        threadLogicalID: "safari-ask:obs-1",
                        messageID: "obs-1",
                        role: "user",
                        authoredAt: base,
                        contentHash: "hash-safari",
                        crossDeviceHMAC: "hmac-safari"
                    )
                ]
            ),
            id: "mem-safari",
            sourceKind: .safariAsk,
            now: base.addingTimeInterval(200),
            enabled: true
        )
        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(text: "Runs the release script from the repo root.", kind: .fact, scope: scope),
            id: "mem-agent",
            sourceKind: .agentSession,
            now: base.addingTimeInterval(100),
            enabled: true
        )
    }

    // MARK: - Source filters

    func test_allFilterUnionsKindsAndEachChipNarrowsToItsOwn() async throws {
        let (_, store) = try makeStore()
        try await seedOneRowPerKind(store: store)
        let model = makeModel(store: store)

        await model.load()
        XCTAssertNil(model.errorMessage)

        // .all unions every served kind, in page order (updatedAt DESC).
        XCTAssertEqual(model.sourceFilter, .all)
        XCTAssertEqual(model.items.map(\.id), ["mem-chat", "mem-safari", "mem-agent"])

        // Bodies are opened for usage rows through the same sealed-snapshot path.
        let safariItem = model.items.first { $0.id == "mem-safari" }
        XCTAssertEqual(safariItem?.body, "Asks about GRDB migrations across sessions.")
        XCTAssertTrue(safariItem?.canApprove ?? false)

        // Each chip narrows to exactly its kind.
        model.sourceFilter = .chat
        XCTAssertEqual(model.items.map(\.id), ["mem-chat"])
        model.sourceFilter = .safariAsk
        XCTAssertEqual(model.items.map(\.id), ["mem-safari"])
        model.sourceFilter = .agentSession
        XCTAssertEqual(model.items.map(\.id), ["mem-agent"])
    }

    func test_chatFilterIsByteIdenticalToPreU7ChatOnlyInbox() async throws {
        let (_, store) = try makeStore()
        try await seedOneRowPerKind(store: store)

        // The generalized page with [.chat] IS the pre-U7 `chatMemoryPage`.
        let request = MemoryPageRequest(scope: scope, page: 1, pageSize: 200, includeQuarantined: true)
        let legacyPage = try await store.chatMemoryPage(request)
        let generalizedPage = try await store.memoryPage(request, sourceKinds: [.chat])
        XCTAssertEqual(legacyPage.items, generalizedPage.items)
        XCTAssertEqual(legacyPage.total, generalizedPage.total)
        XCTAssertEqual(legacyPage.items.map(\.id), ["mem-chat"])

        // The model's .chat filter serves exactly what the pre-U7 model served:
        // the chat page's quarantined rows, in page order, with opened bodies.
        let model = makeModel(store: store)
        await model.load()
        model.sourceFilter = .chat
        let expected = legacyPage.items.filter { $0.reviewStatus == .quarantined }
        XCTAssertEqual(model.items.map(\.memory), expected)
        for item in model.items {
            let body = try await store.openChatMemoryBody(id: item.id)
            XCTAssertEqual(item.body, body)
        }
    }

    func test_preselectedSourceFilterServesLinkOuts() async throws {
        let (_, store) = try makeStore()
        try await seedOneRowPerKind(store: store)
        let model = makeModel(store: store, sourceFilter: .safariAsk)

        await model.load()

        XCTAssertEqual(model.sourceFilter, .safariAsk)
        XCTAssertEqual(model.items.map(\.id), ["mem-safari"])
    }

    // MARK: - Review actions on usage rows

    func test_approveAndRejectOnUsageRowsMutateOnlyThatRow() async throws {
        let (queue, store) = try makeStore()
        try await seedOneRowPerKind(store: store)
        let model = makeModel(store: store)
        await model.load()

        await model.approve("mem-safari")
        XCTAssertNil(model.errorMessage)
        await model.reject("mem-agent")
        XCTAssertNil(model.errorMessage)

        let statuses = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, review_status FROM agent_memories ORDER BY id")
        }
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0["id"] as String? ?? "", $0["review_status"] as String? ?? "") })
        XCTAssertEqual(byID["mem-safari"], "approved")
        XCTAssertEqual(byID["mem-agent"], "rejected")
        // The chat row is untouched by usage-row actions.
        XCTAssertEqual(byID["mem-chat"], "quarantined")

        // The buckets reflect the transitions.
        XCTAssertEqual(model.pending.map(\.id), ["mem-chat"])
        XCTAssertEqual(model.approved.map(\.id), ["mem-safari"])
    }

    func test_forgetHardDeletesUsageRowWithPR1Semantics() async throws {
        let (queue, store) = try makeStore()
        try await seedOneRowPerKind(store: store)
        let model = makeModel(store: store)
        await model.load()

        // Approved-row forget: hard delete + fact tombstone (replication).
        await model.approve("mem-safari")
        await model.forget("mem-safari")
        XCTAssertNil(model.errorMessage)

        // Quarantined-row forget: hard delete, no fact tombstone.
        await model.forget("mem-agent")
        XCTAssertNil(model.errorMessage)

        let remaining = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM agent_memories ORDER BY id")
        }
        XCTAssertEqual(remaining, ["mem-chat"])

        let snapshotIDs = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT memory_id FROM memory_body_snapshots ORDER BY memory_id")
        }
        XCTAssertEqual(snapshotIDs, ["mem-chat"])

        let provenanceCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_provenance WHERE memory_id = 'mem-safari'") ?? -1
        }
        XCTAssertEqual(provenanceCount, 0)

        let safariTombstones = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_fact_tombstones WHERE memory_id = 'mem-safari'") ?? -1
        }
        XCTAssertEqual(safariTombstones, 1)
        let agentTombstones = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_fact_tombstones WHERE memory_id = 'mem-agent'") ?? -1
        }
        XCTAssertEqual(agentTombstones, 0)

        XCTAssertEqual(model.pending.map(\.id), ["mem-chat"])
        XCTAssertTrue(model.approved.isEmpty)
    }

    // MARK: - Pending counts

    func test_pendingCountSumsChatAndUsageKinds() async throws {
        let (_, store) = try makeStore()
        try await seedOneRowPerKind(store: store)
        let model = makeModel(store: store)
        await model.load()

        XCTAssertEqual(model.pendingCount, 3)

        let chatCount = try await store.pendingChatMemoryReviewCount(scope: scope)
        let usageCount = try await store.pendingUsageMemoryReviewCount(scope: scope)
        XCTAssertEqual(chatCount, 1)
        XCTAssertEqual(usageCount, 2)
        XCTAssertEqual(model.pendingCount, chatCount + usageCount)

        await model.approve("mem-safari")
        XCTAssertEqual(model.pendingCount, 2)
        let usageAfterApprove = try await store.pendingUsageMemoryReviewCount(scope: scope)
        XCTAssertEqual(usageAfterApprove, 1)
    }
}
