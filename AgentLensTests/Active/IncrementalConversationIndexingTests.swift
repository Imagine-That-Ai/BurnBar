import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class IncrementalConversationIndexingTests: XCTestCase {

    // MARK: - 1. Unchanged steady-state: batch-fetch skip logic

    func test_conversationIndexer_skipsAll_whenSteadyStateUnchanged() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let count = 5
        var records: [ConversationRecord] = []
        for i in 0..<count {
            records.append(makeFactoryConversationRecord(
                id: "Factory:steady-\(i)",
                indexedAt: mtime,
                fileModifiedAt: mtime
            ))
        }

        // Initial indexing pass — all records are new, all should be changed.
        let firstReport = try await ConversationIndexer.shared.index(records, in: store)
        XCTAssertEqual(firstReport.changedRecordCount, count)
        XCTAssertEqual(firstReport.skippedRecordCount, 0)

        // Second pass with the SAME records (same fileModifiedAt) — all should be skipped.
        let secondReport = try await ConversationIndexer.shared.index(records, in: store)
        XCTAssertEqual(secondReport.skippedRecordCount, count)
        XCTAssertEqual(secondReport.changedRecordCount, 0)
    }

    // MARK: - 2. Append/change: new record upserted, existing skipped

    func test_conversationIndexer_appendsNew_andSkipsExisting() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let count = 3
        var originalRecords: [ConversationRecord] = []
        for i in 0..<count {
            originalRecords.append(makeFactoryConversationRecord(
                id: "Factory:append-\(i)",
                indexedAt: mtime,
                fileModifiedAt: mtime
            ))
        }

        // Initial pass: all N records are new.
        let firstReport = try await ConversationIndexer.shared.index(originalRecords, in: store)
        XCTAssertEqual(firstReport.changedRecordCount, count)

        // Second pass: N original (unchanged) + 1 new record.
        var appendedRecords = originalRecords
        appendedRecords.append(makeFactoryConversationRecord(
            id: "Factory:append-new",
            indexedAt: mtime,
            fileModifiedAt: mtime
        ))

        let secondReport = try await ConversationIndexer.shared.index(appendedRecords, in: store)
        XCTAssertEqual(secondReport.changedRecordCount, 1)
        XCTAssertEqual(secondReport.skippedRecordCount, count)

        // The new record should be upserted.
        let newRow = try await store.fetchConversation(id: "Factory:append-new")
        XCTAssertNotNil(newRow)
    }

    // MARK: - 3. Checkpoint watermark filtering: unchanged corpus filtered

    func test_runConversationIndexing_checkpointFiltersUnchangedCorpus() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let conversations: [ConversationRecord] = (0..<3).map { i in
            makeFactoryConversationRecord(
                id: "Factory:checkpoint-steady-\(i)",
                indexedAt: mtime,
                fileModifiedAt: mtime
            )
        }
        let parser = StubParser(provider: .factory, conversations: conversations)
        let orchestrator = makeOrchestrator(store: store)

        // First call: no checkpoint → process all conversations and set a checkpoint.
        let firstResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: parser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertEqual(firstResult.changedConversationCount, 3)
        XCTAssertGreaterThanOrEqual(firstResult.indexedConversationChanges, 1)

        // Verify a checkpoint was written.
        let checkpoint = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNotNil(checkpoint)

        // Second call: SAME conversations (same fileModifiedAt) — checkpoint should filter them out.
        let secondResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: parser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertEqual(secondResult.changedConversationCount, 0)
        XCTAssertEqual(secondResult.indexedConversationChanges, 0)
    }

    // MARK: - 4. Changed file after checkpoint

    func test_runConversationIndexing_changedFileAfterCheckpoint_isIndexed() async throws {
        let store = try makeInMemoryStore()
        let oldMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let conversations: [ConversationRecord] = (0..<2).map { i in
            makeFactoryConversationRecord(
                id: "Factory:checkpoint-change-\(i)",
                indexedAt: oldMtime,
                fileModifiedAt: oldMtime
            )
        }
        let initialParser = StubParser(provider: .factory, conversations: conversations)
        let orchestrator = makeOrchestrator(store: store)

        // First call indexes all conversations and sets a checkpoint.
        let firstResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: initialParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertEqual(firstResult.changedConversationCount, 2)

        // Advance time past the checkpoint watermark.
        let checkpoint = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNotNil(checkpoint)
        let watermark = checkpoint!.lastProcessedAt

        // Second call: one conversation's fileModifiedAt is newer than the watermark.
        let newerMtime = watermark.addingTimeInterval(3600)
        let changedConversations: [ConversationRecord] = [
            makeFactoryConversationRecord(
                id: "Factory:checkpoint-change-0",
                indexedAt: oldMtime,
                fileModifiedAt: newerMtime
            ),
            makeFactoryConversationRecord(
                id: "Factory:checkpoint-change-1",
                indexedAt: oldMtime,
                fileModifiedAt: oldMtime // unchanged
            )
        ]
        let changedParser = StubParser(provider: .factory, conversations: changedConversations)

        let secondResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: changedParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertGreaterThanOrEqual(secondResult.changedConversationCount, 1)
        XCTAssertGreaterThanOrEqual(secondResult.indexedConversationChanges, 1)
    }

    // MARK: - 5. No-loss semantics: >200 changed conversations all processed in one tick

    func test_runConversationIndexing_processesFullSet_noLoss() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        // 250 conversations with fileModifiedAt: nil → all pass the watermark filter on first run.
        let conversations: [ConversationRecord] = (0..<250).map { i in
            makeFactoryConversationRecord(
                id: "Factory:cap-\(i)",
                indexedAt: mtime,
                fileModifiedAt: nil
            )
        }
        let parser = StubParser(provider: .factory, conversations: conversations)
        let orchestrator = makeOrchestrator(store: store)

        let result = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: parser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        // All 250 are "changed" (fileModifiedAt nil → always index).
        XCTAssertEqual(result.changedConversationCount, 250)
        // No per-tick cap — all 250 are indexed in one tick (no-loss semantics).
        XCTAssertEqual(result.indexedConversationChanges, 250)
    }

    // MARK: - 6. Error/atomicity: parser throws, checkpoint does not advance

    func test_runConversationIndexing_parserError_doesNotAdvanceCheckpoint() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let initialParser = StubParser(
            provider: .factory,
            conversations: [
                makeFactoryConversationRecord(
                    id: "Factory:parse-failure-watermark",
                    indexedAt: mtime,
                    fileModifiedAt: mtime
                )
            ]
        )
        let orchestrator = makeOrchestrator(store: store)

        let initialResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: initialParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertEqual(initialResult.indexedConversationChanges, 1)
        let checkpointBeforeFailureRecord = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        let checkpointBeforeFailure = try XCTUnwrap(checkpointBeforeFailureRecord)

        let result = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: FailingParser()],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        XCTAssertNotNil(result.errors[.factory])
        XCTAssertFalse(result.errors[.factory]!.isEmpty)
        let checkpointAfterFailureRecord = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        let checkpointAfterFailure = try XCTUnwrap(checkpointAfterFailureRecord)
        XCTAssertEqual(
            checkpointAfterFailure.lastProcessedAt,
            checkpointBeforeFailure.lastProcessedAt,
            "a parse failure must retry from the last successful watermark"
        )
        XCTAssertEqual(checkpointAfterFailure.checkpointToken, checkpointBeforeFailure.checkpointToken)
    }

    func test_runConversationIndexing_cancellationDoesNotAdvanceCheckpoint() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let orchestrator = makeOrchestrator(store: store)
        let initialParser = StubParser(
            provider: .factory,
            conversations: [
                makeFactoryConversationRecord(
                    id: "Factory:cancellation-watermark",
                    indexedAt: mtime,
                    fileModifiedAt: mtime
                )
            ]
        )
        _ = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: initialParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        let checkpointBeforeCancellation = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        let before = try XCTUnwrap(checkpointBeforeCancellation)

        let result = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: CancellingParser()],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        let checkpointAfterCancellation = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        let after = try XCTUnwrap(checkpointAfterCancellation)
        XCTAssertTrue(result.errors.isEmpty, "cooperative cancellation is not reported as a parser defect")
        XCTAssertEqual(after.lastProcessedAt, before.lastProcessedAt)
        XCTAssertEqual(after.checkpointToken, before.checkpointToken)
    }

    // MARK: - 7. Old-mtime new ID is indexed despite old fileModifiedAt

    func test_runConversationIndexing_oldMtimeNewID_isIndexed() async throws {
        let store = try makeInMemoryStore()
        let oldMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let initialConversations: [ConversationRecord] = (0..<2).map { i in
            makeFactoryConversationRecord(
                id: "Factory:old-mtime-\(i)",
                indexedAt: oldMtime,
                fileModifiedAt: oldMtime
            )
        }
        let initialParser = StubParser(provider: .factory, conversations: initialConversations)
        let orchestrator = makeOrchestrator(store: store)

        // First tick: index 2 conversations, checkpoint is set.
        let firstResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: initialParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertEqual(firstResult.changedConversationCount, 2)

        // Second tick: same 2 conversations (filtered by watermark) PLUS 1 new
        // conversation with an mtime OLDER than the checkpoint watermark.
        let checkpoint = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNotNil(checkpoint)
        let watermark = checkpoint!.lastProcessedAt
        let newOldMtime = watermark.addingTimeInterval(-100) // older than checkpoint
        var secondConversations = initialConversations
        secondConversations.append(makeFactoryConversationRecord(
            id: "Factory:old-mtime-new-id",
            indexedAt: oldMtime,
            fileModifiedAt: newOldMtime
        ))
        let secondParser = StubParser(provider: .factory, conversations: secondConversations)

        let secondResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: secondParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        XCTAssertEqual(secondResult.changedConversationCount, 1)
        XCTAssertEqual(secondResult.indexedConversationChanges, 1)

        let fetchedRecord = try await store.fetchConversation(id: "Factory:old-mtime-new-id")
        let fetched = try XCTUnwrap(fetchedRecord)
        XCTAssertEqual(fetched.sessionId, "test-session-Factory:old-mtime-new-id")
        XCTAssertEqual(fetched.inferredTaskTitle, "Hello")
        XCTAssertEqual(
            try XCTUnwrap(fetched.fileModifiedAt).timeIntervalSince1970,
            newOldMtime.timeIntervalSince1970,
            accuracy: 0.001
        )

    }
    func test_runConversationIndexing_deferredFileDoesNotAdvanceCheckpointAfterPartialSuccess() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let orchestrator = makeOrchestrator(store: store)
        let initialParser = StubParser(
            provider: .factory,
            conversations: [
                makeFactoryConversationRecord(
                    id: "Factory:defer-existing",
                    indexedAt: mtime,
                    fileModifiedAt: mtime
                )
            ]
        )

        let initialResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: initialParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertEqual(initialResult.indexedConversationChanges, 1)
        let checkpointBeforeDeferralRecord = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        let checkpointBeforeDeferral = try XCTUnwrap(checkpointBeforeDeferralRecord)

        let deferredConversation = makeFactoryConversationRecord(
            id: "Factory:defer-partial-success",
            indexedAt: mtime,
            fileModifiedAt: checkpointBeforeDeferral.lastProcessedAt.addingTimeInterval(60)
        )
        let deferredResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [
                .factory: DeferringParser(provider: .factory, conversations: [deferredConversation])
            ],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        XCTAssertEqual(deferredResult.changedConversationCount, 1)
        XCTAssertEqual(deferredResult.indexedConversationChanges, 1)
        let persistedDeferredConversation = try await store.fetchConversation(id: deferredConversation.id)
        XCTAssertNotNil(persistedDeferredConversation)
        let checkpointAfterDeferralRecord = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        let checkpointAfterDeferral = try XCTUnwrap(checkpointAfterDeferralRecord)
        XCTAssertEqual(
            checkpointAfterDeferral.lastProcessedAt,
            checkpointBeforeDeferral.lastProcessedAt,
            "partial indexing success must not hide a resource-deferred file behind a new watermark"
        )
        XCTAssertEqual(checkpointAfterDeferral.checkpointToken, checkpointBeforeDeferral.checkpointToken)
    }

    // MARK: - 8. Indexing failure does not advance checkpoint (retry on next tick)

    func test_runConversationIndexing_indexingFailure_doesNotAdvanceCheckpoint() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let conversations: [ConversationRecord] = (0..<2).map { i in
            makeFactoryConversationRecord(
                id: "Factory:fail-idx-\(i)",
                indexedAt: mtime,
                fileModifiedAt: mtime
            )
        }
        let initialParser = StubParser(provider: .factory, conversations: conversations)
        let orchestrator = makeOrchestrator(store: store)

        // First tick: index 2 conversations and set checkpoint.
        let firstResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: initialParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertEqual(firstResult.changedConversationCount, 2)

        let checkpointAfterFirst = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNotNil(checkpointAfterFirst)
        let watermarkAfterFirst = checkpointAfterFirst!.lastProcessedAt

        // Corrupt the store: drop the conversations table so indexing throws.
        try await store.actor.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE conversations")
        }

        // Second tick: conversations have nil fileModifiedAt (always changed),
        // but indexing will fail because the conversations table is gone.
        let failingConversations: [ConversationRecord] = (0..<2).map { i in
            makeFactoryConversationRecord(
                id: "Factory:fail-idx-\(i)",
                indexedAt: mtime,
                fileModifiedAt: nil // nil → always passes the watermark filter
            )
        }
        let failingParser = StubParser(provider: .factory, conversations: failingConversations)

        let secondResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: failingParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        // The error should be captured, not crash.
        XCTAssertNotNil(secondResult.errors[.factory])
        XCTAssertFalse(secondResult.errors[.factory]!.isEmpty)

        // The checkpoint should NOT have advanced — same watermark as after the first tick.
        let checkpointAfterSecond = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNotNil(checkpointAfterSecond)
        XCTAssertEqual(
            checkpointAfterSecond!.lastProcessedAt,
            watermarkAfterFirst,
            "Checkpoint must not advance after an indexing failure so the next tick retries."
        )
    }

    // MARK: - 9. Chunked batch fetch handles >SQLite parameter limit

    func test_conversationIndexer_chunkedBatchFetch_handlesMoreThanSQLiteLimit() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        // 1200 conversation records — exceeds SQLite's default 999 parameter limit.
        let records: [ConversationRecord] = (0..<1200).map { i in
            makeFactoryConversationRecord(
                id: "Factory:sqlite-limit-\(i)",
                indexedAt: mtime,
                fileModifiedAt: mtime
            )
        }

        // Must not crash; all 1200 should be indexed via chunked batch fetches.
        let report = try await ConversationIndexer.shared.index(records, in: store)
        XCTAssertEqual(report.changedRecordCount, 1200)
        XCTAssertEqual(report.skippedRecordCount, 0)
    }

    // MARK: - 10. Scan/write race: file modified between scan-start and checkpoint-advance is seen next tick

    func test_runConversationIndexing_scanWriteRace_doesNotSkip() async throws {
        let store = try makeInMemoryStore()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = makeFactoryConversationRecord(
            id: "Factory:race-0",
            indexedAt: mtime,
            fileModifiedAt: mtime
        )
        let initialParser = StubParser(provider: .factory, conversations: [conversation])
        let orchestrator = makeOrchestrator(store: store)

        // First tick: index 1 conversation. Checkpoint advances to scan-start S0.
        let firstResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: initialParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )
        XCTAssertEqual(firstResult.changedConversationCount, 1)

        let checkpoint = try await store.actor.checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNotNil(checkpoint)
        let watermark = checkpoint!.lastProcessedAt

        // Second tick: the same conversation now has fileModifiedAt just barely
        // AFTER the first tick's scan-start watermark (simulating a file written
        // between scan-start and checkpoint-advance). Since the checkpoint
        // advanced to scan-start (not post-processing), this mtime > watermark
        // and must pass the filter.
        let racedMtime = watermark.addingTimeInterval(0.001)
        let racedConversation = makeFactoryConversationRecord(
            id: "Factory:race-0",
            indexedAt: mtime,
            fileModifiedAt: racedMtime
        )
        let racedParser = StubParser(provider: .factory, conversations: [racedConversation])

        let secondResult = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: racedParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        // The raced file must be seen and indexed (finding 5).
        XCTAssertGreaterThanOrEqual(secondResult.changedConversationCount, 1)
        XCTAssertGreaterThanOrEqual(secondResult.indexedConversationChanges, 1)
    }

    // MARK: - Helpers

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeFactoryConversationRecord(
        id: String,
        indexedAt: Date,
        fileModifiedAt: Date?
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .factory,
            sessionId: "test-session-\(id)",
            projectName: "Demo",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_000),
            messageCount: 2,
            userWordCount: 3,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Hello",
            lastAssistantMessage: "Done",
            fullText: "Hello\n\nDone",
            indexedAt: indexedAt,
            fileModifiedAt: fileModifiedAt,
            summary: nil
        )
    }

    private func makeOrchestrator(store: DataStore) -> RefreshOrchestrator {
        RefreshOrchestrator(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            quotaService: ProviderQuotaService(
                appPaths: OpenBurnBar.OpenBurnBarAppPaths(
                    applicationSupportRoot: FileManager.default.temporaryDirectory
                ),
                homeDirectoryURL: FileManager.default.temporaryDirectory,
                refreshProviders: []
            )
        )
    }
}

// MARK: - Mock Parsers

private struct StubParser: LogParser {
    let provider: AgentProvider
    let conversations: [ConversationRecord]

    func parse(options: LogParseOptions) async throws -> ParseResult {
        ParseResult(usages: [], conversations: conversations)
    }
}

private struct FailingParser: LogParser {
    let provider: AgentProvider = .factory

    func parse(options: LogParseOptions) async throws -> ParseResult {
        throw OpenBurnBarError.parse("test", message: "simulated parser failure")
    }
}

private struct CancellingParser: LogParser {
    let provider: AgentProvider = .factory

    func parse(options: LogParseOptions) async throws -> ParseResult {
        throw CancellationError()
    }
}

private struct DeferringParser: LogParser {
    let provider: AgentProvider
    let conversations: [ConversationRecord]

    func parse(options: LogParseOptions) async throws -> ParseResult {
        options.resourceGovernor?.recordDeferredFile()
        return ParseResult(usages: [], conversations: conversations)
    }
}
