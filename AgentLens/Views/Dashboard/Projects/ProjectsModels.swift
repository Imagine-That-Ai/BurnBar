import Charts
import OpenBurnBarCore
import SwiftUI

// Shared project dashboard models extracted from ProjectsView for compile isolation.

struct ProjectReentryControl: Identifiable, Equatable {
    let cadence: BurnBarControllerReviewCadence
    let title: String
    let isEnabled: Bool

    var id: BurnBarControllerReviewCadence { cadence }
}

struct ProjectReviewHistoryIndicator: Identifiable, Equatable {
    let cadence: BurnBarControllerReviewCadence
    let reviewedAt: Date

    var id: String { "\(cadence.rawValue)-\(reviewedAt.timeIntervalSinceReferenceDate)" }
}

struct MergedProject: Identifiable {
    let id: String
    let slug: String
    let displayName: String
    let registeredProject: BurnBarReviewProjectSnapshot?
    let totalCost: Double
    let totalTokens: Int
    let sessionCount: Int
    let providers: [AgentProvider]

    var isRegistered: Bool { registeredProject != nil }
    var cadenceLabel: String? {
        guard let p = registeredProject else { return nil }
        switch p.preferredCadence {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .adHoc: return "Ad hoc"
        }
    }
    var automationMode: BurnBarControllerProjectAutomationMode? { registeredProject?.automationMode }
    var pendingQuestionCount: Int { registeredProject?.pendingQuestionCount ?? 0 }
    var openFollowupCount: Int { registeredProject?.openFollowupCount ?? 0 }
    var activeMissionCount: Int { registeredProject?.activeMissionCount ?? 0 }
    var needsAttention: Bool { registeredProject?.needsOperatorAttention ?? false }

    var attentionSummary: String? {
        var parts: [String] = []
        if pendingQuestionCount > 0 { parts.append("\(pendingQuestionCount) question\(pendingQuestionCount == 1 ? "" : "s")") }
        if activeMissionCount > 0 { parts.append("\(activeMissionCount) mission\(activeMissionCount == 1 ? "" : "s")") }
        if openFollowupCount > 0 { parts.append("\(openFollowupCount) followup\(openFollowupCount == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func reentryReviewControls(daemonIsHealthy: Bool) -> [ProjectReentryControl] {
        guard isRegistered else { return [] }
        return [
            ProjectReentryControl(
                cadence: .daily,
                title: "Run Daily Check-In",
                isEnabled: daemonIsHealthy
            ),
            ProjectReentryControl(
                cadence: .weekly,
                title: "Run Weekly Review",
                isEnabled: daemonIsHealthy
            )
        ]
    }

    var reviewHistoryIndicators: [ProjectReviewHistoryIndicator] {
        guard let project = registeredProject else { return [] }
        var indicators: [ProjectReviewHistoryIndicator] = []
        if let latestWeekly = project.latestWeeklyReviewAt {
            indicators.append(
                ProjectReviewHistoryIndicator(cadence: .weekly, reviewedAt: latestWeekly)
            )
        }
        if let latestDaily = project.latestDailyReviewAt {
            indicators.append(
                ProjectReviewHistoryIndicator(cadence: .daily, reviewedAt: latestDaily)
            )
        }
        return indicators
    }
}
