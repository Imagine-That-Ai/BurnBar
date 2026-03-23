import Foundation

// MARK: - Sentiment

enum Sentiment {
    case positive
    case neutral
    case negative
}

// MARK: - Insight Type

enum InsightType: Equatable {
    case costChange
    case newSessions
    case rankMovement
    case modelShift
    case neutral
    case narrative
    case cacheEfficiency
}

// MARK: - Insight

struct Insight: Identifiable {
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
        insights.append(
            Insight(
                type: .newSessions,
                icon: "bolt.fill",
                sentiment: .neutral,
                headline: "\(todayUsages.count) new session\(todayUsages.count == 1 ? "" : "s") today",
                detail: "Across \(todayProviders.count) provider\(todayProviders.count == 1 ? "" : "s")",
                metric: Double(todayUsages.count),
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
            let total = usages.count
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

        let n = todayUsages.count
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

    private static func topProvider(in usages: [TokenUsage]) -> AgentProvider? {
        var costs: [AgentProvider: Double] = [:]
        for usage in usages {
            costs[usage.provider, default: 0] += usage.cost
        }
        return costs.max { $0.value < $1.value }?.key
    }
}
