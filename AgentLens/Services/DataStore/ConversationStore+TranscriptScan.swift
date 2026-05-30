import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ConversationStore Transcript Scan

extension ConversationStore {
        // MARK: - Transcript Scan Helpers

        func fetchConversationsForTranscriptScan(
            provider: AgentProvider?,
            projectName: String?,
            dateRange: ClosedRange<Date>?,
            conversationSources: Set<ConversationSourceType>?,
            limit: Int = 500
        ) throws -> [ConversationRecord] {
            try dbQueue.read { db -> [ConversationRecord] in
                var sql = """
                SELECT *
                FROM conversations AS c
                WHERE 1 = 1
                """
                var args: [any DatabaseValueConvertible] = []
                if let provider {
                    sql += " AND c.provider = ?"
                    args.append(provider.rawValue)
                }
                if let projectName {
                    sql += " AND c.projectName = ?"
                    args.append(projectName)
                }
                if let range = dateRange {
                    sql += """
                     AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
                     AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
                    """
                    args.append(range.lowerBound)
                    args.append(range.upperBound)
                }
                if let sources = conversationSources, sources.isEmpty == false {
                    let rawVals = sources.map(\.rawValue)
                    let placeholders = Array(repeating: "?", count: rawVals.count).joined(separator: ", ")
                    sql += " AND c.sourceType IN (\(placeholders))"
                    args.append(contentsOf: rawVals)
                }
                sql += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT ?"
                args.append(limit)

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return rows.compactMap(Self.conversation(from:))
            }
        }

        /// Lightweight batched fetch for transcript scanning.
        /// Returns only `id` and `fullText` to bound transient heap usage.
        func fetchTranscriptScanBatch(
            provider: AgentProvider?,
            projectName: String?,
            dateRange: ClosedRange<Date>?,
            conversationSources: Set<ConversationSourceType>?,
            limit: Int,
            offset: Int
        ) throws -> [(id: String, fullText: String)] {
            try dbQueue.read { db -> [(id: String, fullText: String)] in
                var sql = """
                SELECT c.id, c.fullText
                FROM conversations AS c
                WHERE 1 = 1
                """
                var args: [any DatabaseValueConvertible] = []
                if let provider {
                    sql += " AND c.provider = ?"
                    args.append(provider.rawValue)
                }
                if let projectName {
                    sql += " AND c.projectName = ?"
                    args.append(projectName)
                }
                if let range = dateRange {
                    sql += """
                     AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
                     AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
                    """
                    args.append(range.lowerBound)
                    args.append(range.upperBound)
                }
                if let sources = conversationSources, sources.isEmpty == false {
                    let rawVals = sources.map(\.rawValue)
                    let placeholders = Array(repeating: "?", count: rawVals.count).joined(separator: ", ")
                    sql += " AND c.sourceType IN (\(placeholders))"
                    args.append(contentsOf: rawVals)
                }
                sql += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT ? OFFSET ?"
                args.append(limit)
                args.append(offset)

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return rows.compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    let fullText = (row["fullText"] as? String) ?? ""
                    return (id: id, fullText: fullText)
                }
            }
        }
}
