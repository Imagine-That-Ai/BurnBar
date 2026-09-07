// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// The macOS half of the agent-lane quarantine (D-0005 / R10).
///
/// Once `daemon.memory.remember` started defaulting to review, a memory a coding
/// agent asked BurnBar to remember stopped going straight into the next chat and
/// started waiting — but it waited somewhere no member could see it. The review
/// inbox loaded exactly two partitions (`[.chat]` and the usage kinds), and the
/// body of a quarantined mirrored row lives in `memory_quarantine_bodies`, which
/// no app-side reader touched. A promise that "nothing is remembered without your
/// say-so" needs a surface that can say so.
///
/// These tests drive the REAL `ControlPlaneStore` over an in-memory database,
/// wired to `MemoryReviewInboxModel` the way `MemoryReviewInboxHost` wires it,
/// against a row seeded the way the daemon writes one — from the JSON the Memory
/// MCP engine's mirror actually sends, decoded through the shipping contract, so
/// the review posture under test is the wire's and not the test's.
@MainActor
final class AgentLaneMemoryReviewInboxTests: XCTestCase {

    /// The inbox's own scope. It names an app, not a project: an agent-lane row
    /// carries the daemon's project id and no app scope columns at all, so a row
    /// that shows up here shows up because the agent partition is read unscoped.
    private let scope = MemoryScope(appID: "openburnbar")

    /// What the daemon resolves for the checkout it mirrored from.
    private let daemonProjectID = "prj_fixture_checkout"
    private let engineMemoryID = "mem_00112233445566778899aabbccddeeff"
    private let agentMemoryID = "mem_a1b2c3d4e5f60718293a4b5c6d7e8f90"
    private let agentBody = "The release branch is cut on Thursdays."

    // MARK: - Fixtures

    private func makeStore() throws -> (DatabaseQueue, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (queue, ControlPlaneStore(dbQueue: queue))
    }

    /// Mirrors `MemoryReviewInboxHost`'s closure wiring over the real store,
    /// including the body chain the host now uses.
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
            openBody: { id in
                if let snapshotBody = try await store.openChatMemoryBody(id: id) {
                    return snapshotBody
                }
                return try await store.openAgentMemoryBody(id: id)
            },
            setStatus: { id, status, sourceKinds in
                try await store.setMemoryReviewStatus(id: id, status: status, sourceKinds: sourceKinds)
            },
            forget: { id, sourceKinds in
                try await store.deleteMemoryAuthorityRecord(id: id, sourceKinds: sourceKinds)
            }
        )
    }

    /// Writes the row a quarantined `burnbar_remember` leaves behind, exactly as
    /// `BurnBarProjectCodeMemoryStore.remember` writes it: the authority row under
    /// the daemon's project id with no app scope columns, the body parked in
    /// `memory_quarantine_bodies`, and an EMPTY body in `agent_memory_bodies`
    /// holding the engine id the sealed cloud document keys on.
    ///
    /// The request is decoded from the JSON the mirror sends (no `reviewStatus`
    /// member at all), so the seeded row's posture is the wire's own default.
    @discardableResult
    private func seedMirroredAgentMemory(
        on queue: DatabaseQueue,
        now: Date
    ) throws -> BurnBarProjectMemoryRememberRequest {
        let request = try JSONDecoder().decode(
            BurnBarProjectMemoryRememberRequest.self,
            from: Data("""
            {"text": "\(agentBody)",
             "projectPath": "/tmp/FixtureProject",
             "kind": "fact",
             "scope": "project",
             "engineMemoryID": "\(engineMemoryID)"}
            """.utf8)
        )
        XCTAssertEqual(
            request.reviewStatus,
            .quarantined,
            "the seeded row is only interesting because the wire itself says review"
        )

        let timestamp = ISO8601DateFormatter().string(from: now)
        let bodyHash = SHA256.hash(data: Data(agentBody.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        // The engine's taxonomy is wider than the app's, so the daemon stores the
        // nearest `MemoryKind` and keeps the precise one as a tag.
        let storedKind = MemoryKind(rawValue: request.kind)?.rawValue ?? MemoryKind.other.rawValue

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memories
                    (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json,
                     source_path, valid_from, review_status, source_kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    agentMemoryID,
                    daemonProjectID,
                    storedKind,
                    request.scope,
                    request.confidence,
                    bodyHash,
                    "Quarantine body ref:agent-\(daemonProjectID)#\(agentMemoryID)",
                    "[]",
                    timestamp,
                    request.reviewStatus.rawValue,
                    MemorySourceKind.agent.rawValue,
                    timestamp,
                    timestamp
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO memory_quarantine_bodies (memory_id, project_id, body, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [agentMemoryID, daemonProjectID, agentBody, timestamp, timestamp]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES (?, ?, ?, '', '', ?, ?)
                """,
                arguments: [agentMemoryID, daemonProjectID, engineMemoryID, timestamp, timestamp]
            )
        }
        return request
    }

    // MARK: - The row is visible, and readable

    /// The first limit closed: the inbox lists the agent-lane row, opens its
    /// parked body, and offers Approve — and the chat lane beside it is
    /// untouched.
    func testAQuarantinedAgentLaneMemoryIsListedWithItsBodyAndIsApprovable() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try seedMirroredAgentMemory(on: queue, now: now)
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: "Prefers dark mode in every editor.", kind: .preference, scope: scope),
            id: "mem-chat",
            now: now.addingTimeInterval(60),
            enabled: true
        )

        let model = makeModel(store: store)
        await model.load()
        XCTAssertNil(model.errorMessage)

        let agentItem = try XCTUnwrap(
            model.pending.first { $0.id == agentMemoryID },
            "the agent-lane row must reach the inbox — before this it was invisible here"
        )
        XCTAssertEqual(agentItem.memory.sourceKind, .agent)
        XCTAssertEqual(agentItem.memory.reviewStatus, .quarantined)
        XCTAssertEqual(agentItem.bodyLoadState, .loaded, "its body is read from memory_quarantine_bodies")
        XCTAssertEqual(agentItem.body, agentBody)
        XCTAssertTrue(agentItem.canApprove, "a row whose body cannot be shown must not be approvable")

        XCTAssertTrue(
            model.pending.contains { $0.id == "mem-chat" },
            "the chat lane still loads exactly as it did"
        )
        XCTAssertEqual(
            model.pending.map(\.id),
            ["mem-chat", agentMemoryID],
            "and the merged bucket is still in page order (updatedAt DESC, id ASC)"
        )

        // The dashboard badge sums the same three lanes. A row the inbox lists
        // and the badge does not count is the disagreement the badge exists to
        // avoid.
        let chatPending = try await store.pendingChatMemoryReviewCount(scope: scope)
        let usagePending = try await store.pendingUsageMemoryReviewCount(scope: scope)
        let agentPending = try await store.pendingAgentMemoryReviewCount()
        XCTAssertEqual(agentPending, 1)
        XCTAssertEqual(chatPending + usagePending + agentPending, model.pendingCount)
    }

    /// The source-filter axis still narrows: an agent memory is not a chat
    /// memory, and picking "Chat" must not smuggle one in.
    func testTheChatSourceFilterStillExcludesAgentRows() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try seedMirroredAgentMemory(on: queue, now: now)

        let model = makeModel(store: store, sourceFilter: .chat)
        await model.load()

        XCTAssertTrue(model.items.isEmpty, "the chat chip shows chat rows only")
        XCTAssertEqual(model.pendingCount, 1, "but the row is loaded, so the badge still counts it")
    }

    // MARK: - Approval

    /// The second half of a review surface: the verdict lands, and it lands as
    /// the audited app action it always was. Nothing about the approval path is
    /// special-cased for this lane.
    func testApprovingAnAgentLaneMemoryFlipsReviewStatusAndAuditsItAsTheApp() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try seedMirroredAgentMemory(on: queue, now: now)

        let model = makeModel(store: store)
        await model.load()
        await model.approve(agentMemoryID)
        XCTAssertNil(model.errorMessage)

        let status = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT review_status FROM agent_memories WHERE id = ? AND source_kind = ?",
                arguments: [self.agentMemoryID, MemorySourceKind.agent.rawValue]
            )
        }
        XCTAssertEqual(status, MemoryReviewStatus.approved.rawValue)

        let audit = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT actor, action, domain, project_id, labels_json FROM memory_audit ORDER BY seq ASC"
            )
        }
        let approvals = audit.filter { ($0["action"] as? String) == "memory.approve" }
        XCTAssertEqual(approvals.count, 1, "one approval, one audit row")
        let approval = try XCTUnwrap(approvals.first)
        XCTAssertEqual(approval["actor"] as? String, "app", "the exporter's classifier reads this field")
        XCTAssertEqual(approval["domain"] as? String, "memory")
        XCTAssertEqual(
            approval["project_id"] as? String,
            daemonProjectID,
            "the audit row stays in the daemon's project bucket — the app invents no bucket for this lane"
        )
        let labels = try XCTUnwrap(approval["labels_json"] as? String)
        XCTAssertTrue(labels.contains("review_status:approved"), "labels: \(labels)")
        XCTAssertTrue(labels.contains("source_kind:agent"), "labels: \(labels)")

        XCTAssertFalse(model.pending.contains { $0.id == agentMemoryID })
        XCTAssertTrue(
            model.approved.contains { $0.id == agentMemoryID },
            "and the reload moves it into the approved bucket"
        )
    }

    // MARK: - Schema

    /// The app's own half of "one home for a quarantined body": whichever process
    /// opens a fresh profile first, the table the inbox reads is there. (The
    /// daemon-first direction, and the byte-equality of the two statements, are
    /// pinned by `MemoryQuarantineBodiesSchemaParityTests` in the daemon suite,
    /// which is the only target that can see both texts.)
    func testTheAppMigratorCreatesTheQuarantineBodiesTableTheDaemonWritesTo() throws {
        let (queue, _) = try makeStore()
        let objects = try queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT type || ':' || name FROM sqlite_master
                WHERE name IN ('memory_quarantine_bodies', 'memory_quarantine_bodies_project_idx')
                ORDER BY name
                """
            )
        }
        XCTAssertEqual(objects, ["table:memory_quarantine_bodies", "index:memory_quarantine_bodies_project_idx"])

        let columns = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('memory_quarantine_bodies') ORDER BY cid")
        }
        XCTAssertEqual(columns, ["memory_id", "project_id", "body", "created_at", "updated_at"])
    }
}
