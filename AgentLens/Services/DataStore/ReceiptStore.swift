import Foundation
import GRDB
import OpenBurnBarKernel
import OpenBurnBarVectorKit

// MARK: - Receipt Aggregate Summary

public struct ReceiptAggregateSummary: Equatable, Sendable {
    public let count: Int
    public let totalCostUSD: Double
    public let totalTokens: Int
    public let totalCacheSavingsUSD: Double
    public let averageCacheHitPercentage: Double

    public init(
        count: Int = 0,
        totalCostUSD: Double = 0,
        totalTokens: Int = 0,
        totalCacheSavingsUSD: Double = 0,
        averageCacheHitPercentage: Double = 0
    ) {
        self.count = count
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.totalCacheSavingsUSD = totalCacheSavingsUSD
        self.averageCacheHitPercentage = averageCacheHitPercentage
    }

    public var formattedCost: String {
        String(format: "$%.2f", totalCostUSD)
    }

    public var formattedSavings: String {
        String(format: "$%.2f", totalCacheSavingsUSD)
    }

    public var formattedTokens: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000.0)
        } else if totalTokens >= 1_000 {
            return String(format: "%.1fk", Double(totalTokens) / 1_000.0)
        } else {
            return "\(totalTokens)"
        }
    }
}

// MARK: - Receipt Store

/// Handles durable persistence, querying, and backfill for OpenBurnBar receipts.
public final class ReceiptStore: Sendable {
    let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
        try? dbQueue.write { db in // try?-ok(schema initialization fails only if database is locked or read-only)
            try Self.ensureSchema(in: db)
        }
    }

    public static func ensureSchema(in db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE IF NOT EXISTS receipts (
                id TEXT PRIMARY KEY,
                sessionId TEXT NOT NULL,
                projectName TEXT NOT NULL,
                provider TEXT NOT NULL,
                modelName TEXT NOT NULL,
                harness TEXT NOT NULL DEFAULT '',
                timestamp DATETIME NOT NULL,
                durationSeconds REAL NOT NULL DEFAULT 0.0,
                inputTokens INTEGER NOT NULL DEFAULT 0,
                outputTokens INTEGER NOT NULL DEFAULT 0,
                cacheReadTokens INTEGER NOT NULL DEFAULT 0,
                cacheWriteTokens INTEGER NOT NULL DEFAULT 0,
                totalCostUSD REAL NOT NULL DEFAULT 0.0,
                estimatedCacheSavingsUSD REAL NOT NULL DEFAULT 0.0,
                cacheHitPercentage REAL NOT NULL DEFAULT 0.0,
                tokensPerSecond REAL NOT NULL DEFAULT 0.0,
                promptSummary TEXT NOT NULL DEFAULT '',
                actualAccomplishmentsJSON TEXT NOT NULL DEFAULT '[]',
                qualityReviewJSON TEXT NOT NULL DEFAULT '{}',
                achievementsJSON TEXT NOT NULL DEFAULT '[]',
                gitStatsJSON TEXT NOT NULL DEFAULT '{}',
                filesTouchedJSON TEXT NOT NULL DEFAULT '[]',
                toolsUsedJSON TEXT NOT NULL DEFAULT '[]',
                gitBranch TEXT,
                gitCommit TEXT,
                isStarred BOOLEAN NOT NULL DEFAULT 0,
                contentSignature TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            );

            CREATE INDEX IF NOT EXISTS receipts_session_idx ON receipts(sessionId);
            CREATE INDEX IF NOT EXISTS receipts_timestamp_idx ON receipts(timestamp);
            CREATE INDEX IF NOT EXISTS receipts_project_idx ON receipts(projectName);
            CREATE INDEX IF NOT EXISTS receipts_provider_idx ON receipts(provider);
            CREATE INDEX IF NOT EXISTS receipts_cost_idx ON receipts(totalCostUSD);
            CREATE INDEX IF NOT EXISTS receipts_starred_idx ON receipts(isStarred);
            CREATE INDEX IF NOT EXISTS receipts_harness_idx ON receipts(harness);
            """
        )

        let ftsExists = try Bool.fetchOne(db, sql: "SELECT count(*) > 0 FROM sqlite_master WHERE type='table' AND name='receipts_fts'") ?? false
        if !ftsExists {
            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE receipts_fts USING fts5(
                    promptSummary,
                    filesTouched,
                    toolsUsed,
                    modelName,
                    projectName,
                    tokenize='porter unicode61'
                );

                CREATE TRIGGER IF NOT EXISTS receipts_ai AFTER INSERT ON receipts BEGIN
                    INSERT INTO receipts_fts(rowid, promptSummary, filesTouched, toolsUsed, modelName, projectName)
                    VALUES (new.rowid, new.promptSummary, new.filesTouchedJSON, new.toolsUsedJSON, new.modelName, new.projectName);
                END;

                CREATE TRIGGER IF NOT EXISTS receipts_ad AFTER DELETE ON receipts BEGIN
                    DELETE FROM receipts_fts WHERE rowid = old.rowid;
                END;

                CREATE TRIGGER IF NOT EXISTS receipts_au AFTER UPDATE ON receipts BEGIN
                    DELETE FROM receipts_fts WHERE rowid = old.rowid;
                    INSERT INTO receipts_fts(rowid, promptSummary, filesTouched, toolsUsed, modelName, projectName)
                    VALUES (new.rowid, new.promptSummary, new.filesTouchedJSON, new.toolsUsedJSON, new.modelName, new.projectName);
                END;
                """
            )
        }
    }

    // MARK: - Insert / Upsert

    public func insert(receipt: ReceiptRecord) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let filesJSON = (try? String(data: encoder.encode(receipt.filesTouched), encoding: .utf8)) ?? "[]" // try?-ok(encode failure defaults to empty array)
        let toolsJSON = (try? String(data: encoder.encode(receipt.toolsUsed), encoding: .utf8)) ?? "[]" // try?-ok(encode failure defaults to empty array)
        let accomplishmentsJSON = (try? String(data: encoder.encode(receipt.actualAccomplishments), encoding: .utf8)) ?? "[]" // try?-ok(encode failure defaults to empty array)
        let qualityJSON = (try? String(data: encoder.encode(receipt.qualityReview), encoding: .utf8)) ?? "{}" // try?-ok(encode failure defaults to empty object)
        let achievementsJSON = (try? String(data: encoder.encode(receipt.achievements), encoding: .utf8)) ?? "[]" // try?-ok(encode failure defaults to empty array)
        let gitStatsJSON = (try? String(data: encoder.encode(receipt.gitStats), encoding: .utf8)) ?? "{}" // try?-ok(encode failure defaults to empty object)

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO receipts (
                    id, sessionId, projectName, provider, modelName, harness, timestamp,
                    durationSeconds, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
                    totalCostUSD, estimatedCacheSavingsUSD, cacheHitPercentage, tokensPerSecond,
                    promptSummary, actualAccomplishmentsJSON, qualityReviewJSON, achievementsJSON, gitStatsJSON,
                    filesTouchedJSON, toolsUsedJSON, gitBranch, gitCommit,
                    isStarred, contentSignature, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    sessionId = excluded.sessionId,
                    projectName = excluded.projectName,
                    provider = excluded.provider,
                    modelName = excluded.modelName,
                    harness = excluded.harness,
                    timestamp = excluded.timestamp,
                    durationSeconds = excluded.durationSeconds,
                    inputTokens = excluded.inputTokens,
                    outputTokens = excluded.outputTokens,
                    cacheReadTokens = excluded.cacheReadTokens,
                    cacheWriteTokens = excluded.cacheWriteTokens,
                    totalCostUSD = excluded.totalCostUSD,
                    estimatedCacheSavingsUSD = excluded.estimatedCacheSavingsUSD,
                    cacheHitPercentage = excluded.cacheHitPercentage,
                    tokensPerSecond = excluded.tokensPerSecond,
                    promptSummary = excluded.promptSummary,
                    actualAccomplishmentsJSON = excluded.actualAccomplishmentsJSON,
                    qualityReviewJSON = excluded.qualityReviewJSON,
                    achievementsJSON = excluded.achievementsJSON,
                    gitStatsJSON = excluded.gitStatsJSON,
                    filesTouchedJSON = excluded.filesTouchedJSON,
                    toolsUsedJSON = excluded.toolsUsedJSON,
                    gitBranch = excluded.gitBranch,
                    gitCommit = excluded.gitCommit,
                    isStarred = excluded.isStarred,
                    contentSignature = excluded.contentSignature
                """,
                arguments: [
                    receipt.id,
                    receipt.sessionId,
                    receipt.projectName,
                    receipt.provider.rawValue,
                    receipt.modelName,
                    receipt.harness,
                    receipt.timestamp,
                    receipt.durationSeconds,
                    receipt.inputTokens,
                    receipt.outputTokens,
                    receipt.cacheReadTokens,
                    receipt.cacheWriteTokens,
                    receipt.totalCostUSD,
                    receipt.estimatedCacheSavingsUSD,
                    receipt.cacheHitPercentage,
                    receipt.tokensPerSecond,
                    receipt.promptSummary,
                    accomplishmentsJSON,
                    qualityJSON,
                    achievementsJSON,
                    gitStatsJSON,
                    filesJSON,
                    toolsJSON,
                    receipt.gitBranch,
                    receipt.gitCommit,
                    receipt.isStarred,
                    receipt.contentSignature,
                    Date()
                ]
            )
        }
    }

    // MARK: - Star Toggle

    public func setStarred(receiptId: String, isStarred: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE receipts SET isStarred = ? WHERE id = ?",
                arguments: [isStarred, receiptId]
            )
        }
    }

    // MARK: - Fetch Single

    public func fetchReceipt(id: String) async throws -> ReceiptRecord? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM receipts WHERE id = ? LIMIT 1",
                arguments: [id]
            ) else { return nil }
            return Self.decodeReceipt(from: row)
        }
    }

    public func fetchReceiptForSession(sessionId: String) async throws -> ReceiptRecord? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM receipts WHERE sessionId = ? ORDER BY timestamp DESC LIMIT 1",
                arguments: [sessionId]
            ) else { return nil }
            return Self.decodeReceipt(from: row)
        }
    }

    // MARK: - Fetch Filtered Receipts

    public func fetchReceipts(filter: ReceiptFilter, limit: Int = 200, offset: Int = 0) async throws -> [ReceiptRecord] {
        let (cleanedQuery, modifiers) = ReceiptFilter.parseSmartQuery(filter.searchQuery)

        // If there is an active FTS query, delegate to FTS search
        if !cleanedQuery.isEmpty {
            return try await searchReceiptsFTS(
                query: cleanedQuery,
                filter: filter,
                modifiers: modifiers,
                limit: limit,
                offset: offset
            )
        }

        return try await dbQueue.read { db in
            var sql = "SELECT * FROM receipts WHERE 1=1"
            var args: [any DatabaseValueConvertible] = []

            if let provider = filter.provider {
                sql += " AND provider = ?"
                args.append(provider.rawValue)
            }
            if let harness = filter.harness {
                sql += " AND harness = ?"
                args.append(harness)
            }
            if let project = filter.projectName ?? modifiers.project {
                sql += " AND projectName = ?"
                args.append(project)
            }
            if let model = modifiers.model {
                sql += " AND modelName LIKE ?"
                args.append("%\(model)%")
            }
            if let minCost = filter.minCost ?? modifiers.minSpend {
                sql += " AND totalCostUSD >= ?"
                args.append(minCost)
            }
            if let maxCost = filter.maxCost ?? modifiers.maxSpend {
                sql += " AND totalCostUSD <= ?"
                args.append(maxCost)
            }
            if let minCache = filter.minCachePercentage ?? modifiers.minCache {
                sql += " AND cacheHitPercentage >= ?"
                args.append(minCache)
            }
            if filter.isStarredOnly || modifiers.starred == true {
                sql += " AND isStarred = 1"
            }
            if let range = filter.dateRange {
                sql += " AND timestamp >= ? AND timestamp <= ?"
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }

            sql += " ORDER BY timestamp DESC LIMIT ? OFFSET ?"
            args.append(limit)
            args.append(offset)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { Self.decodeReceipt(from: $0) }
        }
    }

    // MARK: - Aggregate Summary

    public func calculateAggregateSummary(filter: ReceiptFilter) async throws -> ReceiptAggregateSummary {
        let (cleanedQuery, modifiers) = ReceiptFilter.parseSmartQuery(filter.searchQuery)

        return try await dbQueue.read { db in
            var sql: String
            var args: [any DatabaseValueConvertible] = []

            if !cleanedQuery.isEmpty {
                let ftsQuery = BurnBarFTSQueryBuilder.naturalLanguage(from: cleanedQuery)
                guard !ftsQuery.isEmpty else {
                    return ReceiptAggregateSummary()
                }
                sql = """
                SELECT
                    COUNT(*) as count,
                    COALESCE(SUM(r.totalCostUSD), 0.0) as totalCost,
                    COALESCE(SUM(r.inputTokens + r.outputTokens + r.cacheReadTokens + r.cacheWriteTokens), 0) as totalTokens,
                    COALESCE(SUM(r.estimatedCacheSavingsUSD), 0.0) as totalSavings,
                    COALESCE(AVG(r.cacheHitPercentage), 0.0) as avgCacheHit
                FROM receipts_fts
                JOIN receipts AS r ON r.rowid = receipts_fts.rowid
                WHERE receipts_fts MATCH ?
                """
                args.append(ftsQuery)
            } else {
                sql = """
                SELECT
                    COUNT(*) as count,
                    COALESCE(SUM(totalCostUSD), 0.0) as totalCost,
                    COALESCE(SUM(inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens), 0) as totalTokens,
                    COALESCE(SUM(estimatedCacheSavingsUSD), 0.0) as totalSavings,
                    COALESCE(AVG(cacheHitPercentage), 0.0) as avgCacheHit
                FROM receipts
                WHERE 1=1
                """
            }

            let prefix = !cleanedQuery.isEmpty ? "r." : ""
            if let provider = filter.provider {
                sql += " AND \(prefix)provider = ?"
                args.append(provider.rawValue)
            }
            if let harness = filter.harness {
                sql += " AND \(prefix)harness = ?"
                args.append(harness)
            }
            if let project = filter.projectName ?? modifiers.project {
                sql += " AND \(prefix)projectName = ?"
                args.append(project)
            }
            if let model = modifiers.model {
                sql += " AND \(prefix)modelName LIKE ?"
                args.append("%\(model)%")
            }
            if let minCost = filter.minCost ?? modifiers.minSpend {
                sql += " AND \(prefix)totalCostUSD >= ?"
                args.append(minCost)
            }
            if let maxCost = filter.maxCost ?? modifiers.maxSpend {
                sql += " AND \(prefix)totalCostUSD <= ?"
                args.append(maxCost)
            }
            if let minCache = filter.minCachePercentage ?? modifiers.minCache {
                sql += " AND \(prefix)cacheHitPercentage >= ?"
                args.append(minCache)
            }
            if filter.isStarredOnly || modifiers.starred == true {
                sql += " AND \(prefix)isStarred = 1"
            }
            if let range = filter.dateRange {
                sql += " AND \(prefix)timestamp >= ? AND \(prefix)timestamp <= ?"
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }

            guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args)) else {
                return ReceiptAggregateSummary()
            }

            let count: Int = row["count"] ?? 0
            let totalCost: Double = row["totalCost"] ?? 0.0
            let totalTokens: Int = row["totalTokens"] ?? 0
            let totalSavings: Double = row["totalSavings"] ?? 0.0
            let avgCacheHit: Double = row["avgCacheHit"] ?? 0.0

            return ReceiptAggregateSummary(
                count: count,
                totalCostUSD: totalCost,
                totalTokens: totalTokens,
                totalCacheSavingsUSD: totalSavings,
                averageCacheHitPercentage: avgCacheHit
            )
        }
    }

    // MARK: - Row Decoding

    public static func decodeReceipt(from row: Row) -> ReceiptRecord? {
        guard let id: String = row["id"],
              let sessionId: String = row["sessionId"],
              let projectName: String = row["projectName"],
              let providerRaw: String = row["provider"],
              let modelName: String = row["modelName"],
              let timestamp: Date = row["timestamp"] else {
            return nil
        }

        let provider = AgentProvider(rawValue: providerRaw) ?? .claudeCode
        let harness: String = row["harness"] ?? provider.displayName
        let duration: Double = row["durationSeconds"] ?? 0.0
        let inputTokens: Int = row["inputTokens"] ?? 0
        let outputTokens: Int = row["outputTokens"] ?? 0
        let cacheReadTokens: Int = row["cacheReadTokens"] ?? 0
        let cacheWriteTokens: Int = row["cacheWriteTokens"] ?? 0
        let totalCostUSD: Double = row["totalCostUSD"] ?? 0.0
        let estimatedCacheSavingsUSD: Double = row["estimatedCacheSavingsUSD"] ?? 0.0
        let cacheHitPercentage: Double = row["cacheHitPercentage"] ?? 0.0
        let tokensPerSecond: Double = row["tokensPerSecond"] ?? 0.0
        let promptSummary: String = row["promptSummary"] ?? ""
        let gitBranch: String? = row["gitBranch"]
        let gitCommit: String? = row["gitCommit"]
        let isStarred: Bool = row["isStarred"] ?? false
        let contentSignature: String = row["contentSignature"] ?? ""

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var filesTouched: [String] = []
        if let filesJSON: String = row["filesTouchedJSON"],
           let data = filesJSON.data(using: .utf8),
           let list = try? decoder.decode([String].self, from: data) { // try?-ok(corrupt json defaults to empty)
            filesTouched = list
        }

        var toolsUsed: [String] = []
        if let toolsJSON: String = row["toolsUsedJSON"],
           let data = toolsJSON.data(using: .utf8),
           let list = try? decoder.decode([String].self, from: data) { // try?-ok(corrupt json defaults to empty)
            toolsUsed = list
        }

        var actualAccomplishments: [String] = []
        if let accJSON: String = row["actualAccomplishmentsJSON"],
           let data = accJSON.data(using: .utf8),
           let list = try? decoder.decode([String].self, from: data) { // try?-ok(corrupt json defaults to empty)
            actualAccomplishments = list
        }

        var qualityReview: ReceiptQualityReview?
        if let qrJSON: String = row["qualityReviewJSON"],
           let data = qrJSON.data(using: .utf8),
           let review = try? decoder.decode(ReceiptQualityReview.self, from: data) { // try?-ok(corrupt json defaults to empty)
            qualityReview = review
        }

        var achievements: [ReceiptAchievement] = []
        if let achJSON: String = row["achievementsJSON"],
           let data = achJSON.data(using: .utf8),
           let list = try? decoder.decode([ReceiptAchievement].self, from: data) { // try?-ok(corrupt json defaults to empty)
            achievements = list
        }

        var gitStats: ReceiptGitStats?
        if let gsJSON: String = row["gitStatsJSON"],
           let data = gsJSON.data(using: .utf8),
           let stats = try? decoder.decode(ReceiptGitStats.self, from: data) { // try?-ok(corrupt json defaults to empty)
            gitStats = stats
        }

        return ReceiptRecord(
            id: id,
            sessionId: sessionId,
            projectName: projectName,
            provider: provider,
            modelName: modelName,
            harness: harness,
            timestamp: timestamp,
            durationSeconds: duration,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalCostUSD: totalCostUSD,
            estimatedCacheSavingsUSD: estimatedCacheSavingsUSD,
            cacheHitPercentage: cacheHitPercentage,
            tokensPerSecond: tokensPerSecond,
            promptSummary: promptSummary,
            actualAccomplishments: actualAccomplishments,
            qualityReview: qualityReview,
            achievements: achievements,
            gitStats: gitStats,
            filesTouched: filesTouched,
            toolsUsed: toolsUsed,
            gitBranch: gitBranch,
            gitCommit: gitCommit,
            isStarred: isStarred,
            contentSignature: contentSignature
        )
    }

    // MARK: - Quality Review Updates

    public func updateQualityReview(receiptId: String, review: ReceiptQualityReview) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reviewJSON = (try? String(data: encoder.encode(review), encoding: .utf8)) ?? "{}" // try?-ok(encode failure defaults to empty object)
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE receipts SET qualityReviewJSON = ? WHERE id = ?",
                arguments: [reviewJSON, receiptId]
            )
        }
    }

    // MARK: - Backfill from Existing Sessions

    /// Scans conversations that don't yet have a receipt record and mints receipts for them.
    public func backfillReceiptsFromConversations() async throws -> Int {
        try await dbQueue.write { db -> Int in
            guard try db.tableExists("conversations") else { return 0 }

            // Find conversations with token usage that do not exist in receipts
            let sql = """
            SELECT
                c.id AS sessionId,
                COALESCE(c.projectName, 'Default') AS projectName,
                c.provider AS provider,
                COALESCE(c.model, 'unknown') AS modelName,
                c.startTime AS timestamp,
                COALESCE(c.durationSeconds, 0.0) AS durationSeconds,
                COALESCE(c.inputTokens, 0) AS inputTokens,
                COALESCE(c.outputTokens, 0) AS outputTokens,
                COALESCE(c.cacheReadTokens, 0) AS cacheReadTokens,
                COALESCE(c.cacheWriteTokens, 0) AS cacheWriteTokens,
                COALESCE(c.costUSD, 0.0) AS totalCostUSD,
                COALESCE(c.inferredTaskTitle, c.userPromptPreview, '') AS promptSummary,
                c.gitBranch AS gitBranch,
                c.gitCommit AS gitCommit
            FROM conversations AS c
            LEFT JOIN receipts AS r ON r.sessionId = c.id
            WHERE r.id IS NULL AND c.deletedAt IS NULL
            ORDER BY c.startTime DESC
            LIMIT 500
            """

            let rows = try Row.fetchAll(db, sql: sql)
            guard !rows.isEmpty else { return 0 }

            for row in rows {
                let sessionId: String = row["sessionId"] ?? UUID().uuidString
                let projectName: String = row["projectName"] ?? "Default"
                let providerRaw: String = row["provider"] ?? AgentProvider.claudeCode.rawValue
                let provider = AgentProvider(rawValue: providerRaw) ?? .claudeCode
                let modelName: String = row["modelName"] ?? "unknown"
                let timestamp: Date = row["timestamp"] ?? Date()
                let duration: Double = row["durationSeconds"] ?? 0.0
                let inputTokens: Int = row["inputTokens"] ?? 0
                let outputTokens: Int = row["outputTokens"] ?? 0
                let cacheReadTokens: Int = row["cacheReadTokens"] ?? 0
                let cacheWriteTokens: Int = row["cacheWriteTokens"] ?? 0
                let totalCostUSD: Double = row["totalCostUSD"] ?? 0.0
                let promptSummary: String = row["promptSummary"] ?? ""
                let gitBranch: String? = row["gitBranch"]
                let gitCommit: String? = row["gitCommit"]

                let totalTokens = inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
                let cacheHitPercentage = totalTokens > 0 ? (Double(cacheReadTokens) / Double(max(totalTokens, 1))) * 100.0 : 0.0
                let tokensPerSec = duration > 0 ? Double(totalTokens) / duration : 0.0

                // Estimate cache savings: standard input rate vs 90% discount on cache reads
                let baseInputCostEst = (Double(cacheReadTokens) / 1_000_000.0) * 3.0 // ~$3/M standard input baseline
                let discountedCostEst = (Double(cacheReadTokens) / 1_000_000.0) * 0.30 // ~$0.30/M cached
                let estimatedSavings = max(0.0, baseInputCostEst - discountedCostEst)

                let receipt = ReceiptRecord(
                    id: "rcpt_\(sessionId)",
                    sessionId: sessionId,
                    projectName: projectName,
                    provider: provider,
                    modelName: modelName,
                    timestamp: timestamp,
                    durationSeconds: duration,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWriteTokens: cacheWriteTokens,
                    totalCostUSD: totalCostUSD,
                    estimatedCacheSavingsUSD: estimatedSavings,
                    cacheHitPercentage: cacheHitPercentage,
                    tokensPerSecond: tokensPerSec,
                    promptSummary: promptSummary,
                    filesTouched: [],
                    toolsUsed: [],
                    gitBranch: gitBranch,
                    gitCommit: gitCommit,
                    isStarred: false
                )

                let filesJSON = "[]"
                let toolsJSON = "[]"

                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO receipts (
                        id, sessionId, projectName, provider, modelName, harness, timestamp,
                        durationSeconds, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
                        totalCostUSD, estimatedCacheSavingsUSD, cacheHitPercentage, tokensPerSecond,
                        promptSummary, actualAccomplishmentsJSON, qualityReviewJSON, achievementsJSON, gitStatsJSON,
                        filesTouchedJSON, toolsUsedJSON, gitBranch, gitCommit,
                        isStarred, contentSignature, createdAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        receipt.id,
                        receipt.sessionId,
                        receipt.projectName,
                        receipt.provider.rawValue,
                        receipt.modelName,
                        receipt.harness,
                        receipt.timestamp,
                        receipt.durationSeconds,
                        receipt.inputTokens,
                        receipt.outputTokens,
                        receipt.cacheReadTokens,
                        receipt.cacheWriteTokens,
                        receipt.totalCostUSD,
                        receipt.estimatedCacheSavingsUSD,
                        receipt.cacheHitPercentage,
                        receipt.tokensPerSecond,
                        receipt.promptSummary,
                        "[]",
                        "{}",
                        "[]",
                        "{}",
                        filesJSON,
                        toolsJSON,
                        receipt.gitBranch,
                        receipt.gitCommit,
                        receipt.isStarred,
                        receipt.contentSignature,
                        Date()
                    ]
                )
            }

            return rows.count
        }
    }
}
