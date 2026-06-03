import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ConversationStore FTS

extension ConversationStore {
        // MARK: - Full-text Search

        func searchConversationsFTS(
            query: String,
            provider: AgentProvider? = nil,
            projectName: String? = nil,
            dateRange: ClosedRange<Date>? = nil
        ) throws -> [SearchResult] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            let ftsQuery = BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)
            guard !ftsQuery.isEmpty else { return [] }

            return try dbQueue.read { db -> [SearchResult] in
                var sql = """
                SELECT c.*, bm25(conversations_fts) AS rank,
                snippet(conversations_fts, 1, '<b>', '</b>', '…', 10) AS snip
                FROM conversations_fts
                JOIN conversations AS c ON c.rowid = conversations_fts.rowid
                WHERE conversations_fts MATCH ? AND c.deletedAt IS NULL
                """
                var args: [any DatabaseValueConvertible] = [ftsQuery]

                if let provider {
                    sql += " AND c.provider = ?"
                    args.append(provider.rawValue)
                }
                if let projectName {
                    sql += " AND c.projectName = ?"
                    args.append(projectName)
                }
                if let range = dateRange {
                    sql += " AND c.startTime >= ? AND c.startTime <= ?"
                    args.append(range.lowerBound)
                    args.append(range.upperBound)
                }

                sql += " ORDER BY rank ASC LIMIT 50"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var results = rows.compactMap { row -> SearchResult? in
                    guard let conv = Self.conversation(from: row) else { return nil }
                    let rank = (row["rank"] as? Double) ?? Double(row["rank"] as? Int64 ?? 0)
                    let snip = (row["snip"] as? String) ?? ""
                    return SearchResult(conversation: conv, snippet: snip, rank: rank)
                }

                if results.count < 50 {
                    var fallbackSQL = """
                    SELECT c.*
                    FROM conversations AS c
                    WHERE c.deletedAt IS NULL AND (
                        LOWER(COALESCE(c.summaryTitle, '')) LIKE ?
                        OR LOWER(COALESCE(c.summary, '')) LIKE ?
                    )
                    """
                    var fallbackArgs: [any DatabaseValueConvertible] = [
                        "%\(trimmed.lowercased())%",
                        "%\(trimmed.lowercased())%"
                    ]

                    if let provider {
                        fallbackSQL += " AND c.provider = ?"
                        fallbackArgs.append(provider.rawValue)
                    }
                    if let projectName {
                        fallbackSQL += " AND c.projectName = ?"
                        fallbackArgs.append(projectName)
                    }
                    if let range = dateRange {
                        fallbackSQL += " AND c.startTime >= ? AND c.startTime <= ?"
                        fallbackArgs.append(range.lowerBound)
                        fallbackArgs.append(range.upperBound)
                    }

                    fallbackSQL += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT 50"
                    let fallbackRows = try Row.fetchAll(db, sql: fallbackSQL, arguments: StatementArguments(fallbackArgs))
                    var seen = Set(results.map { $0.conversation.id })
                    for row in fallbackRows {
                        guard let conv = Self.conversation(from: row), !seen.contains(conv.id) else { continue }
                        seen.insert(conv.id)
                        let fallbackSnippet = conv.summary ?? conv.summaryTitle ?? conv.inferredTaskTitle
                        results.append(
                            SearchResult(
                                conversation: conv,
                                snippet: fallbackSnippet,
                                rank: (results.last?.rank ?? 0) + 100
                            )
                        )
                        if results.count >= 50 { break }
                    }
                }

                return results
            }
        }
}
