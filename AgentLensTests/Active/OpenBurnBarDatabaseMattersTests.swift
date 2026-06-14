import XCTest
import GRDB
@testable import OpenBurnBar

/// Regression coverage for the previously-silent `try?` error-swallows in
/// `OpenBurnBarDatabase.swift` and `WorkingDirectoryBackfillService`.
///
/// These sites used to mask failures behind permissive fallbacks
/// (`?? "[]"`, `?? false`, `?? []`, and a bare `try?` write). Each is now
/// either throwing (so the caller fails closed instead of persisting a lossy
/// empty value) or wrapped in `do/catch` that logs and stops the run rather
/// than treating an error as "no work to do".
@MainActor
final class OpenBurnBarDatabaseMattersTests: XCTestCase {

    // MARK: - encodeJSONStringArray (L1767 fix: throwing, no silent "[]")

    func test_encodeJSONStringArray_encodesNonEmptyArray_neverSilentlyEmpty() throws {
        let json = try OpenBurnBarDatabase.encodeJSONStringArray(["/a/b.swift", "/c/d.swift"])
        // A non-empty input must never collapse to "[]" — that was the data-loss
        // bug the silent `try?` permitted on encode failure.
        XCTAssertNotEqual(json, "[]")
        let decoded = OpenBurnBarDatabase.decodeJSONStringArray(json)
        XCTAssertEqual(decoded, ["/a/b.swift", "/c/d.swift"])
    }

    func test_encodeJSONStringArray_emptyInputStillEncodesEmptyArray() throws {
        // A genuinely empty array still produces "[]" — the distinction we keep
        // is "empty input -> []" vs "encode failure -> [] (silent loss)".
        let json = try OpenBurnBarDatabase.encodeJSONStringArray([])
        XCTAssertEqual(json, "[]")
    }

    func test_encodeJSONStringArray_isThrowing_andRoundTripsThroughInsertRemote() throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()

        let store = ConversationStore(dbQueue: queue)
        let keyFiles = ["/Users/test/proj/Sources/App.swift", "/Users/test/proj/README.md"]
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "encode-roundtrip"),
            provider: .codex,
            sessionId: "encode-roundtrip",
            projectName: "Project",
            startTime: Date(timeIntervalSince1970: 10),
            endTime: Date(timeIntervalSince1970: 20),
            messageCount: 1,
            userWordCount: 1,
            assistantWordCount: 1,
            keyFiles: keyFiles,
            keyCommands: ["swift build"],
            keyTools: ["xcodebuild"],
            inferredTaskTitle: "Encode round-trip",
            lastAssistantMessage: "ok",
            fullText: "u\n\na",
            indexedAt: Date(timeIntervalSince1970: 30),
            workingDirectory: nil,
            fileModifiedAt: Date(timeIntervalSince1970: 40),
            sourceDeviceId: "device-A",
            sourceDeviceName: "Mac",
            isRemote: true
        )

        // The throwing encoder is wired into the remote-insert write path.
        try store.insertRemoteConversation(record)

        let storedKeyFiles = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT keyFiles FROM conversations WHERE id = ?",
                arguments: [record.id]
            )
        }
        let decoded = OpenBurnBarDatabase.decodeJSONStringArray(storedKeyFiles)
        // The real array is persisted intact — not silently overwritten with "[]".
        XCTAssertEqual(decoded, keyFiles)
        XCTAssertNotEqual(storedKeyFiles, "[]")
    }

    // MARK: - Backfill happy path (probe read + batch read + write all succeed)

    func test_backfill_populatesWorkingDirectory_whenWritesSucceed() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()

        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "backfill-ok"),
            provider: .codex,
            sessionId: "backfill-ok",
            projectName: "Project",
            startTime: Date(timeIntervalSince1970: 10),
            endTime: Date(timeIntervalSince1970: 20),
            messageCount: 1,
            userWordCount: 1,
            assistantWordCount: 1,
            keyFiles: ["/Users/test/project/Sources/App.swift"],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Backfill",
            lastAssistantMessage: "Done",
            fullText: "u\n\na",
            indexedAt: Date(timeIntervalSince1970: 30),
            workingDirectory: nil,
            fileModifiedAt: Date(timeIntervalSince1970: 40)
        )
        try ConversationStore(dbQueue: queue).upsertConversation(record)

        await WorkingDirectoryBackfillService(batchSize: 1).runIfNeeded(database: database)

        let workingDirectory = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT workingDirectory FROM conversations WHERE id = ?",
                arguments: [record.id]
            )
        }
        XCTAssertEqual(workingDirectory, "/Users/test/project/Sources")
    }

    // MARK: - Backfill write failure (L1850 fix: catch + log + stop, no spin, no crash)

    func test_backfill_writeFailure_doesNotHangAndLeavesRowUnwritten() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("backfill-readonly.sqlite").path

        // 1. Seed + migrate read-write, leaving a backfillable row (NULL workingDirectory).
        let recordId = ConversationRecord.stableId(provider: .codex, sessionId: "backfill-ro")
        do {
            let rwQueue = try DatabaseQueue(path: dbPath)
            let rwDatabase = OpenBurnBarDatabase(databaseQueue: rwQueue)
            try rwDatabase.runMigrationsSafely()
            let record = ConversationRecord(
                id: recordId,
                provider: .codex,
                sessionId: "backfill-ro",
                projectName: "Project",
                startTime: Date(timeIntervalSince1970: 10),
                endTime: Date(timeIntervalSince1970: 20),
                messageCount: 1,
                userWordCount: 1,
                assistantWordCount: 1,
                keyFiles: ["/Users/test/project/Sources/App.swift"],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Backfill RO",
                lastAssistantMessage: "Done",
                fullText: "u\n\na",
                indexedAt: Date(timeIntervalSince1970: 30),
                workingDirectory: nil,
                fileModifiedAt: Date(timeIntervalSince1970: 40)
            )
            try ConversationStore(dbQueue: rwQueue).upsertConversation(record)
        }

        // 2. Reopen read-only: the column probe read and batch read both succeed,
        //    but the UPDATE write fails. The fixed `do/catch` must log and return
        //    instead of swallowing the error and spinning the loop forever.
        var config = Configuration()
        config.readonly = true
        let roQueue = try DatabaseQueue(path: dbPath, configuration: config)
        let roDatabase = OpenBurnBarDatabase(databaseQueue: roQueue)

        // Bound the run: a regression (infinite loop on swallowed write error)
        // would never return, tripping this expectation timeout.
        let finished = expectation(description: "runIfNeeded returns after a write failure")
        Task {
            await WorkingDirectoryBackfillService(batchSize: 1).runIfNeeded(database: roDatabase)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5.0)

        // The write never landed (read-only), so workingDirectory stays NULL —
        // proving the failure was caught and surfaced, not silently "completed".
        let workingDirectory = try await roQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT workingDirectory FROM conversations WHERE id = ?",
                arguments: [recordId]
            )
        }
        XCTAssertNil(workingDirectory)
    }

    // MARK: - Backfill column-probe behavior (L1804 fix: success-false still skips cleanly)

    func test_backfill_skipsWhenColumnAbsent_withoutThrowing() async throws {
        // A schema without the conversations table at all: the PRAGMA probe
        // succeeds and returns false (no `workingDirectory` column), so the
        // service must skip cleanly rather than crashing or looping.
        let queue = try DatabaseQueue()
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE unrelated (id INTEGER PRIMARY KEY)")
        }
        let database = OpenBurnBarDatabase(databaseQueue: queue)

        await WorkingDirectoryBackfillService(batchSize: 1).runIfNeeded(database: database)
        // Reaching here without hanging or trapping is the assertion: the
        // "successful query returning false" path is treated as a clean skip.
    }
}
