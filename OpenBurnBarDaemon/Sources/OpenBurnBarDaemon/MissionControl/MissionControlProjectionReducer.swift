import OpenBurnBarEngine
import Foundation

struct BurnBarProjectDeletionPayload: Codable, Sendable {
    let projectSlug: String
    let projectID: String?
    let aliases: [String]

    init(
        projectSlug: String,
        projectID: String? = nil,
        aliases: [String] = []
    ) {
        self.projectSlug = projectSlug
        self.projectID = projectID
        self.aliases = aliases
    }

    private enum CodingKeys: String, CodingKey {
        case projectSlug
        case projectID
        case aliases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Older delete events only carried the canonical slug. Keep them
        // replayable while allowing newer events to tombstone every stable
        // project identity.
        projectSlug = try container.decode(String.self, forKey: .projectSlug)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

struct BurnBarProjectReassignmentPayload: Codable, Sendable {
    let sourceProjectSlug: String
    let targetProjectSlug: String
}

enum MissionControlProjectionReducer {
    static func decodePayload<Value: Decodable>(_ type: Value.Type, from event: BurnBarControllerEvent) throws -> Value {
        guard let payload = event.metadata["payload"] else {
            throw BurnBarMissionControlError.missingPayload(event.eventType)
        }
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    static func projectionNames(for event: BurnBarControllerEvent) -> [String] {
        switch event.family {
        case .controller:
            return ["controller_summary", "conversation_home", "governance_history"]
        case .question:
            return ["pending_questions", "controller_summary", "conversation_home"]
        case .followup:
            return ["followups", "controller_summary", "conversation_home"]
        case .mission:
            return ["missions", "controller_summary", "conversation_home"]
        case .notification:
            return ["controller_summary", "governance_history"]
        case .simulator:
            return ["controller_summary", "governance_history"]
        case .projection:
            return ["controller_summary", "conversation_home", "followups", "pending_questions", "missions", "governance_history"]
        case .governance:
            return ["governance_history", "controller_summary"]
        }
    }

    static func touchProjectionStatus(
        for event: BurnBarControllerEvent,
        projection: inout BurnBarMissionControlProjectionFile
    ) {
        let names = projectionNames(for: event)
        for name in names {
            let checkpoint = BurnBarReplayCheckpoint(
                id: BurnBarProjectionCheckpointID(rawValue: "checkpoint-\(name)-\(event.sequence)"),
                projectionName: name,
                eventSequence: event.sequence,
                recordedAt: event.recordedAt
            )
            projection.projectionStatus[name] = BurnBarProjectionStatusSnapshot(
                projectionName: name,
                status: .upToDate,
                freshness: event.isReplay ? .provisional : .fresh,
                lastMaterializedAt: event.recordedAt,
                lastEventSequence: event.sequence,
                checkpoint: checkpoint
            )
        }
    }

    static func apply(
        event: BurnBarControllerEvent,
        projection: inout BurnBarMissionControlProjectionFile?,
        seenEventIDs: inout Set<String>
    ) throws {
        guard seenEventIDs.insert(event.id.rawValue).inserted else {
            return
        }
        var state = projection ?? BurnBarMissionControlProjectionFile.empty(now: event.recordedAt)
        state.lastSequence = max(state.lastSequence, event.sequence)
        state.rebuiltAt = max(state.rebuiltAt, event.recordedAt)
        touchProjectionStatus(for: event, projection: &state)

        switch (event.family, event.eventType) {
        case (.controller, "project_upserted"):
            let project = try decodePayload(BurnBarReviewProjectSnapshot.self, from: event)
            let identities = [project.projectSlug, project.id] + project.aliases
            let tombstones = state.projectDeletionTombstones ?? [:]
            if identities.allSatisfy({ tombstones[$0] == nil }) {
                state.projects[project.projectSlug] = project
            }
        case (.controller, "project_deleted"):
            let payload = try decodePayload(BurnBarProjectDeletionPayload.self, from: event)
            state.projects.removeValue(forKey: payload.projectSlug)
            var tombstones = state.projectDeletionTombstones ?? [:]
            let identities = [payload.projectSlug]
                + (payload.projectID.map { [$0] } ?? [])
                + payload.aliases
            for identity in identities where !identity.isEmpty {
                tombstones[identity] = payload.projectSlug
            }
            state.projectDeletionTombstones = tombstones
        case (.controller, "project_reassigned"):
            let payload = try decodePayload(BurnBarProjectReassignmentPayload.self, from: event)
            state.reviewRuns = Dictionary(uniqueKeysWithValues: state.reviewRuns.map { id, run in
                guard run.projectSlug == payload.sourceProjectSlug else { return (id, run) }
                return (
                    id,
                    BurnBarReviewRunSnapshot(
                        id: run.id,
                        projectSlug: payload.targetProjectSlug,
                        cadence: run.cadence,
                        recordedAt: run.recordedAt,
                        summary: run.summary,
                        questionCount: run.questionCount,
                        followupCount: run.followupCount,
                        missionCount: run.missionCount,
                        origin: run.origin,
                        triggeredBy: run.triggeredBy,
                        launchedRunID: run.launchedRunID,
                        metadata: run.metadata
                    )
                )
            })
            state.questions = Dictionary(uniqueKeysWithValues: state.questions.map { id, question in
                guard question.projectSlug == payload.sourceProjectSlug else { return (id, question) }
                return (
                    id,
                    BurnBarPendingQuestionSnapshot(
                        id: question.id,
                        projectSlug: payload.targetProjectSlug,
                        sessionID: question.sessionID,
                        title: question.title,
                        prompt: question.prompt,
                        stageLabel: question.stageLabel,
                        status: question.status,
                        priority: question.priority,
                        askedAt: question.askedAt,
                        dueAt: question.dueAt,
                        latestAnswer: question.latestAnswer,
                        answerPlaceholder: question.answerPlaceholder,
                        contextSummary: question.contextSummary,
                        evidenceRefs: question.evidenceRefs,
                        suggestedOptions: question.suggestedOptions,
                        deepLink: question.deepLink,
                        tracker: question.tracker,
                        metadata: question.metadata
                    )
                )
            })
            state.followups = Dictionary(uniqueKeysWithValues: state.followups.map { id, followup in
                guard followup.projectSlug == payload.sourceProjectSlug else { return (id, followup) }
                return (
                    id,
                    BurnBarFollowupSnapshot(
                        id: followup.id,
                        projectSlug: payload.targetProjectSlug,
                        questionID: followup.questionID,
                        title: followup.title,
                        summary: followup.summary,
                        stageLabel: followup.stageLabel,
                        status: followup.status,
                        kind: followup.kind,
                        createdAt: followup.createdAt,
                        nextNudgeAt: followup.nextNudgeAt,
                        snoozeUntil: followup.snoozeUntil,
                        calendarEntry: followup.calendarEntry,
                        deepLink: followup.deepLink,
                        metadata: followup.metadata
                    )
                )
            })
            state.missions = Dictionary(uniqueKeysWithValues: state.missions.map { id, mission in
                let reassignedTakeoverHistory = mission.takeoverHistory?.map { takeover in
                    guard takeover.projectSlug == payload.sourceProjectSlug else { return takeover }
                    return BurnBarAutoTakeoverRecord(
                        id: takeover.id,
                        projectSlug: payload.targetProjectSlug,
                        missionID: takeover.missionID,
                        sourceRunID: takeover.sourceRunID,
                        takeoverRunID: takeover.takeoverRunID,
                        status: takeover.status,
                        reason: takeover.reason,
                        createdAt: takeover.createdAt,
                        updatedAt: takeover.updatedAt,
                        metadata: takeover.metadata
                    )
                }
                guard mission.projectSlug == payload.sourceProjectSlug
                    || mission.takeoverHistory?.contains(where: { $0.projectSlug == payload.sourceProjectSlug }) == true else {
                    return (id, mission)
                }
                return (
                    id,
                    BurnBarMissionSnapshot(
                        id: mission.id,
                        projectSlug: mission.projectSlug == payload.sourceProjectSlug
                            ? payload.targetProjectSlug
                            : mission.projectSlug,
                        title: mission.title,
                        summary: mission.summary,
                        status: mission.status,
                        recommendation: mission.recommendation,
                        createdAt: mission.createdAt,
                        updatedAt: mission.updatedAt,
                        approval: mission.approval,
                        packets: mission.packets,
                        results: mission.results,
                        burnRecords: mission.burnRecords,
                        takeoverHistory: reassignedTakeoverHistory,
                        prLinkage: mission.prLinkage,
                        metadata: mission.metadata
                    )
                )
            })
            state.simulatorRuns = Dictionary(uniqueKeysWithValues: state.simulatorRuns.map { id, run in
                guard run.projectSlug == payload.sourceProjectSlug else { return (id, run) }
                return (
                    id,
                    BurnBarSimulatorRunSnapshot(
                        id: run.id,
                        projectSlug: payload.targetProjectSlug,
                        scenarioName: run.scenarioName,
                        status: run.status,
                        seed: run.seed,
                        startedAt: run.startedAt,
                        completedAt: run.completedAt,
                        emittedEvents: run.emittedEvents,
                        projectionStatus: run.projectionStatus,
                        summary: run.summary
                    )
                )
            })
        case (.controller, "review_run_recorded"):
            let run = try decodePayload(BurnBarReviewRunSnapshot.self, from: event)
            state.reviewRuns[run.id] = run
        case (.question, "question_created"),
             (.question, "question_answered"),
             (.question, "question_notified"):
            let question = try decodePayload(BurnBarPendingQuestionSnapshot.self, from: event)
            state.questions[question.id.rawValue] = question
        case (.followup, "followup_created"),
             (.followup, "followup_done"),
             (.followup, "followup_snoozed"),
             (.followup, "followup_reopened"),
             (.followup, "followup_nudged"),
             (.followup, "followup_calendar_create"),
             (.followup, "followup_calendar_update"),
             (.followup, "followup_calendar_remove"):
            let followup = try decodePayload(BurnBarFollowupSnapshot.self, from: event)
            state.followups[followup.id.rawValue] = followup
        case (.mission, _):
            let mission = try decodePayload(BurnBarMissionSnapshot.self, from: event)
            state.missions[mission.id.rawValue] = mission
        case (.notification, "notification_config_updated"):
            let config = try decodePayload(BurnBarNotificationConfig.self, from: event)
            state.notificationConfig = config
        case (.simulator, "simulator_run_recorded"), (.simulator, "simulator_replayed"):
            let run = try decodePayload(BurnBarSimulatorRunSnapshot.self, from: event)
            state.simulatorRuns[run.id.rawValue] = run
        case (.projection, "projection_rebuilt"):
            break
        default:
            break
        }
        projection = state
    }
}
