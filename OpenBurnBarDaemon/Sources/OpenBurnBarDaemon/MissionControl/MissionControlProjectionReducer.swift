import OpenBurnBarCore
import Foundation

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
            state.projects[project.projectSlug] = project
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
