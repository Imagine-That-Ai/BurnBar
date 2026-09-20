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
    /// The root the daemon recorded for that checkout in `pcm_projects`, which
    /// is the only string the app may hand back to `daemon.memory.review_status`.
    private let projectRoot = "/tmp/FixtureProject"

    // MARK: - Fixtures

    /// Stands in for the daemon on the other end of
    /// `daemon.memory.review_status` (I-56): records every verdict handed over
    /// including the `expectedUpdatedAt` precondition stamp (review #2565), and
    /// can refuse the way an unreachable daemon does — or refuse the way a
    /// NEWER verdict's owner does, by reporting `applied: false`. A test store
    /// is ALWAYS built with one of these — the shipping default opens the real
    /// control socket, and a unit test must never reach the member's daemon.
    private final class DaemonPublisherSpy: @unchecked Sendable {
        struct Call: Equatable {
            let memoryID: MemoryID
            let projectPath: String
            let status: MemoryReviewStatus
            let expectedUpdatedAt: String
        }

        enum Outcome { case reachable, unreachable, refusedStale }

        private let lock = NSLock()
        private var storedCalls: [Call] = []
        private var storedOutcome: Outcome

        init(outcome: Outcome = .reachable) { self.storedOutcome = outcome }

        var calls: [Call] { lock.withLock { storedCalls } }

        func set(outcome: Outcome) { lock.withLock { storedOutcome = outcome } }

        func publish(
            _ memoryID: MemoryID,
            _ projectPath: String,
            _ status: MemoryReviewStatus,
            _ expectedUpdatedAt: String
        ) throws -> Bool {
            let outcome: Outcome = lock.withLock {
                storedCalls.append(Call(
                    memoryID: memoryID,
                    projectPath: projectPath,
                    status: status,
                    expectedUpdatedAt: expectedUpdatedAt
                ))
                return storedOutcome
            }
            switch outcome {
            case .reachable: return true
            case .refusedStale: return false
            case .unreachable: throw OpenBurnBarDaemonManagerError.rpcError("daemon unreachable")
            }
        }
    }

    /// Stands in for the daemon on the other end of `daemon.memory.forget`
    /// (review #2565-F1): records every forget handed over, proves the local
    /// authority row still existed when the call landed (the daemon needs it to
    /// find the body), and can refuse the way an unreachable daemon does.
    private final class DaemonForgetterSpy: @unchecked Sendable {
        struct Call: Equatable {
            let memoryID: MemoryID
            let projectPath: String
            /// The `agent_memories` row was still present when the RPC arrived —
            /// a forget that ran after the local delete could not be served.
            let rowStillPresent: Bool
        }

        enum Outcome { case reachable, unreachable, deletionRefused }

        private let lock = NSLock()
        private var storedCalls: [Call] = []
        private var storedOutcome: Outcome
        /// Reads the row's presence inside the call — wired to the test queue.
        private var rowProbe: @Sendable (MemoryID) -> Bool = { _ in false }

        init(outcome: Outcome = .reachable) { self.storedOutcome = outcome }

        var calls: [Call] { lock.withLock { storedCalls } }

        func set(outcome: Outcome) { lock.withLock { storedOutcome = outcome } }

        func probeRows(using probe: @escaping @Sendable (MemoryID) -> Bool) {
            lock.withLock { rowProbe = probe }
        }

        func forget(_ memoryID: MemoryID, _ projectPath: String) throws -> BurnBarProjectMemoryForgetResponse {
            let outcome: Outcome = lock.withLock {
                storedCalls.append(Call(
                    memoryID: memoryID,
                    projectPath: projectPath,
                    rowStillPresent: rowProbe(memoryID)
                ))
                return storedOutcome
            }
            if outcome == .unreachable {
                throw OpenBurnBarDaemonManagerError.rpcError("daemon unreachable")
            }
            return BurnBarProjectMemoryForgetResponse(
                traceID: "test",
                projectID: "prj_fixture_checkout",
                memoryID: memoryID,
                localDeleted: outcome == .reachable,
                cloudDeletePending: false,
                auditHash: "test"
            )
        }
    }

    private func makeStore(
        publisher: DaemonPublisherSpy = DaemonPublisherSpy(),
        forgetter: DaemonForgetterSpy = DaemonForgetterSpy(),
        traced: Bool = false
    ) throws -> (DatabaseQueue, ControlPlaneStore) {
        var configuration = Configuration()
        if traced {
            OpenBurnBarQueryTracer.shared.configure(in: &configuration)
        }
        let queue = try DatabaseQueue(configuration: configuration)
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        forgetter.probeRows { memoryID in
            (try? queue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT id FROM agent_memories WHERE id = ?",
                    arguments: [memoryID]
                )
            }) != nil
        }
        let store = ControlPlaneStore(
            dbQueue: queue,
            publishAgentMemoryReviewStatus: { memoryID, projectPath, status, expectedUpdatedAt in
                try publisher.publish(memoryID, projectPath, status, expectedUpdatedAt)
            },
            forgetAgentMemory: { memoryID, projectPath in
                try forgetter.forget(memoryID, projectPath)
            }
        )
        return (queue, store)
    }

    /// What the daemon publishes on behalf of a verdict it accepted: the body
    /// leaves quarantine, the sync body is refilled under the engine id, and
    /// `body_redacted` names the snapshot instead of the quarantine copy. The
    /// spy cannot do this itself — it has no store — so a test that wants the
    /// published end state calls this after it.
    private func simulateDaemonPublication(on queue: DatabaseQueue) throws {
        let bodyHash = SHA256.hash(data: Data(agentBody.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM memory_quarantine_bodies WHERE memory_id = ?",
                arguments: [self.agentMemoryID]
            )
            try db.execute(
                sql: "UPDATE agent_memory_bodies SET body = ?, body_hash = ? WHERE memory_id = ?",
                arguments: [self.agentBody, bodyHash, self.agentMemoryID]
            )
            try db.execute(
                sql: "UPDATE agent_memories SET body_redacted = ? WHERE id = ?",
                arguments: [
                    "Project Memory snapshot ref:agent-\(self.daemonProjectID)#\(self.agentMemoryID)",
                    self.agentMemoryID
                ]
            )
        }
    }

    /// Mirrors `MemoryReviewInboxHost`'s closure wiring over the real store,
    /// including the body chain and the acting-account binding the host now
    /// passes through every agent-lane call (review #2565).
    private func makeModel(
        store: ControlPlaneStore,
        sourceFilter: MemoryReviewInboxModel.SourceFilter = .all,
        userID: String? = "u-member-1"
    ) -> MemoryReviewInboxModel {
        MemoryReviewInboxModel(
            scope: scope,
            sourceFilter: sourceFilter,
            loadPage: { request, sourceKinds in
                try await store.memoryPage(request, sourceKinds: sourceKinds, actingAccountUserID: userID)
            },
            openBody: { id in
                if let snapshotBody = try await store.openChatMemoryBody(id: id) {
                    return snapshotBody
                }
                return try await store.openAgentMemoryBody(id: id, actingAccountUserID: userID)
            },
            setStatus: { id, status, sourceKinds in
                try await store.setMemoryReviewStatus(
                    id: id,
                    status: status,
                    sourceKinds: sourceKinds,
                    actingAccountUserID: userID
                )
            },
            forget: { id, sourceKinds in
                try await store.deleteMemoryAuthorityRecord(
                    id: id,
                    sourceKinds: sourceKinds,
                    actingAccountUserID: userID
                )
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
        now: Date,
        userID: String? = nil,
        memoryID: String? = nil,
        engineID: String? = nil,
        body: String? = nil
    ) throws -> BurnBarProjectMemoryRememberRequest {
        let seededMemoryID = memoryID ?? agentMemoryID
        let seededEngineID = engineID ?? engineMemoryID
        let seededBody = body ?? agentBody
        let request = try JSONDecoder().decode(
            BurnBarProjectMemoryRememberRequest.self,
            from: Data("""
            {"text": "\(seededBody)",
             "projectPath": "\(projectRoot)",
             "kind": "fact",
             "scope": "project",
             "engineMemoryID": "\(seededEngineID)"}
            """.utf8)
        )
        XCTAssertEqual(
            request.reviewStatus,
            .quarantined,
            "the seeded row is only interesting because the wire itself says review"
        )

        let timestamp = ISO8601DateFormatter().string(from: now)
        let bodyHash = SHA256.hash(data: Data(seededBody.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        // The engine's taxonomy is wider than the app's, so the daemon stores the
        // nearest `MemoryKind` and keeps the precise one as a tag.
        let storedKind = MemoryKind(rawValue: request.kind)?.rawValue ?? MemoryKind.other.rawValue

        // The daemon's own project registry. The app reads `primary_path` back
        // out of it to address the row over the memory RPCs — it never guesses
        // a path, because the daemon resolves one through the WRITING resolver.
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO pcm_projects
                    (project_id, identity_version, identity_fingerprint, project_name,
                     primary_path, created_at, updated_at)
                VALUES (?, 2, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    self.daemonProjectID,
                    "fingerprint:\(self.daemonProjectID)",
                    "FixtureProject",
                    self.projectRoot,
                    timestamp,
                    timestamp
                ]
            )
        }

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memories
                    (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json,
                     source_path, valid_from, review_status, source_kind, user_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    seededMemoryID,
                    daemonProjectID,
                    storedKind,
                    request.scope,
                    request.confidence,
                    bodyHash,
                    "Quarantine body ref:agent-\(daemonProjectID)#\(seededMemoryID)",
                    "[]",
                    timestamp,
                    request.reviewStatus.rawValue,
                    MemorySourceKind.agent.rawValue,
                    userID,
                    timestamp,
                    timestamp
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO memory_quarantine_bodies (memory_id, project_id, body, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [seededMemoryID, daemonProjectID, seededBody, timestamp, timestamp]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES (?, ?, ?, '', '', ?, ?)
                """,
                arguments: [seededMemoryID, daemonProjectID, seededEngineID, timestamp, timestamp]
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
        let agentPending = try await store.pendingAgentMemoryReviewCount(accountUserID: "u-member-1")
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

    // MARK: - Publication (I-56)

    /// The residual I-56 names: the app's approval flips `review_status` and
    /// audits it, but only the daemon may move the body out of
    /// `memory_quarantine_bodies` and refill the `body_hash` the convergence
    /// fold dedupes on. So the app hands the verdict straight back to
    /// `daemon.memory.review_status` — once, for the row it acted on, addressed
    /// by the root the DAEMON recorded.
    func testApprovingAnAgentLaneMemoryHandsThePublicationToTheDaemon() async throws {
        let publisher = DaemonPublisherSpy()
        let (queue, store) = try makeStore(publisher: publisher)
        try seedMirroredAgentMemory(on: queue, now: Date(timeIntervalSince1970: 1_800_000_000))

        let model = makeModel(store: store)
        await model.load()
        await model.approve(agentMemoryID)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(publisher.calls.count, 1, "one verdict, one hand-off")
        let call = try XCTUnwrap(publisher.calls.first)
        XCTAssertEqual(call.memoryID, agentMemoryID)
        XCTAssertEqual(
            call.projectPath,
            projectRoot,
            "addressed by the root the DAEMON recorded, never a guessed one"
        )
        XCTAssertEqual(call.status, .approved)
    }

    /// An unreachable daemon must not cost the member their decision, and must
    /// not be reported as a publication that happened. The verdict stays
    /// approved and audited, the row says so on its card — `isAwaitingPublication`
    /// is what draws the "Pending publication" tag — and the inbox shows no
    /// error, because nothing the member did failed.
    func testAnUnreachableDaemonLeavesTheApprovalAwaitingPublication() async throws {
        let publisher = DaemonPublisherSpy(outcome: .unreachable)
        let (queue, store) = try makeStore(publisher: publisher)
        try seedMirroredAgentMemory(on: queue, now: Date(timeIntervalSince1970: 1_800_000_000))

        let model = makeModel(store: store)
        await model.load()
        await model.approve(agentMemoryID)

        XCTAssertNil(model.errorMessage, "the approval itself succeeded; only the publication is owed")
        XCTAssertEqual(publisher.calls.count, 1, "it was attempted, not skipped")
        let status = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT review_status FROM agent_memories WHERE id = ?",
                arguments: [self.agentMemoryID]
            )
        }
        XCTAssertEqual(
            status,
            MemoryReviewStatus.approved.rawValue,
            "the member's verdict is durable whatever the daemon did"
        )
        let approvedRow = try XCTUnwrap(model.approved.first { $0.id == agentMemoryID })
        XCTAssertTrue(
            approvedRow.isAwaitingPublication,
            "so the card says the body has not been published yet"
        )
        let backlog = try await store.pendingAgentMemoryPublications()
        XCTAssertEqual(
            backlog.map(\.memoryID),
            [agentMemoryID],
            "and the backlog the next launch drains holds exactly that row"
        )
    }

    /// The retry the deferred state promises. `startMemoryProConcierge` drains
    /// the backlog once the daemon is healthy on the next launch; a row the
    /// daemon has published stops matching, so the drain is idempotent and the
    /// pending tag clears itself.
    func testTheNextLaunchRetriesAPendingPublicationAndThenStops() async throws {
        let publisher = DaemonPublisherSpy(outcome: .unreachable)
        let (queue, store) = try makeStore(publisher: publisher)
        try seedMirroredAgentMemory(on: queue, now: Date(timeIntervalSince1970: 1_800_000_000))

        let model = makeModel(store: store)
        await model.load()
        await model.approve(agentMemoryID)
        XCTAssertEqual(publisher.calls.count, 1)

        // Next launch: the daemon is up.
        publisher.set(outcome: .reachable)
        let published = await store.retryPendingAgentMemoryPublications()
        XCTAssertEqual(published, 1)
        XCTAssertEqual(publisher.calls.count, 2, "the retry is the second hand-off of the same verdict")
        XCTAssertEqual(publisher.calls.last?.status, .approved)

        // The daemon does its half; the row leaves the backlog and the tag goes.
        try simulateDaemonPublication(on: queue)
        let republished = await store.retryPendingAgentMemoryPublications()
        XCTAssertEqual(republished, 0)
        XCTAssertEqual(publisher.calls.count, 2, "nothing left to publish, so nothing is asked")
        await model.load()
        let approvedRow = try XCTUnwrap(model.approved.first { $0.id == agentMemoryID })
        XCTAssertFalse(approvedRow.isAwaitingPublication, "a published row carries no pending tag")
    }

    /// The lane boundary: chat and usage memories keep their bodies in the app's
    /// own snapshot table, so approving one hands the daemon nothing at all.
    func testApprovingAChatMemoryNeverCallsTheDaemon() async throws {
        let publisher = DaemonPublisherSpy()
        let (queue, store) = try makeStore(publisher: publisher)
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
        await model.approve("mem-chat")

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(publisher.calls.isEmpty, "no agent row was acted on, so the daemon is not asked")
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

    // MARK: - Forget is daemon-first (review #2565-F1)

    func testRefusedDaemonDeletionPreservesTheBodyUntilASuccessfulRetry() async throws {
        let forgetter = DaemonForgetterSpy(outcome: .deletionRefused)
        let (queue, store) = try makeStore(forgetter: forgetter)
        try seedMirroredAgentMemory(on: queue, now: Date(), userID: "u-member-1")
        let model = makeModel(store: store)
        await model.load()
        await model.forget(agentMemoryID)
        XCTAssertNotNil(model.errorMessage)
        let retainedBody = try await store.openAgentMemoryBody(
            id: agentMemoryID, actingAccountUserID: "u-member-1"
        )
        XCTAssertEqual(retainedBody, agentBody)
        let tombstoneCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_fact_tombstones")
        }
        XCTAssertEqual(tombstoneCount, 0)
        forgetter.set(outcome: .reachable)
        await model.forget(agentMemoryID)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.pending.contains { $0.id == agentMemoryID })
        let retainedRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_quarantine_bodies")
        }
        XCTAssertEqual(retainedRows, 0)
        XCTAssertEqual(forgetter.calls.map(\.rowStillPresent), [true, true])
    }

    /// The forget ordering: `daemon.memory.forget` runs while the local row is
    /// still on disk — the daemon reads `project_id` off it to find the body —
    /// and only then does the local delete take the authority row, the parked
    /// quarantine body AND the syncable body copy. Before this, Forget deleted
    /// the app row and left both body tables' plaintext behind.
    func testAnAgentLaneForgetAsksTheDaemonFirstAndDeletesEveryLocalByte() async throws {
        let forgetter = DaemonForgetterSpy()
        let (queue, store) = try makeStore(forgetter: forgetter)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try seedMirroredAgentMemory(on: queue, now: now, userID: "u-member-1")

        let model = makeModel(store: store, userID: "u-member-1")
        await model.load()
        await model.forget(agentMemoryID)
        XCTAssertNil(model.errorMessage)

        XCTAssertEqual(forgetter.calls.count, 1, "one forget, one hand-off")
        let call = try XCTUnwrap(forgetter.calls.first)
        XCTAssertEqual(call.memoryID, agentMemoryID)
        XCTAssertEqual(call.projectPath, projectRoot, "addressed by the daemon's recorded root")
        XCTAssertTrue(
            call.rowStillPresent,
            "the authority row must still exist when the daemon is asked — it reads project_id off it"
        )

        let residue = try await queue.read { db in
            [
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE id = ?", arguments: [self.agentMemoryID]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_quarantine_bodies WHERE memory_id = ?", arguments: [self.agentMemoryID]) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM agent_memory_bodies
                    WHERE memory_id = ? AND (body != '' OR body_hash != '')
                    """,
                    arguments: [self.agentMemoryID]
                ) ?? -1
            ]
        }
        XCTAssertEqual(residue, [0, 0, 0], "no readable byte of the memory survives a successful forget")

        // The engine id is a routing label, not memory content: it survives so
        // the drain still resolves the sealed cloud document's name. Deleting
        // the mapping row instead would make `cloudFactIdentity` fall back to
        // the local id — and the engine-keyed copy would never be deleted.
        let drainedIdentity = try await store.cloudFactIdentity(for: agentMemoryID)
        XCTAssertEqual(
            drainedIdentity,
            engineMemoryID,
            "the drain deletes the doc keyed on the engine id — lose the mapping and it deletes nothing"
        )

        // The sealed cloud copy is deleted through a fact tombstone keyed on
        // the ENGINE id — that is the document's name, not the local one.
        let tombstones = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM memory_fact_tombstones WHERE memory_id = ?",
                arguments: [self.agentMemoryID]
            )
        }
        XCTAssertEqual(
            tombstones,
            [ControlPlaneStore.agentMemoryFactTombstoneID(
                memoryID: agentMemoryID,
                engineMemoryID: engineMemoryID
            )],
            "the tombstone keys on the engine id — the cloud document's name"
        )
    }

    /// The fail-closed half: a daemon that cannot answer leaves the row, the
    /// quarantine body, the sync body copy and the inbox entry fully intact —
    /// and the member sees the failure instead of a delete that did not happen.
    func testAnUnreachableDaemonKeepsTheAgentLaneMemoryFullyIntact() async throws {
        let forgetter = DaemonForgetterSpy(outcome: .unreachable)
        let (queue, store) = try makeStore(forgetter: forgetter)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try seedMirroredAgentMemory(on: queue, now: now, userID: "u-member-1")

        let model = makeModel(store: store, userID: "u-member-1")
        await model.load()
        // The store throws — the model surfaces it instead of letting the row
        // vanish from under the member's feet.
        do {
            _ = try await store.deleteMemoryAuthorityRecord(
                id: agentMemoryID,
                sourceKinds: [.agent],
                actingAccountUserID: "u-member-1"
            )
            XCTFail("an unreachable daemon must make Forget fail, not pretend")
        } catch {
            XCTAssertTrue(
                error is OpenBurnBarDaemonManagerError,
                "the throw is the daemon's refusal — an unrelated error would be a different bug: \(error)"
            )
        }
        await model.forget(agentMemoryID)
        XCTAssertNotNil(model.errorMessage, "the member is told the forget did not happen")
        XCTAssertEqual(forgetter.calls.count, 2, "both attempts reached the daemon client; none reached the delete")
        let survivors = try await queue.read { db in
            [
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE id = ?", arguments: [self.agentMemoryID]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_quarantine_bodies WHERE memory_id = ?", arguments: [self.agentMemoryID]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_fact_tombstones WHERE memory_id = ?", arguments: [self.agentMemoryID]) ?? 0
            ]
        }
        XCTAssertEqual(survivors, [1, 1, 0], "row and body survive; no tombstone was written for a memory that lives")
        await model.load()
        XCTAssertTrue(
            model.pending.contains { $0.id == agentMemoryID },
            "and the row is still there to forget when the daemon comes back"
        )
    }

    /// A chat forget never talks to the daemon at all — the boundary the agent
    /// lane crossed is not the chat lane's to cross.
    func testAChatForgetNeverCallsTheDaemon() async throws {
        let forgetter = DaemonForgetterSpy()
        let (queue, store) = try makeStore(forgetter: forgetter)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: "Prefers dark mode in every editor.", kind: .preference, scope: scope),
            id: "mem-chat",
            now: now,
            enabled: true
        )

        let model = makeModel(store: store)
        await model.load()
        await model.forget("mem-chat")

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(forgetter.calls.isEmpty, "chat bodies live in the app's own tables; the daemon owns none")
    }

    // MARK: - Pending publication stays out of sync (review #2565-F2)

    /// An approved row whose body the daemon has not published yet is not
    /// syncable: the candidate query used to hand it to the upload lane, where
    /// the quarantine fallback then sealed the UNREVIEWED body copy.
    func testAnAwaitingPublicationRowNeverReachesTheSyncPayload() async throws {
        let publisher = DaemonPublisherSpy(outcome: .unreachable)
        let (queue, store) = try makeStore(publisher: publisher)
        try seedMirroredAgentMemory(on: queue, now: Date(timeIntervalSince1970: 1_800_000_000))

        let model = makeModel(store: store)
        await model.load()
        await model.approve(agentMemoryID)

        // Claimed by the member, approved in-app, body still parked — exactly
        // the row the sync lane must refuse to seal.
        try await store.claimUnownedAgentMemories(userID: "u-member-1")
        let candidates = try await store.cloudSyncCandidateChatMemories(userID: "u-member-1")
        let pendingEligible = try await store.cloudSyncEligibleChatMemories(userID: "u-member-1")
        let pendingBody = try await store.syncableAgentMemoryBody(id: agentMemoryID)
        XCTAssertTrue(candidates.isEmpty, "an approved-but-unpublished mirrored row is not a sync candidate")
        XCTAssertTrue(pendingEligible.isEmpty, "and it cannot reach the eligible payload either")
        XCTAssertNil(pendingBody, "the sync opener refuses the quarantine fallback: no body, no hash")

        // Once the daemon publishes, the same row becomes the syncable thing
        // the lane exists to upload.
        try simulateDaemonPublication(on: queue)
        let eligible = try await store.cloudSyncEligibleChatMemories(userID: "u-member-1")
        XCTAssertEqual(eligible.map(\.id), [agentMemoryID])
        let publishedBody = try await store.syncableAgentMemoryBody(id: agentMemoryID)
        XCTAssertEqual(publishedBody, agentBody)
    }

    // MARK: - Verdict versioning (review #2565-F4, app half)

    /// The precondition the verdict is sent under: `expectedUpdatedAt` is the
    /// `updated_at` the app committed it with, so a verdict that lands after a
    /// newer one is refused instead of resurrected.
    func testThePublicationRPCCarriesTheVerdictStamp() async throws {
        let publisher = DaemonPublisherSpy()
        let (queue, store) = try makeStore(publisher: publisher)
        try seedMirroredAgentMemory(on: queue, now: Date(timeIntervalSince1970: 1_800_000_000))

        let model = makeModel(store: store)
        await model.load()
        await model.approve(agentMemoryID)

        let call = try XCTUnwrap(publisher.calls.first)
        let storedStamp = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT updated_at FROM agent_memories WHERE id = ?",
                arguments: [self.agentMemoryID]
            )
        }
        XCTAssertEqual(
            call.expectedUpdatedAt,
            storedStamp,
            "the precondition is exactly the stamp the verdict was committed under"
        )
        XCTAssertFalse(call.expectedUpdatedAt.isEmpty)
    }

    /// The drained backlog is not a second vote: when the daemon reports a
    /// retry as stale (`applied: false` — a newer verdict already landed), the
    /// store counts it as superseded, not published, and the pending row is
    /// simply out of the way.
    func testASupersededPublicationRetryIsNotResurrected() async throws {
        let publisher = DaemonPublisherSpy(outcome: .unreachable)
        let (queue, store) = try makeStore(publisher: publisher)
        try seedMirroredAgentMemory(on: queue, now: Date(timeIntervalSince1970: 1_800_000_000))

        let model = makeModel(store: store)
        await model.load()
        await model.approve(agentMemoryID)
        XCTAssertEqual(publisher.calls.count, 1)

        // The next launch's daemon answers, but reports the verdict stale —
        // the member re-decided while it was down.
        publisher.set(outcome: .refusedStale)
        let published = await store.retryPendingAgentMemoryPublications()
        XCTAssertEqual(published, 0, "a refused verdict is superseded, never published")
        XCTAssertEqual(publisher.calls.count, 2)
        XCTAssertEqual(publisher.calls.last?.expectedUpdatedAt, publisher.calls.first?.expectedUpdatedAt)
    }

    // MARK: - Badge cost (review #2565-F5)

    /// The dashboard asks this count on every render; before the fix it
    /// hydrated every mirrored row AND its provenance just to count it — an
    /// N+1 the badge paid each time it drew.
    func testTheAgentBadgeCountIsASingleQuery() async throws {
        let (queue, store) = try makeStore(traced: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try seedMirroredAgentMemory(on: queue, now: now)
        try seedMirroredAgentMemory(
            on: queue,
            now: now,
            memoryID: "mem_b2c3d4e5f60718293a4b5c6d7e8f9001",
            engineID: "mem_112233445566778899aabbccddeeff00",
            body: "A second fact the engine mirrored."
        )

        OpenBurnBarQueryTracer.shared.resetLog()
        let count = try await store.pendingAgentMemoryReviewCount(accountUserID: "u-member-1")
        XCTAssertEqual(count, 2)
        // The trace counts every statement GRDB issues — including the
        // `PRAGMA query_only` toggles a writer's read wraps itself in — so the
        // pin is on statements that TOUCH the table, not the raw statement
        // count.
        let agentQueries = OpenBurnBarQueryTracer.shared.queryLog.filter {
            $0.sql.lowercased().contains("from agent_memories")
        }
        XCTAssertEqual(
            agentQueries.count,
            1,
            "one COUNT(*) — not one query per row plus one per row's provenance"
        )
        OpenBurnBarQueryTracer.shared.resetLog()
    }

    // MARK: - The agent partition is account-scoped (review #2565-F6)

    /// Two members, one Mac profile: a row claimed by account A is invisible
    /// and unactionable in account B's inbox — and in nobody's when signed out
    /// — while an unclaimed row remains every signed-in member's to review.
    func testAgentRowsBelongToTheActingAccount() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try seedMirroredAgentMemory(on: queue, now: now, userID: "u-member-A")
        try seedMirroredAgentMemory(
            on: queue,
            now: now.addingTimeInterval(60),
            memoryID: "mem_c3d4e5f60718293a4b5c6d7e8f900102",
            engineID: "mem_2233445566778899aabbccddeeff0011",
            body: "An unclaimed mirrored fact."
        )

        // Account B sees only the unclaimed row.
        let bModel = makeModel(store: store, userID: "u-member-B")
        await bModel.load()
        XCTAssertEqual(bModel.pending.map(\.id), ["mem_c3d4e5f60718293a4b5c6d7e8f900102"])
        let otherAccountBody = try await store.openAgentMemoryBody(id: agentMemoryID, actingAccountUserID: "u-member-B")
        let otherAccountApproval = try await store.setMemoryReviewStatus(
            id: agentMemoryID,
            status: .approved,
            sourceKinds: [.agent],
            actingAccountUserID: "u-member-B"
        )
        let otherAccountDeletion = try await store.deleteMemoryAuthorityRecord(
            id: agentMemoryID,
            sourceKinds: [.agent],
            actingAccountUserID: "u-member-B"
        )
        let otherAccountCount = try await store.pendingAgentMemoryReviewCount(accountUserID: "u-member-B")
        XCTAssertNil(otherAccountBody, "B cannot open A's quarantined body")
        XCTAssertFalse(otherAccountApproval, "B cannot approve A's row")
        XCTAssertFalse(otherAccountDeletion, "B cannot forget A's row")
        XCTAssertEqual(otherAccountCount, 1, "and B's badge does not advertise A's row")

        // Account A sees both; signed-out sees only unclaimed.
        let aModel = makeModel(store: store, userID: "u-member-A")
        await aModel.load()
        XCTAssertEqual(aModel.pending.count, 2)
        let ownerCount = try await store.pendingAgentMemoryReviewCount(accountUserID: "u-member-A")
        let signedOutCount = try await store.pendingAgentMemoryReviewCount(accountUserID: nil)
        let ownerBody = try await store.openAgentMemoryBody(id: agentMemoryID, actingAccountUserID: "u-member-A")
        XCTAssertEqual(ownerCount, 2)
        XCTAssertEqual(signedOutCount, 1, "signed out: only the unclaimed row")
        XCTAssertEqual(ownerBody, agentBody, "A can open what it owns")
    }
}
