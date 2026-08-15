import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// PR1 of the usage-memory program: `MemorySourceKind` gains the two usage
/// kinds and the authority store is parameterized by source kind. These tests
/// pin two things:
///  1. the CHAT lane is byte-identical to its pre-parameterization behavior
///     (row shape, partition prefix, provenance vocabulary, audit labels), and
///  2. the usage kinds land in their own `usage:` partition, dedup across each
///     other, and can never touch chat rows (or be touched by chat calls).
final class UsageMemorySourceKindTests: XCTestCase {
    private func makeStore() throws -> (DatabaseQueue, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (queue, ControlPlaneStore(dbQueue: queue))
    }

    func test_chatWrapperKeepsRowShapeAndAuditLabelsByteIdentical() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let citation = MemoryCitation(
            id: "cite-1",
            threadLogicalID: "thread-1",
            messageID: "msg-1",
            role: "assistant",
            authoredAt: now,
            contentHash: "hash-1",
            crossDeviceHMAC: "hmac-1"
        )

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Prefers dark mode in every editor.",
                kind: .preference,
                scope: MemoryScope(userID: "user-1"),
                confidence: 0.9,
                citations: [citation],
                reviewStatus: .quarantined
            ),
            id: "mem-chat-pin",
            now: now,
            enabled: true
        )

        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM agent_memories WHERE id = 'mem-chat-pin'")
        }
        XCTAssertEqual(row?["source_kind"] as String?, "chat")
        XCTAssertEqual(row?["scope"] as String?, "chat")
        XCTAssertEqual(row?["project_id"] as String?, "chat:user-1")

        let provenanceKind = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT source_kind FROM memory_provenance WHERE memory_id = 'mem-chat-pin'"
            )
        }
        XCTAssertEqual(provenanceKind, "chat_message")

        let snapshotJSON = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT snapshot_json FROM memory_body_snapshots WHERE memory_id = 'mem-chat-pin'"
            )
        }
        let snapshot = try JSONDecoder.memorySnapshotDecoder.decode(
            ControlPlaneStore.MemoryBodySnapshot.self,
            from: Data(try XCTUnwrap(snapshotJSON).utf8)
        )
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.sourceKind, .chat)
        XCTAssertNil(snapshot.context)
        XCTAssertFalse(try XCTUnwrap(snapshotJSON).contains("\"context\""))

        let labelsJSON = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT labels_json FROM memory_audit WHERE subject_id = 'mem-chat-pin' AND action = 'memory.add'"
            )
        }
        let labels = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(labelsJSON).utf8))
        XCTAssertEqual(labels, [
            "body_ref:memory_body_snapshots:memory-mem-chat-pin",
            "memory_id:mem-chat-pin",
            "review_status:quarantined",
            "source_kind:chat"
        ])
    }

    func test_usageKindWritesUsagePartitionRowWithContextSnapshot() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_100)

        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Asks about GRDB migrations across sessions.",
                kind: .fact,
                scope: MemoryScope(userID: "user-1"),
                confidence: 0.6,
                citations: [
                    MemoryCitation(
                        id: "cite-usage",
                        threadLogicalID: "safari-ask:obs-1",
                        messageID: "obs-1",
                        role: "user",
                        authoredAt: now,
                        contentHash: "hash-usage",
                        crossDeviceHMAC: "hmac-usage"
                    )
                ],
                reviewStatus: .quarantined
            ),
            id: "mem-usage-pin",
            sourceKind: .safariAsk,
            context: "Asked while reading the GRDB migration docs.",
            now: now,
            enabled: true
        )

        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM agent_memories WHERE id = 'mem-usage-pin'")
        }
        XCTAssertEqual(row?["source_kind"] as String?, "safari_ask")
        XCTAssertEqual(row?["scope"] as String?, "safari_ask")
        XCTAssertEqual(row?["project_id"] as String?, "usage:user-1")
        XCTAssertEqual(row?["review_status"] as String?, "quarantined")

        let provenanceKind = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT source_kind FROM memory_provenance WHERE memory_id = 'mem-usage-pin'"
            )
        }
        XCTAssertEqual(provenanceKind, "safari_ask")

        let snapshotJSON = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT snapshot_json FROM memory_body_snapshots WHERE memory_id = 'mem-usage-pin'"
            )
        }
        let snapshot = try JSONDecoder.memorySnapshotDecoder.decode(
            ControlPlaneStore.MemoryBodySnapshot.self,
            from: Data(try XCTUnwrap(snapshotJSON).utf8)
        )
        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(snapshot.sourceKind, .safariAsk)
        XCTAssertEqual(snapshot.context, "Asked while reading the GRDB migration docs.")

        let labelsJSON = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT labels_json FROM memory_audit WHERE subject_id = 'mem-usage-pin' AND action = 'memory.add'"
            )
        }
        XCTAssertTrue(try XCTUnwrap(labelsJSON).contains("source_kind:safari_ask"))
    }

    func test_usageKindsDedupAcrossEachOtherButNeverAgainstChat() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        let scope = MemoryScope(userID: "user-1")
        let body = "Runs the release script from the repo root."

        // Same body in the CHAT partition first — must stay untouched below.
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: body, kind: .fact, scope: scope, confidence: 0.9),
            id: "mem-chat-same-body",
            now: now,
            enabled: true
        )

        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(text: body, kind: .fact, scope: scope, confidence: 0.7),
            id: "mem-usage-first",
            sourceKind: .safariAsk,
            now: now.addingTimeInterval(1),
            enabled: true
        )
        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(text: body, kind: .fact, scope: scope, confidence: 0.5),
            id: "mem-usage-second",
            sourceKind: .agentSession,
            now: now.addingTimeInterval(2),
            enabled: true
        )

        let rows = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, source_kind, valid_to, superseded_by
                FROM agent_memories
                WHERE id IN ('mem-chat-same-body', 'mem-usage-first', 'mem-usage-second')
                ORDER BY id
                """
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String? ?? "", $0) })

        // Chat row untouched by the usage-partition dedup.
        XCTAssertNil(byID["mem-chat-same-body"]?["superseded_by"] as String?)
        XCTAssertNil(byID["mem-chat-same-body"]?["valid_to"] as Date?)

        // Higher-confidence safariAsk row wins; the agentSession duplicate is
        // superseded across kinds because both live in the usage partition.
        XCTAssertNil(byID["mem-usage-first"]?["superseded_by"] as String?)
        XCTAssertEqual(byID["mem-usage-second"]?["superseded_by"] as String?, "mem-usage-first")
        XCTAssertNotNil(byID["mem-usage-second"]?["valid_to"] as Date?)

        let mergeLabels = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT labels_json FROM memory_audit WHERE action = 'memory.merge' AND subject_id = 'mem-usage-first'"
            )
        }
        XCTAssertTrue(try XCTUnwrap(mergeLabels).contains("source_kind:agent_session,safari_ask"))
    }

    func test_chatSourceKindGuardCannotReadOrDeleteUsageRows() async throws {
        let (_, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_300)

        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(text: "Usage-only fact.", kind: .fact, scope: MemoryScope(userID: "user-1")),
            id: "mem-usage-guard",
            sourceKind: .agentSession,
            now: now,
            enabled: true
        )

        let chatFetch = try await store.fetchChatMemoryAuthorityRecord(id: "mem-usage-guard")
        XCTAssertNil(chatFetch)

        let chatDelete = try await store.deleteChatMemoryAuthorityRecord(id: "mem-usage-guard", now: now)
        XCTAssertFalse(chatDelete)

        let usageFetch = try await store.fetchMemoryAuthorityRecord(
            id: "mem-usage-guard",
            sourceKinds: MemorySourceKind.usageKinds
        )
        XCTAssertEqual(usageFetch?.sourceKind, .agentSession)

        let usageDelete = try await store.deleteMemoryAuthorityRecord(
            id: "mem-usage-guard",
            sourceKinds: MemorySourceKind.usageKinds,
            now: now
        )
        XCTAssertTrue(usageDelete)
    }

    // MARK: - Reseal preserves the A-MEM context sentence

    /// Seeds a `safari_ask` memory carrying an A-MEM context sentence.
    @discardableResult
    private func addUsageMemoryWithContext(
        store: ControlPlaneStore,
        id: MemoryID,
        body: String = "Prefers GRDB migrations reviewed before merge.",
        context: String? = "Asked while reading the GRDB migration docs.",
        now: Date
    ) async throws -> Memory {
        try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .fact,
                scope: MemoryScope(userID: "user-1"),
                confidence: 0.6,
                reviewStatus: .quarantined
            ),
            id: id,
            sourceKind: .safariAsk,
            context: context,
            now: now,
            enabled: true
        )
    }

    private func snapshot(
        _ queue: DatabaseQueue,
        memoryID: MemoryID
    ) async throws -> (json: String, decoded: ControlPlaneStore.MemoryBodySnapshot) {
        let json = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT snapshot_json FROM memory_body_snapshots WHERE memory_id = ?",
                arguments: [memoryID]
            )
        }
        let unwrapped = try XCTUnwrap(json)
        return (
            unwrapped,
            try JSONDecoder.memorySnapshotDecoder.decode(
                ControlPlaneStore.MemoryBodySnapshot.self,
                from: Data(unwrapped.utf8)
            )
        )
    }

    /// The defect this guards: the reseal used to call `memoryBodySnapshotJSON`
    /// without `context:`, so a body edit dropped the A-MEM context sentence
    /// and silently downgraded the snapshot from schemaVersion 2 to 1.
    func test_bodyUpdatePreservesUsageContextAndSchemaVersion() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_400)
        try await addUsageMemoryWithContext(store: store, id: "mem-usage-reseal", now: now)

        let updated = try await store.updateMemoryAuthorityRecord(
            id: "mem-usage-reseal",
            patch: MemoryPatch(text: "Prefers GRDB migrations reviewed by two people.", confidence: 0.75),
            sourceKinds: MemorySourceKind.usageKinds,
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(updated)

        let (_, resealed) = try await snapshot(queue, memoryID: "mem-usage-reseal")
        XCTAssertEqual(resealed.schemaVersion, 2)
        XCTAssertEqual(resealed.context, "Asked while reading the GRDB migration docs.")
        XCTAssertEqual(resealed.body, "Prefers GRDB migrations reviewed by two people.")
        XCTAssertEqual(resealed.sourceKind, .safariAsk)

        // The reseal re-derives the hash from the new body, in the snapshot and
        // in the `body_hash` column that dedup joins on.
        let expectedHash = ControlPlaneStore.sha256Hex("Prefers GRDB migrations reviewed by two people.")
        XCTAssertEqual(resealed.bodyHash, expectedHash)
        let columnHash = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT body_hash FROM memory_body_snapshots WHERE memory_id = 'mem-usage-reseal'")
        }
        XCTAssertEqual(columnHash, expectedHash)
    }

    /// Chat never has a context sentence, so its reseal must stay on
    /// schemaVersion 1 and must not start emitting a `context` key.
    func test_chatBodyUpdateStaysSchemaVersionOneWithoutContextKey() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_500)
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(text: "Prefers dark mode.", kind: .preference, scope: MemoryScope(userID: "user-1")),
            id: "mem-chat-reseal",
            now: now,
            enabled: true
        )

        let updated = try await store.updateChatMemoryAuthorityRecord(
            id: "mem-chat-reseal",
            patch: MemoryPatch(text: "Prefers dark mode everywhere."),
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(updated)

        let (json, resealed) = try await snapshot(queue, memoryID: "mem-chat-reseal")
        XCTAssertEqual(resealed.schemaVersion, 1)
        XCTAssertNil(resealed.context)
        XCTAssertFalse(json.contains("\"context\""))
        XCTAssertEqual(resealed.body, "Prefers dark mode everywhere.")
    }

    /// A caller may change the context sentence deliberately, with no body
    /// patch — the body and its hash survive the reseal untouched.
    func test_contextReplaceRewritesSentenceWithoutTouchingBody() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_600)
        try await addUsageMemoryWithContext(store: store, id: "mem-usage-context-only", now: now)

        let updated = try await store.updateMemoryAuthorityRecord(
            id: "mem-usage-context-only",
            patch: MemoryPatch(),
            sourceKinds: MemorySourceKind.usageKinds,
            context: .replace("Asked again while reviewing a migration PR."),
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(updated)

        let (_, resealed) = try await snapshot(queue, memoryID: "mem-usage-context-only")
        XCTAssertEqual(resealed.schemaVersion, 2)
        XCTAssertEqual(resealed.context, "Asked again while reviewing a migration PR.")
        XCTAssertEqual(resealed.body, "Prefers GRDB migrations reviewed before merge.")
        XCTAssertEqual(resealed.bodyHash, ControlPlaneStore.sha256Hex("Prefers GRDB migrations reviewed before merge."))
    }

    /// `.replace(nil)` is the one sanctioned way to drop the sentence, and it
    /// takes the snapshot back to schemaVersion 1 without a `context` key.
    func test_contextReplaceWithNilClearsSentenceAndDowngradesSchemaVersion() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_700)
        try await addUsageMemoryWithContext(store: store, id: "mem-usage-context-clear", now: now)

        let updated = try await store.updateMemoryAuthorityRecord(
            id: "mem-usage-context-clear",
            patch: MemoryPatch(),
            sourceKinds: MemorySourceKind.usageKinds,
            context: .replace(nil),
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(updated)

        let (json, resealed) = try await snapshot(queue, memoryID: "mem-usage-context-clear")
        XCTAssertEqual(resealed.schemaVersion, 1)
        XCTAssertNil(resealed.context)
        XCTAssertFalse(json.contains("\"context\""))
    }

    /// G7 runs over the context sentence too — it is plaintext at rest in
    /// `snapshot_json`, so a secret there must fail closed before the reseal.
    func test_replacementContextSecretIsRejectedBeforeReseal() async throws {
        let (queue, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_800)
        try await addUsageMemoryWithContext(store: store, id: "mem-usage-context-secret", now: now)

        do {
            _ = try await store.updateMemoryAuthorityRecord(
                id: "mem-usage-context-secret",
                patch: MemoryPatch(),
                sourceKinds: MemorySourceKind.usageKinds,
                context: .replace("Asked right after pasting sk-ant-1234567890abcdef1234567890."),
                now: now.addingTimeInterval(60)
            )
            XCTFail("Expected a secret-bearing context sentence to be rejected before the reseal.")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneStore.ChatMemoryAuthorityError,
                .secretRejected(labels: ["anthropic-api-key"])
            )
        }

        let (_, unchanged) = try await snapshot(queue, memoryID: "mem-usage-context-secret")
        XCTAssertEqual(unchanged.context, "Asked while reading the GRDB migration docs.")

        let audit = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT labels_json FROM memory_audit
                WHERE subject_id = 'mem-usage-context-secret' AND action = 'memory.secret_rejected'
                """
            )
        }
        XCTAssertTrue(try XCTUnwrap(audit).contains("source_kind:safari_ask"))
    }

    /// Same gate on the add path: the context sentence is sealed alongside the
    /// body, so it must be scanned there as well.
    func test_addPathRejectsSecretInContextSentence() async throws {
        let (queue, store) = try makeStore()

        do {
            try await addUsageMemoryWithContext(
                store: store,
                id: "mem-usage-add-context-secret",
                context: "Asked right after pasting sk-ant-1234567890abcdef1234567890.",
                now: Date(timeIntervalSince1970: 1_800_000_900)
            )
            XCTFail("Expected a secret-bearing context sentence to be rejected before persistence.")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneStore.ChatMemoryAuthorityError,
                .secretRejected(labels: ["anthropic-api-key"])
            )
        }

        let persisted = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_memories WHERE id = 'mem-usage-add-context-secret'"
            ) ?? 0
        }
        XCTAssertEqual(persisted, 0)
    }

    func test_usageSecretRejectionAuditsWithUsageSourceKindLabel() async throws {
        let (queue, store) = try makeStore()
        let secret = "sk-ant-1234567890abcdef1234567890"

        do {
            _ = try await store.addMemoryAuthorityRecord(
                MemoryAddRequest(
                    text: "Pasted \(secret) into a Safari ask.",
                    scope: MemoryScope(userID: "user-1")
                ),
                id: "mem-usage-secret",
                sourceKind: .safariAsk,
                enabled: true
            )
            XCTFail("Expected secret-bearing usage memory to be rejected before persistence.")
        } catch {
            XCTAssertEqual(
                error as? ControlPlaneStore.ChatMemoryAuthorityError,
                .secretRejected(labels: ["anthropic-api-key"])
            )
        }

        let audit = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT labels_json FROM memory_audit WHERE subject_id = 'mem-usage-secret' AND action = 'memory.secret_rejected'"
            )
        }
        XCTAssertTrue(try XCTUnwrap(audit).contains("source_kind:safari_ask"))

        let persisted = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE id = 'mem-usage-secret'") ?? 0
        }
        XCTAssertEqual(persisted, 0)
    }
}

private extension JSONDecoder {
    static var memorySnapshotDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
