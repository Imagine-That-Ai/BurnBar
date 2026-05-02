import OpenBurnBarCore
import Foundation

enum OpenBurnBarDaemonSocketClient {
    private static let controllerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarIdentity.controllerRuntimeKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyControllerRuntimeKeychainServices
    )

    static func health(at socketURL: URL) throws -> BurnBarHealthResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .health),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result
    }

    static func config(at socketURL: URL) throws -> BurnBarProviderConfigurationSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarConfigResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .configGet),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result.snapshot
    }

    static func updateConfig(
        _ snapshot: BurnBarProviderConfigurationSnapshot,
        at socketURL: URL
    ) throws -> BurnBarProviderConfigurationSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarConfigResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .configUpdate,
                params: BurnBarConfigUpdateRequest(snapshot: snapshot)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result.snapshot
    }

    static func recentUsage(
        at socketURL: URL,
        limit: Int = 20
    ) throws -> [BurnBarUsageEvent] {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarRecentUsageResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .usageRecent,
                params: BurnBarRecentUsageRequest(limit: limit)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result.usage
    }

    static func connectorPlane(at socketURL: URL) throws -> BurnBarConnectorPlaneSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .connectorPlaneGet),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }
        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }
        return result.snapshot
    }

    static func updateConnectorConfig(
        _ request: BurnBarConnectorConfigUpdateRequest,
        at socketURL: URL
    ) throws -> BurnBarConnectorPlaneSnapshot {
        let response: BurnBarConnectorPlaneResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .connectorConfigUpdate,
                params: request
            ),
            socketURL: socketURL
        )
        return response.snapshot
    }

    static func performConnectorAction(
        _ request: BurnBarConnectorActionRequest,
        at socketURL: URL
    ) throws -> BurnBarConnectorActionResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .connectorAction,
                params: request
            ),
            socketURL: socketURL
        ) as BurnBarConnectorActionResponse
    }

    static func browserTooling(at socketURL: URL) throws -> BurnBarBrowserToolingSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarBrowserToolingResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .browserToolingGet),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }
        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }
        return result.snapshot
    }

    static func updateBrowserTooling(
        _ request: BurnBarBrowserToolingUpdateRequest,
        at socketURL: URL
    ) throws -> BurnBarBrowserToolingSnapshot {
        let response: BurnBarBrowserToolingResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .browserToolingUpdate,
                params: request
            ),
            socketURL: socketURL
        )
        return response.snapshot
    }

    static func performBrowserAction(
        _ request: BurnBarBrowserActionRequest,
        at socketURL: URL
    ) throws -> BurnBarBrowserActionResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .browserAction,
                params: request
            ),
            socketURL: socketURL
        ) as BurnBarBrowserActionResponse
    }

    static func updateNotificationConfig(
        _ config: BurnBarNotificationConfig,
        at socketURL: URL
    ) throws -> BurnBarNotificationConfig {
        let response: BurnBarNotificationConfigResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .notificationConfigUpdate,
                params: BurnBarNotificationConfigUpdateRequest(config: config)
            ),
            socketURL: socketURL
        )
        return response.config
    }

    static func controllerProjects(at socketURL: URL) throws -> [BurnBarReviewProjectSnapshot] {
        let response: BurnBarControllerProjectsListResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .controllerProjectsList,
                params: BurnBarControllerProjectsListRequest(includePaused: true, limit: 200)
            ),
            socketURL: socketURL
        )
        return response.projects
    }

    static func upsertControllerProject(
        _ project: BurnBarReviewProjectSnapshot,
        at socketURL: URL
    ) throws -> BurnBarReviewProjectSnapshot? {
        let response: BurnBarControllerProjectResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .controllerProjectUpsert,
                params: BurnBarControllerProjectUpsertRequest(project: project)
            ),
            socketURL: socketURL
        )
        return response.project
    }

    static func missionCreate(
        _ request: BurnBarMissionCreateRequest,
        at socketURL: URL
    ) throws -> BurnBarMissionMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .missionCreate,
                params: request
            ),
            socketURL: socketURL
        ) as BurnBarMissionMutationResponse
    }

    static func recordControllerReviewRun(
        _ run: BurnBarReviewRunSnapshot,
        at socketURL: URL
    ) throws -> BurnBarControllerReviewRunRecordResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .reviewRunRecord,
                params: BurnBarControllerReviewRunRecordRequest(run: run)
            ),
            socketURL: socketURL
        ) as BurnBarControllerReviewRunRecordResponse
    }

    static func controllerRuntimeSnapshot(at socketURL: URL) throws -> OpenBurnBarControllerRuntimeSnapshot {
        let summary = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .controllerSummary,
                params: BurnBarControllerSummaryRequest()
            ),
            socketURL: socketURL
        ) as OpenBurnBarCore.BurnBarControllerSummaryResponse
        let questions = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .questionsList,
                params: BurnBarQuestionsListRequest(projectSlug: nil, statuses: BurnBarPendingQuestionStatus.allCases)
            ),
            socketURL: socketURL
        ) as BurnBarQuestionsListResponse
        let followups = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupsList,
                params: BurnBarFollowupsListRequest(projectSlug: nil, statuses: BurnBarFollowupStatus.allCases)
            ),
            socketURL: socketURL
        ) as BurnBarFollowupsListResponse
        let missions = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .missionsList,
                params: BurnBarMissionListRequest()
            ),
            socketURL: socketURL
        ) as BurnBarMissionListResponse
        let notificationHealth = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .notificationHealth,
                params: BurnBarNotificationHealthRequest()
            ),
            socketURL: socketURL
        ) as BurnBarNotificationHealthResponse
        let simulatorRuns = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .simulatorList,
                params: BurnBarSimulatorListRequest()
            ),
            socketURL: socketURL
        ) as BurnBarSimulatorListResponse

        return makeControllerRuntimeSnapshot(
            summary: summary.summary,
            questions: questions.questions,
            followups: followups.followups,
            missions: missions.missions,
            notificationHealth: notificationHealth.health,
            simulatorRuns: simulatorRuns.runs
        )
    }

    static func answerControllerQuestion(
        questionID: String,
        answer: String,
        selectedOptionID: String? = nil,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let _: BurnBarQuestionAnswerResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .questionAnswer,
                params: BurnBarQuestionAnswerRequest(
                    questionID: BurnBarQuestionID(rawValue: questionID),
                    answeredBy: "operator",
                    answer: answer,
                    selectedOptionID: selectedOptionID
                )
            ),
            socketURL: socketURL
        )
        return try controllerRuntimeSnapshot(at: socketURL)
    }

    static func completeControllerFollowup(
        followupID: String,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let _: BurnBarFollowupMutationResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupDone,
                params: BurnBarFollowupDoneRequest(
                    followupID: BurnBarFollowupID(rawValue: followupID),
                    actor: "operator"
                )
            ),
            socketURL: socketURL
        )
        return try controllerRuntimeSnapshot(at: socketURL)
    }

    static func snoozeControllerFollowup(
        followupID: String,
        until: Date,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let _: BurnBarFollowupMutationResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupSnooze,
                params: BurnBarFollowupSnoozeRequest(
                    followupID: BurnBarFollowupID(rawValue: followupID),
                    actor: "operator",
                    snoozeUntil: until
                )
            ),
            socketURL: socketURL
        )
        return try controllerRuntimeSnapshot(at: socketURL)
    }

    static func scheduleControllerFollowupCalendar(
        followupID: String,
        title: String?,
        start: Date,
        durationMinutes: Int,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? title!
            : "OpenBurnBar followup"
        let end = start.addingTimeInterval(Double(max(durationMinutes, 15)) * 60)
        let _: BurnBarFollowupMutationResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupCalendar,
                params: BurnBarFollowupCalendarRequest(
                    followupID: BurnBarFollowupID(rawValue: followupID),
                    actor: "operator",
                    action: .create,
                    entry: BurnBarCalendarEntrySnapshot(
                        externalID: nil,
                        title: resolvedTitle,
                        startAt: start,
                        endAt: end,
                        notes: "Scheduled from AgentLens."
                    )
                )
            ),
            socketURL: socketURL
        )
        return try controllerRuntimeSnapshot(at: socketURL)
    }

    private static func send<Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelope,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let signedRequest = BurnBarRPCRequestEnvelope(
            id: request.id,
            method: request.method,
            authToken: request.authToken ?? daemonSocketAuthToken()
        )
        return try sendEncoded(signedRequest, socketURL: socketURL)
    }

    private static func send<Params: Codable & Sendable, Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelopeWithParams<Params>,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let signedRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: request.id,
            method: request.method,
            authToken: request.authToken ?? daemonSocketAuthToken(),
            params: request.params
        )
        return try sendEncoded(signedRequest, socketURL: socketURL)
    }

    private static func requestResult<Params: Codable & Sendable, Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelopeWithParams<Params>,
        socketURL: URL
    ) throws -> Response {
        let envelope: BurnBarRPCResponseEnvelope<Response> = try send(request, socketURL: socketURL)
        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }
        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }
        return result
    }

    static func makeControllerRuntimeSnapshot(
        summary: OpenBurnBarCore.BurnBarControllerSummary,
        questions: [BurnBarPendingQuestionSnapshot],
        followups: [BurnBarFollowupSnapshot],
        missions: [BurnBarMissionSnapshot],
        notificationHealth: BurnBarNotificationHealthSnapshot,
        simulatorRuns: [BurnBarSimulatorRunSnapshot]
    ) -> OpenBurnBarControllerRuntimeSnapshot {
        let visibleQuestions = questions.filter { shouldIncludeInOperatorInbox($0) }
        let visibleQuestionIDs = Set(visibleQuestions.map(\.id.rawValue))
        let visibleFollowups = followups.filter {
            shouldIncludeInOperatorInbox($0, visibleQuestionIDs: visibleQuestionIDs)
        }

        let mappedQuestions = visibleQuestions.map { question in
            OpenBurnBarControllerQuestion(
                id: question.id.rawValue,
                projectName: displayName(for: question.projectSlug),
                sessionID: question.sessionID?.rawValue,
                title: question.title,
                prompt: question.prompt,
                stageLabel: question.stageLabel,
                evidenceHint: question.contextSummary,
                state: questionState(for: question.status),
                priority: questionPriority(for: question.priority),
                sourceLabel: question.sessionID == nil ? "Daemon controller runtime" : "Daemon session runtime",
                createdAt: question.askedAt,
                answeredAt: question.latestAnswer?.answeredAt,
                answer: question.latestAnswer?.answer,
                selectedOptionID: question.latestAnswer?.selectedOptionID,
                answerPlaceholder: question.answerPlaceholder,
                suggestedOptions: question.suggestedOptions.map { option in
                    OpenBurnBarControllerQuestionOption(
                        id: option.id,
                        title: option.title,
                        detail: option.detail,
                        answer: option.answer
                    )
                },
                deepLink: question.deepLink.map { link in
                    OpenBurnBarControllerQuestionDeepLink(
                        kind: questionDeepLinkKind(for: link.kind),
                        targetID: link.targetID,
                        title: link.title,
                        subtitle: link.subtitle
                    )
                },
                isUnread: question.tracker?.isUnread ?? false,
                notificationCount: question.tracker?.notificationCount ?? 0
            )
        }

        let mappedFollowups = visibleFollowups.map { followup in
            OpenBurnBarControllerFollowup(
                id: followup.id.rawValue,
                projectName: displayName(for: followup.projectSlug),
                title: followup.title,
                summary: followup.summary,
                stageLabel: followup.stageLabel,
                detail: followup.calendarEntry?.notes,
                state: followupState(for: followup.status),
                kind: followupKind(for: followup.kind),
                linkedQuestionID: followup.questionID?.rawValue,
                deepLink: followup.deepLink.map { link in
                    OpenBurnBarControllerQuestionDeepLink(
                        kind: questionDeepLinkKind(for: link.kind),
                        targetID: link.targetID,
                        title: link.title,
                        subtitle: link.subtitle
                    )
                },
                createdAt: followup.createdAt,
                updatedAt: followup.nextNudgeAt ?? followup.snoozeUntil ?? followup.createdAt,
                dueAt: followup.nextNudgeAt,
                snoozedUntil: followup.snoozeUntil,
                calendarTitle: followup.calendarEntry?.title,
                calendarStart: followup.calendarEntry?.startAt,
                calendarEnd: followup.calendarEntry?.endAt
            )
        }

        let mappedMissions = missions.map { mission in
            let latestPacket = mission.packets.sorted {
                ($0.dispatchedAt ?? .distantPast) > ($1.dispatchedAt ?? .distantPast)
            }.first
            let activePacket = mission.packets.first(where: { [.queued, .dispatched, .running].contains($0.status) }) ?? latestPacket
            let latestResult = mission.results.sorted(by: { $0.createdAt > $1.createdAt }).first
            let missionPRLinkage = mission.prLinkage ?? latestResult?.prLinkage
            let packetSummary = latestPacket.map { packet in
                "\(packet.workerName): \(packet.objective)"
            }
            let burnTokens = mission.results.reduce(0) { partial, result in
                partial
                    + intValue(in: result.metadata["input_tokens"])
                    + intValue(in: result.metadata["output_tokens"])
                    + intValue(in: result.metadata["cache_read_tokens"])
            }
            let mappedPRLinkage = missionPRLinkage.map {
                OpenBurnBarControllerMissionPRLinkage(
                    repository: $0.repository,
                    prNumberOrID: $0.prNumberOrID,
                    url: $0.url,
                    state: missionPRState(for: $0.state),
                    isMerged: $0.isMerged,
                    mergeCommitSHA: $0.mergeCommitSHA,
                    mergedAt: $0.mergedAt,
                    closedAt: $0.closedAt
                )
            }
            let latestTakeover = mission.takeoverHistory?
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .first
            let ownerPrincipalID = stringValue(in: mission.metadata["team_owner_id"])
                ?? stringValue(in: mission.metadata["owner_principal_id"])
                ?? mission.approval.approvedBy
            let assigneePrincipalID = stringValue(in: mission.metadata["team_assignee_id"])
                ?? stringValue(in: mission.metadata["assignee_principal_id"])
                ?? activePacket?.workerName
            let roleEligibility = OpenBurnBarControllerMissionRoleEligibility(
                canApprove: boolValue(in: mission.metadata["role_can_approve"])
                    ?? (!mission.approval.approved && mission.status == .awaitingApproval),
                canTransferOwnership: boolValue(in: mission.metadata["role_can_transfer"])
                    ?? ![BurnBarMissionStatus.completed, .failed, .cancelled].contains(mission.status),
                canAnswerClosureQuestion: boolValue(in: mission.metadata["role_can_answer_closure"])
                    ?? (mission.status == .awaitingApproval)
            )
            let latestAuditEventID = stringValue(in: mission.metadata["audit_event_id"])
                ?? stringValue(in: mission.metadata["last_audit_event_id"])
            let latestAuditSummary = stringValue(in: mission.metadata["audit_summary"])
                ?? stringValue(in: mission.metadata["last_audit_summary"])
            return OpenBurnBarControllerMissionRecord(
                id: mission.id.rawValue,
                projectName: displayName(for: mission.projectSlug),
                title: mission.title,
                summary: mission.summary,
                state: missionLifecycle(for: mission.status),
                approval: mission.approval.approved ? .approved : .pending,
                ownerPrincipalID: ownerPrincipalID,
                assigneePrincipalID: assigneePrincipalID,
                roleEligibility: roleEligibility,
                latestAuditEventID: latestAuditEventID,
                latestAuditSummary: latestAuditSummary,
                packetSummary: packetSummary,
                latestResultSummary: latestResult?.summary,
                latestResultDetail: latestResult?.detail,
                latestResultRunID: latestResult?.runID?.rawValue,
                activeWorkerName: activePacket?.workerName,
                activeRunID: activePacket?.runID?.rawValue,
                packetRunCount: mission.packets.compactMap(\.runID).count,
                latestTakeoverState: latestTakeover.map { takeoverState(for: $0.status) },
                latestTakeoverReason: latestTakeover?.reason,
                latestTakeoverRunID: latestTakeover?.takeoverRunID?.rawValue,
                takeoverCount: mission.takeoverHistory?.count ?? 0,
                burnCostUSD: mission.burnRecords.reduce(0) { $0 + $1.amount },
                burnTokens: burnTokens,
                updatedAt: mission.updatedAt,
                prLinkage: mappedPRLinkage
            )
        }

        let mappedEvents = summary.recentEvents.map { event in
            OpenBurnBarControllerEvent(
                id: event.id.rawValue,
                projectName: displayName(for: event.projectSlug),
                category: eventCategory(for: event.family),
                title: readableEventTitle(for: event.eventType),
                summary: event.summary,
                detail: event.detail,
                createdAt: event.recordedAt
            )
        }

        let pendingQuestionCount = mappedQuestions.filter { $0.state == .pending }.count
        let unresolvedFollowupCount = mappedFollowups.filter { $0.state == .open }.count
        let openMissionCount = mappedMissions.filter { $0.state != OpenBurnBarMissionLifecycle.completed }.count

        return OpenBurnBarControllerRuntimeSnapshot(
            source: .daemon,
            updatedAt: summary.updatedAt,
            summary: OpenBurnBarControllerSummary(
                headline: controllerHeadline(
                    questionCount: pendingQuestionCount,
                    followupCount: unresolvedFollowupCount
                ),
                detail: "Daemon-backed controller summary. \(freshnessLabel(for: summary.freshness)).",
                pendingQuestions: pendingQuestionCount,
                unresolvedFollowups: unresolvedFollowupCount,
                openMissions: openMissionCount,
                replayLabel: replayLabel(from: simulatorRuns),
                notificationLabel: notificationLabel(from: notificationHealth)
            ),
            questions: mappedQuestions,
            followups: mappedFollowups,
            missions: mappedMissions,
            recentEvents: mappedEvents
        )
    }

    private static func shouldIncludeInOperatorInbox(_ question: BurnBarPendingQuestionSnapshot) -> Bool {
        stringValue(in: question.metadata["ingestion_source"]) != BurnBarControllerProjectIngestionSource.appActivity.rawValue
    }

    private static func shouldIncludeInOperatorInbox(
        _ followup: BurnBarFollowupSnapshot,
        visibleQuestionIDs: Set<String>
    ) -> Bool {
        guard let questionID = followup.questionID?.rawValue else {
            return true
        }
        return visibleQuestionIDs.contains(questionID)
    }

    private static func controllerHeadline(questionCount: Int, followupCount: Int) -> String {
        if questionCount > 0 && followupCount > 0 {
            return "\(questionCount) pending question\(questionCount == 1 ? "" : "s") and \(followupCount) followup\(followupCount == 1 ? "" : "s") need attention."
        }
        if questionCount > 0 {
            return "\(questionCount) pending question\(questionCount == 1 ? "" : "s") need an answer."
        }
        if followupCount > 0 {
            return "\(followupCount) followup\(followupCount == 1 ? "" : "s") are still open."
        }
        return "Controller runtime is quiet."
    }

    private static func freshnessLabel(for freshness: BurnBarControllerFreshnessState) -> String {
        switch freshness {
        case .fresh: return "Fresh local signal."
        case .aging: return "Aging review signal."
        case .stale: return "Review signal is stale."
        case .provisional: return "Controller view is provisional."
        case .missing: return "Controller view is awaiting its first review."
        }
    }

    private static func notificationLabel(from health: BurnBarNotificationHealthSnapshot) -> String {
        let localHealthy = health.channels.contains { $0.channel == .local && $0.status == .healthy }
        let telegramHealthy = health.channels.contains { $0.channel == .telegram && $0.status == .healthy }
        let needsSetup = health.channels.contains { [.degraded, .unauthorized].contains($0.status) }
        if localHealthy && telegramHealthy {
            return "Telegram and local notifications armed"
        }
        if telegramHealthy {
            return "Telegram armed"
        }
        if localHealthy {
            return "Local notifications armed"
        }
        if needsSetup {
            return "Notifications need setup"
        }
        return "Notifications optional"
    }

    private static func replayLabel(from runs: [BurnBarSimulatorRunSnapshot]) -> String {
        guard let latest = runs.sorted(by: { $0.startedAt > $1.startedAt }).first else {
            return "Replay idle"
        }
        let status: String
        switch latest.status {
        case .idle: status = "Replay idle"
        case .queued: status = "Replay queued"
        case .running: status = "Replay running"
        case .completed: status = "Replay complete"
        case .failed: status = "Replay failed"
        }
        return "\(status): \(latest.scenarioName)"
    }

    private static func questionState(for status: BurnBarPendingQuestionStatus) -> OpenBurnBarControllerQuestionState {
        switch status {
        case .pending: return .pending
        case .answered: return .answered
        case .dismissed, .expired: return .dismissed
        }
    }

    private static func questionPriority(for priority: BurnBarPendingQuestionPriority) -> OpenBurnBarControllerQuestionPriority {
        switch priority {
        case .critical, .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }

    private static func questionDeepLinkKind(
        for kind: BurnBarQuestionDeepLinkKind
    ) -> OpenBurnBarControllerQuestionDeepLinkKind {
        switch kind {
        case .sessionLog: return .sessionLog
        case .dashboard: return .dashboard
        case .project: return .project
        case .settings: return .settings
        }
    }

    private static func followupState(for status: BurnBarFollowupStatus) -> OpenBurnBarControllerFollowupState {
        switch status {
        case .open: return .open
        case .done: return .done
        case .snoozed: return .snoozed
        }
    }

    private static func followupKind(for kind: BurnBarFollowupKind) -> OpenBurnBarControllerFollowupKind {
        switch kind {
        case .pendingQuestion: return .pendingQuestion
        case .completedAction: return .completedAction
        case .missionReview: return .missionWork
        case .controllerNudge: return .setup
        }
    }

    private static func missionLifecycle(for status: BurnBarMissionStatus) -> OpenBurnBarMissionLifecycle {
        switch status {
        case .draft, .awaitingApproval, .approved:
            return .planned
        case .dispatching, .inProgress:
            return .running
        case .partiallyCompleted:
            return .partial
        case .failed, .cancelled:
            return .blocked
        case .completed:
            return .completed
        }
    }

    private static func missionPRState(for state: BurnBarPRLinkageState) -> OpenBurnBarControllerMissionPRState {
        switch state {
        case .opened:
            return .opened
        case .merged:
            return .merged
        case .closed:
            return .closed
        }
    }

    private static func takeoverState(for status: BurnBarAutoTakeoverStatus) -> OpenBurnBarControllerTakeoverState {
        switch status {
        case .monitoring:
            return .monitoring
        case .launched:
            return .launched
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .skipped:
            return .skipped
        }
    }

    private static func eventCategory(for family: BurnBarControllerEventFamily) -> OpenBurnBarControllerEventCategory {
        switch family {
        case .controller: return .controller
        case .question: return .question
        case .followup: return .followup
        case .mission: return .mission
        case .notification: return .notification
        case .simulator, .projection: return .replay
        case .governance: return .governance
        }
    }

    private static func readableEventTitle(for eventType: String) -> String {
        eventType
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func displayName(for slug: String) -> String {
        let title = slug
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { $0.capitalized }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? slug : title
    }

    private static func intValue(in value: BurnBarJSONValue?) -> Int {
        switch value {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value) ?? 0
        default: return 0
        }
    }

    private static func boolValue(in value: BurnBarJSONValue?) -> Bool? {
        guard case .bool(let value) = value else { return nil }
        return value
    }

    private static func stringValue(in value: BurnBarJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func daemonSocketAuthToken() -> String? {
        guard let storedToken = try? controllerRuntimeSecrets.string(for: OpenBurnBarIdentity.daemonSocketAuthTokenAccount) else {
            return nil
        }
        let token = storedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func sendEncoded<Request: Encodable, Response: Codable & Sendable>(
        _ request: Request,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        configureIOTimeouts(for: fileDescriptor)

        var address = try socketAddress(for: socketURL.path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let encoder = JSONEncoder()
        let payload = try encoder.encode(request) + Data([0x0A])
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                guard bytesWritten > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            guard bytesRead > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A {
                break
            }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private static func configureIOTimeouts(for fileDescriptor: Int32, seconds: Int = 30) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        return address
    }
}
