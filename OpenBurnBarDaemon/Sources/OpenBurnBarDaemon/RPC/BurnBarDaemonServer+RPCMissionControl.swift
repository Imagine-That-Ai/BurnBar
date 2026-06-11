import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func handleMissionControlRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .controllerSummary:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerSummaryRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarControllerSummaryResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.controllerSummary(typedRequest.params)
            )
            return encode(response)
        case .controllerRuntimeSnapshot:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerRuntimeSnapshotRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarControllerRuntimeSnapshotResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarControllerRuntimeSnapshotResponse(
                    snapshot: try await makeControllerRuntimeSnapshotPayload()
                )
            )
            return encode(response)
        case .controllerProjectsList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerProjectsListRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarControllerProjectsListResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.controllerProjects(typedRequest.params)
            )
            return encode(response)
        case .controllerProjectGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerProjectGetRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarControllerProjectResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.controllerProject(typedRequest.params)
            )
            return encode(response)
        case .controllerProjectUpsert:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerProjectUpsertRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarControllerProjectResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.controllerProjectUpsert(typedRequest.params)
            )
            return encode(response)
        case .reviewRunRecord:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerReviewRunRecordRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarControllerReviewRunRecordResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.reviewRunRecord(typedRequest.params)
            )
            return encode(response)
        case .questionCreate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarQuestionCreateRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarQuestionResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.questionCreate(typedRequest.params)
            )
            return encode(response)
        case .questionGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarQuestionGetRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarQuestionResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.questionGet(typedRequest.params)
            )
            return encode(response)
        case .questionsList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarQuestionsListRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarQuestionsListResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.questionsList(typedRequest.params)
            )
            return encode(response)
        case .questionAnswer:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarQuestionAnswerRequest>.self,
                from: requestData
            )
            let mutation = try await missionControlService.questionAnswer(typedRequest.params)
            let response = BurnBarRPCResponseEnvelope<BurnBarQuestionAnswerResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarQuestionAnswerResponse(
                    question: mutation.question,
                    followup: mutation.followup,
                    emittedEvent: mutation.emittedEvent,
                    // Embedded so the client skips its 6-RPC follow-up
                    // snapshot (best-effort: a snapshot failure must not
                    // fail the mutation that already committed).
                    runtimeSnapshot: try? await makeControllerRuntimeSnapshotPayload()
                )
            )
            return encode(response)
        case .followupCreate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupCreateRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.followupCreate(typedRequest.params)
            )
            return encode(response)
        case .followupsList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupsListRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarFollowupsListResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.followupsList(typedRequest.params)
            )
            return encode(response)
        case .followupDone:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupDoneRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: await embeddingRuntimeSnapshot(
                    in: try await missionControlService.followupDone(typedRequest.params)
                )
            )
            return encode(response)
        case .followupSnooze:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupSnoozeRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: await embeddingRuntimeSnapshot(
                    in: try await missionControlService.followupSnooze(typedRequest.params)
                )
            )
            return encode(response)
        case .followupCalendar:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupCalendarRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: await embeddingRuntimeSnapshot(
                    in: try await missionControlService.followupCalendar(typedRequest.params)
                )
            )
            return encode(response)
        case .missionCreate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionCreateRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.missionCreate(typedRequest.params)
            )
            return encode(response)
        case .missionsList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionListRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarMissionListResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.missionsList(typedRequest.params)
            )
            return encode(response)
        case .missionGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionGetRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarMissionResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.missionGet(typedRequest.params)
            )
            return encode(response)
        case .missionApprove:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionApproveRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.missionApprove(typedRequest.params)
            )
            return encode(response)
        case .missionCancel:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionCancelRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.missionCancel(typedRequest.params)
            )
            return encode(response)
        case .missionDispatchPacket:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionDispatchPacketRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.missionDispatchPacket(typedRequest.params)
            )
            return encode(response)
        case .missionRecordResult:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionRecordResultRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.missionRecordResult(typedRequest.params)
            )
            return encode(response)
        case .notificationConfigGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarNotificationConfigGetRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarNotificationConfigResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.notificationConfigGet(typedRequest.params)
            )
            return encode(response)
        case .notificationConfigUpdate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarNotificationConfigUpdateRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarNotificationConfigResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.notificationConfigUpdate(typedRequest.params)
            )
            return encode(response)
        case .notificationHealth:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarNotificationHealthRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarNotificationHealthResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.notificationHealth(typedRequest.params)
            )
            return encode(response)
        case .notificationCommand:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarNotificationCommandRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarNotificationCommandResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.notificationCommand(typedRequest.params)
            )
            return encode(response)
        case .simulatorRun:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSimulatorRunRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarSimulatorRunResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.simulatorRun(typedRequest.params)
            )
            return encode(response)
        case .simulatorList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSimulatorListRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarSimulatorListResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.simulatorList(typedRequest.params)
            )
            return encode(response)
        case .simulatorReplay:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSimulatorReplayRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarSimulatorRunResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.simulatorReplay(typedRequest.params)
            )
            return encode(response)
        case .projectionRebuild:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectionRebuildRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope<BurnBarProjectionRebuildResponse>(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await missionControlService.projectionRebuild(typedRequest.params)
            )
            return encode(response)
        default:
            preconditionFailure("Unhandled mission control RPC method: \(method.rawValue)")
        }
    }

    /// One aggregated controller-runtime payload — the daemon-side half of
    /// `daemon.controller.runtime_snapshot`. Mirrors exactly the request
    /// shapes the app's legacy six-RPC path used, so the aggregated and
    /// per-list answers stay byte-equivalent.
    func makeControllerRuntimeSnapshotPayload() async throws -> BurnBarControllerRuntimeSnapshotPayload {
        let summary = try await missionControlService.controllerSummary(BurnBarControllerSummaryRequest())
        let questions = try await missionControlService.questionsList(
            BurnBarQuestionsListRequest(projectSlug: nil, statuses: BurnBarPendingQuestionStatus.allCases)
        )
        let followups = try await missionControlService.followupsList(
            BurnBarFollowupsListRequest(projectSlug: nil, statuses: BurnBarFollowupStatus.allCases)
        )
        let missions = try await missionControlService.missionsList(BurnBarMissionListRequest())
        let notificationHealth = try await missionControlService.notificationHealth(
            BurnBarNotificationHealthRequest()
        )
        let simulatorRuns = try await missionControlService.simulatorList(BurnBarSimulatorListRequest())
        return BurnBarControllerRuntimeSnapshotPayload(
            summary: summary.summary,
            questions: questions.questions,
            followups: followups.followups,
            missions: missions.missions,
            notificationHealth: notificationHealth.health,
            simulatorRuns: simulatorRuns.runs
        )
    }

    /// Attaches the post-mutation runtime snapshot to a followup mutation
    /// response. Best-effort: a snapshot failure must not fail a mutation
    /// that already committed — the client then falls back to its legacy
    /// follow-up snapshot RPCs.
    private func embeddingRuntimeSnapshot(
        in mutation: BurnBarFollowupMutationResponse
    ) async -> BurnBarFollowupMutationResponse {
        BurnBarFollowupMutationResponse(
            followup: mutation.followup,
            emittedEvent: mutation.emittedEvent,
            runtimeSnapshot: try? await makeControllerRuntimeSnapshotPayload()
        )
    }
}
