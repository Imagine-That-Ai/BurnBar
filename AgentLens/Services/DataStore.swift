import Foundation
import GRDB
import SwiftUI

// MARK: - DataStore

@Observable
@MainActor
final class DataStore {
    private let dbQueue: DatabaseQueue
    private(set) var usages: [TokenUsage] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?
    
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
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AgentLens")
        
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        
        let dbPath = appDir.appendingPathComponent("agentlens.sqlite").path
        dbQueue = try! DatabaseQueue(path: dbPath)
        
        try! migrator.migrate(dbQueue)
        
        Task {
            await refresh()
        }
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
    }
    
    // MARK: - Refresh
    
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let records = try await dbQueue.read { db -> [TokenUsage] in
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM token_usage ORDER BY startTime DESC")
                return rows.compactMap { row -> TokenUsage? in
                    guard let idString = row["id"] as? String,
                          let id = UUID(uuidString: idString),
                          let providerString = row["provider"] as? String,
                          let provider = AgentProvider(rawValue: providerString),
                          let sessionId = row["sessionId"] as? String,
                          let projectName = row["projectName"] as? String,
                          let model = row["model"] as? String,
                          let inputTokens = row["inputTokens"] as? Int,
                          let outputTokens = row["outputTokens"] as? Int,
                          let cacheCreationTokens = row["cacheCreationTokens"] as? Int,
                          let cacheReadTokens = row["cacheReadTokens"] as? Int,
                          let cost = row["cost"] as? Double,
                          let startTime = row["startTime"] as? Date,
                          let endTime = row["endTime"] as? Date else {
                        return nil
                    }
                    
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
            usages = records
            lastRefresh = Date()
        } catch {
            print("Failed to refresh data: \(error)")
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
}
