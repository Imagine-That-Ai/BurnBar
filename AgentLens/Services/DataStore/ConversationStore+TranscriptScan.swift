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

        /// Round-4 perf sweep: SQL-side pre-filter for credential exposure scans.
        ///
        /// Adds `INSTR`-based WHERE clauses using distinctive credential
        /// prefixes (`sk-`, `AIza`, `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`,
        /// and generic key-assignment keywords) so SQLite skips conversations
        /// that clearly don't contain credentials **before** loading their
        /// `fullText` into Swift memory. This dramatically reduces the number
        /// of rows fetched and the total bytes loaded for credential scans.
        ///
        /// The pre-filter is intentionally over-broad (high recall, low
        /// precision): it catches all real credentials but also matches some
        /// non-credential text. The Swift-side regex still provides the
        /// precise filtering. The pre-filter only reduces wasted I/O.
        func fetchTranscriptScanBatchWithCredentialPreFilter(
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

                // Metadata filters.
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

                // Round-4 perf sweep: credential indicator pre-filter.
                // Use INSTR on LOWER(fullText) to skip conversations that
                // don't contain any credential indicator substring. This is
                // O(n) per row but done in SQLite's native code (no Swift
                // bridging, no NSString conversion, no regex engine).
                let indicators = Self.credentialIndicatorSubstrings
                let instrConditions = indicators.map { _ in
                    "INSTR(LOWER(COALESCE(c.fullText, '')), ?) > 0"
                }
                sql += " AND (\(instrConditions.joined(separator: " OR ")))"
                args.append(contentsOf: indicators)

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

        /// Distinctive substrings that indicate the presence of a credential.
        /// Used for SQL-side INSTR pre-filtering. High recall, low precision:
        /// every real credential contains at least one of these substrings,
        /// but some non-credential text may also match. The Swift-side regex
        /// provides precise filtering after the pre-filter reduces I/O.
        private static let credentialIndicatorSubstrings: [String] = [
            // OpenAI key prefix
            "sk-",
            // Google API key prefix
            "aiza",
            // GitHub token prefixes
            "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
            // Generic key=value patterns (case-insensitive via LOWER).
            // Standalone "token" and "secret" are intentionally broad: they
            // catch the bare `TOKEN=...` and `SECRET=...` forms that the
            // Swift-side regex matches, at the cost of loading some
            // non-credential conversations that mention those words. The regex
            // still provides precise filtering after the pre-filter reduces I/O.
            "api_key", "api-key", "apikey",
            "access_token", "access-token", "accesstoken",
            "secret_key", "secret-key", "secretkey",
            "secret",
            "token",
            "password", "passwd",
            "bearer ",
            "private_key", "private-key",
            "aws_access_key", "aws-access-key",
            "slack_token", "slack-token"
        ]

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
                // Round-4 perf sweep: collapse N separate UNION ALL full-table
                // scans into a single scan. The old query ran one
                // `SELECT SUM(...) FROM conversations WHERE ...` per pattern,
                // each scanning the full (potentially multi-MB) `fullText`
                // column. The new query computes all pattern occurrence counts
                // per row in a single expression and sums across rows in one
                // pass. Mathematically identical: SUM(a_i + b_i) == SUM(a_i) +
                // SUM(b_i). For 10 patterns this is 10× fewer full-text scans.
                var occurrenceExprs: [String] = []
                var args: [any DatabaseValueConvertible] = []
                for pattern in cleaned {
                    occurrenceExprs.append(
                        """
                        (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ''))) / LENGTH(?)
                        """
                    )
                    args.append(pattern)
                    args.append(pattern)
                }

                let filterSQL = Self.fullTextFilterSQL(
                    provider: provider,
                    projectName: projectName,
                    dateRange: dateRange,
                    conversationSources: conversationSources,
                    args: &args
                )

                let sql = """
                SELECT COALESCE(SUM(\(occurrenceExprs.joined(separator: " + "))), 0) AS count
                FROM conversations AS c
                WHERE c.deletedAt IS NULL
                \(filterSQL)
                """
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
                          let provider = AgentProvider.resolve(providerRaw) else { return nil }
                    let occurrenceCount: Int = row["occurrenceCount"] ?? 0
                    let conversationCount: Int = row["conversationCount"] ?? 0
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
