import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import SQLite3
import XCTest

private let burnBarResumeServiceTestsSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class BurnBarResumeServiceTests: XCTestCase {
    func testBareSessionLookupDoesNotPreferExactConversationIDOverAmbiguity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-resume-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("openburnbar.sqlite")
        try Self.withDatabase(at: databaseURL) { db in
            try Self.exec("""
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                sessionId TEXT NOT NULL,
                projectName TEXT NOT NULL,
                startTime TEXT,
                endTime TEXT,
                messageCount INTEGER NOT NULL DEFAULT 0,
                userWordCount INTEGER NOT NULL DEFAULT 0,
                assistantWordCount INTEGER NOT NULL DEFAULT 0,
                keyFiles TEXT,
                keyCommands TEXT,
                keyTools TEXT,
                inferredTaskTitle TEXT NOT NULL DEFAULT '',
                lastAssistantMessage TEXT NOT NULL DEFAULT '',
                fullText TEXT NOT NULL DEFAULT '',
                indexedAt TEXT NOT NULL,
                fileModifiedAt TEXT,
                summary TEXT,
                conversationSyncedAt TEXT,
                sourceType TEXT NOT NULL DEFAULT 'provider_log',
                logSyncedAt TEXT,
                summaryTitle TEXT,
                summaryUpdatedAt TEXT,
                summaryProvider TEXT,
                summaryModel TEXT,
                summaryAttemptedAt TEXT,
                sourceDeviceId TEXT,
                sourceDeviceName TEXT,
                isRemote INTEGER NOT NULL DEFAULT 0,
                workingDirectory TEXT
            );
            """, db: db)
            try Self.insertConversation(id: "same", provider: "Codex", sessionID: "owner", db: db)
            try Self.insertConversation(id: "Codex:same", provider: "Codex", sessionID: "same", db: db)
            try Self.insertConversation(id: "Claude Code:same", provider: "Claude Code", sessionID: "same", db: db)
        }

        let service = try BurnBarResumeService(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "resume-service-test")
        )
        let response = try service.runResume(BurnBarRunResumeRequest(sessionID: "same", mode: .print))

        XCTAssertEqual(response.kind, "error")
        XCTAssertEqual(response.errorCode, "ambiguous_session")
    }

    private static func withDatabase(at url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        guard let db else {
            throw NSError(domain: "BurnBarResumeServiceTests", code: 1)
        }
        defer { sqlite3_close(db) }
        try body(db)
    }

    private static func insertConversation(id: String, provider: String, sessionID: String, db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO conversations (
            id, provider, sessionId, projectName, startTime, endTime, keyFiles,
            keyCommands, keyTools, inferredTaskTitle, lastAssistantMessage,
            fullText, indexedAt, summary, summaryTitle, summaryModel,
            sourceDeviceId, sourceDeviceName, isRemote, workingDirectory
        ) VALUES (?, ?, ?, 'FixtureApp', '2026-05-01 10:00:00.000',
            '2026-05-01 11:00:00.000', '[]', '[]', '[]', 'Fixture',
            'Next, add a test.', 'User asked.\n\nAssistant answered.',
            '2026-05-01 11:01:00.000', 'Summary', 'Fixture', 'fixture-model',
            'mac-fixture', 'Mac Fixture', 0, '/tmp/fixture')
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, burnBarResumeServiceTestsSQLiteTransient)
        sqlite3_bind_text(stmt, 2, provider, -1, burnBarResumeServiceTestsSQLiteTransient)
        sqlite3_bind_text(stmt, 3, sessionID, -1, burnBarResumeServiceTestsSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db)
        }
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            if let error { sqlite3_free(error) }
            throw NSError(domain: "BurnBarResumeServiceTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func sqliteError(_ db: OpaquePointer) -> NSError {
        NSError(
            domain: "BurnBarResumeServiceTests",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
}
