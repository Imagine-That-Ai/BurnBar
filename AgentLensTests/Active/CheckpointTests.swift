import XCTest
import GRDB
@testable import OpenBurnBar

/// Tests for checkpoint/resume and atomic visibility boundaries.
///
/// Verifies:
/// - VAL-PERSIST-004: Checkpoints advance only after successful commit
/// - VAL-PERSIST-005: Resume from checkpoint is gap-free and duplicate-free
/// - VAL-PERSIST-014: Parser cache corruption/reset recovery is safe
/// - VAL-CROSS-008: Atomic visibility boundary across ingestion, indexing, and reporting
@MainActor
final class CheckpointTests: XCTestCase {

    // MARK: - VAL-PERSIST-004: Checkpoints advance only after successful commit

    func test_checkpoint_doesNotAdvance_whenCommitFails() throws {
        // Given: a DataStore with checkpoint store
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert a usage first
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "commit-fail-test",
            projectName: "TestProject",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(usage)

        // Verify no checkpoint exists initially
        let initialCheckpoint = try checkpointStore.fetchCheckpoint(for: .claudeCode)
        XCTAssertNil(initialCheckpoint, "No checkpoint should exist initially")

        // When: we create a transaction but it fails (empty token prevents advance)
        let tx = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .claudeCode
        )
        tx.append(
            usages: [],
            conversations: [],
            checkpointToken: "", // Empty token - checkpoint won't advance
            lastProcessedFilePath: nil
        )

        // Simulate a commit failure by rolling back
        tx.rollback()

        // Then: no checkpoint should exist (not advanced on failure)
        let afterRollbackCheckpoint = try checkpointStore.fetchCheckpoint(for: .claudeCode)
        XCTAssertNil(afterRollbackCheckpoint, "Checkpoint must not advance on rollback")
    }

    func test_checkpoint_doesNotAdvance_whenTransaction_throwsBeforeCommit() throws {
        // Given: a DataStore with checkpoint store
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert a usage
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "throw-before-commit-test",
            projectName: "TestProject",
            model: "glm-5",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.10,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(usage)

        // Verify no checkpoint exists initially
        let initialCheckpoint = try checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNil(initialCheckpoint, "No checkpoint should exist initially")

        // When: we create a transaction that throws before commit
        do {
            let tx = AtomicIngestionTransaction(
                dbQueue: queue,
                checkpointStore: checkpointStore,
                provider: .factory
            )
            tx.append(
                usages: [],
                conversations: [],
                checkpointToken: "v1:12345:0", // Valid token
                lastProcessedFilePath: nil
            )
            // Simulate failure - just let it fall through without commit
            throw NSError(domain: "Test", code: 42, userInfo: nil)
        } catch {
            // Expected - transaction was abandoned
        }

        // Then: no checkpoint should exist (not advanced on failure)
        let afterFailureCheckpoint = try checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNil(afterFailureCheckpoint, "Checkpoint must not advance when transaction fails before commit")
    }

    func test_checkpoint_advances_onlyAfterSuccessfulCommit() throws {
        // Given: a DataStore with checkpoint store
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert usages
        let usage = TokenUsage(
            provider: .cursor,
            sessionId: "commit-success-test",
            projectName: "TestProject",
            model: "gpt-4",
            inputTokens: 3000,
            outputTokens: 1000,
            costUSD: 0.12,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(usage)

        // Verify no checkpoint exists initially
        let initialCheckpoint = try checkpointStore.fetchCheckpoint(for: .cursor)
        XCTAssertNil(initialCheckpoint, "No checkpoint should exist initially")

        // When: we create and successfully commit a transaction
        let tx = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .cursor
        )
        tx.append(
            usages: [],
            conversations: [],
            checkpointToken: "v1:12345:0",
            lastProcessedFilePath: "/path/to/log"
        )
        try tx.commit()

        // Then: checkpoint should exist and be advanced
        let afterCommitCheckpoint = try checkpointStore.fetchCheckpoint(for: .cursor)
        XCTAssertNotNil(afterCommitCheckpoint, "Checkpoint must exist after successful commit")
        XCTAssertEqual(afterCommitCheckpoint?.checkpointToken, "v1:12345:0")
        XCTAssertEqual(afterCommitCheckpoint?.lastProcessedFilePath, "/path/to/log")
    }

    func test_checkpoint_idempotent_commitIsIdempotent() throws {
        // Given: a DataStore with checkpoint store
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert a usage
        let usage = TokenUsage(
            provider: .kimi,
            sessionId: "idempotent-commit-test",
            projectName: "TestProject",
            model: "moonshot-v1-8k",
            inputTokens: 1500,
            outputTokens: 600,
            costUSD: 0.08,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(usage)

        // When: we commit multiple times
        let tx = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .kimi
        )
        tx.append(
            usages: [],
            conversations: [],
            checkpointToken: "v1:99999:0",
            lastProcessedFilePath: "/path/to/kimi/log"
        )
        try tx.commit()

        // Then: checkpoint exists
        let afterFirstCommit = try checkpointStore.fetchCheckpoint(for: .kimi)
        XCTAssertNotNil(afterFirstCommit)
        XCTAssertEqual(afterFirstCommit?.checkpointToken, "v1:99999:0")

        // When: we try to commit again (idempotent - should be no-op)
        let tx2 = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .kimi
        )
        tx2.append(
            usages: [],
            conversations: [],
            checkpointToken: "v1:99999:0",
            lastProcessedFilePath: "/path/to/kimi/log"
        )
        try tx2.commit()

        // Then: checkpoint still exists with same values
        let afterSecondCommit = try checkpointStore.fetchCheckpoint(for: .kimi)
        XCTAssertNotNil(afterSecondCommit)
        XCTAssertEqual(afterSecondCommit?.checkpointToken, "v1:99999:0")
    }

    // MARK: - VAL-PERSIST-005: Resume from checkpoint is gap-free and duplicate-free

    func test_resume_findsExistingCheckpoint() throws {
        // Given: a DataStore with an existing checkpoint
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert a checkpoint directly
        try checkpointStore.advanceCheckpoint(
            for: .claudeCode,
            checkpointToken: "v1:existing:5",
            lastProcessedFilePath: "/existing/path"
        )

        // When: we create a CheckpointedParserWrapper
        let wrapper = CheckpointedParserWrapper(
            parser: MockLogParser(provider: .claudeCode),
            checkpointStore: checkpointStore
        )

        // Then: it should detect the existing checkpoint
        XCTAssertTrue(wrapper.hasCheckpoint(), "Wrapper should detect existing checkpoint")
    }

    func test_resume_noCheckpoint_meansFreshStart() throws {
        // Given: a DataStore with no checkpoint
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // When: we create a CheckpointedParserWrapper
        let wrapper = CheckpointedParserWrapper(
            parser: MockLogParser(provider: .factory),
            checkpointStore: checkpointStore
        )

        // Then: it should detect no checkpoint
        XCTAssertFalse(wrapper.hasCheckpoint(), "Wrapper should detect no checkpoint")
    }

    func test_resume_gapFreeAfterInterruption() throws {
        // Given: a scenario simulating interruption and resume
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert usages representing first batch
        let usage1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "gap-free-test-1",
            projectName: "TestProject",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(usage1)

        // Advance checkpoint after first batch
        try checkpointStore.advanceCheckpoint(
            for: .claudeCode,
            checkpointToken: "v1:batch1:10",
            lastProcessedFilePath: "/path/batch1"
        )

        // Insert usages representing second batch (simulating resume)
        let usage2 = TokenUsage(
            provider: .claudeCode,
            sessionId: "gap-free-test-2",
            projectName: "TestProject",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.10,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(usage2)

        // Advance checkpoint after second batch
        try checkpointStore.advanceCheckpoint(
            for: .claudeCode,
            checkpointToken: "v1:batch2:20",
            lastProcessedFilePath: "/path/batch2"
        )

        // Then: both usages should exist (no gap)
        let allUsages = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage WHERE sessionId LIKE 'gap-free-test-%'")
        }
        XCTAssertEqual(allUsages.count, 2, "Both batches should be present - no gap")

        // And: checkpoint should reflect latest position
        let checkpoint = try checkpointStore.fetchCheckpoint(for: .claudeCode)
        XCTAssertEqual(checkpoint?.checkpointToken, "v1:batch2:20")
    }

    func test_resume_duplicateFreeOnReingest() throws {
        // Given: a scenario where same data is re-ingested after checkpoint
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert usages
        let usage = TokenUsage(
            provider: .cursor,
            sessionId: "duplicate-free-test",
            projectName: "TestProject",
            model: "gpt-4",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(usage)

        // Advance checkpoint
        try checkpointStore.advanceCheckpoint(
            for: .cursor,
            checkpointToken: "v1:after-first:5",
            lastProcessedFilePath: "/path/first"
        )

        // Simulate re-ingest of same data (same session)
        try store.insert(usage)

        // Advance checkpoint again
        try checkpointStore.advanceCheckpoint(
            for: .cursor,
            checkpointToken: "v1:after-second:10",
            lastProcessedFilePath: "/path/second"
        )

        // Then: only one usage row should exist (duplicate-free due to upsert semantics)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage WHERE sessionId = 'duplicate-free-test'")
        }
        XCTAssertEqual(rows.count, 1, "Should have only one row - duplicate-free upsert")
    }

    // MARK: - VAL-PERSIST-014: Parser cache corruption/reset recovery is safe

    func test_clearCheckpoint_forcesFullReprocess() throws {
        // Given: a DataStore with checkpoint
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert usages and checkpoint
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "corruption-recovery-test",
            projectName: "TestProject",
            model: "glm-5",
            inputTokens: 3000,
            outputTokens: 1200,
            costUSD: 0.15,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(usage)

        try checkpointStore.advanceCheckpoint(
            for: .factory,
            checkpointToken: "v1:corrupted:100",
            lastProcessedFilePath: "/corrupted/path"
        )

        // Verify checkpoint exists
        let checkpointBefore = try checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNotNil(checkpointBefore, "Checkpoint should exist before clear")

        // When: we clear the checkpoint (simulating corruption detection)
        try checkpointStore.clearCheckpoint(for: .factory)

        // Then: checkpoint is gone and usage remains
        let checkpointAfter = try checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNil(checkpointAfter, "Checkpoint should be cleared")

        // Usage should still exist (data not lost)
        let usageAfter = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM token_usage WHERE sessionId = 'corruption-recovery-test'")
        }
        XCTAssertNotNil(usageAfter, "Usage data should still exist after checkpoint clear")
    }

    func test_clearAllCheckpoints_fullReset() throws {
        // Given: a DataStore with multiple provider checkpoints
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert checkpoints for multiple providers
        try checkpointStore.advanceCheckpoint(
            for: .claudeCode,
            checkpointToken: "v1:cc:1",
            lastProcessedFilePath: "/cc/path"
        )
        try checkpointStore.advanceCheckpoint(
            for: .cursor,
            checkpointToken: "v1:cursor:1",
            lastProcessedFilePath: "/cursor/path"
        )
        try checkpointStore.advanceCheckpoint(
            for: .factory,
            checkpointToken: "v1:factory:1",
            lastProcessedFilePath: "/factory/path"
        )

        // When: we clear all checkpoints
        try checkpointStore.clearAllCheckpoints()

        // Then: all checkpoints are gone
        let allCheckpoints = try checkpointStore.fetchAllCheckpoints()
        XCTAssertTrue(allCheckpoints.isEmpty, "All checkpoints should be cleared")
    }

    func test_recoveryAfterCorruption_noMissingRows() throws {
        // Given: a scenario with usage data and checkpoint
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // Insert multiple usages
        for i in 1...5 {
            let usage = TokenUsage(
                provider: .claudeCode,
                sessionId: "recovery-test-\(i)",
                projectName: "TestProject",
                model: "claude-4-sonnet",
                inputTokens: 1000 * i,
                outputTokens: 500 * i,
                costUSD: 0.05 * Double(i),
                startTime: Date(),
                endTime: Date(),
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact,
                estimatorVersion: ""
            )
            try store.insert(usage)
        }

        // Advance checkpoint
        try checkpointStore.advanceCheckpoint(
            for: .claudeCode,
            checkpointToken: "v1:pre-corruption:5",
            lastProcessedFilePath: "/path/before"
        )

        // Simulate corruption by clearing checkpoint
        try checkpointStore.clearCheckpoint(for: .claudeCode)

        // Re-ingest the same data (simulating recovery reprocess)
        for i in 1...5 {
            let usage = TokenUsage(
                provider: .claudeCode,
                sessionId: "recovery-test-\(i)",
                projectName: "TestProject",
                model: "claude-4-sonnet",
                inputTokens: 1000 * i,
                outputTokens: 500 * i,
                costUSD: 0.05 * Double(i),
                startTime: Date(),
                endTime: Date(),
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact,
                estimatorVersion: ""
            )
            try store.insert(usage)
        }

        // Then: should have exactly 5 rows (no duplicates due to upsert)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage WHERE sessionId LIKE 'recovery-test-%'")
        }
        XCTAssertEqual(rows.count, 5, "Should have exactly 5 rows - no duplicates after recovery reprocess")
    }

    // MARK: - VAL-CROSS-008: Atomic visibility boundary

    func test_atomicVisibility_noPartialState_onFailure() throws {
        // Given: a DataStore with checkpoint store
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // When: we append to transaction but fail before commit
        let tx = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .claudeCode
        )

        // Simulate adding data to transaction
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "partial-state-test",
            projectName: "TestProject",
            model: "claude-4-sonnet",
            inputTokens: 5000,
            outputTokens: 2000,
            costUSD: 0.25,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        tx.append(
            usages: [usage],
            conversations: [],
            checkpointToken: "v1:partial:0",
            lastProcessedFilePath: nil
        )

        // Rollback without committing
        tx.rollback()

        // Then: no usage row should exist (not visible)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage WHERE sessionId = 'partial-state-test'")
        }
        XCTAssertTrue(rows.isEmpty, "No partial state should be visible after rollback")

        // And: no checkpoint should exist
        let checkpoint = try checkpointStore.fetchCheckpoint(for: .claudeCode)
        XCTAssertNil(checkpoint, "No checkpoint should exist after rollback")
    }

    func test_atomicVisibility_fullState_afterCommit() throws {
        // Given: a DataStore with checkpoint store
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        // When: we commit atomically
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "full-state-test",
            projectName: "TestProject",
            model: "claude-4-sonnet",
            inputTokens: 5000,
            outputTokens: 2000,
            costUSD: 0.25,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )

        let tx = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .claudeCode
        )
        tx.append(
            usages: [usage],
            conversations: [],
            checkpointToken: "v1:full:0",
            lastProcessedFilePath: "/path/full"
        )
        try tx.commit()

        // Then: usage should be visible
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage WHERE sessionId = 'full-state-test'")
        }
        XCTAssertEqual(rows.count, 1, "Full state should be visible after commit")

        // And: checkpoint should exist
        let checkpoint = try checkpointStore.fetchCheckpoint(for: .claudeCode)
        XCTAssertNotNil(checkpoint, "Checkpoint should exist after commit")
        XCTAssertEqual(checkpoint?.checkpointToken, "v1:full:0")
    }

    func test_atomicVisibility_rollbackClearsInMemoryState() throws {
        // Given: a transaction with data
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        let usage = TokenUsage(
            provider: .cursor,
            sessionId: "rollback-clear-test",
            projectName: "TestProject",
            model: "gpt-4",
            inputTokens: 3000,
            outputTokens: 1200,
            costUSD: 0.15,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )

        let tx = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .cursor
        )
        tx.append(
            usages: [usage],
            conversations: [],
            checkpointToken: "v1:rollback:0",
            lastProcessedFilePath: nil
        )

        // When: we rollback
        tx.rollback()

        // Then: transaction was rolled back
        XCTAssertTrue(tx.wasRolledBack, "Transaction should be marked as rolled back")
        XCTAssertFalse(tx.wasCommitted, "Transaction should not be marked as committed")
    }

    func test_atomicVisibility_multipleCommits_advancesCheckpointEachTime() throws {
        // Given: a committed transaction
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let checkpointStore = ParserCheckpointStore(dbQueue: queue)

        let tx = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .kimi
        )
        tx.append(
            usages: [],
            conversations: [],
            checkpointToken: "v1:first:0",
            lastProcessedFilePath: nil
        )
        try tx.commit()

        // When: we commit again with a new token
        let tx2 = AtomicIngestionTransaction(
            dbQueue: queue,
            checkpointStore: checkpointStore,
            provider: .kimi
        )
        tx2.append(
            usages: [],
            conversations: [],
            checkpointToken: "v1:second:0",
            lastProcessedFilePath: nil
        )
        try tx2.commit()

        // Then: the checkpoint reflects the latest commit
        let checkpoint = try checkpointStore.fetchCheckpoint(for: .kimi)
        XCTAssertEqual(checkpoint?.checkpointToken, "v1:second:0", "Latest committed checkpoint should persist")
        XCTAssertEqual(checkpoint?.version, 2, "Version should be incremented")
    }
}

// MARK: - Mock LogParser for Testing

private struct MockLogParser: LogParser {
    let provider: AgentProvider

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }
}
