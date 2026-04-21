import Foundation

public typealias BurnBarMetadata = [String: BurnBarJSONValue]

public enum BurnBarControllerReviewCadence: String, Codable, CaseIterable, Hashable, Sendable {
    case daily
    case weekly
    case adHoc = "ad_hoc"
}

public enum BurnBarControllerFreshnessState: String, Codable, CaseIterable, Hashable, Sendable {
    case fresh
    case aging
    case stale
    case provisional
    case missing
}

public enum BurnBarReviewProjectStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case healthy
    case needsAttention = "needs_attention"
    case stale
    case onboarding
    case paused
}

public enum BurnBarControllerProjectAutomationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case manual
    case suggested
    case scheduled
}

public enum BurnBarControllerProjectIngestionSource: String, Codable, CaseIterable, Hashable, Sendable {
    case manual
    case appActivity = "app_activity"
}

public enum BurnBarPendingQuestionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case answered
    case dismissed
    case expired
}

public enum BurnBarPendingQuestionPriority: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high
    case critical
}

public enum BurnBarQuestionDeepLinkKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sessionLog = "session_log"
    case dashboard
    case project
    case settings
}

public enum BurnBarFollowupStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case open
    case done
    case snoozed
}

public enum BurnBarFollowupKind: String, Codable, CaseIterable, Hashable, Sendable {
    case pendingQuestion = "pending_question"
    case completedAction = "completed_action"
    case missionReview = "mission_review"
    case controllerNudge = "controller_nudge"
}

public enum BurnBarMissionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case draft
    case awaitingApproval = "awaiting_approval"
    case approved
    case dispatching
    case inProgress = "in_progress"
    case partiallyCompleted = "partially_completed"
    case completed
    case failed
    case cancelled
}

public enum BurnBarMissionRecommendation: String, Codable, CaseIterable, Hashable, Sendable {
    case proceed
    case review
    case pause
    case escalate
}

public enum BurnBarControllerNextActionBucket: String, Codable, CaseIterable, Hashable, Sendable {
    case blockage
    case interruption
    case completion
}

public struct BurnBarControllerNextActionSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let missionID: BurnBarMissionID
    public let projectSlug: String
    public let title: String
    public let summary: String
    public let bucket: BurnBarControllerNextActionBucket
    public let status: BurnBarMissionStatus
    public let recommendation: BurnBarMissionRecommendation
    public let updatedAt: Date

    public init(
        id: String,
        missionID: BurnBarMissionID,
        projectSlug: String,
        title: String,
        summary: String,
        bucket: BurnBarControllerNextActionBucket,
        status: BurnBarMissionStatus,
        recommendation: BurnBarMissionRecommendation,
        updatedAt: Date
    ) {
        self.id = id
        self.missionID = missionID
        self.projectSlug = projectSlug
        self.title = title
        self.summary = summary
        self.bucket = bucket
        self.status = status
        self.recommendation = recommendation
        self.updatedAt = updatedAt
    }
}

public enum BurnBarMissionPacketStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case dispatched
    case running
    case completed
    case failed
    case cancelled
}

public enum BurnBarMissionResultStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case succeeded
    case partial
    case failed
    case replayed
}

public enum BurnBarAutoTakeoverStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case monitoring
    case launched
    case completed
    case failed
    case skipped
}

public enum BurnBarNotificationChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case telegram
    case calendar
}

public enum BurnBarEnterpriseApprovalMode: String, Codable, CaseIterable, Hashable, Sendable {
    case autoLowMedium = "auto_low_medium"
    case autoLowOnly = "auto_low_only"
    case manualAll = "manual_all"
}

public enum BurnBarEnterprisePolicyReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    case budgetHardCapBlocked = "policy_budget_hard_cap_blocked"
    case approvalRequiredByMode = "policy_approval_required_by_mode"
    case realIntegrationRequired = "policy_real_integration_required"
    case configurationInvalid = "policy_configuration_invalid"
}

public struct BurnBarEnterprisePolicyBlock: Codable, Hashable, Sendable {
    public let reasonCode: BurnBarEnterprisePolicyReasonCode
    public let detail: String
    public let approvalMode: BurnBarEnterpriseApprovalMode?
    public let budgetHardCapUSD: Double?
    public let observedSpendUSD: Double?
    public let blockedAt: Date

    public init(
        reasonCode: BurnBarEnterprisePolicyReasonCode,
        detail: String,
        approvalMode: BurnBarEnterpriseApprovalMode? = nil,
        budgetHardCapUSD: Double? = nil,
        observedSpendUSD: Double? = nil,
        blockedAt: Date = Date()
    ) {
        self.reasonCode = reasonCode
        self.detail = detail
        self.approvalMode = approvalMode
        self.budgetHardCapUSD = budgetHardCapUSD
        self.observedSpendUSD = observedSpendUSD
        self.blockedAt = blockedAt
    }

    public init(
        code: BurnBarEnterprisePolicyReasonCode,
        detail: String,
        approvalMode: BurnBarEnterpriseApprovalMode? = nil,
        budgetHardCapUSD: Double? = nil,
        observedSpendUSD: Double? = nil,
        blockedAt: Date = Date()
    ) {
        self.init(
            reasonCode: code,
            detail: detail,
            approvalMode: approvalMode,
            budgetHardCapUSD: budgetHardCapUSD,
            observedSpendUSD: observedSpendUSD,
            blockedAt: blockedAt
        )
    }

    public var displayMessage: String {
        switch reasonCode {
        case .budgetHardCapBlocked:
            return "Budget hard cap reached: \(detail)"
        case .approvalRequiredByMode:
            return "Explicit approval required: \(detail)"
        case .realIntegrationRequired:
            return "Real integration required: \(detail)"
        case .configurationInvalid:
            return "Enterprise policy configuration invalid: \(detail)"
        }
    }
}

public struct BurnBarScheduledReviewIntent: Codable, Hashable, Sendable {
    public let taskID: String
    public let projectSlug: String
    public let dueAt: Date
    public let notificationIntentID: String
    public let notificationChannels: [BurnBarNotificationChannel]

    public init(
        taskID: String,
        projectSlug: String,
        dueAt: Date,
        notificationIntentID: String,
        notificationChannels: [BurnBarNotificationChannel]
    ) {
        self.taskID = taskID
        self.projectSlug = projectSlug
        self.dueAt = dueAt
        self.notificationIntentID = notificationIntentID
        self.notificationChannels = notificationChannels
    }
}

public enum BurnBarNotificationHealthStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case healthy
    case degraded
    case disabled
    case unauthorized
}

public enum BurnBarProjectionStatusKind: String, Codable, CaseIterable, Hashable, Sendable {
    case upToDate = "up_to_date"
    case stale
    case rebuilding
    case failed
}

public enum BurnBarReplayStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case queued
    case running
    case completed
    case failed
}

public enum BurnBarControllerReviewRunOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case manual
    case scheduled
    case telegram
    case dashboard
    case projects
    case ingestion
}

public enum BurnBarControllerEventFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case controller
    case question
    case followup
    case mission
    case notification
    case simulator
    case projection
    case governance
}

public enum BurnBarTelegramCommand: String, Codable, CaseIterable, Hashable, Sendable {
    case help
    case pending
    case followups
    case done
    case snooze
    case calendar
    case answer
    case latest
    case status
    case runDaily = "run_daily"
    case runWeekly = "run_weekly"
}

public enum BurnBarCalendarAction: String, Codable, CaseIterable, Hashable, Sendable {
    case create
    case update
    case remove
}

public struct BurnBarControllerCounts: Codable, Hashable, Sendable {
    public let projectCount: Int
    public let pendingQuestionCount: Int
    public let openFollowupCount: Int
    public let activeMissionCount: Int
    public let staleProjectCount: Int

    public init(
        projectCount: Int,
        pendingQuestionCount: Int,
        openFollowupCount: Int,
        activeMissionCount: Int,
        staleProjectCount: Int
    ) {
        self.projectCount = projectCount
        self.pendingQuestionCount = pendingQuestionCount
        self.openFollowupCount = openFollowupCount
        self.activeMissionCount = activeMissionCount
        self.staleProjectCount = staleProjectCount
    }
}

public struct BurnBarReplayCheckpoint: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarProjectionCheckpointID
    public let projectionName: String
    public let eventSequence: Int
    public let recordedAt: Date

    public init(
        id: BurnBarProjectionCheckpointID,
        projectionName: String,
        eventSequence: Int,
        recordedAt: Date
    ) {
        self.id = id
        self.projectionName = projectionName
        self.eventSequence = eventSequence
        self.recordedAt = recordedAt
    }
}

public struct BurnBarProjectionStatusSnapshot: Codable, Hashable, Sendable {
    public let projectionName: String
    public let status: BurnBarProjectionStatusKind
    public let freshness: BurnBarControllerFreshnessState
    public let lastMaterializedAt: Date?
    public let lastEventSequence: Int
    public let lastError: String?
    public let checkpoint: BurnBarReplayCheckpoint?

    public init(
        projectionName: String,
        status: BurnBarProjectionStatusKind,
        freshness: BurnBarControllerFreshnessState,
        lastMaterializedAt: Date? = nil,
        lastEventSequence: Int,
        lastError: String? = nil,
        checkpoint: BurnBarReplayCheckpoint? = nil
    ) {
        self.projectionName = projectionName
        self.status = status
        self.freshness = freshness
        self.lastMaterializedAt = lastMaterializedAt
        self.lastEventSequence = lastEventSequence
        self.lastError = lastError
        self.checkpoint = checkpoint
    }
}

public struct BurnBarControllerEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarControllerEventID
    public let family: BurnBarControllerEventFamily
    public let eventType: String
    public let projectSlug: String
    public let recordedAt: Date
    public let sequence: Int
    public let summary: String
    public let detail: String?
    public let metadata: BurnBarMetadata
    public let isReplay: Bool

    public init(
        id: BurnBarControllerEventID,
        family: BurnBarControllerEventFamily,
        eventType: String,
        projectSlug: String,
        recordedAt: Date,
        sequence: Int,
        summary: String,
        detail: String? = nil,
        metadata: BurnBarMetadata = [:],
        isReplay: Bool = false
    ) {
        self.id = id
        self.family = family
        self.eventType = eventType
        self.projectSlug = projectSlug
        self.recordedAt = recordedAt
        self.sequence = sequence
        self.summary = summary
        self.detail = detail
        self.metadata = metadata
        self.isReplay = isReplay
    }
}

public struct BurnBarControllerSummary: Codable, Hashable, Sendable {
    public let updatedAt: Date
    public let activeProjectSlug: String?
    public let counts: BurnBarControllerCounts
    public let nextSuggestedCadence: BurnBarControllerReviewCadence?
    public let latestReviewAt: Date?
    public let freshness: BurnBarControllerFreshnessState
    public let projectionStatus: [BurnBarProjectionStatusSnapshot]
    public let recentEvents: [BurnBarControllerEvent]
    public let nextActions: [BurnBarControllerNextActionSnapshot]?

    public init(
        updatedAt: Date,
        activeProjectSlug: String? = nil,
        counts: BurnBarControllerCounts,
        nextSuggestedCadence: BurnBarControllerReviewCadence? = nil,
        latestReviewAt: Date? = nil,
        freshness: BurnBarControllerFreshnessState,
        projectionStatus: [BurnBarProjectionStatusSnapshot] = [],
        recentEvents: [BurnBarControllerEvent] = [],
        nextActions: [BurnBarControllerNextActionSnapshot]? = nil
    ) {
        self.updatedAt = updatedAt
        self.activeProjectSlug = activeProjectSlug
        self.counts = counts
        self.nextSuggestedCadence = nextSuggestedCadence
        self.latestReviewAt = latestReviewAt
        self.freshness = freshness
        self.projectionStatus = projectionStatus
        self.recentEvents = recentEvents
        self.nextActions = nextActions
    }
}

public struct BurnBarReviewProjectSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let projectSlug: String
    public let displayName: String
    public let summary: String
    public let status: BurnBarReviewProjectStatus
    public let preferredCadence: BurnBarControllerReviewCadence
    public let aliases: [String]
    public let automationMode: BurnBarControllerProjectAutomationMode
    public let reviewModelID: String?
    public let scheduleHourLocal: Int?
    public let scheduleWeekdayLocal: Int?
    public let freshness: BurnBarControllerFreshnessState
    public let latestDailyReviewAt: Date?
    public let latestWeeklyReviewAt: Date?
    public let nextScheduledReviewAt: Date?
    public let pendingQuestionCount: Int
    public let openFollowupCount: Int
    public let activeMissionCount: Int
    public let activeMissionID: BurnBarMissionID?
    public let needsOperatorAttention: Bool
    public let ingestionSource: BurnBarControllerProjectIngestionSource
    public let metadata: BurnBarMetadata

    public init(
        id: String,
        projectSlug: String,
        displayName: String,
        summary: String,
        status: BurnBarReviewProjectStatus,
        preferredCadence: BurnBarControllerReviewCadence,
        aliases: [String] = [],
        automationMode: BurnBarControllerProjectAutomationMode = .manual,
        reviewModelID: String? = nil,
        scheduleHourLocal: Int? = nil,
        scheduleWeekdayLocal: Int? = nil,
        freshness: BurnBarControllerFreshnessState,
        latestDailyReviewAt: Date? = nil,
        latestWeeklyReviewAt: Date? = nil,
        nextScheduledReviewAt: Date? = nil,
        pendingQuestionCount: Int,
        openFollowupCount: Int,
        activeMissionCount: Int,
        activeMissionID: BurnBarMissionID? = nil,
        needsOperatorAttention: Bool,
        ingestionSource: BurnBarControllerProjectIngestionSource = .manual,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.projectSlug = projectSlug
        self.displayName = displayName
        self.summary = summary
        self.status = status
        self.preferredCadence = preferredCadence
        self.aliases = aliases
        self.automationMode = automationMode
        self.reviewModelID = reviewModelID
        self.scheduleHourLocal = scheduleHourLocal
        self.scheduleWeekdayLocal = scheduleWeekdayLocal
        self.freshness = freshness
        self.latestDailyReviewAt = latestDailyReviewAt
        self.latestWeeklyReviewAt = latestWeeklyReviewAt
        self.nextScheduledReviewAt = nextScheduledReviewAt
        self.pendingQuestionCount = pendingQuestionCount
        self.openFollowupCount = openFollowupCount
        self.activeMissionCount = activeMissionCount
        self.activeMissionID = activeMissionID
        self.needsOperatorAttention = needsOperatorAttention
        self.ingestionSource = ingestionSource
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectSlug
        case displayName
        case summary
        case status
        case preferredCadence
        case aliases
        case automationMode
        case reviewModelID
        case scheduleHourLocal
        case scheduleWeekdayLocal
        case freshness
        case latestDailyReviewAt
        case latestWeeklyReviewAt
        case nextScheduledReviewAt
        case pendingQuestionCount
        case openFollowupCount
        case activeMissionCount
        case activeMissionID
        case needsOperatorAttention
        case ingestionSource
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectSlug = try container.decode(String.self, forKey: .projectSlug)
        displayName = try container.decode(String.self, forKey: .displayName)
        summary = try container.decode(String.self, forKey: .summary)
        status = try container.decode(BurnBarReviewProjectStatus.self, forKey: .status)
        preferredCadence = try container.decode(BurnBarControllerReviewCadence.self, forKey: .preferredCadence)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        automationMode = try container.decodeIfPresent(BurnBarControllerProjectAutomationMode.self, forKey: .automationMode) ?? .manual
        reviewModelID = try container.decodeIfPresent(String.self, forKey: .reviewModelID)
        scheduleHourLocal = try container.decodeIfPresent(Int.self, forKey: .scheduleHourLocal)
        scheduleWeekdayLocal = try container.decodeIfPresent(Int.self, forKey: .scheduleWeekdayLocal)
        freshness = try container.decode(BurnBarControllerFreshnessState.self, forKey: .freshness)
        latestDailyReviewAt = try container.decodeIfPresent(Date.self, forKey: .latestDailyReviewAt)
        latestWeeklyReviewAt = try container.decodeIfPresent(Date.self, forKey: .latestWeeklyReviewAt)
        nextScheduledReviewAt = try container.decodeIfPresent(Date.self, forKey: .nextScheduledReviewAt)
        pendingQuestionCount = try container.decode(Int.self, forKey: .pendingQuestionCount)
        openFollowupCount = try container.decode(Int.self, forKey: .openFollowupCount)
        activeMissionCount = try container.decode(Int.self, forKey: .activeMissionCount)
        activeMissionID = try container.decodeIfPresent(BurnBarMissionID.self, forKey: .activeMissionID)
        needsOperatorAttention = try container.decode(Bool.self, forKey: .needsOperatorAttention)
        ingestionSource = try container.decodeIfPresent(BurnBarControllerProjectIngestionSource.self, forKey: .ingestionSource) ?? .manual
        metadata = try container.decodeIfPresent(BurnBarMetadata.self, forKey: .metadata) ?? [:]
    }
}

public struct BurnBarReviewRunSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let projectSlug: String
    public let cadence: BurnBarControllerReviewCadence
    public let recordedAt: Date
    public let summary: String
    public let questionCount: Int
    public let followupCount: Int
    public let missionCount: Int
    public let origin: BurnBarControllerReviewRunOrigin
    public let triggeredBy: String?
    public let launchedRunID: BurnBarRunID?
    public let metadata: BurnBarMetadata

    public init(
        id: String,
        projectSlug: String,
        cadence: BurnBarControllerReviewCadence,
        recordedAt: Date,
        summary: String,
        questionCount: Int,
        followupCount: Int,
        missionCount: Int,
        origin: BurnBarControllerReviewRunOrigin = .manual,
        triggeredBy: String? = nil,
        launchedRunID: BurnBarRunID? = nil,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.projectSlug = projectSlug
        self.cadence = cadence
        self.recordedAt = recordedAt
        self.summary = summary
        self.questionCount = questionCount
        self.followupCount = followupCount
        self.missionCount = missionCount
        self.origin = origin
        self.triggeredBy = triggeredBy
        self.launchedRunID = launchedRunID
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectSlug
        case cadence
        case recordedAt
        case summary
        case questionCount
        case followupCount
        case missionCount
        case origin
        case triggeredBy
        case launchedRunID
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectSlug = try container.decode(String.self, forKey: .projectSlug)
        cadence = try container.decode(BurnBarControllerReviewCadence.self, forKey: .cadence)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        summary = try container.decode(String.self, forKey: .summary)
        questionCount = try container.decode(Int.self, forKey: .questionCount)
        followupCount = try container.decode(Int.self, forKey: .followupCount)
        missionCount = try container.decode(Int.self, forKey: .missionCount)
        origin = try container.decodeIfPresent(BurnBarControllerReviewRunOrigin.self, forKey: .origin) ?? .manual
        triggeredBy = try container.decodeIfPresent(String.self, forKey: .triggeredBy)
        launchedRunID = try container.decodeIfPresent(BurnBarRunID.self, forKey: .launchedRunID)
        metadata = try container.decodeIfPresent(BurnBarMetadata.self, forKey: .metadata) ?? [:]
    }
}

public struct BurnBarControllerActivitySnapshot: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let activeProjectSlug: String?
    public let projects: [BurnBarControllerActivityProject]

    public init(
        generatedAt: Date,
        activeProjectSlug: String? = nil,
        projects: [BurnBarControllerActivityProject]
    ) {
        self.generatedAt = generatedAt
        self.activeProjectSlug = activeProjectSlug
        self.projects = projects
    }
}

public struct BurnBarControllerActivityProject: Codable, Hashable, Identifiable, Sendable {
    public var id: String { projectSlug }

    public let projectSlug: String
    public let displayName: String
    public let summary: String
    public let latestActivityAt: Date?
    public let latestConversationID: String?
    public let latestConversationSessionID: BurnBarSessionID?
    public let latestConversationTitle: String?
    public let latestConversationSummary: String?
    public let latestQuestionPrompt: String?
    public let sessionCountLast7Days: Int
    public let totalCostLast7Days: Double
    public let totalTokensLast7Days: Int
    public let aliases: [String]
    public let preferredCadence: BurnBarControllerReviewCadence?
    public let automationMode: BurnBarControllerProjectAutomationMode?
    public let reviewModelID: String?
    public let scheduleHourLocal: Int?
    public let scheduleWeekdayLocal: Int?

    public init(
        projectSlug: String,
        displayName: String,
        summary: String,
        latestActivityAt: Date? = nil,
        latestConversationID: String? = nil,
        latestConversationSessionID: BurnBarSessionID? = nil,
        latestConversationTitle: String? = nil,
        latestConversationSummary: String? = nil,
        latestQuestionPrompt: String? = nil,
        sessionCountLast7Days: Int,
        totalCostLast7Days: Double,
        totalTokensLast7Days: Int,
        aliases: [String] = [],
        preferredCadence: BurnBarControllerReviewCadence? = nil,
        automationMode: BurnBarControllerProjectAutomationMode? = nil,
        reviewModelID: String? = nil,
        scheduleHourLocal: Int? = nil,
        scheduleWeekdayLocal: Int? = nil
    ) {
        self.projectSlug = projectSlug
        self.displayName = displayName
        self.summary = summary
        self.latestActivityAt = latestActivityAt
        self.latestConversationID = latestConversationID
        self.latestConversationSessionID = latestConversationSessionID
        self.latestConversationTitle = latestConversationTitle
        self.latestConversationSummary = latestConversationSummary
        self.latestQuestionPrompt = latestQuestionPrompt
        self.sessionCountLast7Days = sessionCountLast7Days
        self.totalCostLast7Days = totalCostLast7Days
        self.totalTokensLast7Days = totalTokensLast7Days
        self.aliases = aliases
        self.preferredCadence = preferredCadence
        self.automationMode = automationMode
        self.reviewModelID = reviewModelID
        self.scheduleHourLocal = scheduleHourLocal
        self.scheduleWeekdayLocal = scheduleWeekdayLocal
    }
}

public struct BurnBarAnswerRecord: Codable, Hashable, Sendable {
    public let answeredAt: Date
    public let answeredBy: String
    public let answer: String
    public let selectedOptionID: String?
    public let metadata: BurnBarMetadata

    public init(
        answeredAt: Date,
        answeredBy: String,
        answer: String,
        selectedOptionID: String? = nil,
        metadata: BurnBarMetadata = [:]
    ) {
        self.answeredAt = answeredAt
        self.answeredBy = answeredBy
        self.answer = answer
        self.selectedOptionID = selectedOptionID
        self.metadata = metadata
    }
}

public struct BurnBarQuestionOptionSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let answer: String
    public let metadata: BurnBarMetadata

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        answer: String,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.answer = answer
        self.metadata = metadata
    }
}

public struct BurnBarQuestionDeepLinkSnapshot: Codable, Hashable, Sendable {
    public let kind: BurnBarQuestionDeepLinkKind
    public let targetID: String?
    public let title: String
    public let subtitle: String?
    public let metadata: BurnBarMetadata

    public init(
        kind: BurnBarQuestionDeepLinkKind,
        targetID: String? = nil,
        title: String,
        subtitle: String? = nil,
        metadata: BurnBarMetadata = [:]
    ) {
        self.kind = kind
        self.targetID = targetID
        self.title = title
        self.subtitle = subtitle
        self.metadata = metadata
    }
}

public struct BurnBarQuestionTrackerSnapshot: Codable, Hashable, Sendable {
    public let isUnread: Bool
    public let surfacedAt: Date?
    public let firstNotifiedAt: Date?
    public let lastNotifiedAt: Date?
    public let notificationCount: Int
    public let metadata: BurnBarMetadata

    public init(
        isUnread: Bool = true,
        surfacedAt: Date? = nil,
        firstNotifiedAt: Date? = nil,
        lastNotifiedAt: Date? = nil,
        notificationCount: Int = 0,
        metadata: BurnBarMetadata = [:]
    ) {
        self.isUnread = isUnread
        self.surfacedAt = surfacedAt
        self.firstNotifiedAt = firstNotifiedAt
        self.lastNotifiedAt = lastNotifiedAt
        self.notificationCount = notificationCount
        self.metadata = metadata
    }
}

public struct BurnBarPendingQuestionSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarQuestionID
    public let projectSlug: String
    public let sessionID: BurnBarSessionID?
    public let title: String
    public let prompt: String
    public let stageLabel: String?
    public let status: BurnBarPendingQuestionStatus
    public let priority: BurnBarPendingQuestionPriority
    public let askedAt: Date
    public let dueAt: Date?
    public let latestAnswer: BurnBarAnswerRecord?
    public let answerPlaceholder: String?
    public let contextSummary: String?
    public let evidenceRefs: [String]
    public let suggestedOptions: [BurnBarQuestionOptionSnapshot]
    public let deepLink: BurnBarQuestionDeepLinkSnapshot?
    public let tracker: BurnBarQuestionTrackerSnapshot?
    public let metadata: BurnBarMetadata

    public init(
        id: BurnBarQuestionID,
        projectSlug: String,
        sessionID: BurnBarSessionID? = nil,
        title: String,
        prompt: String,
        stageLabel: String? = nil,
        status: BurnBarPendingQuestionStatus,
        priority: BurnBarPendingQuestionPriority,
        askedAt: Date,
        dueAt: Date? = nil,
        latestAnswer: BurnBarAnswerRecord? = nil,
        answerPlaceholder: String? = nil,
        contextSummary: String? = nil,
        evidenceRefs: [String] = [],
        suggestedOptions: [BurnBarQuestionOptionSnapshot] = [],
        deepLink: BurnBarQuestionDeepLinkSnapshot? = nil,
        tracker: BurnBarQuestionTrackerSnapshot? = nil,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.projectSlug = projectSlug
        self.sessionID = sessionID
        self.title = title
        self.prompt = prompt
        self.stageLabel = stageLabel
        self.status = status
        self.priority = priority
        self.askedAt = askedAt
        self.dueAt = dueAt
        self.latestAnswer = latestAnswer
        self.answerPlaceholder = answerPlaceholder
        self.contextSummary = contextSummary
        self.evidenceRefs = evidenceRefs
        self.suggestedOptions = suggestedOptions
        self.deepLink = deepLink
        self.tracker = tracker
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectSlug
        case sessionID
        case title
        case prompt
        case stageLabel
        case status
        case priority
        case askedAt
        case dueAt
        case latestAnswer
        case answerPlaceholder
        case contextSummary
        case evidenceRefs
        case suggestedOptions
        case deepLink
        case tracker
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(BurnBarQuestionID.self, forKey: .id)
        projectSlug = try container.decode(String.self, forKey: .projectSlug)
        sessionID = try container.decodeIfPresent(BurnBarSessionID.self, forKey: .sessionID)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        stageLabel = try container.decodeIfPresent(String.self, forKey: .stageLabel)
        status = try container.decode(BurnBarPendingQuestionStatus.self, forKey: .status)
        priority = try container.decode(BurnBarPendingQuestionPriority.self, forKey: .priority)
        askedAt = try container.decode(Date.self, forKey: .askedAt)
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        latestAnswer = try container.decodeIfPresent(BurnBarAnswerRecord.self, forKey: .latestAnswer)
        answerPlaceholder = try container.decodeIfPresent(String.self, forKey: .answerPlaceholder)
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary)
        evidenceRefs = try container.decodeIfPresent([String].self, forKey: .evidenceRefs) ?? []
        suggestedOptions = try container.decodeIfPresent([BurnBarQuestionOptionSnapshot].self, forKey: .suggestedOptions) ?? []
        deepLink = try container.decodeIfPresent(BurnBarQuestionDeepLinkSnapshot.self, forKey: .deepLink)
        tracker = try container.decodeIfPresent(BurnBarQuestionTrackerSnapshot.self, forKey: .tracker)
        metadata = try container.decodeIfPresent(BurnBarMetadata.self, forKey: .metadata) ?? [:]
    }
}

public struct BurnBarCalendarEntrySnapshot: Codable, Hashable, Sendable {
    public let externalID: String?
    public let title: String
    public let startAt: Date?
    public let endAt: Date?
    public let notes: String?

    public init(
        externalID: String? = nil,
        title: String,
        startAt: Date? = nil,
        endAt: Date? = nil,
        notes: String? = nil
    ) {
        self.externalID = externalID
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.notes = notes
    }
}

public struct BurnBarFollowupSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarFollowupID
    public let projectSlug: String
    public let questionID: BurnBarQuestionID?
    public let title: String
    public let summary: String
    public let stageLabel: String?
    public let status: BurnBarFollowupStatus
    public let kind: BurnBarFollowupKind
    public let createdAt: Date
    public let nextNudgeAt: Date?
    public let snoozeUntil: Date?
    public let calendarEntry: BurnBarCalendarEntrySnapshot?
    public let deepLink: BurnBarQuestionDeepLinkSnapshot?
    public let metadata: BurnBarMetadata

    public init(
        id: BurnBarFollowupID,
        projectSlug: String,
        questionID: BurnBarQuestionID? = nil,
        title: String,
        summary: String,
        stageLabel: String? = nil,
        status: BurnBarFollowupStatus,
        kind: BurnBarFollowupKind,
        createdAt: Date,
        nextNudgeAt: Date? = nil,
        snoozeUntil: Date? = nil,
        calendarEntry: BurnBarCalendarEntrySnapshot? = nil,
        deepLink: BurnBarQuestionDeepLinkSnapshot? = nil,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.projectSlug = projectSlug
        self.questionID = questionID
        self.title = title
        self.summary = summary
        self.stageLabel = stageLabel
        self.status = status
        self.kind = kind
        self.createdAt = createdAt
        self.nextNudgeAt = nextNudgeAt
        self.snoozeUntil = snoozeUntil
        self.calendarEntry = calendarEntry
        self.deepLink = deepLink
        self.metadata = metadata
    }
}

