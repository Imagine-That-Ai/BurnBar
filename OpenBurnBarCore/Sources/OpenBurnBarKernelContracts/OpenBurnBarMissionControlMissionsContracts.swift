import Foundation
import OpenBurnBarKernelPlatform

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
            schemaVersion: firstInteger(in: object, keys: ["schemaVersion", "schema_version"]) ?? currentSchemaVersion,
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
                if let integer = boundedIntegerString(raw) {
                    return integer
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func firstInteger(
        in object: [String: BurnBarJSONValue],
        keys: [String]
    ) -> Int? {
        for key in keys {
            guard case .number(let raw)? = object[key],
                  raw.isFinite,
                  raw.rounded(.towardZero) == raw,
                  let value = Int(exactly: raw) else {
                continue
            }
            return value
        }
        return nil
    }

    private static func boundedIntegerString(_ raw: Double) -> String? {
        guard raw.isFinite,
              raw.rounded(.towardZero) == raw,
              raw >= 0,
              raw <= 9_007_199_254_740_991 else {
            return nil
        }
        return String(Int64(raw))
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
                if let date = ThreadSafeISO8601DateFormatter.parseBasic(trimmed) {
                    return date
                }
            default:
                continue
            }
        }
        return nil
    }
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

public struct BurnBarControllerRuntimeSnapshotRequest: Codable, Hashable, Sendable {
    public init() {}
}

/// Everything the app's controller runtime needs in ONE daemon round trip.
/// Replaces the legacy six sequential RPCs (summary, questions, followups,
/// missions, notification health, simulator runs) that each paid a full
/// connect/close cycle on every popover open and periodic tick. The same
/// payload rides along in controller-mutation responses so a mutation
/// costs one connection instead of seven. Clients MUST tolerate its
/// absence (older daemons) and fall back to the per-list RPCs.
public struct BurnBarControllerRuntimeSnapshotPayload: Codable, Hashable, Sendable {
    public let summary: BurnBarControllerSummary
    public let questions: [BurnBarPendingQuestionSnapshot]
    public let followups: [BurnBarFollowupSnapshot]
    public let missions: [BurnBarMissionSnapshot]
    public let notificationHealth: BurnBarNotificationHealthSnapshot
    public let simulatorRuns: [BurnBarSimulatorRunSnapshot]

    public init(
        summary: BurnBarControllerSummary,
        questions: [BurnBarPendingQuestionSnapshot],
        followups: [BurnBarFollowupSnapshot],
        missions: [BurnBarMissionSnapshot],
        notificationHealth: BurnBarNotificationHealthSnapshot,
        simulatorRuns: [BurnBarSimulatorRunSnapshot]
    ) {
        self.summary = summary
        self.questions = questions
        self.followups = followups
        self.missions = missions
        self.notificationHealth = notificationHealth
        self.simulatorRuns = simulatorRuns
    }
}

public struct BurnBarControllerRuntimeSnapshotResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarControllerRuntimeSnapshotPayload

    public init(snapshot: BurnBarControllerRuntimeSnapshotPayload) {
        self.snapshot = snapshot
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
    /// Post-mutation controller runtime, embedded so the client skips its
    /// follow-up snapshot RPCs. Optional across the daemon version-skew
    /// boundary: absent from older daemons (client falls back to the
    /// legacy follow-up calls); ignored by older clients.
    public let runtimeSnapshot: BurnBarControllerRuntimeSnapshotPayload?

    public init(
        question: BurnBarPendingQuestionSnapshot,
        followup: BurnBarFollowupSnapshot? = nil,
        emittedEvent: BurnBarControllerEvent? = nil,
        runtimeSnapshot: BurnBarControllerRuntimeSnapshotPayload? = nil
    ) {
        self.question = question
        self.followup = followup
        self.emittedEvent = emittedEvent
        self.runtimeSnapshot = runtimeSnapshot
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
    /// Post-mutation controller runtime — same version-skew contract as
    /// `BurnBarQuestionAnswerResponse.runtimeSnapshot`.
    public let runtimeSnapshot: BurnBarControllerRuntimeSnapshotPayload?

    public init(
        followup: BurnBarFollowupSnapshot,
        emittedEvent: BurnBarControllerEvent? = nil,
        runtimeSnapshot: BurnBarControllerRuntimeSnapshotPayload? = nil
    ) {
        self.followup = followup
        self.emittedEvent = emittedEvent
        self.runtimeSnapshot = runtimeSnapshot
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

// MARK: - Remote mission authorization (daemon.mission.authorizeRemote)
//
// M2 of the split-brain remediation program
// (docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md, Phase 2). The
// menubar GUI remains the TRANSPORT for remote (mobile/Wand) missions — it
// alone can authenticate to Firebase, attach the listener, and unseal
// cloud-vault payloads — but forwards the DECODED decision inputs to the
// daemon so a single authority issues the trust / approval / capability /
// fan-out verdict. The request deliberately carries a prompt summary + hash
// only: never sealed payloads, never the full prompt.

/// The capability grant a remote mission asks the executor Mac to run with.
/// Doubles as the daemon's authorized CEILING in the response: the ceiling is
/// never wider than the request, and capability identifiers the daemon does
/// not recognize are denied by default (dropped from the ceiling).
public struct BurnBarRemoteMissionCapabilityGrantRequest: Codable, Hashable, Sendable {
    public let commandsAllowed: Bool
    public let fileEditsAllowed: Bool
    /// Forward-compatibility lane for capability identifiers newer clients may
    /// request. Deny-by-default: an authorizer that does not recognize an
    /// identifier never carries it into the authorized ceiling.
    public let additionalCapabilities: [String]

    public init(
        commandsAllowed: Bool,
        fileEditsAllowed: Bool,
        additionalCapabilities: [String] = []
    ) {
        self.commandsAllowed = commandsAllowed
        self.fileEditsAllowed = fileEditsAllowed
        self.additionalCapabilities = additionalCapabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Fail closed: an ABSENT capability key on the wire is a non-grant,
        // never a default-open.
        commandsAllowed = try container.decodeIfPresent(Bool.self, forKey: .commandsAllowed) ?? false
        fileEditsAllowed = try container.decodeIfPresent(Bool.self, forKey: .fileEditsAllowed) ?? false
        additionalCapabilities = try container.decodeIfPresent([String].self, forKey: .additionalCapabilities) ?? []
    }
}

public enum BurnBarRemoteMissionAuthorizationVerdict: String, Codable, CaseIterable, Hashable, Sendable {
    case authorized
    case requiresApproval = "requires_approval"
    case denied
}

public enum BurnBarRemoteMissionDenialReason: String, Codable, CaseIterable, Hashable, Sendable {
    /// The executor device's trust state is a KNOWN not-trusted state.
    case untrustedDevice = "untrusted_device"
    /// The executor device's trust state is unrecognized — fail closed.
    case unknownTrustState = "unknown_trust_state"
    /// The mission's approval handshake was rejected or cancelled.
    case approvalRejected = "approval_rejected"
    /// The requested fan-out exceeds the entitlement tier's parallelism cap.
    case fanOutCapExceeded = "fan_out_cap_exceeded"
    /// The request itself is malformed (e.g. non-positive fan-out count).
    case invalidRequest = "invalid_request"
}

/// The backend/model decision accompanying an authorized verdict. In M2 the
/// daemon carries the requested runtime through unchanged (defaulting to
/// "auto"); actual Wand backend resolution stays GUI-side until execution
/// migrates in M5.
public struct BurnBarRemoteMissionBackendDecision: Codable, Hashable, Sendable {
    public let runtimeID: String
    public let modelID: String?
    public let reason: String

    public init(runtimeID: String, modelID: String? = nil, reason: String) {
        self.runtimeID = runtimeID
        self.modelID = modelID
        self.reason = reason
    }
}

public struct BurnBarRemoteMissionAuthorizeRequest: Codable, Hashable, Sendable {
    /// Firestore mission request document ID.
    public let missionID: String
    /// Device that published the mission (phone/tablet), not the executor.
    public let originDeviceID: String
    /// Origin platform, e.g. "ios" / "android".
    public let originPlatform: String
    /// GUI-reported `escrow_devices.trustState` for THIS executor Mac.
    /// Advisory input only: the daemon applies its own fail-closed policy.
    public let executorTrustState: String
    /// Short human-readable summary — never the full mission prompt.
    public let promptSummary: String
    /// SHA-256 hex of the full decoded prompt, for audit correlation without
    /// carrying the payload across the socket.
    public let promptSHA256: String
    /// Requested runtime/backend identifier (e.g. "codex", "hermes", "auto").
    public let requestedRuntime: String?
    public let requestedModelID: String?
    public let requestedGrant: BurnBarRemoteMissionCapabilityGrantRequest
    /// Persona sandbox envelope decoded by the GUI (`personaScopeJSON`).
    public let personaScope: PersonaScopeEnvelope?
    /// Approval evidence, verbatim from the mission document.
    public let approvalMode: String?
    public let approvalStatus: String?
    public let approverDeviceID: String?
    /// Caller-reported entitlement tier wire name: "none" / "cloud" / "pro" /
    /// "ultra". Advisory only; daemon authorization must use daemon-trusted
    /// entitlement state when deciding fan-out authority.
    public let entitlementTier: String
    /// Sibling count of the mission's Wand fan-out group (1 = solo mission).
    public let requestedFanOutCount: Int
    public let workingDirectory: String?

    public init(
        missionID: String,
        originDeviceID: String,
        originPlatform: String,
        executorTrustState: String,
        promptSummary: String,
        promptSHA256: String,
        requestedRuntime: String? = nil,
        requestedModelID: String? = nil,
        requestedGrant: BurnBarRemoteMissionCapabilityGrantRequest,
        personaScope: PersonaScopeEnvelope? = nil,
        approvalMode: String? = nil,
        approvalStatus: String? = nil,
        approverDeviceID: String? = nil,
        entitlementTier: String,
        requestedFanOutCount: Int = 1,
        workingDirectory: String? = nil
    ) {
        self.missionID = missionID
        self.originDeviceID = originDeviceID
        self.originPlatform = originPlatform
        self.executorTrustState = executorTrustState
        self.promptSummary = promptSummary
        self.promptSHA256 = promptSHA256
        self.requestedRuntime = requestedRuntime
        self.requestedModelID = requestedModelID
        self.requestedGrant = requestedGrant
        self.personaScope = personaScope
        self.approvalMode = approvalMode
        self.approvalStatus = approvalStatus
        self.approverDeviceID = approverDeviceID
        self.entitlementTier = entitlementTier
        self.requestedFanOutCount = requestedFanOutCount
        self.workingDirectory = workingDirectory
    }
}

public struct BurnBarRemoteMissionAuthorizeResponse: Codable, Hashable, Sendable {
    public let verdict: BurnBarRemoteMissionAuthorizationVerdict
    /// Present exactly when `verdict == .denied`.
    public let deniedReason: BurnBarRemoteMissionDenialReason?
    /// Human-readable explanation for operators/telemetry; never load-bearing.
    public let detail: String?
    /// The authorized capability ceiling (never wider than requested). Present
    /// for `.authorized` and `.requiresApproval` (what WOULD be authorized
    /// once approval lands); absent for `.denied`.
    public let grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest?
    /// Present exactly when `verdict == .authorized`.
    public let backendDecision: BurnBarRemoteMissionBackendDecision?

    public init(
        verdict: BurnBarRemoteMissionAuthorizationVerdict,
        deniedReason: BurnBarRemoteMissionDenialReason? = nil,
        detail: String? = nil,
        grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest? = nil,
        backendDecision: BurnBarRemoteMissionBackendDecision? = nil
    ) {
        self.verdict = verdict
        self.deniedReason = deniedReason
        self.detail = detail
        self.grantCeiling = grantCeiling
        self.backendDecision = backendDecision
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
