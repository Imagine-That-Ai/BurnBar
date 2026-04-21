import Foundation
import SwiftUI
import OpenBurnBarCore

// MARK: - Operating Layer Models

enum OpenBurnBarOperatingAvailability: String, Equatable, Sendable {
    case available
    case sparse
    case missing

    var isRenderable: Bool {
        self != .missing
    }
}

enum OpenBurnBarMissionLifecycle: String, Codable, Equatable, Sendable {
    case planned
    case running
    case partial
    case blocked
    case completed

    var label: String {
        switch self {
        case .planned: return "Planned"
        case .running: return "Running"
        case .partial: return "Partial"
        case .blocked: return "Blocked"
        case .completed: return "Completed"
        }
    }

    var color: Color {
        switch self {
        case .planned: return DesignSystem.Colors.textSecondary
        case .running: return DesignSystem.Colors.blaze
        case .partial: return DesignSystem.Colors.amber
        case .blocked: return DesignSystem.Colors.error
        case .completed: return DesignSystem.Colors.success
        }
    }
}

enum OpenBurnBarMissionApprovalState: String, Codable, Equatable, Sendable {
    case pending
    case approved

    var label: String {
        switch self {
        case .pending: return "Needs approval"
        case .approved: return "Approved"
        }
    }

    var color: Color {
        switch self {
        case .pending: return DesignSystem.Colors.amber
        case .approved: return DesignSystem.Colors.success
        }
    }
}

enum OpenBurnBarDirectionAssessment: String, Equatable, CaseIterable, Codable, Sendable {
    case aligned
    case drifting
    case ambiguous
    case notEnoughSignal = "not_enough_signal"

    var label: String {
        switch self {
        case .aligned: return "Aligned"
        case .drifting: return "Drifting"
        case .ambiguous: return "Ambiguous"
        case .notEnoughSignal: return "Not enough signal"
        }
    }

    var color: Color {
        switch self {
        case .aligned: return DesignSystem.Colors.success
        case .drifting: return DesignSystem.Colors.warning
        case .ambiguous: return DesignSystem.Colors.blaze
        case .notEnoughSignal: return DesignSystem.Colors.textSecondary
        }
    }
}

enum OpenBurnBarDirectionMode: String, Equatable, Sendable {
    case inferred
    case sparse
    case overrideAnnotating = "override_annotating"
    case overrideSuperseding = "override_superseding"

    var label: String {
        switch self {
        case .inferred: return "Inferred"
        case .sparse: return "Sparse"
        case .overrideAnnotating: return "Annotated"
        case .overrideSuperseding: return "Overridden"
        }
    }
}

enum OpenBurnBarFreshnessKind: String, Equatable, Sendable {
    case live
    case provisional
    case stale
    case missing

    var label: String {
        switch self {
        case .live: return "Fresh local signal"
        case .provisional: return "Provisional"
        case .stale: return "Stale"
        case .missing: return "Awaiting first scan"
        }
    }

    var color: Color {
        switch self {
        case .live: return DesignSystem.Colors.success
        case .provisional: return DesignSystem.Colors.amber
        case .stale: return DesignSystem.Colors.warning
        case .missing: return DesignSystem.Colors.textSecondary
        }
    }
}

enum OpenBurnBarEvidenceFreshness: String, Equatable, Sendable {
    case fresh
    case stale
    case unknown

    var label: String {
        switch self {
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .fresh: return DesignSystem.Colors.success
        case .stale: return DesignSystem.Colors.warning
        case .unknown: return DesignSystem.Colors.textSecondary
        }
    }
}

enum OpenBurnBarActionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case missionApproval = "mission_approval"
    case missionCreation = "mission_creation"
    case directionOverride = "direction_override"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .missionApproval: return "Approve Mission"
        case .missionCreation: return "Create Mission"
        case .directionOverride: return "Override Direction"
        }
    }

    var icon: String {
        switch self {
        case .missionApproval: return "checkmark.seal.fill"
        case .missionCreation: return "flag.badge.ellipsis"
        case .directionOverride: return "flag.fill"
        }
    }
}

enum OpenBurnBarActionTone: Equatable, Sendable {
    case success
    case error
    case neutral

    var color: Color {
        switch self {
        case .success: return DesignSystem.Colors.success
        case .error: return DesignSystem.Colors.error
        case .neutral: return DesignSystem.Colors.textSecondary
        }
    }
}

enum OpenBurnBarDirectionOverrideModeKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case annotate
    case supersedeStatus = "supersede_status"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .annotate: return "Annotate"
        case .supersedeStatus: return "Force status"
        }
    }
}

struct OpenBurnBarMissionSummary: Equatable, Sendable {
    let availability: OpenBurnBarOperatingAvailability
    let missionID: String
    let projectName: String
    let title: String
    let subtitle: String
    let state: OpenBurnBarMissionLifecycle
    let approval: OpenBurnBarMissionApprovalState
    let sessionCount: Int
    let summarizedSessionCount: Int
    let burnRecordCount: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
    let changedFilesSummary: String
    let risksSummary: String
    let remainingWorkSummary: String
    let recommendationSummary: String
    let nextRecommendation: String
    let approvalNote: String?
    let readinessFailure: BurnBarReadinessFailure?
}

// MARK: - Readiness Failure

/// Represents a pre-dispatch execution readiness failure.
/// Maps directly from daemon BurnBarExecutionReadinessCode for cross-surface parity.
/// Used to propagate actionable failure reasons when a mission cannot be dispatched.
struct BurnBarReadinessFailure: Equatable, Sendable {
    let code: BurnBarExecutionReadinessCode
    let detail: String

    /// Human-readable display message for operator-facing UI.
    var displayMessage: String {
        switch code {
        case .missingCredential:
            return "Credential missing: \(detail)"
        case .invalidRepoBranch:
            return "Repository unavailable: \(detail)"
        case .runtimeUnavailable:
            return "Runtime unavailable: \(detail)"
        case .insufficientCredentialPermissions:
            return "Insufficient permissions: \(detail)"
        }
    }

    /// Creates a readiness failure from daemon execution readiness response.
    init(code: BurnBarExecutionReadinessCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

struct OpenBurnBarDirectionSummary: Equatable, Sendable {
    let availability: OpenBurnBarOperatingAvailability
    let projectName: String
    let title: String
    let status: OpenBurnBarDirectionAssessment
    let summary: String
    let scopeLabel: String
    let freshness: OpenBurnBarEvidenceFreshness
    let mode: OpenBurnBarDirectionMode
    let sparseReason: String?
    let nextActions: [String]
    let overrideSummary: String?
}

struct OpenBurnBarBurnSummary: Equatable, Sendable {
    let availability: OpenBurnBarOperatingAvailability
    let projectName: String
    let sessionCount: Int
    let burnRecordCount: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
    let latestSource: String?
    let dominantModel: String?
    let windowLabel: String
}

struct OpenBurnBarFreshnessSummary: Equatable, Sendable {
    let status: OpenBurnBarFreshnessKind
    let provisional: Bool
    let updatedAt: Date?
    let reasons: [String]

    var headline: String {
        status.label
    }
}

struct OpenBurnBarEvidenceEntry: Identifiable, Equatable, Sendable {
    let id: String
    let sourceLabel: String
    let summary: String
    let detail: String
    let includedReason: String
    let freshness: OpenBurnBarEvidenceFreshness
}

struct OpenBurnBarEvidenceJudgment: Identifiable, Equatable, Sendable {
    let id: String
    let summary: String
    let detail: String
}

struct OpenBurnBarEvidenceSummary: Equatable, Sendable {
    let availability: OpenBurnBarOperatingAvailability
    let projectName: String
    let freshness: OpenBurnBarEvidenceFreshness
    let summary: String
    let sparseReason: String?
    let entries: [OpenBurnBarEvidenceEntry]
    let inclusionReasons: [String]
    let majorExclusions: [String]
    let support: [OpenBurnBarEvidenceJudgment]
    let contradictions: [OpenBurnBarEvidenceJudgment]
}

struct OpenBurnBarActionAvailability: Identifiable, Equatable, Sendable {
    let kind: OpenBurnBarActionKind
    let available: Bool
    let reason: String
    let title: String

    var id: String { kind.id }
}

struct OpenBurnBarActionFeedback: Identifiable, Equatable, Sendable {
    let kind: OpenBurnBarActionKind
    let tone: OpenBurnBarActionTone
    let message: String
    let detail: String?

    var id: String { "\(kind.rawValue)-\(message)" }
}

struct OpenBurnBarOperatingHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let kind: OpenBurnBarActionKind
    let title: String
    let summary: String
    let detail: String?
    let createdAt: Date

    var tint: Color {
        switch kind {
        case .missionApproval: return DesignSystem.Colors.success
        case .missionCreation: return DesignSystem.Colors.hermesAureate
        case .directionOverride: return DesignSystem.Colors.whimsy
        }
    }

    var icon: String {
        switch kind {
        case .missionApproval: return "checkmark.seal.fill"
        case .missionCreation: return "flag.badge.ellipsis"
        case .directionOverride: return "flag.fill"
        }
    }
}

enum OpenBurnBarControllerRuntimeSource: String, Codable, Equatable, Sendable {
    case daemon
    case mirrored
    case inferred

    var label: String {
        switch self {
        case .daemon: return "Daemon-backed"
        case .mirrored: return "Mirrored"
        case .inferred: return "Local inference"
        }
    }
}

enum OpenBurnBarControllerQuestionState: String, Codable, Equatable, Sendable {
    case pending
    case answered
    case dismissed
}

enum OpenBurnBarControllerQuestionPriority: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low

    var color: Color {
        switch self {
        case .high: return DesignSystem.Colors.error
        case .medium: return DesignSystem.Colors.amber
        case .low: return DesignSystem.Colors.textSecondary
        }
    }
}

enum OpenBurnBarControllerQuestionDeepLinkKind: String, Codable, Equatable, Sendable {
    case sessionLog = "session_log"
    case dashboard
    case project
    case settings
}

enum OpenBurnBarControllerFollowupState: String, Codable, Equatable, Sendable {
    case open
    case done
    case snoozed
}

enum OpenBurnBarControllerFollowupKind: String, Codable, Equatable, Sendable {
    case pendingQuestion = "pending_question"
    case completedAction = "completed_action"
    case missionWork = "mission_work"
    case setup
}

enum OpenBurnBarControllerTakeoverState: String, Codable, Equatable, Sendable {
    case monitoring
    case launched
    case completed
    case failed
    case skipped

    var label: String {
        switch self {
        case .monitoring: return "Monitoring"
        case .launched: return "Takeover live"
        case .completed: return "Takeover done"
        case .failed: return "Takeover failed"
        case .skipped: return "Takeover skipped"
        }
    }

    var color: Color {
        switch self {
        case .monitoring: return DesignSystem.Colors.textSecondary
        case .launched: return DesignSystem.Colors.blaze
        case .completed: return DesignSystem.Colors.success
        case .failed: return DesignSystem.Colors.error
        case .skipped: return DesignSystem.Colors.textMuted
        }
    }
}

enum OpenBurnBarControllerEventCategory: String, Codable, Equatable, Sendable {
    case controller
    case question
    case followup
    case mission
    case notification
    case replay
    case governance

    var icon: String {
        switch self {
        case .controller: return "dial.medium"
        case .question: return "questionmark.bubble"
        case .followup: return "list.bullet.clipboard"
        case .mission: return "flag.2.crossed"
        case .notification: return "bell.badge"
        case .replay: return "play.square.stack"
        case .governance: return "checkmark.seal"
        }
    }

    var color: Color {
        switch self {
        case .controller: return DesignSystem.Colors.blaze
        case .question: return DesignSystem.Colors.amber
        case .followup: return DesignSystem.Colors.whimsy
        case .mission: return DesignSystem.Colors.hermesAureate
        case .notification: return DesignSystem.Colors.teal
        case .replay: return DesignSystem.Colors.textSecondary
        case .governance: return DesignSystem.Colors.success
        }
    }
}

struct OpenBurnBarControllerQuestionOption: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let answer: String
}

struct OpenBurnBarControllerQuestionDeepLink: Codable, Equatable, Sendable {
    let kind: OpenBurnBarControllerQuestionDeepLinkKind
    let targetID: String?
    let title: String
    let subtitle: String?
}

struct OpenBurnBarControllerQuestion: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let projectName: String
    let sessionID: String?
    let title: String
    let prompt: String
    let stageLabel: String?
    let evidenceHint: String?
    let state: OpenBurnBarControllerQuestionState
    let priority: OpenBurnBarControllerQuestionPriority
    let sourceLabel: String
    let createdAt: Date
    let answeredAt: Date?
    let answer: String?
    let selectedOptionID: String?
    let answerPlaceholder: String?
    let suggestedOptions: [OpenBurnBarControllerQuestionOption]
    let deepLink: OpenBurnBarControllerQuestionDeepLink?
    let isUnread: Bool
    let notificationCount: Int

    init(
        id: String = UUID().uuidString,
        projectName: String,
        sessionID: String? = nil,
        title: String,
        prompt: String,
        stageLabel: String? = nil,
        evidenceHint: String? = nil,
        state: OpenBurnBarControllerQuestionState = .pending,
        priority: OpenBurnBarControllerQuestionPriority = .medium,
        sourceLabel: String = "Local runtime",
        createdAt: Date = Date(),
        answeredAt: Date? = nil,
        answer: String? = nil,
        selectedOptionID: String? = nil,
        answerPlaceholder: String? = nil,
        suggestedOptions: [OpenBurnBarControllerQuestionOption] = [],
        deepLink: OpenBurnBarControllerQuestionDeepLink? = nil,
        isUnread: Bool = true,
        notificationCount: Int = 0
    ) {
        self.id = id
        self.projectName = projectName
        self.sessionID = sessionID
        self.title = title
        self.prompt = prompt
        self.stageLabel = stageLabel
        self.evidenceHint = evidenceHint
        self.state = state
        self.priority = priority
        self.sourceLabel = sourceLabel
        self.createdAt = createdAt
        self.answeredAt = answeredAt
        self.answer = answer
        self.selectedOptionID = selectedOptionID
        self.answerPlaceholder = answerPlaceholder
        self.suggestedOptions = suggestedOptions
        self.deepLink = deepLink
        self.isUnread = isUnread
        self.notificationCount = notificationCount
    }
}

struct OpenBurnBarControllerFollowup: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let projectName: String
    let title: String
    let summary: String
    let stageLabel: String?
    let detail: String?
    let state: OpenBurnBarControllerFollowupState
    let kind: OpenBurnBarControllerFollowupKind
    let linkedQuestionID: String?
    let deepLink: OpenBurnBarControllerQuestionDeepLink?
    let createdAt: Date
    let updatedAt: Date
    let dueAt: Date?
    let snoozedUntil: Date?
    let calendarTitle: String?
    let calendarStart: Date?
    let calendarEnd: Date?

    init(
        id: String = UUID().uuidString,
        projectName: String,
        title: String,
        summary: String,
        stageLabel: String? = nil,
        detail: String? = nil,
        state: OpenBurnBarControllerFollowupState = .open,
        kind: OpenBurnBarControllerFollowupKind,
        linkedQuestionID: String? = nil,
        deepLink: OpenBurnBarControllerQuestionDeepLink? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        dueAt: Date? = nil,
        snoozedUntil: Date? = nil,
        calendarTitle: String? = nil,
        calendarStart: Date? = nil,
        calendarEnd: Date? = nil
    ) {
        self.id = id
        self.projectName = projectName
        self.title = title
        self.summary = summary
        self.stageLabel = stageLabel
        self.detail = detail
        self.state = state
        self.kind = kind
        self.linkedQuestionID = linkedQuestionID
        self.deepLink = deepLink
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dueAt = dueAt
        self.snoozedUntil = snoozedUntil
        self.calendarTitle = calendarTitle
        self.calendarStart = calendarStart
        self.calendarEnd = calendarEnd
    }

    func updating(
        state: OpenBurnBarControllerFollowupState? = nil,
        snoozedUntil: Date? = nil,
        calendarTitle: String? = nil,
        calendarStart: Date? = nil,
        calendarEnd: Date? = nil,
        updatedAt: Date
    ) -> OpenBurnBarControllerFollowup {
        OpenBurnBarControllerFollowup(
            id: id,
            projectName: projectName,
            title: title,
            summary: summary,
            stageLabel: stageLabel,
            detail: detail,
            state: state ?? self.state,
            kind: kind,
            linkedQuestionID: linkedQuestionID,
            deepLink: deepLink,
            createdAt: createdAt,
            updatedAt: updatedAt,
            dueAt: dueAt,
            snoozedUntil: snoozedUntil ?? self.snoozedUntil,
            calendarTitle: calendarTitle ?? self.calendarTitle,
            calendarStart: calendarStart ?? self.calendarStart,
            calendarEnd: calendarEnd ?? self.calendarEnd
        )
    }
}

struct OpenBurnBarControllerMissionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let projectName: String
    let title: String
    let summary: String
    let state: OpenBurnBarMissionLifecycle
    let approval: OpenBurnBarMissionApprovalState
    let packetSummary: String?
    let latestResultSummary: String?
    let latestResultDetail: String?
    let latestResultRunID: String?
    let activeWorkerName: String?
    let activeRunID: String?
    let packetRunCount: Int
    let latestTakeoverState: OpenBurnBarControllerTakeoverState?
    let latestTakeoverReason: String?
    let latestTakeoverRunID: String?
    let takeoverCount: Int
    let burnCostUSD: Double
    let burnTokens: Int
    let updatedAt: Date
    let prLinkage: OpenBurnBarControllerMissionPRLinkage?

    init(
        id: String,
        projectName: String,
        title: String,
        summary: String,
        state: OpenBurnBarMissionLifecycle,
        approval: OpenBurnBarMissionApprovalState,
        packetSummary: String?,
        latestResultSummary: String?,
        latestResultDetail: String?,
        latestResultRunID: String?,
        activeWorkerName: String?,
        activeRunID: String?,
        packetRunCount: Int,
        latestTakeoverState: OpenBurnBarControllerTakeoverState?,
        latestTakeoverReason: String?,
        latestTakeoverRunID: String?,
        takeoverCount: Int,
        burnCostUSD: Double,
        burnTokens: Int,
        updatedAt: Date,
        prLinkage: OpenBurnBarControllerMissionPRLinkage? = nil
    ) {
        self.id = id
        self.projectName = projectName
        self.title = title
        self.summary = summary
        self.state = state
        self.approval = approval
        self.packetSummary = packetSummary
        self.latestResultSummary = latestResultSummary
        self.latestResultDetail = latestResultDetail
        self.latestResultRunID = latestResultRunID
        self.activeWorkerName = activeWorkerName
        self.activeRunID = activeRunID
        self.packetRunCount = packetRunCount
        self.latestTakeoverState = latestTakeoverState
        self.latestTakeoverReason = latestTakeoverReason
        self.latestTakeoverRunID = latestTakeoverRunID
        self.takeoverCount = takeoverCount
        self.burnCostUSD = burnCostUSD
        self.burnTokens = burnTokens
        self.updatedAt = updatedAt
        self.prLinkage = prLinkage
    }
}

enum OpenBurnBarControllerMissionPRState: String, Codable, Equatable, Sendable {
    case opened
    case merged
    case closed

    var label: String {
        switch self {
        case .opened:
            return "Opened"
        case .merged:
            return "Merged"
        case .closed:
            return "Closed"
        }
    }
}

struct OpenBurnBarControllerMissionPRLinkage: Codable, Equatable, Sendable {
    let repository: String
    let prNumberOrID: String
    let url: String
    let state: OpenBurnBarControllerMissionPRState
    let isMerged: Bool
    let mergeCommitSHA: String?
    let mergedAt: Date?
    let closedAt: Date?
}

enum OpenBurnBarControllerNextActionBucket: String, Codable, Equatable, Sendable {
    case blockage
    case interruption
    case completion
}

struct OpenBurnBarControllerNextAction: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let missionID: String
    let projectName: String
    let title: String
    let summary: String
    let bucket: OpenBurnBarControllerNextActionBucket
    let missionState: OpenBurnBarMissionLifecycle
    let updatedAt: Date
}

enum OpenBurnBarControllerNextActionPlanner {
    static func orderedActions(
        from missions: [OpenBurnBarControllerMissionRecord]
    ) -> [OpenBurnBarControllerNextAction] {
        missions
            .map(action(for:))
            .sorted(by: actionSort)
    }

    private static func action(
        for mission: OpenBurnBarControllerMissionRecord
    ) -> OpenBurnBarControllerNextAction {
        OpenBurnBarControllerNextAction(
            id: "next-action-\(mission.id)",
            missionID: mission.id,
            projectName: mission.projectName,
            title: actionTitle(for: mission.state, approval: mission.approval),
            summary: mission.summary.nonEmpty
                ?? mission.latestResultSummary?.nonEmpty
                ?? "OpenBurnBar captured mission state and is ready for the next operator call.",
            bucket: bucket(for: mission.state),
            missionState: mission.state,
            updatedAt: mission.updatedAt
        )
    }

    private static func actionSort(
        lhs: OpenBurnBarControllerNextAction,
        rhs: OpenBurnBarControllerNextAction
    ) -> Bool {
        let lhsBucket = bucketRank(lhs.bucket)
        let rhsBucket = bucketRank(rhs.bucket)
        if lhsBucket != rhsBucket {
            return lhsBucket < rhsBucket
        }

        let lhsStateRank = stateRank(lhs.missionState)
        let rhsStateRank = stateRank(rhs.missionState)
        if lhsStateRank != rhsStateRank {
            return lhsStateRank < rhsStateRank
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return lhs.missionID < rhs.missionID
    }

    private static func bucket(
        for state: OpenBurnBarMissionLifecycle
    ) -> OpenBurnBarControllerNextActionBucket {
        switch state {
        case .blocked:
            return .blockage
        case .completed:
            return .completion
        case .running, .partial, .planned:
            return .interruption
        }
    }

    private static func bucketRank(
        _ bucket: OpenBurnBarControllerNextActionBucket
    ) -> Int {
        switch bucket {
        case .blockage: return 0
        case .interruption: return 1
        case .completion: return 2
        }
    }

    private static func stateRank(
        _ state: OpenBurnBarMissionLifecycle
    ) -> Int {
        switch state {
        case .blocked: return 0
        case .partial: return 1
        case .running: return 2
        case .planned: return 3
        case .completed: return 4
        }
    }

    private static func actionTitle(
        for state: OpenBurnBarMissionLifecycle,
        approval: OpenBurnBarMissionApprovalState
    ) -> String {
        switch state {
        case .blocked:
            return "Resolve blocker"
        case .partial:
            return "Resume interrupted mission"
        case .running:
            return "Monitor active mission"
        case .planned:
            return approval == .pending ? "Approve mission" : "Start mission execution"
        case .completed:
            return "Review completion"
        }
    }
}

struct OpenBurnBarControllerEvent: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let projectName: String?
    let category: OpenBurnBarControllerEventCategory
    let title: String
    let summary: String
    let detail: String?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        projectName: String? = nil,
        category: OpenBurnBarControllerEventCategory,
        title: String,
        summary: String,
        detail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectName = projectName
        self.category = category
        self.title = title
        self.summary = summary
        self.detail = detail
        self.createdAt = createdAt
    }
}

struct OpenBurnBarControllerSummary: Codable, Equatable, Sendable {
    let headline: String
    let detail: String
    let pendingQuestions: Int
    let unresolvedFollowups: Int
    let openMissions: Int
    let replayLabel: String
    let notificationLabel: String

    static let empty = OpenBurnBarControllerSummary(
        headline: "Controller runtime is quiet.",
        detail: "OpenBurnBar will mirror followups, questions, missions, and replay state here once the daemon or local operating layer has signal.",
        pendingQuestions: 0,
        unresolvedFollowups: 0,
        openMissions: 0,
        replayLabel: "Replay idle",
        notificationLabel: "Notifications optional"
    )

    func recounted(
        pendingQuestions: Int,
        unresolvedFollowups: Int,
        openMissions: Int
    ) -> OpenBurnBarControllerSummary {
        OpenBurnBarControllerSummary(
            headline: headline,
            detail: detail,
            pendingQuestions: pendingQuestions,
            unresolvedFollowups: unresolvedFollowups,
            openMissions: openMissions,
            replayLabel: replayLabel,
            notificationLabel: notificationLabel
        )
    }
}

struct OpenBurnBarControllerRuntimeSnapshot: Codable, Equatable, Sendable {
    var source: OpenBurnBarControllerRuntimeSource
    var updatedAt: Date
    var summary: OpenBurnBarControllerSummary
    var questions: [OpenBurnBarControllerQuestion]
    var followups: [OpenBurnBarControllerFollowup]
    var missions: [OpenBurnBarControllerMissionRecord]
    var nextActions: [OpenBurnBarControllerNextAction]? = nil
    var recentEvents: [OpenBurnBarControllerEvent]

    static let empty = OpenBurnBarControllerRuntimeSnapshot(
        source: .inferred,
        updatedAt: .distantPast,
        summary: .empty,
        questions: [],
        followups: [],
        missions: [],
        nextActions: [],
        recentEvents: []
    )

    var pendingQuestions: [OpenBurnBarControllerQuestion] {
        questions.filter { $0.state == .pending }
    }

    var openFollowups: [OpenBurnBarControllerFollowup] {
        followups.filter { $0.state == .open }
    }

    var unresolvedCount: Int {
        pendingQuestions.count + openFollowups.count
    }

    var compactHighlight: String? {
        if let question = pendingQuestions.first {
            return question.title
        }
        if let followup = openFollowups.first {
            return followup.title
        }
        if let nextAction = nextActions?.first {
            return nextAction.title
        }
        if let mission = missions.first {
            if let takeoverReason = mission.latestTakeoverReason?.nonEmpty {
                return takeoverReason
            }
            if let result = mission.latestResultSummary?.nonEmpty {
                return result
            }
        }
        return nil
    }
}

struct OpenBurnBarControllerFeedback: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case success
        case error

        var color: Color {
            switch self {
            case .success: return DesignSystem.Colors.success
            case .error: return DesignSystem.Colors.error
            }
        }
    }

    let id = UUID()
    let tone: Tone
    let message: String
}

struct OpenBurnBarOperatingSnapshot: Equatable, Sendable {
    let updatedAt: Date
    let projectName: String?
    let secondaryProjectName: String?
    let mission: OpenBurnBarMissionSummary
    let direction: OpenBurnBarDirectionSummary
    let burn: OpenBurnBarBurnSummary
    let freshness: OpenBurnBarFreshnessSummary
    let evidence: OpenBurnBarEvidenceSummary
    let availableActions: [OpenBurnBarActionAvailability]
    let recentHistory: [OpenBurnBarOperatingHistoryEntry]
    let controllerRuntime: OpenBurnBarControllerRuntimeSnapshot
    let compactSummary: String
    let pendingHighlight: String?
}

// MARK: - Operating Layer Persistence

struct OpenBurnBarMissionApprovalRecord: Codable, Equatable, Sendable {
    let projectName: String
    let missionFingerprint: String
    let note: String
    let approvedAt: Date
}

struct OpenBurnBarDirectionOverrideRecord: Codable, Equatable, Sendable {
    let projectName: String
    let mode: OpenBurnBarDirectionOverrideModeKind
    let forcedStatus: OpenBurnBarDirectionAssessment?
    let summary: String
    let rationale: String
    let createdAt: Date
}

struct OpenBurnBarOperatingDecisionState: Codable, Equatable, Sendable {
    var missionApprovalsByProject: [String: OpenBurnBarMissionApprovalRecord] = [:]
    var directionOverridesByProject: [String: OpenBurnBarDirectionOverrideRecord] = [:]
}
