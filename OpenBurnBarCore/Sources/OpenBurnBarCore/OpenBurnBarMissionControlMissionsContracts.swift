import Foundation

public struct BurnBarMissionApprovalSnapshot: Codable, Hashable, Sendable {
    public let approved: Bool
    public let approvedAt: Date?
    public let approvedBy: String?
    public let note: String?

    public init(
        approved: Bool,
        approvedAt: Date? = nil,
        approvedBy: String? = nil,
        note: String? = nil
    ) {
        self.approved = approved
        self.approvedAt = approvedAt
        self.approvedBy = approvedBy
        self.note = note
    }
}

public struct BurnBarMissionBurnRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let amount: Double
    public let unit: String
    public let recordedAt: Date

    public init(
        id: String,
        label: String,
        amount: Double,
        unit: String,
        recordedAt: Date
    ) {
        self.id = id
        self.label = label
        self.amount = amount
        self.unit = unit
        self.recordedAt = recordedAt
    }
}

public struct BurnBarMissionPacketSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarMissionPacketID
    public let missionID: BurnBarMissionID
    public let workerName: String
    public let objective: String
    public let status: BurnBarMissionPacketStatus
    public let runID: BurnBarRunID?
    public let dispatchedAt: Date?
    public let completedAt: Date?
    public let metadata: BurnBarMetadata

    public init(
        id: BurnBarMissionPacketID,
        missionID: BurnBarMissionID,
        workerName: String,
        objective: String,
        status: BurnBarMissionPacketStatus,
        runID: BurnBarRunID? = nil,
        dispatchedAt: Date? = nil,
        completedAt: Date? = nil,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.missionID = missionID
        self.workerName = workerName
        self.objective = objective
        self.status = status
        self.runID = runID
        self.dispatchedAt = dispatchedAt
        self.completedAt = completedAt
        self.metadata = metadata
    }
}

public enum BurnBarPRLinkageState: String, Codable, CaseIterable, Hashable, Sendable {
    case opened
    case merged
    case closed
}

public struct BurnBarPRLinkageSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let repository: String
    public let prNumberOrID: String
    public let url: String
    public let state: BurnBarPRLinkageState
    public let mergeCommitSHA: String?
    public let mergedAt: Date?
    public let closedAt: Date?

    public var isMerged: Bool {
        state == .merged || mergeCommitSHA?.isEmpty == false || mergedAt != nil
    }

    public init(
        schemaVersion: Int = BurnBarPRLinkageSnapshot.currentSchemaVersion,
        repository: String,
        prNumberOrID: String,
        url: String,
        state: BurnBarPRLinkageState,
        mergeCommitSHA: String? = nil,
        mergedAt: Date? = nil,
        closedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.repository = repository
        self.prNumberOrID = prNumberOrID
        self.url = url
        self.state = state
        self.mergeCommitSHA = mergeCommitSHA
        self.mergedAt = mergedAt
        self.closedAt = closedAt
    }

    public static func fromMetadata(_ metadata: BurnBarMetadata) -> BurnBarPRLinkageSnapshot? {
        if let nested = nestedObject(
            in: metadata,
            keys: ["pr_linkage", "prLinkage", "pull_request", "pullRequest"]
        ), let parsed = parseObject(nested) {
            return parsed
        }
        return parseObject(metadata)
    }

    private static func parseObject(_ object: [String: BurnBarJSONValue]) -> BurnBarPRLinkageSnapshot? {
        guard let repository = firstString(
            in: object,
            keys: ["repository", "repo", "pr_repository", "pull_request_repository"]
        ),
              let prNumberOrID = firstString(
                  in: object,
                  keys: ["prNumberOrID", "pr_number_or_id", "pr_number", "pr_id", "pull_request_id", "number"]
              ),
              let url = firstString(
                  in: object,
                  keys: ["url", "pr_url", "pull_request_url"]
              ) else {
            return nil
        }

        let mergeCommitSHA = firstString(
            in: object,
            keys: ["mergeCommitSHA", "merge_commit_sha", "pr_merge_commit_sha"]
        )
        let mergedAt = firstDate(
            in: object,
            keys: ["mergedAt", "merged_at", "pr_merged_at"]
        )
        let closedAt = firstDate(
            in: object,
            keys: ["closedAt", "closed_at", "pr_closed_at"]
        )

        let explicitState = firstString(
            in: object,
            keys: ["state", "pr_state", "pull_request_state"]
        )
        let mergedFlag = firstBool(
            in: object,
            keys: ["isMerged", "is_merged", "pr_is_merged", "merged"]
        ) ?? false
        let resolvedState = parseState(
            explicitState,
            mergedSignal: mergedFlag || mergedAt != nil || mergeCommitSHA?.isEmpty == false,
            closedSignal: closedAt != nil
        )

        return BurnBarPRLinkageSnapshot(
            schemaVersion: Int(firstNumber(in: object, keys: ["schemaVersion", "schema_version"]) ?? Double(currentSchemaVersion)),
            repository: repository,
            prNumberOrID: prNumberOrID,
            url: url,
            state: resolvedState,
            mergeCommitSHA: mergeCommitSHA,
            mergedAt: mergedAt,
            closedAt: closedAt
        )
    }

    private static func parseState(
        _ rawValue: String?,
        mergedSignal: Bool,
        closedSignal: Bool
    ) -> BurnBarPRLinkageState {
        if let rawValue {
            switch rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "_") {
            case "open", "opened":
                return .opened
            case "merged":
                return .merged
            case "closed":
                return .closed
            default:
                break
            }
        }
        if mergedSignal {
            return .merged
        }
        if closedSignal {
            return .closed
        }
        return .opened
    }

    private static func nestedObject(
        in object: [String: BurnBarJSONValue],
        keys: [String]
    ) -> [String: BurnBarJSONValue]? {
        for key in keys {
            if case .object(let nested)? = object[key] {
                return nested
            }
        }
        return nil
    }

    private static func firstString(
        in object: [String: BurnBarJSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            case .number(let raw):
                return String(raw)
            default:
                continue
            }
        }
        return nil
    }

    private static func firstNumber(
        in object: [String: BurnBarJSONValue],
        keys: [String]
    ) -> Double? {
        for key in keys {
            guard case .number(let raw)? = object[key] else { continue }
            return raw
        }
        return nil
    }

    private static func firstBool(
        in object: [String: BurnBarJSONValue],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .bool(let raw):
                return raw
            case .number(let raw):
                return raw != 0
            default:
                continue
            }
        }
        return nil
    }

    private static func firstDate(
        in object: [String: BurnBarJSONValue],
        keys: [String]
    ) -> Date? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .number(let epoch):
                return Date(timeIntervalSince1970: epoch)
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let date = metadataDateFormatter.date(from: trimmed) {
                    return date
                }
            default:
                continue
            }
        }
        return nil
    }

    private static let metadataDateFormatter = ISO8601DateFormatter()
}

public struct BurnBarMissionResultSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarMissionResultID
    public let missionID: BurnBarMissionID
    public let packetID: BurnBarMissionPacketID?
    public let runID: BurnBarRunID?
    public let status: BurnBarMissionResultStatus
    public let summary: String
    public let detail: String?
    public let burnDelta: Double
    public let createdAt: Date
    public let evidenceRefs: [String]
    public let prLinkage: BurnBarPRLinkageSnapshot?
    public let metadata: BurnBarMetadata

    public init(
        id: BurnBarMissionResultID,
        missionID: BurnBarMissionID,
        packetID: BurnBarMissionPacketID? = nil,
        runID: BurnBarRunID? = nil,
        status: BurnBarMissionResultStatus,
        summary: String,
        detail: String? = nil,
        burnDelta: Double = 0,
        createdAt: Date,
        evidenceRefs: [String] = [],
        prLinkage: BurnBarPRLinkageSnapshot? = nil,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.missionID = missionID
        self.packetID = packetID
        self.runID = runID
        self.status = status
        self.summary = summary
        self.detail = detail
        self.burnDelta = burnDelta
        self.createdAt = createdAt
        self.evidenceRefs = evidenceRefs
        self.prLinkage = prLinkage ?? BurnBarPRLinkageSnapshot.fromMetadata(metadata)
        self.metadata = metadata
    }
}

public struct BurnBarAutoTakeoverRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let projectSlug: String
    public let missionID: BurnBarMissionID?
    public let sourceRunID: BurnBarRunID?
    public let takeoverRunID: BurnBarRunID?
    public let status: BurnBarAutoTakeoverStatus
    public let reason: String
    public let createdAt: Date
    public let updatedAt: Date
    public let metadata: BurnBarMetadata

    public init(
        id: String,
        projectSlug: String,
        missionID: BurnBarMissionID? = nil,
        sourceRunID: BurnBarRunID? = nil,
        takeoverRunID: BurnBarRunID? = nil,
        status: BurnBarAutoTakeoverStatus,
        reason: String,
        createdAt: Date,
        updatedAt: Date,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.projectSlug = projectSlug
        self.missionID = missionID
        self.sourceRunID = sourceRunID
        self.takeoverRunID = takeoverRunID
        self.status = status
        self.reason = reason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public struct BurnBarMissionSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarMissionID
    public let projectSlug: String
    public let title: String
    public let summary: String
    public let status: BurnBarMissionStatus
    public let recommendation: BurnBarMissionRecommendation
    public let createdAt: Date
    public let updatedAt: Date
    public let approval: BurnBarMissionApprovalSnapshot
    public let packets: [BurnBarMissionPacketSnapshot]
    public let results: [BurnBarMissionResultSnapshot]
    public let burnRecords: [BurnBarMissionBurnRecord]
    public let takeoverHistory: [BurnBarAutoTakeoverRecord]?
    public let prLinkage: BurnBarPRLinkageSnapshot?
    public let metadata: BurnBarMetadata

    public init(
        id: BurnBarMissionID,
        projectSlug: String,
        title: String,
        summary: String,
        status: BurnBarMissionStatus,
        recommendation: BurnBarMissionRecommendation,
        createdAt: Date,
        updatedAt: Date,
        approval: BurnBarMissionApprovalSnapshot,
        packets: [BurnBarMissionPacketSnapshot] = [],
        results: [BurnBarMissionResultSnapshot] = [],
        burnRecords: [BurnBarMissionBurnRecord] = [],
        takeoverHistory: [BurnBarAutoTakeoverRecord]? = nil,
        prLinkage: BurnBarPRLinkageSnapshot? = nil,
        metadata: BurnBarMetadata = [:]
    ) {
        self.id = id
        self.projectSlug = projectSlug
        self.title = title
        self.summary = summary
        self.status = status
        self.recommendation = recommendation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.approval = approval
        self.packets = packets
        self.results = results
        self.burnRecords = burnRecords
        self.takeoverHistory = takeoverHistory
        self.prLinkage = prLinkage
            ?? results
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.rawValue < $1.id.rawValue
            }
            .compactMap(\.prLinkage)
            .last
        self.metadata = metadata
    }
}

public struct BurnBarNotificationChannelHealth: Codable, Hashable, Sendable {
    public let channel: BurnBarNotificationChannel
    public let status: BurnBarNotificationHealthStatus
    public let detail: String?
    public let checkedAt: Date

    public init(
        channel: BurnBarNotificationChannel,
        status: BurnBarNotificationHealthStatus,
        detail: String? = nil,
        checkedAt: Date
    ) {
        self.channel = channel
        self.status = status
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

public struct BurnBarLocalNotificationConfig: Codable, Hashable, Sendable {
    public let isEnabled: Bool
    public let quietHoursStart: Int?
    public let quietHoursEnd: Int?

    public init(
        isEnabled: Bool,
        quietHoursStart: Int? = nil,
        quietHoursEnd: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
    }
}

public struct BurnBarTelegramNotificationConfig: Codable, Hashable, Sendable {
    public let isEnabled: Bool
    public let botTokenConfigured: Bool
    public let botToken: String?
    public let botTokenHint: String?
    public let chatID: String?
    public let supportedCommands: [BurnBarTelegramCommand]

    public init(
        isEnabled: Bool,
        botTokenConfigured: Bool,
        botToken: String? = nil,
        botTokenHint: String? = nil,
        chatID: String? = nil,
        supportedCommands: [BurnBarTelegramCommand] = BurnBarTelegramCommand.allCases
    ) {
        self.isEnabled = isEnabled
        self.botTokenConfigured = botTokenConfigured
        self.botToken = botToken
        self.botTokenHint = botTokenHint
        self.chatID = chatID
        self.supportedCommands = supportedCommands
    }
}

public struct BurnBarCalendarNotificationConfig: Codable, Hashable, Sendable {
    public let isEnabled: Bool
    public let defaultDurationMinutes: Int
    public let defaultCalendarName: String?

    public init(
        isEnabled: Bool,
        defaultDurationMinutes: Int,
        defaultCalendarName: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.defaultDurationMinutes = defaultDurationMinutes
        self.defaultCalendarName = defaultCalendarName
    }
}

public struct BurnBarNotificationConfig: Codable, Hashable, Sendable {
    public let defaultSnoozeMinutes: Int
    public let nudgeHoursLocal: [Int]
    public let local: BurnBarLocalNotificationConfig
    public let telegram: BurnBarTelegramNotificationConfig
    public let calendar: BurnBarCalendarNotificationConfig

    public init(
        defaultSnoozeMinutes: Int,
        nudgeHoursLocal: [Int],
        local: BurnBarLocalNotificationConfig,
        telegram: BurnBarTelegramNotificationConfig,
        calendar: BurnBarCalendarNotificationConfig
    ) {
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
        self.nudgeHoursLocal = nudgeHoursLocal
        self.local = local
        self.telegram = telegram
        self.calendar = calendar
    }
}

public struct BurnBarNotificationHealthSnapshot: Codable, Hashable, Sendable {
    public let checkedAt: Date
    public let channels: [BurnBarNotificationChannelHealth]

    public init(checkedAt: Date, channels: [BurnBarNotificationChannelHealth]) {
        self.checkedAt = checkedAt
        self.channels = channels
    }
}

public struct BurnBarNotificationCommandResponse: Codable, Hashable, Sendable {
    public let command: BurnBarTelegramCommand
    public let ok: Bool
    public let message: String
    public let followup: BurnBarFollowupSnapshot?
    public let question: BurnBarPendingQuestionSnapshot?
    public let mission: BurnBarMissionSnapshot?

    public init(
        command: BurnBarTelegramCommand,
        ok: Bool,
        message: String,
        followup: BurnBarFollowupSnapshot? = nil,
        question: BurnBarPendingQuestionSnapshot? = nil,
        mission: BurnBarMissionSnapshot? = nil
    ) {
        self.command = command
        self.ok = ok
        self.message = message
        self.followup = followup
        self.question = question
        self.mission = mission
    }
}

public struct BurnBarSimulatorRunSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarSimulatorRunID
    public let projectSlug: String
    public let scenarioName: String
    public let status: BurnBarReplayStatus
    public let seed: Int
    public let startedAt: Date
    public let completedAt: Date?
    public let emittedEvents: [BurnBarControllerEvent]
    public let projectionStatus: [BurnBarProjectionStatusSnapshot]
    public let summary: String

    public init(
        id: BurnBarSimulatorRunID,
        projectSlug: String,
        scenarioName: String,
        status: BurnBarReplayStatus,
        seed: Int,
        startedAt: Date,
        completedAt: Date? = nil,
        emittedEvents: [BurnBarControllerEvent] = [],
        projectionStatus: [BurnBarProjectionStatusSnapshot] = [],
        summary: String
    ) {
        self.id = id
        self.projectSlug = projectSlug
        self.scenarioName = scenarioName
        self.status = status
        self.seed = seed
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.emittedEvents = emittedEvents
        self.projectionStatus = projectionStatus
        self.summary = summary
    }
}

public struct BurnBarControllerSummaryRequest: Codable, Hashable, Sendable {
    public let projectSlug: String?
    public let includeRecentEvents: Bool
    public let includeProjectionStatus: Bool

    public init(
        projectSlug: String? = nil,
        includeRecentEvents: Bool = true,
        includeProjectionStatus: Bool = true
    ) {
        self.projectSlug = projectSlug
        self.includeRecentEvents = includeRecentEvents
        self.includeProjectionStatus = includeProjectionStatus
    }
}

public struct BurnBarControllerSummaryResponse: Codable, Hashable, Sendable {
    public let summary: BurnBarControllerSummary

    public init(summary: BurnBarControllerSummary) {
        self.summary = summary
    }
}

public struct BurnBarControllerProjectsListRequest: Codable, Hashable, Sendable {
    public let includePaused: Bool
    public let limit: Int

    public init(includePaused: Bool = false, limit: Int = 100) {
        self.includePaused = includePaused
        self.limit = limit
    }
}

public struct BurnBarControllerProjectsListResponse: Codable, Hashable, Sendable {
    public let projects: [BurnBarReviewProjectSnapshot]

    public init(projects: [BurnBarReviewProjectSnapshot]) {
        self.projects = projects
    }
}

public struct BurnBarControllerProjectGetRequest: Codable, Hashable, Sendable {
    public let projectSlug: String

    public init(projectSlug: String) {
        self.projectSlug = projectSlug
    }
}

public struct BurnBarControllerProjectResponse: Codable, Hashable, Sendable {
    public let project: BurnBarReviewProjectSnapshot?

    public init(project: BurnBarReviewProjectSnapshot?) {
        self.project = project
    }
}

public struct BurnBarControllerProjectUpsertRequest: Codable, Hashable, Sendable {
    public let project: BurnBarReviewProjectSnapshot

    public init(project: BurnBarReviewProjectSnapshot) {
        self.project = project
    }
}

public struct BurnBarControllerReviewRunRecordRequest: Codable, Hashable, Sendable {
    public let run: BurnBarReviewRunSnapshot

    public init(run: BurnBarReviewRunSnapshot) {
        self.run = run
    }
}

public struct BurnBarControllerReviewRunRecordResponse: Codable, Hashable, Sendable {
    public let run: BurnBarReviewRunSnapshot
    public let summary: BurnBarControllerSummary

    public init(run: BurnBarReviewRunSnapshot, summary: BurnBarControllerSummary) {
        self.run = run
        self.summary = summary
    }
}

public struct BurnBarQuestionCreateRequest: Codable, Hashable, Sendable {
    public let question: BurnBarPendingQuestionSnapshot

    public init(question: BurnBarPendingQuestionSnapshot) {
        self.question = question
    }
}

public struct BurnBarQuestionResponse: Codable, Hashable, Sendable {
    public let question: BurnBarPendingQuestionSnapshot?

    public init(question: BurnBarPendingQuestionSnapshot?) {
        self.question = question
    }
}

public struct BurnBarQuestionsListRequest: Codable, Hashable, Sendable {
    public let projectSlug: String?
    public let statuses: [BurnBarPendingQuestionStatus]
    public let limit: Int

    public init(
        projectSlug: String? = nil,
        statuses: [BurnBarPendingQuestionStatus] = [.pending],
        limit: Int = 100
    ) {
        self.projectSlug = projectSlug
        self.statuses = statuses
        self.limit = limit
    }
}

public struct BurnBarQuestionsListResponse: Codable, Hashable, Sendable {
    public let questions: [BurnBarPendingQuestionSnapshot]

    public init(questions: [BurnBarPendingQuestionSnapshot]) {
        self.questions = questions
    }
}

public struct BurnBarQuestionGetRequest: Codable, Hashable, Sendable {
    public let questionID: BurnBarQuestionID

    public init(questionID: BurnBarQuestionID) {
        self.questionID = questionID
    }
}

public struct BurnBarQuestionAnswerRequest: Codable, Hashable, Sendable {
    public let questionID: BurnBarQuestionID
    public let answeredBy: String
    public let answer: String
    public let selectedOptionID: String?
    public let markFollowupDone: Bool
    public let metadata: BurnBarMetadata

    public init(
        questionID: BurnBarQuestionID,
        answeredBy: String,
        answer: String,
        selectedOptionID: String? = nil,
        markFollowupDone: Bool = true,
        metadata: BurnBarMetadata = [:]
    ) {
        self.questionID = questionID
        self.answeredBy = answeredBy
        self.answer = answer
        self.selectedOptionID = selectedOptionID
        self.markFollowupDone = markFollowupDone
        self.metadata = metadata
    }
}

public struct BurnBarQuestionAnswerResponse: Codable, Hashable, Sendable {
    public let question: BurnBarPendingQuestionSnapshot
    public let followup: BurnBarFollowupSnapshot?
    public let emittedEvent: BurnBarControllerEvent?

    public init(
        question: BurnBarPendingQuestionSnapshot,
        followup: BurnBarFollowupSnapshot? = nil,
        emittedEvent: BurnBarControllerEvent? = nil
    ) {
        self.question = question
        self.followup = followup
        self.emittedEvent = emittedEvent
    }
}

public struct BurnBarFollowupCreateRequest: Codable, Hashable, Sendable {
    public let followup: BurnBarFollowupSnapshot

    public init(followup: BurnBarFollowupSnapshot) {
        self.followup = followup
    }
}

public struct BurnBarFollowupsListRequest: Codable, Hashable, Sendable {
    public let projectSlug: String?
    public let statuses: [BurnBarFollowupStatus]
    public let limit: Int

    public init(
        projectSlug: String? = nil,
        statuses: [BurnBarFollowupStatus] = [.open, .snoozed],
        limit: Int = 100
    ) {
        self.projectSlug = projectSlug
        self.statuses = statuses
        self.limit = limit
    }
}

public struct BurnBarFollowupsListResponse: Codable, Hashable, Sendable {
    public let followups: [BurnBarFollowupSnapshot]

    public init(followups: [BurnBarFollowupSnapshot]) {
        self.followups = followups
    }
}

public struct BurnBarFollowupDoneRequest: Codable, Hashable, Sendable {
    public let followupID: BurnBarFollowupID
    public let actor: String
    public let note: String?

    public init(followupID: BurnBarFollowupID, actor: String, note: String? = nil) {
        self.followupID = followupID
        self.actor = actor
        self.note = note
    }
}

public struct BurnBarFollowupSnoozeRequest: Codable, Hashable, Sendable {
    public let followupID: BurnBarFollowupID
    public let actor: String
    public let snoozeUntil: Date
    public let note: String?

    public init(
        followupID: BurnBarFollowupID,
        actor: String,
        snoozeUntil: Date,
        note: String? = nil
    ) {
        self.followupID = followupID
        self.actor = actor
        self.snoozeUntil = snoozeUntil
        self.note = note
    }
}

public struct BurnBarFollowupCalendarRequest: Codable, Hashable, Sendable {
    public let followupID: BurnBarFollowupID
    public let actor: String
    public let action: BurnBarCalendarAction
    public let entry: BurnBarCalendarEntrySnapshot

    public init(
        followupID: BurnBarFollowupID,
        actor: String,
        action: BurnBarCalendarAction,
        entry: BurnBarCalendarEntrySnapshot
    ) {
        self.followupID = followupID
        self.actor = actor
        self.action = action
        self.entry = entry
    }
}

public struct BurnBarFollowupMutationResponse: Codable, Hashable, Sendable {
    public let followup: BurnBarFollowupSnapshot
    public let emittedEvent: BurnBarControllerEvent?

    public init(followup: BurnBarFollowupSnapshot, emittedEvent: BurnBarControllerEvent? = nil) {
        self.followup = followup
        self.emittedEvent = emittedEvent
    }
}

public struct BurnBarMissionCreateRequest: Codable, Hashable, Sendable {
    public let projectSlug: String
    public let title: String
    public let summary: String
    public let createdBy: String
    public let recommendation: BurnBarMissionRecommendation
    public let metadata: BurnBarMetadata

    public init(
        projectSlug: String,
        title: String,
        summary: String,
        createdBy: String,
        recommendation: BurnBarMissionRecommendation,
        metadata: BurnBarMetadata = [:]
    ) {
        self.projectSlug = projectSlug
        self.title = title
        self.summary = summary
        self.createdBy = createdBy
        self.recommendation = recommendation
        self.metadata = metadata
    }
}

public struct BurnBarMissionListRequest: Codable, Hashable, Sendable {
    public let projectSlug: String?
    public let statuses: [BurnBarMissionStatus]
    public let limit: Int

    public init(
        projectSlug: String? = nil,
        statuses: [BurnBarMissionStatus] = BurnBarMissionStatus.allCases,
        limit: Int = 100
    ) {
        self.projectSlug = projectSlug
        self.statuses = statuses
        self.limit = limit
    }
}

public struct BurnBarMissionListResponse: Codable, Hashable, Sendable {
    public let missions: [BurnBarMissionSnapshot]

    public init(missions: [BurnBarMissionSnapshot]) {
        self.missions = missions
    }
}

public struct BurnBarMissionGetRequest: Codable, Hashable, Sendable {
    public let missionID: BurnBarMissionID

    public init(missionID: BurnBarMissionID) {
        self.missionID = missionID
    }
}

public struct BurnBarMissionResponse: Codable, Hashable, Sendable {
    public let mission: BurnBarMissionSnapshot?

    public init(mission: BurnBarMissionSnapshot?) {
        self.mission = mission
    }
}

public struct BurnBarMissionApproveRequest: Codable, Hashable, Sendable {
    public let missionID: BurnBarMissionID
    public let actor: String
    public let note: String?

    public init(missionID: BurnBarMissionID, actor: String, note: String? = nil) {
        self.missionID = missionID
        self.actor = actor
        self.note = note
    }
}

public struct BurnBarMissionCancelRequest: Codable, Hashable, Sendable {
    public let missionID: BurnBarMissionID
    public let actor: String
    public let note: String?

    public init(missionID: BurnBarMissionID, actor: String, note: String? = nil) {
        self.missionID = missionID
        self.actor = actor
        self.note = note
    }
}

public struct BurnBarMissionDispatchPacketRequest: Codable, Hashable, Sendable {
    public let missionID: BurnBarMissionID
    public let actor: String
    public let packet: BurnBarMissionPacketSnapshot

    public init(
        missionID: BurnBarMissionID,
        actor: String,
        packet: BurnBarMissionPacketSnapshot
    ) {
        self.missionID = missionID
        self.actor = actor
        self.packet = packet
    }
}

public struct BurnBarMissionRecordResultRequest: Codable, Hashable, Sendable {
    public let missionID: BurnBarMissionID
    public let result: BurnBarMissionResultSnapshot

    public init(missionID: BurnBarMissionID, result: BurnBarMissionResultSnapshot) {
        self.missionID = missionID
        self.result = result
    }
}

public struct BurnBarMissionMutationResponse: Codable, Hashable, Sendable {
    public let mission: BurnBarMissionSnapshot
    public let emittedEvent: BurnBarControllerEvent?

    public init(mission: BurnBarMissionSnapshot, emittedEvent: BurnBarControllerEvent? = nil) {
        self.mission = mission
        self.emittedEvent = emittedEvent
    }
}

public struct BurnBarNotificationConfigGetRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarNotificationConfigUpdateRequest: Codable, Hashable, Sendable {
    public let config: BurnBarNotificationConfig

    public init(config: BurnBarNotificationConfig) {
        self.config = config
    }
}

public struct BurnBarNotificationConfigResponse: Codable, Hashable, Sendable {
    public let config: BurnBarNotificationConfig

    public init(config: BurnBarNotificationConfig) {
        self.config = config
    }
}

public struct BurnBarNotificationHealthRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarNotificationHealthResponse: Codable, Hashable, Sendable {
    public let health: BurnBarNotificationHealthSnapshot

    public init(health: BurnBarNotificationHealthSnapshot) {
        self.health = health
    }
}

public struct BurnBarNotificationCommandRequest: Codable, Hashable, Sendable {
    public let command: BurnBarTelegramCommand
    public let arguments: [String]
    public let actor: String

    public init(command: BurnBarTelegramCommand, arguments: [String] = [], actor: String) {
        self.command = command
        self.arguments = arguments
        self.actor = actor
    }
}

public struct BurnBarSimulatorRunRequest: Codable, Hashable, Sendable {
    public let projectSlug: String
    public let scenarioName: String
    public let seed: Int
    public let injectedEvents: [BurnBarControllerEvent]
    public let metadata: BurnBarMetadata

    public init(
        projectSlug: String,
        scenarioName: String,
        seed: Int,
        injectedEvents: [BurnBarControllerEvent] = [],
        metadata: BurnBarMetadata = [:]
    ) {
        self.projectSlug = projectSlug
        self.scenarioName = scenarioName
        self.seed = seed
        self.injectedEvents = injectedEvents
        self.metadata = metadata
    }
}

public struct BurnBarSimulatorListRequest: Codable, Hashable, Sendable {
    public let projectSlug: String?
    public let limit: Int

    public init(projectSlug: String? = nil, limit: Int = 50) {
        self.projectSlug = projectSlug
        self.limit = limit
    }
}

public struct BurnBarSimulatorListResponse: Codable, Hashable, Sendable {
    public let runs: [BurnBarSimulatorRunSnapshot]

    public init(runs: [BurnBarSimulatorRunSnapshot]) {
        self.runs = runs
    }
}

public struct BurnBarSimulatorReplayRequest: Codable, Hashable, Sendable {
    public let runID: BurnBarSimulatorRunID
    public let fromCheckpointID: BurnBarProjectionCheckpointID?
    public let includeEvents: Bool

    public init(
        runID: BurnBarSimulatorRunID,
        fromCheckpointID: BurnBarProjectionCheckpointID? = nil,
        includeEvents: Bool = true
    ) {
        self.runID = runID
        self.fromCheckpointID = fromCheckpointID
        self.includeEvents = includeEvents
    }
}

public struct BurnBarSimulatorRunResponse: Codable, Hashable, Sendable {
    public let run: BurnBarSimulatorRunSnapshot

    public init(run: BurnBarSimulatorRunSnapshot) {
        self.run = run
    }
}

public struct BurnBarProjectionRebuildRequest: Codable, Hashable, Sendable {
    public let projectionNames: [String]
    public let fromCheckpointID: BurnBarProjectionCheckpointID?

    public init(projectionNames: [String], fromCheckpointID: BurnBarProjectionCheckpointID? = nil) {
        self.projectionNames = projectionNames
        self.fromCheckpointID = fromCheckpointID
    }
}

public struct BurnBarProjectionRebuildResponse: Codable, Hashable, Sendable {
    public let status: [BurnBarProjectionStatusSnapshot]

    public init(status: [BurnBarProjectionStatusSnapshot]) {
        self.status = status
    }
}
