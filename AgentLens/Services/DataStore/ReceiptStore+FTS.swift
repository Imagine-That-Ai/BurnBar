import Foundation
import GRDB
import OpenBurnBarKernel
import OpenBurnBarVectorKit

// MARK: - ReceiptStore FTS Extension

extension ReceiptStore {
    public func searchReceiptsFTS(
        query: String,
        filter: ReceiptFilter,
        modifiers: ReceiptFilterModifiers,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> [ReceiptRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try await fetchReceipts(filter: filter, limit: limit, offset: offset)
        }

        let ftsQuery = BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)
        guard !ftsQuery.isEmpty else {
            return try await fetchReceipts(filter: filter, limit: limit, offset: offset)
        }

        return try await dbQueue.read { db -> [ReceiptRecord] in
            var sql = """
            SELECT r.*, bm25(receipts_fts) AS rank
            FROM receipts_fts
            JOIN receipts AS r ON r.rowid = receipts_fts.rowid
            WHERE receipts_fts MATCH ?
            """
            var args: [any DatabaseValueConvertible] = [ftsQuery]

            if let provider = filter.provider {
                sql += " AND r.provider = ?"
                args.append(provider.rawValue)
            }
            if let project = filter.projectName ?? modifiers.project {
                sql += " AND r.projectName = ?"
                args.append(project)
            }
            if let model = modifiers.model {
                sql += " AND r.modelName LIKE ?"
                args.append("%\(model)%")
            }
            if let minCost = filter.minCost ?? modifiers.minSpend {
                sql += " AND r.totalCostUSD >= ?"
                args.append(minCost)
            }
            if let maxCost = filter.maxCost ?? modifiers.maxSpend {
                sql += " AND r.totalCostUSD <= ?"
                args.append(maxCost)
            }
            if let minCache = filter.minCachePercentage ?? modifiers.minCache {
                sql += " AND r.cacheHitPercentage >= ?"
                args.append(minCache)
            }
            if filter.isStarredOnly || modifiers.starred == true {
                sql += " AND r.isStarred = 1"
            }
            if let range = filter.dateRange {
                sql += " AND r.timestamp >= ? AND r.timestamp <= ?"
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }

            sql += " ORDER BY rank ASC, r.timestamp DESC LIMIT ? OFFSET ?"
            args.append(limit)
            args.append(offset)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            let results = rows.compactMap { Self.decodeReceipt(from: $0) }

            // If FTS matches are fewer than requested, fallback to prefix/substring search
            if results.count < limit {
                var fallbackSQL = """
                SELECT r.*
                FROM receipts AS r
                WHERE (r.promptSummary LIKE ? OR r.modelName LIKE ? OR r.projectName LIKE ?)
                """
                let pattern = "%\(trimmed)%"
                var fallbackArgs: [any DatabaseValueConvertible] = [pattern, pattern, pattern]

                if let provider = filter.provider {
                    fallbackSQL += " AND r.provider = ?"
                    fallbackArgs.append(provider.rawValue)
                }
                if let project = filter.projectName ?? modifiers.project {
                    fallbackSQL += " AND r.projectName = ?"
                    fallbackArgs.append(project)
                }
                if let model = modifiers.model {
                    fallbackSQL += " AND r.modelName LIKE ?"
                    fallbackArgs.append("%\(model)%")
                }
                if let minCost = filter.minCost ?? modifiers.minSpend {
                    fallbackSQL += " AND r.totalCostUSD >= ?"
                    fallbackArgs.append(minCost)
                }
                if let maxCost = filter.maxCost ?? modifiers.maxSpend {
                    fallbackSQL += " AND r.totalCostUSD <= ?"
                    fallbackArgs.append(maxCost)
                }
                if let minCache = filter.minCachePercentage ?? modifiers.minCache {
                    fallbackSQL += " AND r.cacheHitPercentage >= ?"
                    fallbackArgs.append(minCache)
                }
                if filter.isStarredOnly || modifiers.starred == true {
                    fallbackSQL += " AND r.isStarred = 1"
                }
                if let range = filter.dateRange {
                    fallbackSQL += " AND r.timestamp >= ? AND r.timestamp <= ?"
                    fallbackArgs.append(range.lowerBound)
                    fallbackArgs.append(range.upperBound)
                }

                fallbackSQL += " ORDER BY r.timestamp DESC LIMIT ?"
                fallbackArgs.append(limit - results.count)

                let existingIDs = Set(results.map(\.id))
                let fallbackRows = try Row.fetchAll(db, sql: fallbackSQL, arguments: StatementArguments(fallbackArgs))
                let fallbackResults = fallbackRows.compactMap { Self.decodeReceipt(from: $0) }.filter { !existingIDs.contains($0.id) }

                return results + fallbackResults
            }

            return results
        }
    }
}
