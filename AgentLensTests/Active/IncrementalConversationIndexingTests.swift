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
        let checkpoint = try await store.checkpointStore.fetchCheckpoint(for: .factory)
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
        let checkpoint = try await store.checkpointStore.fetchCheckpoint(for: .factory)
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
            ),
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

    // MARK: - 5. Per-tick cap: >200 changed conversations deferred

    func test_runConversationIndexing_capsAt200_andDefersExcess() async throws {
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
        // 50 should be deferred past the per-tick cap of 200.
        XCTAssertEqual(result.deferredConversationCount, 50)
        // Exactly 200 should have been indexed.
        XCTAssertEqual(result.indexedConversationChanges, 200)
    }

    // MARK: - 6. Error/atomicity: parser throws, checkpoint does not advance

    func test_runConversationIndexing_parserError_doesNotAdvanceCheckpoint() async throws {
        let store = try makeInMemoryStore()
        let failingParser = FailingParser()
        let orchestrator = makeOrchestrator(store: store)

        // Verify no checkpoint exists before the call.
        let beforeCheckpoint = try await store.checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNil(beforeCheckpoint)

        let result = await RefreshBackgroundWork.runConversationIndexing(
            parsers: [.factory: failingParser],
            dataStore: store,
            orchestrator: orchestrator,
            indexingEnabled: true
        )

        // The error should be captured, not crash.
        XCTAssertNotNil(result.errors[.factory])
        XCTAssertFalse(result.errors[.factory]!.isEmpty)

        // The checkpoint should NOT have advanced (no checkpoint row written).
        let afterCheckpoint = try await store.checkpointStore.fetchCheckpoint(for: .factory)
        XCTAssertNil(afterCheckpoint)
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

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: conversations)
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        ParseResult(usages: [], conversations: conversations)
    }
}

private struct FailingParser: LogParser {
    let provider: AgentProvider = .factory

    func parse() async throws -> ParseResult {
        throw OpenBurnBarError.parse("test", message: "simulated parser failure")
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        throw OpenBurnBarError.parse("test", message: "simulated parser failure")
    }
}