import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    // MARK: - Session Facets Lookup

    /// Aggregates token + cost + timing facets per `(provider:rootSession)` so the encrypted
    /// session-log backup can attach plaintext cockpit facets to each manifest without ever
    /// touching the conversation body. Mirrors `sessionModelMap()` keying so the two maps align.
    func sessionFacetsMap() async throws -> [String: SessionUsageFacets] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT provider, sessionId, model,
                    SUM(inputTokens) AS input,
                    SUM(outputTokens) AS output,
                    SUM(cacheCreationTokens) AS cacheCreation,
                    SUM(cacheReadTokens) AS cacheRead,
                    SUM(totalTokens) AS total,
                    SUM(cost) AS cost,
                    MIN(startTime) AS startTime,
                    MAX(endTime) AS endTime
                FROM token_usage
                GROUP BY provider, sessionId
                """)
            var result: [String: SessionUsageFacets] = [:]
            for row in rows {
                guard let provider = row["provider"] as? String,
                      let sessionId = row["sessionId"] as? String else { continue }
                let rootSession: String
                if let slashIdx = sessionId.firstIndex(of: "/") {
                    rootSession = String(sessionId[..<slashIdx])
                } else {
                    rootSession = sessionId
                }
                let key = "\(provider):\(rootSession)"
                let facets = SessionUsageFacets(
                    model: row["model"] as? String ?? "unknown",
                    inputTokens: Self.intColumn(row, "input"),
                    outputTokens: Self.intColumn(row, "output"),
                    cacheCreationTokens: Self.intColumn(row, "cacheCreation"),
                    cacheReadTokens: Self.intColumn(row, "cacheRead"),
                    totalTokens: Self.intColumn(row, "total"),
                    costUSD: row["cost"] ?? 0,
                    // A row subscript hands back SQLite storage (TEXT or a
                    // number), never a Date, so an `as? Date` cast always
                    // dropped both timestamps.
                    startTime: OpenBurnBarDatabase.parseDateValue(row["startTime"]),
                    endTime: OpenBurnBarDatabase.parseDateValue(row["endTime"])
                )
                if let existing = result[key] {
                    result[key] = existing.merging(facets)
                } else {
                    result[key] = facets
                }
            }
            return result
        }
    }

    private static func intColumn(_ row: Row, _ name: String) -> Int {
        if let value: Int = row[name] { return value }
        if let value: Int64 = row[name] { return Int(value) }
        if let value: Double = row[name] { return Int(value.rounded()) }
        return 0
    }

    // MARK: - Session Model Lookup

    func sessionModelMap() async throws -> [String: String] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT provider, sessionId, model, SUM(cost) AS totalCost
                FROM token_usage
                GROUP BY provider, sessionId, model
                ORDER BY provider, sessionId, totalCost DESC
                """)
            var result: [String: String] = [:]
            for row in rows {
                guard let provider = row["provider"] as? String,
                      let sessionId = row["sessionId"] as? String,
                      let model = row["model"] as? String else { continue }
                let rootSession: String
                if let slashIdx = sessionId.firstIndex(of: "/") {
                    rootSession = String(sessionId[..<slashIdx])
                } else {
                    rootSession = sessionId
                }
                let key = "\(provider):\(rootSession)"
                if result[key] == nil {
                    result[key] = model
                }
            }
            return result
        }
    }
}
