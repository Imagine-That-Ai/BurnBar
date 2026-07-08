import Foundation

extension OpenBurnBarOperatingComposer {
    static func filterByPrimaryProject<T>(
        _ items: [T],
        _ primaryProject: String?,
        projectName: (T) -> String
    ) -> [T] {
        guard let primaryProject else { return [] }
        return items.filter { normalizeProjectName(projectName($0)) == primaryProject }
    }
    static func selectProjectFocus(
        conversations: [ConversationRecord],
        usages: [TokenUsage]
    ) -> ProjectFocus {
        var metricsByProject: [String: ProjectSignalMetrics] = [:]
        for (index, conversation) in conversations.enumerated() {
            let project = normalizeProjectName(conversation.projectName)
            guard project.isEmpty == false else { continue }
            let activityDate = latestConversationActivityDate(conversation) ?? conversation.indexedAt
            var metrics = metricsByProject[project] ?? ProjectSignalMetrics(projectName: project)
            metrics.score += Double(max(18 - index, 2))
            metrics.conversationCount += 1
            metrics.lastConversationAt = maxDate([metrics.lastConversationAt, activityDate])
            metrics.lastActivityDate = maxDate([metrics.lastActivityDate, activityDate])
            if activityDate >= Date().addingTimeInterval(-24 * 60 * 60) {
                metrics.recentConversationCount += 1
            }
            if conversation.summary?.nonEmpty != nil || conversation.summaryTitle?.nonEmpty != nil {
                metrics.summarizedConversationCount += 1
            }
            metricsByProject[project] = metrics
        }
        let oneWeekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for usage in usages where usage.startTime >= oneWeekAgo {
            let project = normalizeProjectName(usage.projectName)
            guard project.isEmpty == false else { continue }
            let weight = max(1, min(usage.cost * 6, Double(usage.totalTokens) / 100_000))
            var metrics = metricsByProject[project] ?? ProjectSignalMetrics(projectName: project)
            metrics.score += weight
            metrics.recentBurnCost += usage.cost
            metrics.lastUsageAt = maxDate([metrics.lastUsageAt, usage.endTime])
            metrics.lastActivityDate = maxDate([metrics.lastActivityDate, usage.endTime])
            metricsByProject[project] = metrics
        }
        let sorted = metricsByProject.values.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        let primaryMetrics = sorted.first
        let secondaryMetrics = sorted.dropFirst().first
        let meaningfulCompetition = meaningfulSecondaryCompetition(
            primary: primaryMetrics,
            secondary: secondaryMetrics
        )
        return ProjectFocus(
            primaryMetrics: primaryMetrics,
            secondaryMetrics: meaningfulCompetition ? secondaryMetrics : nil,
            totalConversationCount: conversations.count
        )
    }
    private static func normalizeProjectName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func latestConversationActivityDate(_ conversation: ConversationRecord?) -> Date? {
        maxDate([
            conversation?.endTime,
            conversation?.startTime,
            conversation?.indexedAt
        ])
    }

    static func latestActivityDate(
        latestConversation: ConversationRecord?,
        projectUsages: [TokenUsage]
    ) -> Date? {
        maxDate([
            latestConversationActivityDate(latestConversation),
            projectUsages.map(\.endTime).max()
        ])
    }

    static func relativeTimeString(since date: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 {
            return "just now"
        }
        if seconds < 60 * 60 {
            let minutes = seconds / 60
            return "\(minutes)m ago"
        }
        if seconds < 24 * 60 * 60 {
            let hours = seconds / (60 * 60)
            return "\(hours)h ago"
        }
        let days = seconds / (24 * 60 * 60)
        return "\(days)d ago"
    }
    private static func meaningfulSecondaryCompetition(
        primary: ProjectSignalMetrics?,
        secondary: ProjectSignalMetrics?
    ) -> Bool {
        guard let primary, let secondary else { return false }
        guard secondary.score >= primary.score * 0.75 else { return false }
        guard secondary.recentBurnCost >= max(1.5, primary.recentBurnCost * 0.35) else { return false }
        guard let secondaryActivity = secondary.lastActivityDate,
              Date().timeIntervalSince(secondaryActivity) <= 24 * 60 * 60 else {
            return false
        }
        return secondary.recentConversationCount >= 1 || secondary.recentBurnCost >= 3
    }
    static func maxDate(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.max()
    }
}

struct ProjectSignalMetrics: Equatable {
    let projectName: String
    var score: Double = 0
    var conversationCount: Int = 0
    var recentConversationCount: Int = 0
    var summarizedConversationCount: Int = 0
    var recentBurnCost: Double = 0
    var lastConversationAt: Date?
    var lastUsageAt: Date?
    var lastActivityDate: Date?

    var key: String { projectName }
    var value: Double { score }
}

struct ProjectFocus: Equatable {
    let primaryMetrics: ProjectSignalMetrics?
    let secondaryMetrics: ProjectSignalMetrics?
    let totalConversationCount: Int

    var primaryProject: String? { primaryMetrics?.projectName }
    var secondaryProject: String? { secondaryMetrics?.projectName }
    var dominanceRatio: Double {
        guard let primaryScore = primaryMetrics?.score, primaryScore > 0 else { return 0 }
        let secondaryScore = secondaryMetrics?.score ?? 0
        return primaryScore / max(primaryScore + secondaryScore, 1)
    }

    var scopeLabel: String {
        if secondaryProject != nil {
            return "Cross-project"
        }
        return primaryProject ?? "Workspace"
    }
}
