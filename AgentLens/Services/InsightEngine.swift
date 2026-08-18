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
    // `nonisolated` so the snapshot pipeline can run off the main actor:
    // `DataStore` is a `@MainActor` class (hence Sendable) and every store
    // accessor the pipeline touches is itself `nonisolated`.
    private nonisolated let dataStore: DataStore
    private nonisolated let nowProvider: @Sendable () -> Date

    init(dataStore: DataStore, nowProvider: @escaping @Sendable () -> Date = Date.init) {
        self.dataStore = dataStore
        self.nowProvider = nowProvider
    }

    /// Value snapshot of the main-actor state the pipeline needs, captured
    /// once so the GRDB I/O and any stale-path recompute can leave the
    /// main actor.
    private struct MainActorInputs: Sendable {
        let usages: [TokenUsage]
        let latestUsageAt: Date?
        let totalUsageSessionCount: Int
    }

    private func captureInputs() -> MainActorInputs {
        let usages = dataStore.usages
        return MainActorInputs(
            usages: usages,
            latestUsageAt: usages.map(\.endTime).max(),
            totalUsageSessionCount: dataStore.totalUsageSessionCount
        )
    }

    func snapshot(refreshIfStale: Bool = true) -> WorkflowInsightRollupSnapshot {
        WorkflowInsightRollupSnapshot.unavailable
    }

    /// Off-main variant for hot UI paths (popover open, `usagesVersion`
    /// ticks, chat brief refresh): captures the main-actor inputs once,
    /// then runs every GRDB read/write — and the stale-path recompute —
    /// on a background task so the main thread never blocks on SQLite.
    func snapshotAsync(refreshIfStale: Bool = true) async -> WorkflowInsightRollupSnapshot {
        let inputs = captureInputs()
        return await buildSnapshotOffMainActor(inputs: inputs, refreshIfStale: refreshIfStale)
    }

    /// `nonisolated` async bridge so `snapshotAsync` leaves the main actor here
    /// (SE-0338); the synchronous `buildSnapshot` (and all its GRDB work) then
    /// runs entirely off the main actor. `buildSnapshot` stays synchronous for
    /// its other, on-actor caller.
    private nonisolated func buildSnapshotOffMainActor(
        inputs: MainActorInputs,
        refreshIfStale: Bool
    ) async -> WorkflowInsightRollupSnapshot {
        await buildSnapshot(inputs: inputs, refreshIfStale: refreshIfStale)
    }

    private nonisolated func buildSnapshot(
        inputs: MainActorInputs,
        refreshIfStale: Bool
    ) async -> WorkflowInsightRollupSnapshot {
        // Single health-row read feeds both the materialized payload and
        // the write-skip comparison in `upsertHealthIfChanged`.
        let existingHealth = await loadHealthRecord()

        let context: RollupContext
        do {
            context = try await buildContext(inputs: inputs)
        } catch {
            let message = "Workflow insights are unavailable: \(error.localizedDescription)"
            await upsertHealthIfChanged(
                existing: existingHealth,
                payloadJSON: nil,
                status: .failed,
                errorCode: "INSIGHT_ROLLUP_CONTEXT_FAILED",
                errorMessage: message
            )
            return WorkflowInsightRollupSnapshot(
                insights: [],
                freshness: .unavailable,
                computedAt: nil,
                statusMessage: message
            )
        }

        var payload = decodePayload(from: existingHealth)
        // Carry the stored JSON verbatim while the payload is unchanged so
        // the write-skip comparison never trips on encoder nondeterminism.
        var payloadJSON = payload != nil ? existingHealth?.detailsJSON : nil
        var freshness = freshness(for: payload, context: context)

        let canRefreshSynchronously = context.hasInputs
            && context.rebuildInProgress == false
            && context.pendingJobCount == 0
            && context.failedJobCount == 0

        if refreshIfStale, freshness == .stale, canRefreshSynchronously {
            do {
                let refreshed = try materialize(context: context, usages: inputs.usages)
                payload = refreshed.payload
                payloadJSON = refreshed.json
                freshness = .fresh
            } catch {
                let message = "Workflow insights could not refresh: \(error.localizedDescription)"
                await upsertHealthIfChanged(
                    existing: existingHealth,
                    payloadJSON: payloadJSON,
                    status: .failed,
                    errorCode: "INSIGHT_ROLLUP_MATERIALIZE_FAILED",
                    errorMessage: message
                )
                return WorkflowInsightRollupSnapshot(
                    insights: payload?.insights ?? [],
                    freshness: payload == nil ? .unavailable : .stale,
                    computedAt: payload?.computedAt,
                    statusMessage: message
                )
            }
        }

        await upsertHealthIfChanged(
            existing: existingHealth,
            payloadJSON: payloadJSON,
            status: healthStatus(for: freshness),
            errorCode: nil,
            errorMessage: nil
        )

        return WorkflowInsightRollupSnapshot(
            insights: payload?.insights ?? [],
            freshness: freshness,
            computedAt: payload?.computedAt,
            statusMessage: statusMessage(for: freshness, context: context)
        )
    }

    private nonisolated func buildContext(inputs: MainActorInputs) async throws -> RollupContext {
        let pendingCount = try await dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])
        let failedCount = try await dataStore.countProjectionJobs(statuses: [.failed, .canceled])
        let rebuildInProgress = try await dataStore.hasProjectionJobs(
            statuses: [.queued, .leased, .running],
            jobTypes: [.rebuild, .reembed]
        )
        let latestIndexedAt = try await dataStore.fetchSearchDocuments(limit: 1).first?.indexedAt
        let hasInputs = inputs.totalUsageSessionCount > 0 || latestIndexedAt != nil
        return RollupContext(
            latestUsageAt: inputs.latestUsageAt,
            latestIndexedAt: latestIndexedAt,
            pendingJobCount: pendingCount,
            failedJobCount: failedCount,
            rebuildInProgress: rebuildInProgress,
            hasInputs: hasInputs
        )
    }

    private nonisolated func freshness(
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

    /// Builds a fresh payload without persisting it — the single gated
    /// health write in `buildSnapshot` persists the result, so the stale
    /// path no longer writes the health row twice per refresh.
    private nonisolated func materialize(
        context: RollupContext,
        usages: [TokenUsage]
    ) throws -> (payload: MaterializedInsightRollupPayload, json: String?) {
        let computedAt = nowProvider()
        let payload = MaterializedInsightRollupPayload(
            schemaVersion: 1,
            insights: InsightEngine.generate(usages: usages),
            computedAt: computedAt,
            latestUsageAt: context.latestUsageAt,
            latestIndexedAt: context.latestIndexedAt
        )
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8)
        return (payload, json)
    }

    private nonisolated func loadHealthRecord() async -> RetrievalHealthRecord? {
        guard let rows = try? await dataStore.fetchRetrievalHealth() else { return nil } // try?-ok(cache read recovered)
        return rows.first(where: { $0.subsystem == .insightRollups })
    }

    private nonisolated func decodePayload(
        from record: RetrievalHealthRecord?
    ) -> MaterializedInsightRollupPayload? {
        guard let json = record?.detailsJSON?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MaterializedInsightRollupPayload.self, from: json) // try?-ok(optional cache decode)
    }

    /// Persists the insight-rollup health row only when its semantic content
    /// (status, payload JSON, error fields) actually changed. The fresh path
    /// used to rewrite an identical row on every popover open, taking the
    /// DatabasePool single-writer queue for nothing.
    private nonisolated func upsertHealthIfChanged(
        existing: RetrievalHealthRecord?,
        payloadJSON: String?,
        status: RetrievalHealthStatus,
        errorCode: String?,
        errorMessage: String?
    ) async {
        if let existing,
           existing.status == status,
           existing.detailsJSON == payloadJSON,
           existing.errorCode == errorCode,
           existing.errorMessage == errorMessage {
            return
        }
        let now = nowProvider()
        do {
            try await dataStore.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .insightRollups,
                    status: status,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    detailsJSON: payloadJSON,
                    observedAt: now,
                    updatedAt: now
                )
            )
        } catch {
            AppLogger.dataStore.silentFailure("upsertHealth", error: error)
        }
    }

    private nonisolated func healthStatus(for freshness: InsightRollupFreshness) -> RetrievalHealthStatus {
        switch freshness {
        case .fresh:
            return .healthy
        case .stale, .rebuilding:
            return .degraded
        case .unavailable:
            return .failed
        }
    }

    private nonisolated func statusMessage(for freshness: InsightRollupFreshness, context: RollupContext) -> String? {
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
        generate(usages: dataStore.usages)
    }

    /// Value-snapshot variant so the rollup pipeline can run the O(N)
    /// passes over the usage array off the main actor.
    nonisolated static func generate(usages: [TokenUsage]) -> [Insight] {
        let calendar = Calendar.current
        let now = Date()

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
        let yesterdayEnd = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: yesterdayEnd)
            ?? yesterdayEnd.addingTimeInterval(-86_400)
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

        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now).addingTimeInterval(-7 * 86_400)
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

    // MARK: - Daily Digest

    /// The calendar day a digest delivered at `deliveryDate` describes: the
    /// whole day before it.
    ///
    /// The window is anchored to the *delivery* date rather than to "now" on
    /// purpose. `DailyDigestManager` re-arms the pending notification on a
    /// background cadence, so a body is often built hours before it is shown —
    /// sometimes on the previous calendar day. Resolving the window from the
    /// date the digest will actually fire keeps "yesterday" pointing at the
    /// same day regardless of when the text was computed.
    static func digestWindow(
        forDeliveryAt deliveryDate: Date,
        calendar: Calendar = .current
    ) -> Range<Date> {
        let deliveryDayStart = calendar.startOfDay(for: deliveryDate)
        let windowStart = calendar.date(byAdding: .day, value: -1, to: deliveryDayStart)
            ?? deliveryDayStart.addingTimeInterval(-86_400)
        return windowStart..<deliveryDayStart
    }

    /// Name of the day a digest delivered at `deliveryDate` describes.
    ///
    /// The digest names its own day rather than saying "yesterday" because it
    /// cannot control when it is shown: a Mac asleep through the delivery hour
    /// gets the notification on wake, possibly a day or more later, and
    /// "yesterday" would by then point at the wrong day. A weekday name is
    /// still true whenever it arrives.
    static func digestDayName(
        forDeliveryAt deliveryDate: Date,
        calendar: Calendar = .current
    ) -> String {
        let covered = digestWindow(forDeliveryAt: deliveryDate, calendar: calendar).lowerBound
        let symbols = calendar.weekdaySymbols
        let index = calendar.component(.weekday, from: covered) - 1
        guard symbols.indices.contains(index) else { return "Yesterday" }
        return symbols[index]
    }

    /// Builds the daily digest body: a closed-out summary of the day before
    /// `deliveryDate`.
    ///
    /// `generateNarrative` narrates the day *in progress* for the dashboard,
    /// which is the wrong window for a notification — it renders "Quiet
    /// morning" for anyone whose delivery hour lands before they start work.
    /// This summarises a day that has already ended, which is both what the
    /// Settings copy promises and what keeps the text stable between the
    /// moment it is armed and the moment it is delivered.
    static func generateDigestNarrative(
        from usages: [TokenUsage],
        deliveredAt deliveryDate: Date,
        calendar: Calendar = .current
    ) -> Insight {
        let window = digestWindow(forDeliveryAt: deliveryDate, calendar: calendar)
        let dayUsages = usages.filter { window.contains($0.startTime) }
        let dayName = digestDayName(forDeliveryAt: deliveryDate, calendar: calendar)

        guard !dayUsages.isEmpty else {
            return Insight(
                type: .narrative,
                icon: "moon.zzz.fill",
                sentiment: .neutral,
                headline: "No burn \(dayName)",
                detail: usages.isEmpty
                    ? "Run a scan to import sessions from your AI coding agents."
                    : "No agent sessions were recorded.",
                metric: 0,
                delta: nil
            )
        }

        let sessions = distinctSessionCount(in: dayUsages)
        let cost = dayUsages.reduce(0.0) { $0 + $1.cost }
        let providerList = Set(dayUsages.map { $0.provider.displayName })
            .sorted()
            .joined(separator: " & ")

        // The day before the digest window, so the body can answer "is that a
        // lot?" instead of just stating a number. The notification renders
        // headline + detail only, so the cost has to live in the text —
        // `metric` never reaches the user here.
        let priorStart = calendar.date(byAdding: .day, value: -1, to: window.lowerBound)
            ?? window.lowerBound.addingTimeInterval(-86_400)
        let priorCost = usages
            .filter { $0.startTime >= priorStart && $0.startTime < window.lowerBound }
            .reduce(0.0) { $0 + $1.cost }
        let delta: Double? = priorCost > 0 ? (cost - priorCost) / priorCost : nil

        var detail = "\(providerList)."
        if let delta, abs(delta) >= 0.05 {
            let direction = delta > 0 ? "Up" : "Down"
            detail += " \(direction) \(Int((abs(delta) * 100).rounded()))% on the day before."
        }

        let sentiment: Sentiment
        switch delta {
        case .some(let d) where d >= 0.25:  sentiment = .negative
        case .some(let d) where d <= -0.25: sentiment = .positive
        default:                            sentiment = .neutral
        }

        return Insight(
            type: .narrative,
            icon: "text.quote",
            sentiment: sentiment,
            headline: "\(dayName): \(cost.formatAsCost()) across \(sessions) session\(sessions == 1 ? "" : "s")",
            detail: detail,
            metric: cost,
            delta: delta
        )
    }

    private nonisolated static func distinctSessionCount(in usages: [TokenUsage]) -> Int {
        Set(usages.map { usage in
            "\(usage.provider.rawValue)|\(canonicalSessionID(for: usage))"
        }).count
    }

    private nonisolated static func canonicalSessionID(for usage: TokenUsage) -> String {
        if usage.provider == .claudeCode {
            return usage.sessionId.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? usage.sessionId
        }
        return usage.sessionId
    }

    private nonisolated static func topProvider(in usages: [TokenUsage]) -> AgentProvider? {
        var costs: [AgentProvider: Double] = [:]
        for usage in usages {
            costs[usage.provider, default: 0] += usage.cost
        }
        return costs.max { $0.value < $1.value }?.key
    }
}
