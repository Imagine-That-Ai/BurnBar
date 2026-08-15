import Foundation
import OpenBurnBarLogParsers
import OpenBurnBarSQLiteReader
import XCTest

/// EXPLAIN QUERY PLAN on a real on-disk SQLite file. These statements match
/// the production unsynced / OpenCode JSON-extract shapes. No GRDB migration
/// is added; the existing `token_usage_sync_pending_idx` must remain the
/// unsynced plan, and JSON-only `part` must carry a `json_extract` WHERE.
final class TokenUsageExplainQueryPlanTests: XCTestCase {
    func test_unsyncedQueryUsesSyncPendingIndex() throws {
        let db = try makeUsageDatabase()
        defer { db.close() }
        try db.execute("ANALYZE")
        let plan = try explain(
            db,
            sql: """
                SELECT id, startTime FROM token_usage
                WHERE syncedAt IS NULL AND isRemote = 0
                ORDER BY startTime ASC LIMIT 400
                """
        )
        XCTAssertTrue(
            plan.localizedCaseInsensitiveContains("token_usage_sync_pending_idx"),
            "got:\n\(plan)"
        )
    }

    func test_openCodeJSONExtractPartQueryIsBounded() throws {
        let db = try SQLiteConnection.openForWriting(creatingAt: makeTempDBPath("opencode-eqp"))
        defer { db.close() }
        try db.execute("CREATE TABLE part (data TEXT)")
        for index in 0..<40 {
            try db.execute(
                "INSERT INTO part VALUES (?)",
                arguments: [.text("{\"messageID\":\"m-\(index)\",\"type\":\"text\",\"text\":\"x\"}")]
            )
        }
        try db.execute("ANALYZE")
        let clause = try XCTUnwrap(
            OpenCodePartQuery.jsonExtractWhereSQL(payloadColumn: "data", placeholderCount: 2)
        )
        let plan = try explain(
            db,
            sql: "SELECT data FROM part WHERE \(clause)",
            arguments: [.text("m-1"), .text("m-2")]
        )
        XCTAssertTrue(plan.localizedCaseInsensitiveContains("part"), plan)
        XCTAssertFalse(
            plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            plan
        )
        let rows = try db.query(
            "SELECT data FROM part WHERE \(clause)",
            arguments: [.text("m-1"), .text("m-2")]
        )
        XCTAssertEqual(rows.count, 2)
    }

    func test_chartIntersectionHasNoCoveringIndexOnThisSchema() throws {
        let db = try makeUsageDatabase()
        defer { db.close() }
        try db.execute("ANALYZE")
        let plan = try explain(
            db,
            sql: """
                SELECT startTime, endTime, cost FROM token_usage
                WHERE ((startTime <= ? AND endTime >= ?) OR (endTime <= ? AND startTime >= ?))
                ORDER BY startTime DESC
                """,
            arguments: [
                .text("2026-08-14 12:00:00.000"),
                .text("2026-08-01 00:00:00.000"),
                .text("2026-08-14 12:00:00.000"),
                .text("2026-08-01 00:00:00.000")
            ]
        )
        XCTAssertTrue(plan.localizedCaseInsensitiveContains("token_usage"), plan)
        XCTAssertFalse(plan.localizedCaseInsensitiveContains("token_usage_chart_fact_covering"), plan)
    }

    private func makeUsageDatabase() throws -> SQLiteConnection {
        let db = try SQLiteConnection.openForWriting(creatingAt: makeTempDBPath("usage-eqp"))
        try db.execute("""
            CREATE TABLE token_usage (
                id TEXT PRIMARY KEY,
                startTime TEXT NOT NULL,
                endTime TEXT NOT NULL,
                cost REAL NOT NULL,
                syncedAt TEXT,
                isRemote INTEGER NOT NULL DEFAULT 0
            )
            """)
        try db.execute(
            "CREATE INDEX token_usage_sync_pending_idx ON token_usage(syncedAt, isRemote, startTime)"
        )
        try db.execute(
            "CREATE INDEX token_usage_provider_time_idx ON token_usage(startTime)"
        )
        for index in 0..<400 {
            try db.execute(
                "INSERT INTO token_usage (id, startTime, endTime, cost, syncedAt, isRemote) VALUES (?, ?, ?, ?, NULL, 0)",
                arguments: [
                    .text("row-\(index)"),
                    .text("2026-08-01 00:00:00.00\(index % 10)"),
                    .text("2026-08-01 01:00:00.00\(index % 10)"),
                    .double(1)
                ]
            )
        }
        return db
    }

    private func explain(
        _ db: SQLiteConnection,
        sql: String,
        arguments: [SQLiteArgument] = []
    ) throws -> String {
        let rows = try db.query("EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
        return rows.map { row in
            if let detail = row.string("detail") ?? row.string("DETAIL"), !detail.isEmpty {
                return detail
            }
            return row.allTextValues().joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private func makeTempDBPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(label)-\(UUID().uuidString).sqlite")
            .path
    }
}
