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
            conversationSources: Set<OpenBurnBarCore.ConversationSourceType>?,
            limit: Int = 500
        ) async throws -> [OpenBurnBarCore.ConversationRecord] {
            try await dbQueue.read { db -> [OpenBurnBarCore.ConversationRecord] in
                var sql = """
                SELECT *
                FROM conversations AS c
                WHERE c.deletedAt IS NULL
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
            conversationSources: Set<OpenBurnBarCore.ConversationSourceType>?,
            limit: Int,
            offset: Int
        ) async throws -> [(id: String, fullText: String)] {
            try await dbQueue.read { db -> [(id: String, fullText: String)] in
                var sql = """
                SELECT c.id, c.fullText
                FROM conversations AS c
                WHERE c.deletedAt IS NULL
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

        func countOccurrencesInConversationFullText(
            patterns: [String],
            provider: AgentProvider?,
            projectName: String?,
            dateRange: ClosedRange<Date>?,
            conversationSources: Set<OpenBurnBarCore.ConversationSourceType>?
        ) async throws -> Int {
            let cleaned = patterns
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            guard cleaned.isEmpty == false else { return 0 }

            return try await dbQueue.read { db -> Int in
                var occurrenceSelects: [String] = []
                var args: [any DatabaseValueConvertible] = []
                for pattern in cleaned {
                    var branchArgs: [any DatabaseValueConvertible] = [pattern, pattern]
                    let filterSQL = Self.fullTextFilterSQL(
                        provider: provider,
                        projectName: projectName,
                        dateRange: dateRange,
                        conversationSources: conversationSources,
                        args: &branchArgs
                    )
                    occurrenceSelects.append(
                        """
                        SELECT COALESCE(SUM(
                            (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ''))) / LENGTH(?)
                        ), 0) AS count
                        FROM conversations AS c
                        WHERE c.deletedAt IS NULL
                        \(filterSQL)
                        """
                    )
                    args.append(contentsOf: branchArgs)
                }

                let sql = "SELECT COALESCE(SUM(count), 0) FROM (\(occurrenceSelects.joined(separator: " UNION ALL ")))"
                let value = try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
                return Int(value)
            }
        }

        func fetchConversationsMatchingFullTextPatterns(
            patterns: [String],
            provider: AgentProvider?,
            projectName: String?,
            dateRange: ClosedRange<Date>?,
            conversationSources: Set<OpenBurnBarCore.ConversationSourceType>?,
            limit: Int
        ) async throws -> [OpenBurnBarCore.ConversationRecord] {
            let cleaned = Array(
                Set(
                    patterns
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty }
                )
            )
            .sorted()
            let boundedLimit = max(1, min(limit, 600))
            guard cleaned.isEmpty == false else { return [] }

            return try await dbQueue.read { db -> [OpenBurnBarCore.ConversationRecord] in
                var instrConditions: [String] = []
                var args: [any DatabaseValueConvertible] = []
                for pattern in cleaned {
                    instrConditions.append("INSTR(LOWER(COALESCE(c.fullText,'')), ?) > 0")
                    args.append(pattern)
                }

                var sql = """
                SELECT *
                FROM conversations AS c
                WHERE c.deletedAt IS NULL AND (\(instrConditions.joined(separator: " OR ")))
                """
                sql += Self.fullTextFilterSQL(
                    provider: provider,
                    projectName: projectName,
                    dateRange: dateRange,
                    conversationSources: conversationSources,
                    args: &args
                )
                sql += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT ?"
                args.append(boundedLimit)

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return rows.compactMap(Self.conversation(from:))
            }
        }

        func countOccurrencesInConversationFullTextByProvider(
            patterns: [String],
            projectName: String?,
            dateRange: ClosedRange<Date>?,
            conversationSources: Set<OpenBurnBarCore.ConversationSourceType>?
        ) async throws -> [ConversationProviderOccurrence] {
            let cleaned = Array(
                Set(
                    patterns
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty }
                )
            )
            .sorted()
            guard cleaned.isEmpty == false else { return [] }

            return try await dbQueue.read { db -> [ConversationProviderOccurrence] in
                var occurrenceExprs: [String] = []
                var instrConditions: [String] = []
                var args: [any DatabaseValueConvertible] = []

                for pattern in cleaned {
                    occurrenceExprs.append(
                        """
                        (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ''))) / LENGTH(?)
                        """
                    )
                    instrConditions.append("INSTR(LOWER(COALESCE(c.fullText,'')), ?) > 0")
                    args.append(pattern)
                    args.append(pattern)
                    args.append(pattern)
                }

                var sql = """
                SELECT c.provider,
                    COALESCE(SUM(\(occurrenceExprs.joined(separator: " + "))), 0) AS occurrenceCount,
                    COUNT(DISTINCT c.id) AS conversationCount
                FROM conversations AS c
                WHERE c.deletedAt IS NULL AND (\(instrConditions.joined(separator: " OR ")))
                """
                sql += Self.fullTextFilterSQL(
                    provider: nil,
                    projectName: projectName,
                    dateRange: dateRange,
                    conversationSources: conversationSources,
                    args: &args
                )
                sql += " GROUP BY c.provider HAVING occurrenceCount > 0"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return rows.compactMap { row in
                    guard let providerRaw = row["provider"] as? String,
                          let provider = AgentProvider(rawValue: providerRaw) else { return nil }
                    let occurrenceCount = Int((row["occurrenceCount"] as? Int64) ?? 0)
                    let conversationCount = Int((row["conversationCount"] as? Int64) ?? 0)
                    return ConversationProviderOccurrence(
                        provider: provider,
                        occurrenceCount: occurrenceCount,
                        conversationCount: conversationCount
                    )
                }
                .sorted {
                    if $0.occurrenceCount != $1.occurrenceCount {
                        return $0.occurrenceCount > $1.occurrenceCount
                    }
                    if $0.conversationCount != $1.conversationCount {
                        return $0.conversationCount > $1.conversationCount
                    }
                    return $0.provider.displayName < $1.provider.displayName
                }
            }
        }

        private static func fullTextFilterSQL(
            provider: AgentProvider?,
            projectName: String?,
            dateRange: ClosedRange<Date>?,
            conversationSources: Set<OpenBurnBarCore.ConversationSourceType>?,
            args: inout [any DatabaseValueConvertible]
        ) -> String {
            var sql = ""
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
                let rawValues = sources.map(\.rawValue)
                let placeholders = Array(repeating: "?", count: rawValues.count).joined(separator: ", ")
                sql += " AND c.sourceType IN (\(placeholders))"
                args.append(contentsOf: rawValues)
            }
            return sql
        }

}
