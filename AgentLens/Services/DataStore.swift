import Foundation
import GRDB
import SwiftUI

// MARK: - Rolling Average + Mood

enum MoodBand: Equatable {
    case light
    case onPace
    case heavy
    case baseline
    case quiet
}

// MARK: - DataStore

@Observable
@MainActor
final class DataStore {
    private let dbQueue: DatabaseQueue
    private(set) var usages: [TokenUsage] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?

    private let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    // MARK: - Computed Properties
    
    var totalCostToday: Double {
        let calendar = Calendar.current
        return usages
            .filter { calendar.isDateInToday($0.startTime) }
            .reduce(0) { $0 + $1.cost }
    }
    
    var totalCostThisWeek: Double {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return usages
            .filter { $0.startTime >= weekAgo }
            .reduce(0) { $0 + $1.cost }
    }
    
    var totalCostThisMonth: Double {
        let calendar = Calendar.current
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return usages
            .filter { $0.startTime >= monthAgo }
            .reduce(0) { $0 + $1.cost }
    }
    
    var totalCostAllTime: Double {
        usages.reduce(0) { $0 + $1.cost }
    }

    var totalTokensToday: Int {
        let calendar = Calendar.current
        return usages
            .filter { calendar.isDateInToday($0.startTime) }
            .reduce(0) { $0 + $1.totalTokens }
    }

    var totalTokensThisWeek: Int {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return usages
            .filter { $0.startTime >= weekAgo }
            .reduce(0) { $0 + $1.totalTokens }
    }

    var totalTokensThisMonth: Int {
        let calendar = Calendar.current
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return usages
            .filter { $0.startTime >= monthAgo }
            .reduce(0) { $0 + $1.totalTokens }
    }

    var totalTokensAllTime: Int {
        usages.reduce(0) { $0 + $1.totalTokens }
    }

    /// 7-day rolling daily average (zero-fills missing days). Updated in `replaceUsages(_:)`.
    private(set) var rollingDailyAverage: Double = 0

    var moodBand: MoodBand {
        let calendar = Calendar.current
        let distinctDays = Set(usages.map { calendar.startOfDay(for: $0.startTime) })
        guard distinctDays.count >= 2 else { return .baseline }
        let today = totalCostToday
        guard today > 0 else { return .quiet }
        guard rollingDailyAverage > 0 else { return .onPace }
        let ratio = today / rollingDailyAverage
        switch ratio {
        case ..<0.8: return .light
        case 0.8..<1.2: return .onPace
        default: return .heavy
        }
    }

    var moodLabel: String {
        switch moodBand {
        case .light: return "Light day"
        case .onPace: return "On pace"
        case .heavy: return "Heavy day"
        case .baseline: return "Building baseline..."
        case .quiet: return "Quiet day"
        }
    }

    var moodColor: Color {
        switch moodBand {
        case .light: return DesignSystem.Colors.success
        case .onPace: return DesignSystem.Colors.textSecondary
        case .heavy: return DesignSystem.Colors.warning
        case .baseline, .quiet: return DesignSystem.Colors.textMuted
        }
    }

    /// Last 7 calendar days of daily cost, zero-filled, oldest first.
    var last7DayCosts: [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset -> Double in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            return usages
                .filter { $0.startTime >= day && $0.startTime < next }
                .reduce(0) { $0 + $1.cost }
        }
    }

    /// Last 7 calendar days of total tokens per day (for token-mode sparkline).
    var last7DayTokenTotals: [Int] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset -> Int in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            return usages
                .filter { $0.startTime >= day && $0.startTime < next }
                .reduce(0) { $0 + $1.totalTokens }
        }
    }

    var providerSummaries: [ProviderSummary] {
        AgentProvider.allCases.compactMap { provider -> ProviderSummary? in
            let providerUsages = usages.filter { $0.provider == provider }
            guard !providerUsages.isEmpty else { return nil }
            
            let totalCost = providerUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = providerUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = providerUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = providerUsages.reduce(0) { $0 + $1.outputTokens }
            
            // Model breakdown
            var modelData: [String: (input: Int, output: Int, cacheCreation: Int, cacheRead: Int, cost: Double)] = [:]
            for usage in providerUsages {
                let existing = modelData[usage.model] ?? (0, 0, 0, 0, 0)
                modelData[usage.model] = (
                    existing.0 + usage.inputTokens,
                    existing.1 + usage.outputTokens,
                    existing.2 + usage.cacheCreationTokens,
                    existing.3 + usage.cacheReadTokens,
                    existing.4 + usage.cost
                )
            }
            
            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.input + data.output + data.cacheCreation + data.cacheRead
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.input,
                    outputTokens: data.output,
                    cacheCreationTokens: data.cacheCreation,
                    cacheReadTokens: data.cacheRead,
                    totalTokens: totalModelTokens,
                    cost: data.cost,
                    percentage: totalCost > 0 ? (data.cost / totalCost) * 100 : 0
                )
            }.sorted { $0.cost > $1.cost }
            
            return ProviderSummary(
                provider: provider,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: providerUsages.count,
                modelBreakdown: modelBreakdown
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }
    
    // MARK: - Model Summaries

    var modelSummaries: [ModelSummary] {
        let grouped = Dictionary(grouping: usages) {
            TokenExtractionUtility.normalizeModelKey($0.model)
        }
        return grouped.compactMap { key, modelUsages -> ModelSummary? in
            guard !modelUsages.isEmpty else { return nil }
            let totalCost = modelUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = modelUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = modelUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = modelUsages.reduce(0) { $0 + $1.outputTokens }

            let byProvider = Dictionary(grouping: modelUsages) { $0.provider }
            let providerBreakdown = byProvider.map { provider, pUsages -> ProviderUsage in
                let pCost = pUsages.reduce(0) { $0 + $1.cost }
                let pTokens = pUsages.reduce(0) { $0 + $1.totalTokens }
                return ProviderUsage(
                    provider: provider,
                    sessionCount: pUsages.count,
                    totalTokens: pTokens,
                    cost: pCost,
                    percentage: totalCost > 0 ? (pCost / totalCost) * 100 : 0
                )
            }.sorted { $0.cost > $1.cost }

            return ModelSummary(
                modelName: key,
                displayName: TokenExtractionUtility.displayNameForModel(modelUsages.first?.model ?? key),
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: modelUsages.count,
                providerBreakdown: providerBreakdown
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }

    func usages(forModel normalizedName: String) -> [TokenUsage] {
        usages.filter { TokenExtractionUtility.normalizeModelKey($0.model) == normalizedName }
    }

    func usages(forModel normalizedName: String, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usages.filter {
            TokenExtractionUtility.normalizeModelKey($0.model) == normalizedName
            && dateRange.contains($0.startTime)
        }
    }

    var dailySummaries: [DailyUsageSummary] {
        let calendar = Calendar.current
        var dayData: [Date: [TokenUsage]] = [:]
        
        for usage in usages {
            let dayKey = calendar.startOfDay(for: usage.startTime)
            dayData[dayKey, default: []].append(usage)
        }
        
        return dayData.map { date, usages in
            DailyUsageSummary(
                date: date,
                provider: usages.first?.provider ?? .factory,
                totalInputTokens: usages.reduce(0) { $0 + $1.inputTokens },
                totalOutputTokens: usages.reduce(0) { $0 + $1.outputTokens },
                totalCacheCreationTokens: usages.reduce(0) { $0 + $1.cacheCreationTokens },
                totalCacheReadTokens: usages.reduce(0) { $0 + $1.cacheReadTokens },
                totalTokens: usages.reduce(0) { $0 + $1.totalTokens },
                totalCost: usages.reduce(0) { $0 + $1.cost },
                sessionCount: usages.count,
                models: Array(Set(usages.map { $0.model }))
            )
        }.sorted { $0.date > $1.date }
    }
    
    // MARK: - Initialization
    
    init() {
        let appDir = try! BurnBarMigration.prepareSupportDirectory()
        let dbPath = appDir.appendingPathComponent(BurnBarIdentity.databaseFileName).path
        dbQueue = try! DatabaseQueue(path: dbPath)
        
        try! migrator.migrate(dbQueue)

        refresh()
    }
    
    // MARK: - Database Schema
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "token_usage") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("sessionId", .text).notNull().indexed()
                t.column("projectName", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("cacheCreationTokens", .integer).notNull()
                t.column("cacheReadTokens", .integer).notNull()
                t.column("totalTokens", .integer).notNull()
                t.column("cost", .double).notNull()
                t.column("startTime", .datetime).notNull().indexed()
                t.column("endTime", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_sync") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "syncedAt", .datetime)
            }
        }

        migrator.registerMigration("v3_conversations") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("sessionId", .text).notNull().indexed()
                t.column("projectName", .text).notNull()
                t.column("startTime", .datetime)
                t.column("endTime", .datetime)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("userWordCount", .integer).notNull().defaults(to: 0)
                t.column("assistantWordCount", .integer).notNull().defaults(to: 0)
                t.column("keyFiles", .text)
                t.column("keyCommands", .text)
                t.column("keyTools", .text)
                t.column("inferredTaskTitle", .text).notNull().defaults(to: "")
                t.column("lastAssistantMessage", .text).notNull().defaults(to: "")
                t.column("fullText", .text).notNull().defaults(to: "")
                t.column("indexedAt", .datetime).notNull()
                t.column("fileModifiedAt", .datetime)
            }

            try db.create(table: "chat_messages") { t in
                t.column("id", .text).primaryKey()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("cliUsed", .text)
            }

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    content='conversations',
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                )
                """
            )
        }

        migrator.registerMigration("v4_summaries") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summary", .text)
            }
        }

        /// Rebuild FTS index from `conversations` so MATCH/snippet queries work. External-content
        /// FTS5 is normally updated automatically on DML; a rebuild fixes empty or stale indexes
        /// (e.g. after upgrades or if the shadow table was not populated).
        migrator.registerMigration("v5_fts_rebuild") { db in
            try db.execute(
                sql: "INSERT INTO conversations_fts(conversations_fts) VALUES('rebuild')"
            )
        }

        /// Replace external-content FTS with a standalone FTS5 table + triggers so the index
        /// is always updated on DML (external-content auto-sync is unreliable with some SQLite builds).
        migrator.registerMigration("v6_fts_standalone_triggers") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")
            try db.execute(sql: "DROP TABLE IF EXISTS conversations_fts")

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    tokenize='porter unicode61'
                )
                """
            )

            try db.execute(
                sql: """
                INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                SELECT rowid, inferredTaskTitle, fullText FROM conversations
                """
            )

            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ai AFTER INSERT ON conversations BEGIN
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN
                    INSERT INTO conversations_fts(conversations_fts, rowid, inferredTaskTitle, fullText)
                    VALUES('delete', old.rowid, old.inferredTaskTitle, old.fullText);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN
                    INSERT INTO conversations_fts(conversations_fts, rowid, inferredTaskTitle, fullText)
                    VALUES('delete', old.rowid, old.inferredTaskTitle, old.fullText);
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
        }

        migrator.registerMigration("v7_conversation_cloud_sync") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "conversationSyncedAt", .datetime)
            }
        }

        migrator.registerMigration("v8_chat_transcript_pieces") { db in
            try db.alter(table: "chat_messages") { t in
                t.add(column: "transcriptPiecesJSON", .text)
            }
        }

        /// Discriminates provider-log conversations from the in-app CLI assistant thread.
        migrator.registerMigration("v9_source_type") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "sourceType", .text).notNull().defaults(to: "provider_log")
            }
        }

        /// Independent dirty-flag for full session-log (Markdown) cloud backup.
        migrator.registerMigration("v10_log_synced_at") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "logSyncedAt", .datetime)
            }
        }

        return migrator
    }
    
    // MARK: - CRUD Operations
    
    func insert(_ usage: TokenUsage) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO token_usage (
                        id, provider, sessionId, projectName, model,
                        inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                        totalTokens, cost, startTime, endTime, createdAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    usage.id.uuidString,
                    usage.provider.rawValue,
                    usage.sessionId,
                    usage.projectName,
                    usage.model,
                    usage.inputTokens,
                    usage.outputTokens,
                    usage.cacheCreationTokens,
                    usage.cacheReadTokens,
                    usage.totalTokens,
                    usage.cost,
                    usage.startTime,
                    usage.endTime,
                    usage.createdAt
                ]
            )
        }
    }
    
    func insert(_ newUsages: [TokenUsage]) throws {
        for usage in newUsages {
            try insert(usage)
        }
    }
    
    func deleteAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM token_usage")
        }
        usages = []
        rollingDailyAverage = 0
    }

    func replaceUsages(_ newUsages: [TokenUsage]) {
        usages = newUsages.sorted { $0.startTime > $1.startTime }
        rollingDailyAverage = computeRollingAverage()
        lastRefresh = Date()
    }

    private func computeRollingAverage() -> Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var total: Double = 0
        for dayOffset in 1...7 {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
            let dayCost = usages
                .filter { $0.startTime >= day && $0.startTime < nextDay }
                .reduce(0) { $0 + $1.cost }
            total += dayCost
        }
        return total / 7
    }
    
    // MARK: - Refresh
    
    func refresh() {
        isLoading = true
        
        do {
            let records = try dbQueue.read { db -> [TokenUsage] in
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM token_usage ORDER BY startTime DESC")
                return rows.compactMap { row -> TokenUsage? in
                    guard let idString = row["id"] as? String,
                          let id = UUID(uuidString: idString),
                          let providerString = row["provider"] as? String,
                          let provider = AgentProvider(rawValue: providerString),
                          let sessionId = row["sessionId"] as? String,
                          let projectName = row["projectName"] as? String,
                          let model = row["model"] as? String else {
                        return nil
                    }

                    let inputTokens = (row["inputTokens"] as? Int) ?? Int(row["inputTokens"] as? Int64 ?? 0)
                    let outputTokens = (row["outputTokens"] as? Int) ?? Int(row["outputTokens"] as? Int64 ?? 0)
                    let cacheCreationTokens = (row["cacheCreationTokens"] as? Int) ?? Int(row["cacheCreationTokens"] as? Int64 ?? 0)
                    let cacheReadTokens = (row["cacheReadTokens"] as? Int) ?? Int(row["cacheReadTokens"] as? Int64 ?? 0)

                    let cost = (row["cost"] as? Double)
                        ?? ((row["cost"] as? NSNumber)?.doubleValue)
                        ?? 0

                    let startTime = parseDate(row["startTime"])
                    let endTime = parseDate(row["endTime"])
                    guard let startTime, let endTime else { return nil }
                    
                    return TokenUsage(
                        id: id,
                        provider: provider,
                        sessionId: sessionId,
                        projectName: projectName,
                        model: model,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheCreationTokens: cacheCreationTokens,
                        cacheReadTokens: cacheReadTokens,
                        costUSD: cost,
                        startTime: startTime,
                        endTime: endTime
                    )
                }
            }
            replaceUsages(records)
        } catch {
            print("DataStore: Failed to refresh data: \(error)")
        }
        
        isLoading = false
    }

    private func parseDate(_ value: Any?) -> Date? {
        Self.parseDateValue(value)
    }

    private static func parseDateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let string = value as? String {
            if let parsed = sqliteDateFormatterStatic.date(from: string) { return parsed }
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private static let sqliteDateFormatterStatic: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    // MARK: - Sync Helpers

    func fetchUnsynced() throws -> [TokenUsage] {
        try dbQueue.read { db -> [TokenUsage] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM token_usage WHERE syncedAt IS NULL ORDER BY startTime ASC LIMIT 400"
            )
            return rows.compactMap { row -> TokenUsage? in
                guard let idString = row["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let providerString = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerString),
                      let sessionId = row["sessionId"] as? String,
                      let projectName = row["projectName"] as? String,
                      let model = row["model"] as? String else { return nil }

                let inputTokens = (row["inputTokens"] as? Int) ?? Int(row["inputTokens"] as? Int64 ?? 0)
                let outputTokens = (row["outputTokens"] as? Int) ?? Int(row["outputTokens"] as? Int64 ?? 0)
                let cacheCreationTokens = (row["cacheCreationTokens"] as? Int) ?? Int(row["cacheCreationTokens"] as? Int64 ?? 0)
                let cacheReadTokens = (row["cacheReadTokens"] as? Int) ?? Int(row["cacheReadTokens"] as? Int64 ?? 0)
                let cost = (row["cost"] as? Double) ?? ((row["cost"] as? NSNumber)?.doubleValue) ?? 0
                let startTime = parseDate(row["startTime"])
                let endTime = parseDate(row["endTime"])
                guard let startTime, let endTime else { return nil }

                return TokenUsage(
                    id: id,
                    provider: provider,
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: cacheCreationTokens,
                    cacheReadTokens: cacheReadTokens,
                    costUSD: cost,
                    startTime: startTime,
                    endTime: endTime
                )
            }
        }
    }

    func markSynced(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let idStrings: [String] = ids.map { $0.uuidString }
        try dbQueue.write { db in
            // Build arguments: first param is the syncedAt date, rest are UUIDs
            var args = StatementArguments([Date()])
            args += StatementArguments(idStrings)
            try db.execute(
                sql: "UPDATE token_usage SET syncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    /// Conversations whose metadata has not been uploaded to Firestore (or changed since last upload).
    func fetchUnsyncedConversations(limit: Int = 400) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                WHERE conversationSyncedAt IS NULL
                ORDER BY COALESCE(endTime, startTime) ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func markConversationsSynced(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try dbQueue.write { db in
            var args = StatementArguments([Date()])
            args += StatementArguments(ids)
            try db.execute(
                sql: "UPDATE conversations SET conversationSyncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    // MARK: - Query Helpers
    
    func usages(for provider: AgentProvider) -> [TokenUsage] {
        usages.filter { $0.provider == provider }
    }
    
    func usages(for provider: AgentProvider, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usages.filter { $0.provider == provider && dateRange.contains($0.startTime) }
    }
    
    func topProviderToday() -> (provider: AgentProvider, cost: Double)? {
        let calendar = Calendar.current
        let todayUsages = usages.filter { calendar.isDateInToday($0.startTime) }
        
        var costs: [AgentProvider: Double] = [:]
        for usage in todayUsages {
            costs[usage.provider, default: 0] += usage.cost
        }
        
        return costs.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: - Conversations (indexed)

    func upsertConversation(_ record: ConversationRecord) throws {
        let keyFilesJSON = try Self.encodeJSON(record.keyFiles)
        let keyCommandsJSON = try Self.encodeJSON(record.keyCommands)
        let keyToolsJSON = try Self.encodeJSON(record.keyTools)

        try dbQueue.write { db in
            let existing = try Self.fetchConversationRow(db, id: record.id)
            let priorSyncedAt: Date? = try Date.fetchOne(
                db,
                sql: "SELECT conversationSyncedAt FROM conversations WHERE id = ?",
                arguments: [record.id]
            )
            let priorLogSyncedAt: Date? = try Date.fetchOne(
                db,
                sql: "SELECT logSyncedAt FROM conversations WHERE id = ?",
                arguments: [record.id]
            )

            var summaryOut = record.summary
            if summaryOut == nil {
                summaryOut = try String.fetchOne(db, sql: "SELECT summary FROM conversations WHERE id = ?", arguments: [record.id])
            }

            let preserve = existing.map {
                Self.shouldPreserveConversationSyncedAt(existing: $0, incoming: record, resolvedSummary: summaryOut)
            } ?? false

            let conversationSyncedAt: Date? = preserve ? priorSyncedAt : nil
            let logSyncedAt: Date? = preserve ? priorLogSyncedAt : nil

            try db.execute(
                sql: """
                INSERT OR REPLACE INTO conversations (
                    id, provider, sessionId, projectName, startTime, endTime,
                    messageCount, userWordCount, assistantWordCount,
                    keyFiles, keyCommands, keyTools,
                    inferredTaskTitle, lastAssistantMessage, fullText,
                    indexedAt, fileModifiedAt, summary, conversationSyncedAt,
                    sourceType, logSyncedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.id,
                    record.provider.rawValue,
                    record.sessionId,
                    record.projectName,
                    record.startTime,
                    record.endTime,
                    record.messageCount,
                    record.userWordCount,
                    record.assistantWordCount,
                    keyFilesJSON,
                    keyCommandsJSON,
                    keyToolsJSON,
                    record.inferredTaskTitle,
                    record.lastAssistantMessage,
                    record.fullText,
                    record.indexedAt,
                    record.fileModifiedAt,
                    summaryOut,
                    conversationSyncedAt,
                    record.sourceType.rawValue,
                    logSyncedAt
                ]
            )
        }
    }

    func fileModifiedAtForConversation(id: String) throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT fileModifiedAt FROM conversations WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func fetchConversation(id: String) throws -> ConversationRecord? {
        try dbQueue.read { db in
            try Self.fetchConversationRow(db, id: id)
        }
    }

    func fetchConversations(limit: Int = 500) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversations ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func updateConversationSummary(id: String, summary: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET summary = ?, indexedAt = ?, conversationSyncedAt = NULL WHERE id = ?",
                arguments: [summary, Date(), id]
            )
        }
    }

    func deleteAllIndexedConversations() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM conversations")
        }
    }

    func approximateConversationStorageBytes() throws -> Int64 {
        try dbQueue.read { db in
            let text: Int64 = try Int64.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(LENGTH(fullText)), 0) + COALESCE(SUM(LENGTH(inferredTaskTitle)), 0)
                + COALESCE(SUM(LENGTH(lastAssistantMessage)), 0) FROM conversations
                """
            ) ?? 0
            return text
        }
    }

    // MARK: - Chat messages (persisted)

    func saveChatMessage(_ message: ChatMessageRecord) throws {
        let piecesJSON: String?
        if message.transcriptPieces.isEmpty {
            piecesJSON = nil
        } else {
            piecesJSON = try Self.encodeTranscriptPieces(message.transcriptPieces)
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO chat_messages (id, role, content, timestamp, cliUsed, transcriptPiecesJSON)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    message.id,
                    message.role.rawValue,
                    message.content,
                    message.timestamp,
                    message.cliUsed,
                    piecesJSON
                ]
            )
        }
    }

    func fetchChatMessages() throws -> [ChatMessageRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM chat_messages ORDER BY timestamp ASC")
            return rows.compactMap { row -> ChatMessageRecord? in
                guard let id = row["id"] as? String,
                      let roleRaw = row["role"] as? String,
                      let role = ChatMessageRole(rawValue: roleRaw),
                      let content = row["content"] as? String,
                      let ts = parseDate(row["timestamp"]) else { return nil }
                let pieces = Self.decodeTranscriptPieces(row["transcriptPiecesJSON"] as? String) ?? []
                return ChatMessageRecord(
                    id: id,
                    role: role,
                    content: content,
                    timestamp: ts,
                    cliUsed: row["cliUsed"] as? String,
                    transcriptPieces: pieces
                )
            }
        }
    }

    func deleteAllChatMessages() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chat_messages")
        }
    }

    // MARK: - Full-text search

    func searchConversationsFTS(
        query: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let ftsQuery = Self.fts5SafeQuery(from: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        return try dbQueue.read { db -> [SearchResult] in
            var sql = """
            SELECT c.*, bm25(conversations_fts) AS rank,
            snippet(conversations_fts, 1, '<b>', '</b>', '…', 10) AS snip
            FROM conversations_fts
            JOIN conversations AS c ON c.rowid = conversations_fts.rowid
            WHERE conversations_fts MATCH ?
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
            return rows.compactMap { row -> SearchResult? in
                guard let conv = Self.conversation(from: row) else { return nil }
                let rank = (row["rank"] as? Double) ?? Double(row["rank"] as? Int64 ?? 0)
                let snip = (row["snip"] as? String) ?? ""
                return SearchResult(conversation: conv, snippet: snip, rank: rank)
            }
        }
    }

    private static func fts5SafeQuery(from userInput: String) -> String {
        let parts = userInput.split { $0.isWhitespace || $0.isNewline }.map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return parts.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }.joined(separator: " AND ")
    }

    // MARK: - Conversation row mapping

    private static func fetchConversationRow(_ db: Database, id: String) throws -> ConversationRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return conversation(from: row)
    }

    private static func conversation(from row: Row) -> ConversationRecord? {
        guard let id = row["id"] as? String,
              let providerRaw = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String else {
            return nil
        }
        let messageCount = (row["messageCount"] as? Int) ?? Int(row["messageCount"] as? Int64 ?? 0)
        let userWordCount = (row["userWordCount"] as? Int) ?? Int(row["userWordCount"] as? Int64 ?? 0)
        let assistantWordCount = (row["assistantWordCount"] as? Int) ?? Int(row["assistantWordCount"] as? Int64 ?? 0)
        let inferredTaskTitle = (row["inferredTaskTitle"] as? String) ?? ""
        let lastAssistantMessage = (row["lastAssistantMessage"] as? String) ?? ""
        let fullText = (row["fullText"] as? String) ?? ""

        let keyFiles = decodeJSONStringArray(row["keyFiles"] as? String)
        let keyCommands = decodeJSONStringArray(row["keyCommands"] as? String)
        let keyTools = decodeJSONStringArray(row["keyTools"] as? String)

        let startTime = Self.parseDateValue(row["startTime"])
        let endTime = Self.parseDateValue(row["endTime"])
        let indexedAt = Self.parseDateValue(row["indexedAt"]) ?? Date()
        let fileModifiedAt = Self.parseDateValue(row["fileModifiedAt"])

        let sourceTypeRaw = (row["sourceType"] as? String) ?? "provider_log"
        let sourceType = ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog

        return ConversationRecord(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: messageCount,
            userWordCount: userWordCount,
            assistantWordCount: assistantWordCount,
            keyFiles: keyFiles,
            keyCommands: keyCommands,
            keyTools: keyTools,
            inferredTaskTitle: inferredTaskTitle,
            lastAssistantMessage: lastAssistantMessage,
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: fileModifiedAt,
            summary: row["summary"] as? String,
            sourceType: sourceType
        )
    }

    private static func decodeJSONStringArray(_ string: String?) -> [String] {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func encodeTranscriptPieces(_ value: [ChatTranscriptPiece]) throws -> String {
        try encodeJSON(value)
    }

    private static func decodeTranscriptPieces(_ string: String?) -> [ChatTranscriptPiece]? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([ChatTranscriptPiece].self, from: data) else {
            return nil
        }
        return arr
    }

    // MARK: - Session Logs

    /// All indexed conversations sorted by most-recent first, for the Session Logs center.
    func fetchAllSessionLogs(limit: Int = 1000) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversations ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    /// Conversations whose full Markdown log has not yet been uploaded to Firestore.
    func fetchUnsyncedSessionLogs(limit: Int = 100) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                WHERE logSyncedAt IS NULL
                ORDER BY COALESCE(endTime, startTime) ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func markSessionLogsSynced(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try dbQueue.write { db in
            var args = StatementArguments([Date()])
            args += StatementArguments(ids)
            try db.execute(
                sql: "UPDATE conversations SET logSyncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    /// Synthesizes a single `cliAssistant` ConversationRecord from persisted chat messages
    /// and upserts it so the Session Logs center and cloud sync treat it like any other session.
    func upsertCLIConversation(from messages: [ChatMessageRecord]) throws {
        guard messages.isEmpty == false else { return }

        let start = messages.first?.timestamp
        let end   = messages.last?.timestamp

        let assistantWords = messages
            .filter { $0.role == .assistant }
            .reduce(0) { $0 + $1.content.split(separator: " ").count }
        let userWords = messages
            .filter { $0.role == .user }
            .reduce(0) { $0 + $1.content.split(separator: " ").count }

        let markdown = SessionLogMarkdownFormatter.cliMarkdown(from: messages)
        let lastAssistant = messages.last(where: { $0.role == .assistant })?.content ?? ""

        let record = ConversationRecord(
            id: ConversationRecord.cliAssistantId,
            provider: .claudeCode,
            sessionId: "cli-assistant-local",
            projectName: "BurnBar",
            startTime: start,
            endTime: end,
            messageCount: messages.count,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "BurnBar Assistant",
            lastAssistantMessage: String(lastAssistant.prefix(500)),
            fullText: markdown,
            indexedAt: Date(),
            fileModifiedAt: nil,
            summary: nil,
            sourceType: .cliAssistant
        )
        try upsertConversation(record)
    }

    // MARK: - Sync Helpers (private)

    /// Returns true when every synced field is unchanged so the existing sync timestamps can be preserved.
    /// Checking `fullText` ensures transcript changes also reset the full-log dirty flag (`logSyncedAt`).
    private static func shouldPreserveConversationSyncedAt(
        existing: ConversationRecord,
        incoming: ConversationRecord,
        resolvedSummary: String?
    ) -> Bool {
        existing.provider == incoming.provider
            && existing.sessionId == incoming.sessionId
            && existing.projectName == incoming.projectName
            && existing.startTime == incoming.startTime
            && existing.endTime == incoming.endTime
            && existing.messageCount == incoming.messageCount
            && existing.userWordCount == incoming.userWordCount
            && existing.assistantWordCount == incoming.assistantWordCount
            && existing.keyFiles == incoming.keyFiles
            && existing.keyCommands == incoming.keyCommands
            && existing.keyTools == incoming.keyTools
            && existing.inferredTaskTitle == incoming.inferredTaskTitle
            && existing.lastAssistantMessage == incoming.lastAssistantMessage
            && existing.fullText == incoming.fullText
            && existing.summary == resolvedSummary
    }

}
