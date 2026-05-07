import Foundation

// MARK: - Sentiment

enum Sentiment: String, Codable, CaseIterable, Sendable {
    case positive
    case neutral
    case negative
}

// MARK: - Insight Type

enum InsightType: String, Codable, CaseIterable, Equatable, Sendable {
    case costChange = "cost_change"
    case newSessions = "new_sessions"
    case rankMovement = "rank_movement"
    case modelShift = "model_shift"
    case neutral
    case narrative
    case cacheEfficiency = "cache_efficiency"
}

// MARK: - Insight

struct Insight: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let type: InsightType
    let icon: String
    let sentiment: Sentiment
    let headline: String
    let detail: String?
    let metric: Double?
    let delta: Double?

    init(
        id: UUID = UUID(),
        type: InsightType,
        icon: String,
        sentiment: Sentiment,
        headline: String,
        detail: String? = nil,
        metric: Double? = nil,
        delta: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.icon = icon
        self.sentiment = sentiment
        self.headline = headline
        self.detail = detail
        self.metric = metric
        self.delta = delta
    }
}

// MARK: - Materialized Rollups

enum InsightRollupFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case rebuilding
    case unavailable
}

struct WorkflowInsightRollupSnapshot: Equatable, Sendable {
    let insights: [Insight]
    let freshness: InsightRollupFreshness
    let computedAt: Date?
    let statusMessage: String?

    static let unavailable = WorkflowInsightRollupSnapshot(
        insights: [],
        freshness: .unavailable,
        computedAt: nil,
        statusMessage: "Workflow insights are unavailable until OpenBurnBar has indexed enough activity."
    )
}

private struct MaterializedInsightRollupPayload: Codable, Sendable {
    let schemaVersion: Int
    let insights: [Insight]
    let computedAt: Date
    let latestUsageAt: Date?
    let latestIndexedAt: Date?
}

private struct RollupContext {
    let latestUsageAt: Date?
    let latestIndexedAt: Date?
    let pendingJobCount: Int
    let failedJobCount: Int
    let rebuildInProgress: Bool
    let hasInputs: Bool
}

@MainActor
final class WorkflowInsightRollupService {
    private let dataStore: DataStore
    private let nowProvider: () -> Date

    init(dataStore: DataStore, nowProvider: @escaping () -> Date = Date.init) {
        self.dataStore = dataStore
        self.nowProvider = nowProvider
    }

    func snapshot(refreshIfStale: Bool = true) -> WorkflowInsightRollupSnapshot {
        let context: RollupContext
        do {
            context = try buildContext()
        } catch {
            let message = "Workflow insights are unavailable: \(error.localizedDescription)"
            do {
                try upsertHealth(
                    payload: nil,
                    status: .failed,
                    errorCode: "INSIGHT_ROLLUP_CONTEXT_FAILED",
                    errorMessage: message
                )
            } catch {
                AppLogger.dataStore.silentFailure("upsertHealth", error: error)
            }
            return WorkflowInsightRollupSnapshot(
                insights: [],
                freshness: .unavailable,
                computedAt: nil,
                statusMessage: message
            )
        }

        var payload = loadMaterializedPayload()
        var freshness = freshness(for: payload, context: context)

        let canRefreshSynchronously = context.hasInputs
            && context.rebuildInProgress == false
            && context.pendingJobCount == 0
            && context.failedJobCount == 0

        if refreshIfStale, freshness == .stale, canRefreshSynchronously {
            do {
                let refreshed = try materialize(context: context)
                payload = refreshed
                freshness = .fresh
            } catch {
                let message = "Workflow insights could not refresh: \(error.localizedDescription)"
                do {
                    try upsertHealth(
                        payload: payload,
                        status: .failed,
                        errorCode: "INSIGHT_ROLLUP_MATERIALIZE_FAILED",
                        errorMessage: message
                    )
                } catch {
                    AppLogger.dataStore.silentFailure("upsertHealth", error: error)
                }
                return WorkflowInsightRollupSnapshot(
                    insights: payload?.insights ?? [],
                    freshness: payload == nil ? .unavailable : .stale,
                    computedAt: payload?.computedAt,
                    statusMessage: message
                )
            }
        }

        let status = healthStatus(for: freshness)
        do {
            try upsertHealth(
                payload: payload,
                status: status,
                errorCode: nil,
                errorMessage: nil
            )
        } catch {
            AppLogger.dataStore.silentFailure("upsertHealth", error: error)
        }

        return WorkflowInsightRollupSnapshot(
            insights: payload?.insights ?? [],
            freshness: freshness,
            computedAt: payload?.computedAt,
            statusMessage: statusMessage(for: freshness, context: context)
        )
    }

    private func buildContext() throws -> RollupContext {
        let pendingCount = try dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])
        let failedCount = try dataStore.countProjectionJobs(statuses: [.failed, .canceled])
        let rebuildInProgress = try dataStore.hasProjectionJobs(
            statuses: [.queued, .leased, .running],
            jobTypes: [.rebuild, .reembed]
        )
        let latestIndexedAt = try dataStore.fetchSearchDocuments(limit: 1).first?.indexedAt
        let latestUsageAt = dataStore.usages.map(\.endTime).max()
        let hasInputs = dataStore.totalUsageSessionCount > 0 || latestIndexedAt != nil
        return RollupContext(
            latestUsageAt: latestUsageAt,
            latestIndexedAt: latestIndexedAt,
            pendingJobCount: pendingCount,
            failedJobCount: failedCount,
            rebuildInProgress: rebuildInProgress,
            hasInputs: hasInputs
        )
    }

    private func freshness(
        for payload: MaterializedInsightRollupPayload?,
        context: RollupContext
    ) -> InsightRollupFreshness {
        if context.rebuildInProgress {
            return .rebuilding
        }

        guard let payload else {
            return context.hasInputs ? .stale : .unavailable
        }

        if context.pendingJobCount > 0 || context.failedJobCount > 0 {
            return .stale
        }
        if let latestUsageAt = context.latestUsageAt, latestUsageAt > payload.computedAt {
            return .stale
        }
        if let latestIndexedAt = context.latestIndexedAt, latestIndexedAt > payload.computedAt {
            return .stale
        }
        return .fresh
    }

    private func materialize(context: RollupContext) throws -> MaterializedInsightRollupPayload {
        let computedAt = nowProvider()
        let payload = MaterializedInsightRollupPayload(
            schemaVersion: 1,
            insights: InsightEngine.generate(from: dataStore),
            computedAt: computedAt,
            latestUsageAt: context.latestUsageAt,
            latestIndexedAt: context.latestIndexedAt
        )
        try upsertHealth(payload: payload, status: .healthy, errorCode: nil, errorMessage: nil)
        return payload
    }

    private func loadMaterializedPayload() -> MaterializedInsightRollupPayload? {
        guard
            let row = try? dataStore.fetchRetrievalHealth().first(where: { $0.subsystem == .insightRollups }),
            let json = row.detailsJSON?.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(MaterializedInsightRollupPayload.self, from: json)
    }

    private func upsertHealth(
        payload: MaterializedInsightRollupPayload?,
        status: RetrievalHealthStatus,
        errorCode: String?,
        errorMessage: String?
    ) throws {
        let detailsJSON: String?
        if let payload {
            let data = try JSONEncoder().encode(payload)
            detailsJSON = String(data: data, encoding: .utf8)
        } else {
            detailsJSON = nil
        }
        let now = nowProvider()
        try dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .insightRollups,
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )
    }

    private func healthStatus(for freshness: InsightRollupFreshness) -> RetrievalHealthStatus {
        switch freshness {
        case .fresh:
            return .healthy
        case .stale, .rebuilding:
            return .degraded
        case .unavailable:
            return .failed
        }
    }

    private func statusMessage(for freshness: InsightRollupFreshness, context: RollupContext) -> String? {
        switch freshness {
        case .fresh:
            return nil
        case .stale:
            if context.failedJobCount > 0 {
                return "Workflow insights are stale because \(context.failedJobCount) projection job(s) failed."
            }
            if context.pendingJobCount > 0 {
                return "Workflow insights are stale while \(context.pendingJobCount) projection job(s) catch up."
            }
            return "Workflow insights are stale and will refresh on the next projection sweep."
        case .rebuilding:
            return "Workflow insights are rebuilding while projection and re-embedding complete."
        case .unavailable:
            return "Workflow insights are unavailable until OpenBurnBar has indexed enough activity."
        }
    }
}

// MARK: - InsightEngine

@MainActor
enum InsightEngine {

    static func generate(from dataStore: DataStore) -> [Insight] {
        let calendar = Calendar.current
        let now = Date()
        let usages = dataStore.usages

        guard !usages.isEmpty else { return [] }

        let todayUsages = usages.filter { calendar.isDateInToday($0.startTime) }
        let distinctDays = Set(usages.map { calendar.startOfDay(for: $0.startTime) })

        guard distinctDays.count >= 2 else { return [] }

        guard !todayUsages.isEmpty else { return [] }

        var insights: [Insight] = []

        // Cache efficiency (today)
        let cacheTokens = todayUsages.reduce(0) { $0 + $1.cacheReadTokens }
        let totalTokens = todayUsages.reduce(0) { $0 + $1.totalTokens }
        if totalTokens > 0, Double(cacheTokens) / Double(totalTokens) > 0.5 {
            let pct = Double(cacheTokens) / Double(totalTokens) * 100
            insights.append(
                Insight(
                    type: .cacheEfficiency,
                    icon: "externaldrive.fill.badge.icloud",
                    sentiment: .positive,
                    headline: "Cache-heavy day",
                    detail: String(format: "%.0f%% of tokens from cache reads — lower effective cost.", pct),
                    metric: pct,
                    delta: nil
                )
            )
        }

        let todayCost = todayUsages.reduce(0.0) { $0 + $1.cost }
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let yesterdayEnd = calendar.startOfDay(for: now)
        let yesterdayUsages = usages.filter { $0.startTime >= yesterdayStart && $0.startTime < yesterdayEnd }
        let yesterdayCost = yesterdayUsages.reduce(0.0) { $0 + $1.cost }

        if yesterdayCost > 0 {
            let deltaPct = ((todayCost - yesterdayCost) / yesterdayCost) * 100
            let absDelta = abs(deltaPct)
            if deltaPct > 0 {
                insights.append(
                    Insight(
                        type: .costChange,
                        icon: "chart.line.uptrend.xyaxis",
                        sentiment: .negative,
                        headline: String(format: "Spend up %.0f%% vs yesterday", absDelta),
                        detail: "\(todayCost.formatAsCost()) today vs \(yesterdayCost.formatAsCost()) yesterday",
                        metric: todayCost,
                        delta: deltaPct
                    )
                )
            } else if deltaPct < 0 {
                insights.append(
                    Insight(
                        type: .costChange,
                        icon: "arrow.down.circle.fill",
                        sentiment: .positive,
                        headline: String(format: "Spend down %.0f%% vs yesterday", absDelta),
                        detail: "\(todayCost.formatAsCost()) today vs \(yesterdayCost.formatAsCost()) yesterday",
                        metric: todayCost,
                        delta: deltaPct
                    )
                )
            }
        }

        let todayProviders = Set(todayUsages.map { $0.provider })
        let todaySessionCount = distinctSessionCount(in: todayUsages)
        insights.append(
            Insight(
                type: .newSessions,
                icon: "bolt.fill",
                sentiment: .neutral,
                headline: "\(todaySessionCount) new session\(todaySessionCount == 1 ? "" : "s") today",
                detail: "Across \(todayProviders.count) provider\(todayProviders.count == 1 ? "" : "s")",
                metric: Double(todaySessionCount),
                delta: nil
            )
        )

        if let topToday = topProvider(in: todayUsages),
           let topOverall = topProvider(in: usages),
           topToday != topOverall {
            insights.append(
                Insight(
                    type: .rankMovement,
                    icon: "trophy.fill",
                    sentiment: .neutral,
                    headline: "\(topToday.displayName) leads today",
                    detail: "\(topOverall.displayName) is your all-time top spend",
                    metric: nil,
                    delta: nil
                )
            )
        }

        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))!
        let recentPastUsages = usages.filter {
            $0.startTime >= weekAgo && $0.startTime < calendar.startOfDay(for: now)
        }
        let pastModels = Set(recentPastUsages.map { $0.model })
        let todayModels = Set(todayUsages.map { $0.model })
        let newModels = todayModels.subtracting(pastModels)

        for model in newModels.sorted() {
            insights.append(
                Insight(
                    type: .modelShift,
                    icon: "sparkles",
                    sentiment: .neutral,
                    headline: "First sessions with \(model)",
                    detail: "New model activity vs your last 7 days",
                    metric: nil,
                    delta: nil
                )
            )
        }

        return insights
    }

    static func generateNarrative(from dataStore: DataStore) -> Insight {
        let usages = dataStore.usages
        let calendar = Calendar.current
        let todayUsages = usages.filter { calendar.isDateInToday($0.startTime) }
        let hour = calendar.component(.hour, from: Date())
        let timeLabel = hour < 12 ? "morning" : hour < 17 ? "afternoon" : "evening"

        if usages.isEmpty {
            return Insight(
                type: .narrative,
                icon: "moon.stars.fill",
                sentiment: .neutral,
                headline: "No sessions recorded yet",
                detail: "Run a scan to import sessions from your AI coding agents.",
                metric: nil,
                delta: nil
            )
        }

        if todayUsages.isEmpty {
            let total = distinctSessionCount(in: usages)
            return Insight(
                type: .narrative,
                icon: "bed.double.fill",
                sentiment: .neutral,
                headline: "Quiet \(timeLabel)",
                detail: "\(total) session\(total == 1 ? "" : "s") tracked in total.",
                metric: nil,
                delta: nil
            )
        }

        let n = distinctSessionCount(in: todayUsages)
        let cost = todayUsages.reduce(0.0) { $0 + $1.cost }
        let providers = Set(todayUsages.map { $0.provider.displayName })
        let providerList = providers.sorted().joined(separator: " & ")
        var detail: String?

        let cacheTokens = todayUsages.reduce(0) { $0 + $1.cacheReadTokens }
        let totalTokens = todayUsages.reduce(0) { $0 + $1.totalTokens }
        if totalTokens > 0, Double(cacheTokens) / Double(totalTokens) > 0.5 {
            detail = "Cache hits are covering over half your tokens — solid savings."
        }

        let headline: String
        if n == 1 {
            headline = "One \(timeLabel) session on \(providerList)"
        } else {
            headline = "\(n) sessions so far this \(timeLabel) across \(providerList)"
        }

        let sentiment: Sentiment =
            dataStore.moodBand == .heavy ? .negative :
            dataStore.moodBand == .light ? .positive : .neutral

        return Insight(
            type: .narrative,
            icon: "text.quote",
            sentiment: sentiment,
            headline: headline,
            detail: detail,
            metric: cost,
            delta: nil
        )
    }

    private static func distinctSessionCount(in usages: [TokenUsage]) -> Int {
        Set(usages.map { usage in
            "\(usage.provider.rawValue)|\(canonicalSessionID(for: usage))"
        }).count
    }

    private static func canonicalSessionID(for usage: TokenUsage) -> String {
        if usage.provider == .claudeCode {
            return usage.sessionId.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? usage.sessionId
        }
        return usage.sessionId
    }

    private static func topProvider(in usages: [TokenUsage]) -> AgentProvider? {
        var costs: [AgentProvider: Double] = [:]
        for usage in usages {
            costs[usage.provider, default: 0] += usage.cost
        }
        return costs.max { $0.value < $1.value }?.key
    }
}
