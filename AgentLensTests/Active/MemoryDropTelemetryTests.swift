import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - G7 drop telemetry tests
//
// Proves that when the worker drains a job whose extractor returns a mix of clean and
// secret-bearing candidates:
//   1. The secret candidate is DROPPED (not persisted).
//   2. A `memory.candidate_dropped` audit event is written with the finding label
//      (stable dashed id) and NEVER the secret text or the candidate body.
//   3. `MemoryExtractionPumpReport.dropped` is 1 (matching the one dropped candidate).
//
// The fixtures mirror `MemoryExtractionEngineTests` exactly (same makeStore / enqueue /
// insertChatMessage helpers) so this file is self-contained and does not couple to the
// integrator-owned test files.

@MainActor
final class MemoryDropTelemetryTests: XCTestCase {

    // MARK: - Fixtures (mirrored from MemoryExtractionEngineTests)

    private func makeStore() throws -> (ControlPlaneStore, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (ControlPlaneStore(dbQueue: queue), queue)
    }

    private func insertChatMessage(
        _ queue: DatabaseQueue,
        threadID: String,
        id: String,
        role: String,
        body: String,
        at date: Date
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [threadID, date, date]
            )
            try db.execute(
                sql: """
                INSERT INTO chat_messages (id, role, content, timestamp, threadId)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [id, role, body, date, threadID]
            )
        }
    }

    @discardableResult
    private func enqueue(
        _ store: ControlPlaneStore,
        threadID: String,
        messageID: String,
        idempotencyKey: String,
        now: Date
    ) async throws -> String {
        let intent = ExtractionIntent(
            threadID: threadID,
            threadLogicalID: "\(threadID)-logical",
            messageID: messageID,
            scope: MemoryScope(userID: "telemetry-user", appID: "telemetry-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: idempotencyKey
        )
        return try await store.enqueueMemoryExtraction(intent, now: now)
    }

    // MARK: - Headline: drop telemetry + pump report

    func test_worker_secretCandidateDropped_emitsAuditEvent_andPumpReportCountsIt() async throws {
        let (store, queue) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_900_001_000)

        // The clean candidate needs a cited source message so provenance resolves.
        let threadID = "thread-telemetry"
        let sourceID = "msg-telemetry-source"
        try await insertChatMessage(
            queue,
            threadID: threadID,
            id: sourceID,
            role: "assistant",
            body: "Context for the extracted facts.",
            at: now
        )

        let jobID = try await enqueue(
            store,
            threadID: threadID,
            messageID: sourceID,
            idempotencyKey: "idem-telemetry",
            now: now
        )

        // A live-looking Anthropic key the G7 corpus flags as `anthropic-api-key`.
        // NEVER use the secret text as an expected value in an assertion — only the
        // stable finding id (the dashed label) is safe to check in audit output.
        let secretText = "sk-ant-deadbeefdeadbeefdeadbeef0001"

        @Sendable func candidate(_ text: String) -> MemoryAddRequest {
            MemoryAddRequest(
                text: text,
                kind: .fact,
                scope: MemoryScope(userID: "telemetry-user", appID: "telemetry-app"),
                confidence: 0.9,
                citations: [
                    MemoryCitation(
                        id: "cite-telemetry",
                        threadLogicalID: "\(threadID)-logical",
                        messageID: sourceID,
                        role: "assistant",
                        authoredAt: now,
                        contentHash: "ignored",
                        crossDeviceHMAC: "ignored"
                    )
                ],
                reviewStatus: .quarantined
            )
        }

        // Batch: clean (index 0) → SECRET (index 1). Worker must drop index 1 only.
        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { _ in
                [
                    candidate("User prefers concise answers."),
                    candidate("My api key is \(secretText) keep it safe.")
                ]
            }
        )

        // Drive the worker the way the engine does, capturing lastDroppedCount per tick.
        var totalDropped = 0
        var report = MemoryExtractionPumpReport()
        for _ in 0 ..< 16 {
            let outcome = try await worker.drainNext()
            switch outcome {
            case .drained:
                report.processed += 1
                report.dropped += await worker.lastDroppedCount
                totalDropped += await worker.lastDroppedCount
            case .claimedButFailed:
                report.processed += 1
                report.failed += 1
                report.dropped += await worker.lastDroppedCount
                totalDropped += await worker.lastDroppedCount
            case .idle:
                break
            }
            if outcome == .idle { break }
        }

        // (1) The job succeeded — a drop is not a job failure.
        let jobStatus = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(jobStatus, .succeeded, "job succeeds even when one candidate is dropped")

        // (2) The clean candidate (index 0) persisted; the secret (index 1) did NOT.
        let cleanMem = try await store.fetchChatMemoryAuthorityRecord(id: "memory-\(jobID)-0")
        let droppedMem = try await store.fetchChatMemoryAuthorityRecord(id: "memory-\(jobID)-1")
        XCTAssertNotNil(cleanMem, "clean candidate must be persisted")
        XCTAssertNil(droppedMem, "secret candidate must be dropped (no authority record)")

        let totalChatMemories = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? -1
        }
        XCTAssertEqual(totalChatMemories, 1, "exactly one clean fact; the secret never persisted")

        // (3) pump report's dropped count matches the one dropped candidate.
        XCTAssertEqual(report.dropped, 1, "pump report must count the one dropped candidate")

        // (4) A `memory.candidate_dropped` audit event was written.
        let auditRows = try await queue.read { db -> [(action: String, labelsJSON: String, subjectID: String)] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT action, labels_json, subject_id FROM memory_audit WHERE action = 'memory.candidate_dropped'"
            )
            return rows.map { (action: $0["action"], labelsJSON: $0["labels_json"], subjectID: $0["subject_id"]) }
        }
        XCTAssertEqual(auditRows.count, 1, "exactly one candidate_dropped event")
        let auditRow = try XCTUnwrap(auditRows.first)

        // subject_id is the deterministic memory id for the dropped candidate (index 1).
        let expectedDroppedMemoryID = "memory-\(jobID)-1"
        XCTAssertEqual(auditRow.subjectID, expectedDroppedMemoryID,
                       "audit subject_id is the deterministic memory id of the dropped candidate")

        // labels_json is a sorted JSON array of `key:value` strings. Decode and inspect.
        let labels = try JSONDecoder().decode([String].self, from: Data(auditRow.labelsJSON.utf8))

        // Must carry the finding id — the stable dashed label (e.g. `anthropic-api-key`).
        let hasFindingLabel = labels.contains(where: { $0.hasPrefix("finding_labels:") && $0.contains("anthropic-api-key") })
        XCTAssertTrue(hasFindingLabel, "audit labels must carry the finding id (dashed, stable)")

        // Must carry candidate_index = 1 (the position of the dropped candidate in the batch).
        XCTAssertTrue(labels.contains("candidate_index:1"), "audit labels must carry the candidate index")

        // Must carry source_kind = chat.
        XCTAssertTrue(labels.contains("source_kind:chat"), "audit labels must carry source_kind:chat")

        // MUST NOT contain the secret text anywhere in the audit event.
        XCTAssertFalse(auditRow.labelsJSON.contains(secretText),
                       "the secret text must NEVER appear in audit labels_json")
        XCTAssertFalse(auditRow.action.contains(secretText),
                       "the secret text must NEVER appear in the audit action")
    }
}
