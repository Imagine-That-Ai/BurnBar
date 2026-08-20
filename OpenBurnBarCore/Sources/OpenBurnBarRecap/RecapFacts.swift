import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

// MARK: - Component types

/// One entry in a ranked dimension (model, provider, project, pairing).
public struct RecapShare: Codable, Hashable, Sendable, Identifiable {
    /// Stable key for matching across months (raw provider key, model id, …).
    public let key: String
    /// What the card shows.
    public let label: String
    public let costUSD: Double
    public let tokens: Int
    public let sessions: Int
    /// Fraction of the month's total cost, 0…1.
    public let costShare: Double
    /// Fraction of the month's sessions, 0…1.
    public let sessionShare: Double

    public var id: String { key }

    public init(
        key: String,
        label: String,
        costUSD: Double,
        tokens: Int,
        sessions: Int,
        costShare: Double,
        sessionShare: Double
    ) {
        self.key = key
        self.label = label
        self.costUSD = costUSD
        self.tokens = tokens
        self.sessions = sessions
        self.costShare = costShare
        self.sessionShare = sessionShare
    }
}

/// A name with an occurrence count — tools, commands.
public struct RecapCount: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let count: Int
    /// Fraction of the sessions that mention it, 0…1.
    public let share: Double

    public var id: String { name }

    public init(name: String, count: Int, share: Double) {
        self.name = name
        self.count = count
        self.share = share
    }
}

/// Shape of the month's sessions.
public struct RecapSessionStats: Codable, Hashable, Sendable {
    public let count: Int
    public let medianSeconds: Double
    public let p90Seconds: Double
    public let meanSeconds: Double
    public let totalSeconds: Double
    public let medianCostUSD: Double

    public static let empty = RecapSessionStats(
        count: 0, medianSeconds: 0, p90Seconds: 0, meanSeconds: 0, totalSeconds: 0, medianCostUSD: 0
    )

    public init(
        count: Int,
        medianSeconds: Double,
        p90Seconds: Double,
        meanSeconds: Double,
        totalSeconds: Double,
        medianCostUSD: Double
    ) {
        self.count = count
        self.medianSeconds = medianSeconds
        self.p90Seconds = p90Seconds
        self.meanSeconds = meanSeconds
        self.totalSeconds = totalSeconds
        self.medianCostUSD = medianCostUSD
    }
}

/// The single most notable session of the month.
public struct RecapSessionHighlight: Codable, Hashable, Sendable {
    public let sessionID: String
    public let projectName: String?
    public let model: String
    public let providerKey: String
    public let startTime: Date
    public let durationSeconds: Double
    public let costUSD: Double
    public let tokens: Int

    public init(
        sessionID: String,
        projectName: String?,
        model: String,
        providerKey: String,
        startTime: Date,
        durationSeconds: Double,
        costUSD: Double,
        tokens: Int
    ) {
        self.sessionID = sessionID
        self.projectName = projectName
        self.model = model
        self.providerKey = providerKey
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

/// A standout day within the month.
public struct RecapDayHighlight: Codable, Hashable, Sendable {
    /// 0-based index into the month.
    public let dayIndex: Int
    public let date: Date
    public let costUSD: Double
    public let tokens: Int
    public let sessions: Int

    public init(dayIndex: Int, date: Date, costUSD: Double, tokens: Int, sessions: Int) {
        self.dayIndex = dayIndex
        self.date = date
        self.costUSD = costUSD
        self.tokens = tokens
        self.sessions = sessions
    }
}

/// The busiest seven consecutive days — a sliding window, not a calendar week,
/// so the answer reads the way a person would say it ("August 8–14").
public struct RecapWeekHighlight: Codable, Hashable, Sendable {
    public let startDayIndex: Int
    public let endDayIndex: Int
    public let startDate: Date
    public let endDate: Date
    public let costUSD: Double
    public let sessions: Int

    public init(
        startDayIndex: Int,
        endDayIndex: Int,
        startDate: Date,
        endDate: Date,
        costUSD: Double,
        sessions: Int
    ) {
        self.startDayIndex = startDayIndex
        self.endDayIndex = endDayIndex
        self.startDate = startDate
        self.endDate = endDate
        self.costUSD = costUSD
        self.sessions = sessions
    }
}

// MARK: - Facts

/// The deterministic aggregate of one calendar month.
///
/// Every number the recap will ever show comes from here. The LLM layer reads a
/// sanitized projection of it and writes prose; it never contributes a figure.
///
/// Persisted per month by `RecapHistoryStore`, which is what makes
/// month-over-month and all-time comparisons cheap: comparing two months is
/// comparing two of these, not re-reading a year of raw rows.
///
/// Real project names are kept because this value is displayed locally to the
/// person whose data it is. `RecapPromptPayload` is the separate, narrower
/// projection permitted to leave the device.
public struct RecapFacts: Codable, Hashable, Sendable {

    /// Bumped whenever the fold changes shape or meaning. Stored facts with a
    /// different version are recomputed where the raw rows are still reachable
    /// and dropped where they are not — a missing month narrows comparisons,
    /// which every rule already tolerates, rather than corrupting them.
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let window: RecapWindow
    public let builtAt: Date

    /// True when the source could not read the whole month. Suppresses every
    /// total, record and "most ever" downstream.
    public let isPartial: Bool
    /// Whether conversation-level rows were available at all on this platform.
    public let hasSessionData: Bool
    /// Share of cost with exact provenance, 0…1.
    public let exactShare: Double

    // MARK: Totals

    public let totalCostUSD: Double
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let sessionCount: Int
    /// Days in the month with any activity.
    public let activeDayCount: Int
    /// Days in the month (28–31).
    public let dayCount: Int

    // MARK: Series (all aligned to `dayCount`)

    public let dailyCost: [Double]
    public let dailyTokens: [Int]
    public let dailySessions: [Int]

    /// 7×24 cost matrix; row 0 = Sunday, matching Gregorian weekday order.
    public let hourWeekdayCost: [[Double]]
    /// 24 buckets.
    public let hourCost: [Double]
    /// 7 buckets, index 0 = Sunday.
    public let weekdayCost: [Double]
    /// 7 buckets of session counts, index 0 = Sunday.
    public let weekdaySessions: [Int]

    // MARK: Ranked dimensions (descending by cost)

    public let models: [RecapShare]
    public let providers: [RecapShare]
    public let projects: [RecapShare]
    /// "model × harness" pairings — the combination the brief cares about.
    public let pairings: [RecapShare]
    public let tools: [RecapCount]

    // MARK: Session shape

    public let sessionStats: RecapSessionStats
    public let longestSession: RecapSessionHighlight?
    public let busiestDay: RecapDayHighlight?
    public let busiestWeek: RecapWeekHighlight?
    public let peakHour: Int?
    public let peakWeekday: Int?

    // MARK: Streaks

    public let longestActiveStreak: Int

    // MARK: Identity sets (sorted for stable encoding)

    public let modelKeys: [String]
    public let providerKeys: [String]
    public let projectKeys: [String]
    public let toolKeys: [String]

    // MARK: Derived ratios

    public let cacheHitRate: Double
    /// Herfindahl–Hirschman index over model cost shares, 0…1.
    /// 1 = one model did everything; near 0 = evenly spread.
    public let modelConcentration: Double
    public let weekendCostShare: Double
    /// 00:00–05:59 local.
    public let lateNightCostShare: Double
    /// 06:00–11:59 local.
    public let morningCostShare: Double
    /// 18:00–23:59 local.
    public let eveningCostShare: Double

    public init(
        schemaVersion: Int = RecapFacts.currentSchemaVersion,
        window: RecapWindow,
        builtAt: Date,
        isPartial: Bool,
        hasSessionData: Bool,
        exactShare: Double,
        totalCostUSD: Double,
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        sessionCount: Int,
        activeDayCount: Int,
        dayCount: Int,
        dailyCost: [Double],
        dailyTokens: [Int],
        dailySessions: [Int],
        hourWeekdayCost: [[Double]],
        hourCost: [Double],
        weekdayCost: [Double],
        weekdaySessions: [Int],
        models: [RecapShare],
        providers: [RecapShare],
        projects: [RecapShare],
        pairings: [RecapShare],
        tools: [RecapCount],
        sessionStats: RecapSessionStats,
        longestSession: RecapSessionHighlight?,
        busiestDay: RecapDayHighlight?,
        busiestWeek: RecapWeekHighlight?,
        peakHour: Int?,
        peakWeekday: Int?,
        longestActiveStreak: Int,
        modelKeys: [String],
        providerKeys: [String],
        projectKeys: [String],
        toolKeys: [String],
        cacheHitRate: Double,
        modelConcentration: Double,
        weekendCostShare: Double,
        lateNightCostShare: Double,
        morningCostShare: Double,
        eveningCostShare: Double
    ) {
        self.schemaVersion = schemaVersion
        self.window = window
        self.builtAt = builtAt
        self.isPartial = isPartial
        self.hasSessionData = hasSessionData
        self.exactShare = exactShare
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.sessionCount = sessionCount
        self.activeDayCount = activeDayCount
        self.dayCount = dayCount
        self.dailyCost = dailyCost
        self.dailyTokens = dailyTokens
        self.dailySessions = dailySessions
        self.hourWeekdayCost = hourWeekdayCost
        self.hourCost = hourCost
        self.weekdayCost = weekdayCost
        self.weekdaySessions = weekdaySessions
        self.models = models
        self.providers = providers
        self.projects = projects
        self.pairings = pairings
        self.tools = tools
        self.sessionStats = sessionStats
        self.longestSession = longestSession
        self.busiestDay = busiestDay
        self.busiestWeek = busiestWeek
        self.peakHour = peakHour
        self.peakWeekday = peakWeekday
        self.longestActiveStreak = longestActiveStreak
        self.modelKeys = modelKeys
        self.providerKeys = providerKeys
        self.projectKeys = projectKeys
        self.toolKeys = toolKeys
        self.cacheHitRate = cacheHitRate
        self.modelConcentration = modelConcentration
        self.weekendCostShare = weekendCostShare
        self.lateNightCostShare = lateNightCostShare
        self.morningCostShare = morningCostShare
        self.eveningCostShare = eveningCostShare
    }

    // MARK: - Convenience

    /// True when the month has no usage at all.
    public var isEmpty: Bool { sessionCount == 0 && totalCostUSD == 0 && totalTokens == 0 }

    /// Whether this month carries enough signal to be worth a recap at all.
    /// Below this the surface shows a single "unlocks with more history" card
    /// rather than a deck padded with nothing.
    public var meetsMinimumSubstance: Bool { activeDayCount >= 5 && sessionCount >= 5 }

    public var topModel: RecapShare? { models.first }
    public var topProject: RecapShare? { projects.first }
    public var topPairing: RecapShare? { pairings.first }

    public func project(key: String) -> RecapShare? { projects.first { $0.key == key } }
    public func provider(key: String) -> RecapShare? { providers.first { $0.key == key } }
}
