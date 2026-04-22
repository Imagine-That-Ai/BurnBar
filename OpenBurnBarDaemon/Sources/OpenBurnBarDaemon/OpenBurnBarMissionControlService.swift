// MARK: - MissionControl Module Refactoring
//
// The types originally defined in this file have been moved to the MissionControl/ subdirectory:
//
//   - BurnBarMissionControlError          -> MissionControl/MissionControlError.swift
//   - BurnBarMissionControlProjectionFile -> MissionControl/MissionControlProjectionFile.swift
//   - BurnBarMissionControlStore         -> MissionControl/MissionControlStore.swift
//   - BurnBarMissionControlTransport     -> MissionControl/MissionControlTransport.swift
//   - BurnBarLocalNotificationBridge     -> MissionControl/Bridges/LocalNotificationBridge.swift
//   - BurnBarTelegramBotBridge           -> MissionControl/Bridges/TelegramBotBridge.swift
//   - BurnBarEventKitBridge              -> MissionControl/Bridges/EventKitBridge.swift
//   - BurnBarMissionControlService       -> MissionControl/MissionControlService.swift
//
// All public types remain accessible under their original names within the OpenBurnBarDaemon module.
// This file is kept as a placeholder to preserve source compatibility.
import OpenBurnBarCore

public protocol BurnBarMissionControlServing: AnyObject {
    func startBackgroundLoops() async
    func stopBackgroundLoops() async

    func controllerSummary(_ request: BurnBarControllerSummaryRequest) async throws -> BurnBarControllerSummaryResponse
    func controllerProjects(_ request: BurnBarControllerProjectsListRequest) async throws -> BurnBarControllerProjectsListResponse
    func controllerProject(_ request: BurnBarControllerProjectGetRequest) async throws -> BurnBarControllerProjectResponse
    func controllerProjectUpsert(_ request: BurnBarControllerProjectUpsertRequest) async throws -> BurnBarControllerProjectResponse
    func reviewRunRecord(_ request: BurnBarControllerReviewRunRecordRequest) async throws -> BurnBarControllerReviewRunRecordResponse

    func questionCreate(_ request: BurnBarQuestionCreateRequest) async throws -> BurnBarQuestionResponse
    func questionGet(_ request: BurnBarQuestionGetRequest) async throws -> BurnBarQuestionResponse
    func questionsList(_ request: BurnBarQuestionsListRequest) async throws -> BurnBarQuestionsListResponse
    func questionAnswer(_ request: BurnBarQuestionAnswerRequest) async throws -> BurnBarQuestionAnswerResponse

    func followupCreate(_ request: BurnBarFollowupCreateRequest) async throws -> BurnBarFollowupMutationResponse
    func followupsList(_ request: BurnBarFollowupsListRequest) async throws -> BurnBarFollowupsListResponse
    func followupDone(_ request: BurnBarFollowupDoneRequest) async throws -> BurnBarFollowupMutationResponse
    func followupSnooze(_ request: BurnBarFollowupSnoozeRequest) async throws -> BurnBarFollowupMutationResponse
    func followupCalendar(_ request: BurnBarFollowupCalendarRequest) async throws -> BurnBarFollowupMutationResponse

    func missionCreate(_ request: BurnBarMissionCreateRequest) async throws -> BurnBarMissionMutationResponse
    func missionsList(_ request: BurnBarMissionListRequest) async throws -> BurnBarMissionListResponse
    func missionGet(_ request: BurnBarMissionGetRequest) async throws -> BurnBarMissionResponse
    func missionApprove(_ request: BurnBarMissionApproveRequest) async throws -> BurnBarMissionMutationResponse
    func missionCancel(_ request: BurnBarMissionCancelRequest) async throws -> BurnBarMissionMutationResponse
    func missionDispatchPacket(_ request: BurnBarMissionDispatchPacketRequest) async throws -> BurnBarMissionMutationResponse
    func missionRecordResult(_ request: BurnBarMissionRecordResultRequest) async throws -> BurnBarMissionMutationResponse

    func notificationConfigGet(_ request: BurnBarNotificationConfigGetRequest) async throws -> BurnBarNotificationConfigResponse
    func notificationConfigUpdate(_ request: BurnBarNotificationConfigUpdateRequest) async throws -> BurnBarNotificationConfigResponse
    func notificationHealth(_ request: BurnBarNotificationHealthRequest) async throws -> BurnBarNotificationHealthResponse
    func notificationCommand(_ request: BurnBarNotificationCommandRequest) async throws -> BurnBarNotificationCommandResponse

    func simulatorRun(_ request: BurnBarSimulatorRunRequest) async throws -> BurnBarSimulatorRunResponse
    func simulatorList(_ request: BurnBarSimulatorListRequest) async throws -> BurnBarSimulatorListResponse
    func simulatorReplay(_ request: BurnBarSimulatorReplayRequest) async throws -> BurnBarSimulatorRunResponse
    func projectionRebuild(_ request: BurnBarProjectionRebuildRequest) async throws -> BurnBarProjectionRebuildResponse
}

extension BurnBarMissionControlService {
    // Back-compat names used by the current daemon server switch.
    public func upsertProject(_ request: BurnBarControllerProjectUpsertRequest) async throws -> BurnBarControllerProjectResponse {
        try await controllerProjectUpsert(request)
    }

    public func recordReviewRun(_ request: BurnBarControllerReviewRunRecordRequest) async throws -> BurnBarControllerReviewRunRecordResponse {
        try await reviewRunRecord(request)
    }

    public func createQuestion(_ request: BurnBarQuestionCreateRequest) async throws -> BurnBarQuestionResponse {
        try await questionCreate(request)
    }

    public func question(_ request: BurnBarQuestionGetRequest) async throws -> BurnBarQuestionResponse {
        try await questionGet(request)
    }

    public func questions(_ request: BurnBarQuestionsListRequest) async throws -> BurnBarQuestionsListResponse {
        try await questionsList(request)
    }

    public func answerQuestion(_ request: BurnBarQuestionAnswerRequest) async throws -> BurnBarQuestionAnswerResponse {
        try await questionAnswer(request)
    }

    public func createFollowup(_ request: BurnBarFollowupCreateRequest) async throws -> BurnBarFollowupMutationResponse {
        try await followupCreate(request)
    }

    public func followups(_ request: BurnBarFollowupsListRequest) async throws -> BurnBarFollowupsListResponse {
        try await followupsList(request)
    }

    public func markFollowupDone(_ request: BurnBarFollowupDoneRequest) async throws -> BurnBarFollowupMutationResponse {
        try await followupDone(request)
    }

    public func snoozeFollowup(_ request: BurnBarFollowupSnoozeRequest) async throws -> BurnBarFollowupMutationResponse {
        try await followupSnooze(request)
    }

    public func scheduleFollowupCalendar(_ request: BurnBarFollowupCalendarRequest) async throws -> BurnBarFollowupMutationResponse {
        try await followupCalendar(request)
    }

    public func createMission(_ request: BurnBarMissionCreateRequest) async throws -> BurnBarMissionMutationResponse {
        try await missionCreate(request)
    }

    public func missions(_ request: BurnBarMissionListRequest) async throws -> BurnBarMissionListResponse {
        try await missionsList(request)
    }

    public func mission(_ request: BurnBarMissionGetRequest) async throws -> BurnBarMissionResponse {
        try await missionGet(request)
    }

    public func approveMission(_ request: BurnBarMissionApproveRequest) async throws -> BurnBarMissionMutationResponse {
        try await missionApprove(request)
    }

    public func dispatchMissionPacket(_ request: BurnBarMissionDispatchPacketRequest) async throws -> BurnBarMissionMutationResponse {
        try await missionDispatchPacket(request)
    }

    public func recordMissionResult(_ request: BurnBarMissionRecordResultRequest) async throws -> BurnBarMissionMutationResponse {
        try await missionRecordResult(request)
    }

    public func notificationConfig(_ request: BurnBarNotificationConfigGetRequest) async throws -> BurnBarNotificationConfigResponse {
        try await notificationConfigGet(request)
    }

    public func updateNotificationConfig(_ request: BurnBarNotificationConfigUpdateRequest) async throws -> BurnBarNotificationConfigResponse {
        try await notificationConfigUpdate(request)
    }

    public func handleNotificationCommand(_ request: BurnBarNotificationCommandRequest) async throws -> BurnBarNotificationCommandResponse {
        try await notificationCommand(request)
    }

    public func runSimulator(_ request: BurnBarSimulatorRunRequest) async throws -> BurnBarSimulatorRunResponse {
        try await simulatorRun(request)
    }

    public func simulatorRuns(_ request: BurnBarSimulatorListRequest) async throws -> BurnBarSimulatorListResponse {
        try await simulatorList(request)
    }

    public func replaySimulator(_ request: BurnBarSimulatorReplayRequest) async throws -> BurnBarSimulatorRunResponse {
        try await simulatorReplay(request)
    }

    public func rebuildProjection(_ request: BurnBarProjectionRebuildRequest) async throws -> BurnBarProjectionRebuildResponse {
        try await projectionRebuild(request)
    }
}
