import Foundation
import GRDB
import SwiftUI
import OpenBurnBarCore

// MARK: - Device Record

enum DeviceHardwareIcon {
    /// All SF Symbols available for device icon customization.
    static let allIcons: [(symbol: String, label: String)] = [
        ("macbook", "MacBook"),
        ("macmini", "Mac mini"),
        ("macpro.gen3", "Mac Pro"),
        ("macstudio", "Mac Studio"),
        ("desktopcomputer", "iMac / Desktop"),
        ("display", "Display"),
        ("laptopcomputer", "Laptop"),
        ("server.rack", "Server"),
        ("cpu", "Workstation"),
        ("terminal", "Terminal"),
    ]

    // Apple Silicon Macs use generic "MacXX,YY" identifiers.
    // This table maps known model numbers to device types.
    private static let genericMacMap: [String: String] = [
        "mac16,1": "macmini", "mac16,2": "macmini", "mac16,3": "macmini",
        "mac16,4": "macmini", "mac16,5": "macmini", "mac16,10": "macmini",
        "mac16,11": "macmini", "mac16,12": "macmini",
        "mac16,6": "macbook", "mac16,7": "macbook", "mac16,8": "macbook",
        "mac16,9": "macbook",
        "mac16,13": "macbook", "mac16,14": "macbook", "mac16,15": "macbook",
        "mac16,16": "desktopcomputer", "mac16,17": "desktopcomputer",
        "mac16,20": "macstudio", "mac16,21": "macstudio",
        "mac14,8": "macpro.gen3",
        "mac14,13": "macstudio", "mac14,14": "macstudio",
        "mac14,3": "macmini", "mac14,12": "macmini",
        "mac13,1": "macstudio", "mac13,2": "macstudio",
        "mac14,1": "macmini",
        "mac15,3": "macbook", "mac15,6": "macbook", "mac15,7": "macbook",
        "mac15,8": "macbook", "mac15,9": "macbook", "mac15,10": "macbook",
        "mac15,11": "macbook",
        "mac15,12": "macbook", "mac15,13": "macbook",
        "mac15,4": "desktopcomputer", "mac15,5": "desktopcomputer",
    ]

    static func sfSymbol(for hardwareModel: String?) -> String {
        guard let hw = hardwareModel?.lowercased() else { return "desktopcomputer" }

        if hw.hasPrefix("macbookpro") || hw.hasPrefix("macbookair") || hw.hasPrefix("macbook") {
            return "macbook"
        }
        if hw.hasPrefix("macmini") {
            return "macmini"
        }
        if hw.hasPrefix("macpro") {
            return "macpro.gen3"
        }
        if hw.hasPrefix("imac") {
            return "desktopcomputer"
        }

        if let mapped = genericMacMap[hw] {
            return mapped
        }

        let hostName = (Host.current().localizedName ?? "").lowercased()
        if hostName.contains("macbook") || hostName.contains("laptop") { return "macbook" }
        if hostName.contains("mini") { return "macmini" }
        if hostName.contains("studio") { return "macstudio" }
        if hostName.contains("imac") { return "desktopcomputer" }
        if hostName.contains("pro") && !hostName.contains("book") { return "macpro.gen3" }

        return "desktopcomputer"
    }

    /// Reads the hardware model identifier from sysctl.
    static var localHardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}

// MARK: - DataStore

@Observable
@MainActor
final class DataStore {
    nonisolated static let legacyChatThreadID = "openburnbar-chat-legacy"

    let dbQueue: DatabaseQueue
    let database: OpenBurnBarDatabase
    let usageStore: UsageStore
    let conversationStore: ConversationStore
    let searchIndexStore: SearchIndexStore
    let artifactStore: ArtifactStore
    let projectionStore: ProjectionStore
    let controlPlaneStore: ControlPlaneStore
    let deviceStore: DeviceStore
    let checkpointStore: ParserCheckpointStore

    private(set) var usages: [TokenUsage] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?
    private(set) var rollingDailyAverage: Double = 0

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

    var moodBand: MoodBand {
        let calendar = Calendar.current
        let distinctDays = Set(usages.map { calendar.startOfDay(for: $0.startTime) })
        guard distinctDays.count >= 2 else { return .baseline }
        let today = totalCostToday
        guard today > 0 else { return .quiet }
        guard rollingDailyAverage > 0 else { return .onPace }
        switch today / rollingDailyAverage {
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
        Self.makeProviderSummaries(from: usages)
    }

    var hasEstimatedProviders: Bool {
        providerSummaries.contains { $0.provider.dataConfidence != .exact }
    }

    func providerSummaries(in dateRange: ClosedRange<Date>?) -> [ProviderSummary] {
        Self.makeProviderSummaries(from: usages(in: dateRange))
    }

    private static func makeProviderSummaries(from usages: [TokenUsage]) -> [ProviderSummary] {
        AgentProvider.allCases.compactMap { provider -> ProviderSummary? in
            let providerUsages = usages.filter { $0.provider == provider }
            guard !providerUsages.isEmpty else { return nil }

            let totalCost = providerUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = providerUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = providerUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = providerUsages.reduce(0) { $0 + $1.outputTokens }

            var modelData: [String: (input: Int, output: Int, cacheCreation: Int, cacheRead: Int, reasoning: Int, cost: Double)] = [:]
            for usage in providerUsages {
                let existing = modelData[usage.model] ?? (0, 0, 0, 0, 0, 0)
                modelData[usage.model] = (
                    existing.0 + usage.inputTokens,
                    existing.1 + usage.outputTokens,
                    existing.2 + usage.cacheCreationTokens,
                    existing.3 + usage.cacheReadTokens,
                    existing.4 + usage.reasoningTokens,
                    existing.5 + usage.cost
                )
            }

            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.0 + data.1 + data.2 + data.3 + data.4
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.0,
                    outputTokens: data.1,
                    cacheCreationTokens: data.2,
                    cacheReadTokens: data.3,
                    reasoningTokens: data.4,
                    totalTokens: totalModelTokens,
                    cost: data.5,
                    percentage: totalCost > 0 ? (data.5 / totalCost) * 100 : 0
                )
            }
            .sorted { $0.cost > $1.cost }

            return ProviderSummary(
                provider: provider,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: providerUsages.count,
                modelBreakdown: modelBreakdown
            )
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    // MARK: - Model Summaries

    var modelSummaries: [ModelSummary] {
        Self.makeModelSummaries(from: usages)
    }

    func modelSummaries(in dateRange: ClosedRange<Date>?) -> [ModelSummary] {
        Self.makeModelSummaries(from: usages(in: dateRange))
    }

    private static func makeModelSummaries(from usages: [TokenUsage]) -> [ModelSummary] {
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
            let providerBreakdown = byProvider.map { provider, providerUsages -> ProviderUsage in
                let providerCost = providerUsages.reduce(0) { $0 + $1.cost }
                let providerTokens = providerUsages.reduce(0) { $0 + $1.totalTokens }
                return ProviderUsage(
                    provider: provider,
                    sessionCount: providerUsages.count,
                    totalTokens: providerTokens,
                    cost: providerCost,
                    percentage: totalCost > 0 ? (providerCost / totalCost) * 100 : 0
                )
            }
            .sorted { $0.cost > $1.cost }

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
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    func usages(in dateRange: ClosedRange<Date>?) -> [TokenUsage] {
        guard let dateRange else { return usages }
        return usages.filter { $0.intersects(dateRange: dateRange) }
    }

    func usages(forModel normalizedName: String) -> [TokenUsage] {
        usages.filter { TokenExtractionUtility.normalizeModelKey($0.model) == normalizedName }
    }

    func usages(forModel normalizedName: String, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usages.filter {
            TokenExtractionUtility.normalizeModelKey($0.model) == normalizedName
            && $0.intersects(dateRange: dateRange)
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
        }
        .sorted { $0.date > $1.date }
    }

    func usages(for provider: AgentProvider) -> [TokenUsage] {
        usages.filter { $0.provider == provider }
    }

    func usages(for provider: AgentProvider, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usages.filter { $0.provider == provider && $0.intersects(dateRange: dateRange) }
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

    // MARK: - Initialization

    convenience init() throws {
        let appDir = try OpenBurnBarMigration.prepareSupportDirectory()
        let dbPath = appDir.appendingPathComponent(OpenBurnBarIdentity.databaseFileName).path
        let queue = try DatabaseQueue(path: dbPath)
        try self.init(databaseQueue: queue)
    }

    init(
        databaseQueue: DatabaseQueue,
        runMigrations: Bool = true,
        refreshOnInit: Bool = true
    ) throws {
        dbQueue = databaseQueue
        database = OpenBurnBarDatabase(databaseQueue: databaseQueue)
        usageStore = UsageStore(dbQueue: databaseQueue)
        conversationStore = ConversationStore(dbQueue: databaseQueue)
        searchIndexStore = SearchIndexStore(dbQueue: databaseQueue)
        artifactStore = ArtifactStore(dbQueue: databaseQueue)
        projectionStore = ProjectionStore(dbQueue: databaseQueue)
        controlPlaneStore = ControlPlaneStore(dbQueue: databaseQueue)
        deviceStore = DeviceStore(dbQueue: databaseQueue)
        checkpointStore = ParserCheckpointStore(dbQueue: databaseQueue)

        if runMigrations {
            try database.runMigrations()
        }

        if refreshOnInit {
            refresh()
        }
    }

    // MARK: - Cache Refresh

    func replaceUsages(_ newUsages: [TokenUsage]) {
        usages = newUsages.sorted { $0.startTime > $1.startTime }
        rollingDailyAverage = computeRollingAverage()
        lastRefresh = Date()
    }

    func refresh() {
        isLoading = true

        do {
            let records = try usageStore.fetchAllUsage()
            replaceUsages(records)
        } catch {
            print("DataStore: Failed to refresh data: \(error)")
        }

        isLoading = false
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
}
