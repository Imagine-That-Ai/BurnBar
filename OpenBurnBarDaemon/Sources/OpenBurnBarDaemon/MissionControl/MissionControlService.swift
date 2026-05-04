// MARK: - Mission Control Scope Note
//
// Mission Control provides project/question/followup/mission CRUD for daemon-managed
// AI runs. This is experimental infrastructure built ahead of user validation.
//
// If you are reading this during a refactor: consider whether Mission Control
// complexity is justified by active user demand. The core OpenBurnBar value
// proposition is token usage tracking; Mission Control is a secondary surface.
//
// Before expanding Mission Control, validate:
//   1. Are users actively creating missions through the UI?
//   2. Does the mission approval flow reduce error rates vs. direct execution?
//   3. Is the operational burden of maintaining Mission Control < value delivered?
//
// If the answer to any is "no" or "unknown", deprioritize Mission Control expansion
// and invest in core tracking, search, and sync reliability instead.

import OpenBurnBarCore
import Foundation

public actor BurnBarMissionControlService: BurnBarMissionControlServing {
    let store: BurnBarMissionControlStore
    let logger: BurnBarDaemonLogger
    let transport: BurnBarMissionControlTransport
    let activitySnapshotURL: URL?
    let reviewRunLauncher: BurnBarMissionControlReviewRunLauncher?
    let runSnapshotLookup: BurnBarMissionControlRunSnapshotLookup?
    let usageLedgerURL: URL
    /// VAL-DAEMON-011: Execution readiness gate for pre-dispatch checks.
    /// When nil, dispatch proceeds without readiness checks (legacy behavior for tests).
    let executionReadinessGate: BurnBarExecutionReadinessGate?
    let performanceGuardrails: BurnBarMissionControlPerformanceGuardrails?

    /// Terminal mission statuses that block dispatch — must match MissionControlStore.terminalStatuses.
    static let terminalMissionStatuses: Set<BurnBarMissionStatus> = [
        .completed, .failed, .cancelled
    ]
    var notificationLoopTask: Task<Void, Never>?
    var lastIngestedActivityDigest: String?

    public init(
        store: BurnBarMissionControlStore = BurnBarMissionControlStore(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "mission-control-service"),
        activitySnapshotURL: URL? = BurnBarDaemonPaths.defaultControllerActivitySnapshotURL,
        reviewRunLauncher: BurnBarMissionControlReviewRunLauncher? = nil,
        runSnapshotLookup: BurnBarMissionControlRunSnapshotLookup? = nil,
        usageLedgerURL: URL = BurnBarDaemonPaths.defaultUsageLedgerURL,
        executionReadinessGate: BurnBarExecutionReadinessGate? = nil,
        performanceGuardrails: BurnBarMissionControlPerformanceGuardrails? = nil
    ) {
        self.store = store
        self.logger = logger
        self.transport = .live()
        self.activitySnapshotURL = activitySnapshotURL
        self.reviewRunLauncher = reviewRunLauncher
        self.runSnapshotLookup = runSnapshotLookup
        self.usageLedgerURL = usageLedgerURL
        self.executionReadinessGate = executionReadinessGate
        self.performanceGuardrails = performanceGuardrails
    }

    init(
        store: BurnBarMissionControlStore = BurnBarMissionControlStore(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "mission-control-service"),
        transport: BurnBarMissionControlTransport,
        activitySnapshotURL: URL? = nil,
        reviewRunLauncher: BurnBarMissionControlReviewRunLauncher? = nil,
        runSnapshotLookup: BurnBarMissionControlRunSnapshotLookup? = nil,
        usageLedgerURL: URL = BurnBarDaemonPaths.defaultUsageLedgerURL,
        executionReadinessGate: BurnBarExecutionReadinessGate? = nil,
        performanceGuardrails: BurnBarMissionControlPerformanceGuardrails? = nil
    ) {
        self.store = store
        self.logger = logger
        self.transport = transport
        self.activitySnapshotURL = activitySnapshotURL
        self.reviewRunLauncher = reviewRunLauncher
        self.runSnapshotLookup = runSnapshotLookup
        self.usageLedgerURL = usageLedgerURL
        self.executionReadinessGate = executionReadinessGate
        self.performanceGuardrails = performanceGuardrails
    }

    public func startBackgroundLoops() async {
        guard notificationLoopTask == nil else { return }
        notificationLoopTask = Task(priority: .background) { [service = self] in
            await service.runNotificationLoop()
        }
    }

    public func stopBackgroundLoops() async {
        let task = notificationLoopTask
        notificationLoopTask = nil
        task?.cancel()
        _ = await task?.result
    }

    private func runNotificationLoop() async {
        while !Task.isCancelled {
            do {
                try await processTransportCycle(now: Date())
            } catch is CancellationError {
                break
            } catch {
                logger.error(
                    "mission_control_notification_loop_failed",
                    metadata: ["error": error.localizedDescription]
                )
            }

            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                break
            }
        }
    }

    func runTransportCycle(now: Date = Date()) async throws {
        try await processTransportCycle(now: now)
    }

    public func controllerSummary(_ request: BurnBarControllerSummaryRequest) async throws -> BurnBarControllerSummaryResponse {
        try await ingestControllerActivityIfNeeded(now: Date())
        _ = try await store.evaluateDueNotifications(now: Date())
        return try await store.controllerSummary(request)
    }

    public func controllerProjects(_ request: BurnBarControllerProjectsListRequest) async throws -> BurnBarControllerProjectsListResponse {
        try await ingestControllerActivityIfNeeded(now: Date())
        return BurnBarControllerProjectsListResponse(projects: try await store.projects(request))
    }

    public func controllerProject(_ request: BurnBarControllerProjectGetRequest) async throws -> BurnBarControllerProjectResponse {
        try await ingestControllerActivityIfNeeded(now: Date())
        return BurnBarControllerProjectResponse(project: try await store.project(slug: request.projectSlug))
    }

    public func controllerProjectUpsert(_ request: BurnBarControllerProjectUpsertRequest) async throws -> BurnBarControllerProjectResponse {
        let (project, _) = try await store.upsertProject(request.project)
        return BurnBarControllerProjectResponse(project: project)
    }

    public func reviewRunRecord(_ request: BurnBarControllerReviewRunRecordRequest) async throws -> BurnBarControllerReviewRunRecordResponse {
        try await ingestControllerActivityIfNeeded(now: Date())
        return try await launchReviewRun(
            projectSlug: request.run.projectSlug,
            cadence: request.run.cadence,
            origin: request.run.origin,
            triggeredBy: request.run.triggeredBy,
            summary: request.run.summary,
            metadata: request.run.metadata
        )
    }

    public func questionCreate(_ request: BurnBarQuestionCreateRequest) async throws -> BurnBarQuestionResponse {
        let normalized = normalizedQuestion(request.question)
        let (question, _) = try await store.createQuestion(normalized)
        try await deliverNewQuestionNotificationsIfNeeded(question)
        return BurnBarQuestionResponse(question: try await store.question(id: question.id))
    }

    public func questionGet(_ request: BurnBarQuestionGetRequest) async throws -> BurnBarQuestionResponse {
        BurnBarQuestionResponse(question: try await store.question(id: request.questionID))
    }

    public func questionsList(_ request: BurnBarQuestionsListRequest) async throws -> BurnBarQuestionsListResponse {
        try await ingestControllerActivityIfNeeded(now: Date())
        _ = try await store.evaluateDueNotifications(now: Date())
        return BurnBarQuestionsListResponse(questions: try await store.questions(request))
    }

    public func questionAnswer(_ request: BurnBarQuestionAnswerRequest) async throws -> BurnBarQuestionAnswerResponse {
        try await store.answerQuestion(request)
    }

    public func followupCreate(_ request: BurnBarFollowupCreateRequest) async throws -> BurnBarFollowupMutationResponse {
        try await store.createFollowup(request)
    }

    public func followupsList(_ request: BurnBarFollowupsListRequest) async throws -> BurnBarFollowupsListResponse {
        try await ingestControllerActivityIfNeeded(now: Date())
        _ = try await store.evaluateDueNotifications(now: Date())
        return BurnBarFollowupsListResponse(followups: try await store.followups(request))
    }

    public func followupDone(_ request: BurnBarFollowupDoneRequest) async throws -> BurnBarFollowupMutationResponse {
        try await store.markFollowupDone(request)
    }

    public func followupSnooze(_ request: BurnBarFollowupSnoozeRequest) async throws -> BurnBarFollowupMutationResponse {
        try await store.snoozeFollowup(request)
    }

    public func followupCalendar(_ request: BurnBarFollowupCalendarRequest) async throws -> BurnBarFollowupMutationResponse {
        let config = try await store.notificationConfig()
        let resolvedEntry: BurnBarCalendarEntrySnapshot
        if config.calendar.isEnabled {
            do {
                resolvedEntry = try await transport.applyCalendarEntry(
                    request.action,
                    request.entry,
                    config.calendar.defaultCalendarName
                )
                try await store.recordTransportError(channel: .calendar, error: nil)
            } catch {
                try await store.recordTransportError(channel: .calendar, error: error.localizedDescription)
                throw error
            }
        } else {
            resolvedEntry = request.entry
        }

        return try await store.scheduleFollowupCalendar(
            BurnBarFollowupCalendarRequest(
                followupID: request.followupID,
                actor: request.actor,
                action: request.action,
                entry: resolvedEntry
            )
        )
    }

    public func missionCreate(_ request: BurnBarMissionCreateRequest) async throws -> BurnBarMissionMutationResponse {
        try await store.createMission(request)
    }

    public func missionsList(_ request: BurnBarMissionListRequest) async throws -> BurnBarMissionListResponse {
        BurnBarMissionListResponse(missions: try await store.missions(request))
    }

    public func missionGet(_ request: BurnBarMissionGetRequest) async throws -> BurnBarMissionResponse {
        BurnBarMissionResponse(mission: try await store.mission(id: request.missionID))
    }

    public func missionApprove(_ request: BurnBarMissionApproveRequest) async throws -> BurnBarMissionMutationResponse {
        try await store.approveMission(request)
    }

    public func missionCancel(_ request: BurnBarMissionCancelRequest) async throws -> BurnBarMissionMutationResponse {
        try await store.missionCancel(request)
    }

    public func missionDispatchPacket(_ request: BurnBarMissionDispatchPacketRequest) async throws -> BurnBarMissionMutationResponse {
        guard let mission = try await store.mission(id: request.missionID) else {
            throw BurnBarMissionControlError.missionNotFound(request.missionID)
        }

        // VAL-DAEMON-009: Dispatch is approval-gated and terminal-safe.
        // Guards MUST be checked before any reviewRunLauncher side effect, not after.
        // Block dispatch if mission is not approved
        guard mission.approval.approved else {
            throw BurnBarMissionControlError.missionNotApproved(request.missionID)
        }
        // Block dispatch if mission is in a terminal state
        guard !Self.terminalMissionStatuses.contains(mission.status) else {
            throw BurnBarMissionControlError.missionTerminal(request.missionID, mission.status)
        }

        if let enterprisePolicyBlock = try await evaluateEnterprisePolicyBlock(mission: mission, packet: request.packet) {
            try await persistEnterprisePolicyBlock(
                enterprisePolicyBlock,
                mission: mission,
                actor: request.actor
            )
            throw BurnBarMissionControlError.enterprisePolicyBlocked(
                request.missionID,
                enterprisePolicyBlock.reasonCode,
                enterprisePolicyBlock.detail
            )
        }

        // VAL-DAEMON-011: Execution readiness gate fails closed with explicit reason codes.
        // Run readiness check before any side effects. Fail-closed when executionReadinessGate
        // is nil (no gate data available) — return explicit reason code instead of allowing dispatch.
        if let readinessGate = executionReadinessGate {
            if let failure = await readinessGate(mission, request.packet) {
                throw BurnBarMissionControlError.executionReadinessFailed(
                    request.missionID,
                    failure.code,
                    failure.detail
                )
            }
        } else {
            // Fail-closed: when no readiness gate is configured, reject dispatch with explicit reason
            throw BurnBarMissionControlError.executionReadinessFailed(
                request.missionID,
                .runtimeUnavailable,
                "Execution readiness gate is not configured. Mission dispatch requires a readiness gate to verify runtime availability."
            )
        }

        let launchedRun: BurnBarRunCreateResponse?
        if let reviewRunLauncher {
            let metadata = BurnBarRunCreateMetadata(
                request.packet.metadata.merging([
                    "missionExecution": .bool(true),
                    "mission_id": .string(mission.id.rawValue),
                    "mission_packet_id": .string(request.packet.id.rawValue),
                    "project_slug": .string(mission.projectSlug)
                ]) { _, new in new }
            )
            launchedRun = try await reviewRunLauncher(
                buildMissionPacketPrompt(mission: mission, packet: request.packet),
                missionExecutionModelID(for: mission, packet: request.packet),
                metadata
            )
        } else {
            launchedRun = nil
        }

        let linkedRequest = BurnBarMissionDispatchPacketRequest(
            missionID: request.missionID,
            actor: request.actor,
            packet: BurnBarMissionPacketSnapshot(
                id: request.packet.id,
                missionID: request.missionID,
                workerName: request.packet.workerName,
                objective: request.packet.objective,
                status: launchedRun == nil ? request.packet.status : .dispatched,
                runID: launchedRun?.runID,
                dispatchedAt: request.packet.dispatchedAt ?? Date(),
                completedAt: request.packet.completedAt,
                metadata: request.packet.metadata
            )
        )
        return try await store.dispatchMissionPacket(linkedRequest)
    }

    public func missionRecordResult(_ request: BurnBarMissionRecordResultRequest) async throws -> BurnBarMissionMutationResponse {
        try await store.recordMissionResult(request)
    }

    public func notificationConfigGet(_ request: BurnBarNotificationConfigGetRequest) async throws -> BurnBarNotificationConfigResponse {
        _ = request
        let config = try await store.notificationConfig()
        return BurnBarNotificationConfigResponse(config: config)
    }

    public func notificationConfigUpdate(_ request: BurnBarNotificationConfigUpdateRequest) async throws -> BurnBarNotificationConfigResponse {
        try await store.updateNotificationConfig(request)
    }

    public func notificationHealth(_ request: BurnBarNotificationHealthRequest) async throws -> BurnBarNotificationHealthResponse {
        _ = request
        _ = try await store.evaluateDueNotifications(now: Date())
        return try await store.notificationHealth()
    }

    public func notificationCommand(_ request: BurnBarNotificationCommandRequest) async throws -> BurnBarNotificationCommandResponse {
        let response: BurnBarNotificationCommandResponse

        switch request.command {
        case .help:
            response = BurnBarNotificationCommandResponse(
                command: .help,
                ok: true,
                message: "Commands: help, pending, followups, done <id>, snooze <id> [minutes], calendar <id> <ISO8601>, answer <id> <text>, latest, status, run_daily <project>, run_weekly <project>."
            )
        case .pending, .followups:
            let open = try await store.followups(BurnBarFollowupsListRequest())
            if open.isEmpty {
                response = BurnBarNotificationCommandResponse(command: request.command, ok: true, message: "No unresolved followups.")
            } else {
                let preview = open.prefix(5).map { "\($0.id.rawValue): \($0.title)" }.joined(separator: "\n")
                response = BurnBarNotificationCommandResponse(command: request.command, ok: true, message: preview, followup: open.first)
            }
        case .done:
            guard let rawID = request.arguments.first else {
                response = BurnBarNotificationCommandResponse(command: .done, ok: false, message: "Usage: done <followupID>")
                break
            }
            let mutation = try await followupDone(
                BurnBarFollowupDoneRequest(
                    followupID: BurnBarFollowupID(rawValue: rawID),
                    actor: request.actor
                )
            )
            response = BurnBarNotificationCommandResponse(command: .done, ok: true, message: "Marked \(mutation.followup.title) done.", followup: mutation.followup)
        case .snooze:
            guard let rawID = request.arguments.first else {
                response = BurnBarNotificationCommandResponse(command: .snooze, ok: false, message: "Usage: snooze <followupID> [minutes]")
                break
            }
            let minutes = request.arguments.count > 1 ? Int(request.arguments[1]) ?? 60 : 60
            let mutation = try await followupSnooze(
                BurnBarFollowupSnoozeRequest(
                    followupID: BurnBarFollowupID(rawValue: rawID),
                    actor: request.actor,
                    snoozeUntil: Date().addingTimeInterval(Double(minutes * 60))
                )
            )
            response = BurnBarNotificationCommandResponse(command: .snooze, ok: true, message: "Snoozed \(mutation.followup.title) for \(minutes)m.", followup: mutation.followup)
        case .calendar:
            guard let rawID = request.arguments.first else {
                response = BurnBarNotificationCommandResponse(command: .calendar, ok: false, message: "Usage: calendar <followupID> <ISO8601>")
                break
            }
            let formatter = ISO8601DateFormatter()
            let start = request.arguments.count > 1
                ? (formatter.date(from: request.arguments[1]) ?? Date().addingTimeInterval(3600))
                : Date().addingTimeInterval(3600)
            let duration = try await store.notificationConfig().calendar.defaultDurationMinutes
            let mutation = try await followupCalendar(
                BurnBarFollowupCalendarRequest(
                    followupID: BurnBarFollowupID(rawValue: rawID),
                    actor: request.actor,
                    action: .create,
                    entry: BurnBarCalendarEntrySnapshot(
                        externalID: nil,
                        title: "OpenBurnBar followup \(rawID)",
                        startAt: start,
                        endAt: start.addingTimeInterval(Double(duration) * 60),
                        notes: "Scheduled from notification command."
                    )
                )
            )
            response = BurnBarNotificationCommandResponse(command: .calendar, ok: true, message: "Scheduled \(mutation.followup.title) on the calendar.", followup: mutation.followup)
        case .answer:
            guard let rawID = request.arguments.first, request.arguments.count > 1 else {
                response = BurnBarNotificationCommandResponse(command: .answer, ok: false, message: "Usage: answer <questionID> <text>")
                break
            }
            let answered = try await questionAnswer(
                BurnBarQuestionAnswerRequest(
                    questionID: BurnBarQuestionID(rawValue: rawID),
                    answeredBy: request.actor,
                    answer: request.arguments.dropFirst().joined(separator: " ")
                )
            )
            response = BurnBarNotificationCommandResponse(command: .answer, ok: true, message: "Answered \(answered.question.title).", followup: answered.followup, question: answered.question)
        case .latest, .status:
            let summary = try await store.controllerSummary(BurnBarControllerSummaryRequest())
            response = BurnBarNotificationCommandResponse(
                command: request.command,
                ok: true,
                message: "Projects: \(summary.summary.counts.projectCount), pending questions: \(summary.summary.counts.pendingQuestionCount), open followups: \(summary.summary.counts.openFollowupCount), active missions: \(summary.summary.counts.activeMissionCount)."
            )
        case .runDaily, .runWeekly:
            let fallbackSummary = try await store.controllerSummary(BurnBarControllerSummaryRequest())
            let slug = request.arguments.first ?? (fallbackSummary.summary.activeProjectSlug ?? "openburnbar")
            let cadence: BurnBarControllerReviewCadence = request.command == .runDaily ? .daily : .weekly
            let launched = try await launchReviewRun(
                projectSlug: slug,
                cadence: cadence,
                origin: .telegram,
                triggeredBy: request.actor,
                summary: "Triggered from \(request.actor) notification command."
            )
            let liveRunSummary = launched.run.launchedRunID.map { " (run \($0.rawValue))" } ?? ""
            response = BurnBarNotificationCommandResponse(
                command: request.command,
                ok: true,
                message: "Launched \(cadence.rawValue) review for \(slug)\(liveRunSummary)."
            )
        }

        let projectSlug = response.followup?.projectSlug
            ?? response.question?.projectSlug
            ?? response.mission?.projectSlug
            ?? request.arguments.first
            ?? "openburnbar"
        try await store.recordNotificationCommand(request, responseSummary: response.message, projectSlug: projectSlug)
        return response
    }

    public func simulatorRun(_ request: BurnBarSimulatorRunRequest) async throws -> BurnBarSimulatorRunResponse {
        try await store.recordSimulatorRun(request)
    }

    public func simulatorList(_ request: BurnBarSimulatorListRequest) async throws -> BurnBarSimulatorListResponse {
        try await store.simulatorRuns(request)
    }

    public func simulatorReplay(_ request: BurnBarSimulatorReplayRequest) async throws -> BurnBarSimulatorRunResponse {
        try await store.replaySimulator(request)
    }

    public func projectionRebuild(_ request: BurnBarProjectionRebuildRequest) async throws -> BurnBarProjectionRebuildResponse {
        try await store.rebuildProjection(request)
    }

    private func processTransportCycle(now: Date) async throws {
        let cycleStartedAt = Date()
        try await enforcePerformanceGuardrailsBeforeTransportCycle()
        try await ingestControllerActivityIfNeeded(now: now)
        try await launchDueScheduledReviews(now: now)
        try await syncMissionExecution(now: now)
        let dueFollowups = try await store.evaluateDueNotifications(now: now)
        try await deliverDueFollowups(dueFollowups)
        try await pollTelegramCommands()
        try enforcePerformanceGuardrailsAfterTransportCycle(startedAt: cycleStartedAt, finishedAt: Date())
    }

    private func ingestControllerActivityIfNeeded(now: Date) async throws {
        guard let snapshot = try loadActivitySnapshotIfChanged() else {
            return
        }

        for activityProject in snapshot.projects {
            try await syncActivityProject(activityProject, now: now)
        }
    }

    private func loadActivitySnapshotIfChanged() throws -> BurnBarControllerActivitySnapshot? {
        guard let activitySnapshotURL,
              FileManager.default.fileExists(atPath: activitySnapshotURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: activitySnapshotURL)
        let digest = String(decoding: data, as: UTF8.self)
        guard digest != lastIngestedActivityDigest else {
            return nil
        }

        let snapshot = try JSONDecoder().decode(BurnBarControllerActivitySnapshot.self, from: data)
        lastIngestedActivityDigest = digest
        return snapshot
    }

    private func enforcePerformanceGuardrailsBeforeTransportCycle() async throws {
        guard let performanceGuardrails else { return }

        let probeLimit = max(performanceGuardrails.maxTrackedMissionCount + 1, 1)
        let trackedMissions = try await store.missions(
            BurnBarMissionListRequest(
                statuses: BurnBarMissionStatus.allCases,
                limit: probeLimit
            )
        )
        let trackedMissionCount = trackedMissions.count
        if trackedMissionCount > performanceGuardrails.maxTrackedMissionCount {
            throw BurnBarMissionControlError.performanceGuardrailExceeded(
                "tracked_mission_count",
                Double(performanceGuardrails.maxTrackedMissionCount),
                Double(trackedMissionCount)
            )
        }
    }

    private func enforcePerformanceGuardrailsAfterTransportCycle(
        startedAt: Date,
        finishedAt: Date
    ) throws {
        guard let performanceGuardrails else { return }

        let elapsedMilliseconds = finishedAt.timeIntervalSince(startedAt) * 1_000
        if elapsedMilliseconds > performanceGuardrails.maxTransportCycleDurationMilliseconds {
            throw BurnBarMissionControlError.performanceGuardrailExceeded(
                "transport_cycle_duration_ms",
                performanceGuardrails.maxTransportCycleDurationMilliseconds,
                elapsedMilliseconds
            )
        }
    }

    private func syncActivityProject(
        _ activityProject: BurnBarControllerActivityProject,
        now: Date
    ) async throws {
        let existing = try await store.project(slug: activityProject.projectSlug)
        let mergedProject = mergeProject(activityProject, existing: existing)

        if let existing, projectRegistryEquivalent(existing, mergedProject) == false {
            _ = try await store.upsertProject(mergedProject)
        } else if existing == nil {
            _ = try await store.upsertProject(mergedProject)
        }

        try await syncInferredQuestion(for: activityProject, now: now)
    }

    private func mergeProject(
        _ activityProject: BurnBarControllerActivityProject,
        existing: BurnBarReviewProjectSnapshot?
    ) -> BurnBarReviewProjectSnapshot {
        var metadata = existing?.metadata ?? [:]
        if let latestActivityAt = activityProject.latestActivityAt {
            metadata["latest_activity_at"] = .string(latestActivityAt.ISO8601Format())
        }
        if let latestConversationID = activityProject.latestConversationID?.nonEmpty {
            metadata["latest_conversation_id"] = .string(latestConversationID)
        }
        if let latestConversationSessionID = activityProject.latestConversationSessionID?.rawValue,
           latestConversationSessionID.isEmpty == false {
            metadata["latest_conversation_session_id"] = .string(latestConversationSessionID)
        }
        if let latestConversationTitle = activityProject.latestConversationTitle?.nonEmpty {
            metadata["latest_conversation_title"] = .string(latestConversationTitle)
        }
        if let latestConversationSummary = activityProject.latestConversationSummary?.nonEmpty {
            metadata["latest_conversation_summary"] = .string(latestConversationSummary)
        }
        if let latestQuestionPrompt = activityProject.latestQuestionPrompt?.nonEmpty {
            metadata["latest_question_prompt"] = .string(latestQuestionPrompt)
        }
        metadata["session_count_last_7d"] = .number(Double(activityProject.sessionCountLast7Days))
        metadata["total_cost_last_7d"] = .number(activityProject.totalCostLast7Days)
        metadata["total_tokens_last_7d"] = .number(Double(activityProject.totalTokensLast7Days))

        let cadence = existing?.preferredCadence
            ?? activityProject.preferredCadence
            ?? defaultCadence(for: activityProject)
        let automationMode = existing?.automationMode
            ?? activityProject.automationMode
            ?? .manual
        let reviewModelID = existing?.reviewModelID
            ?? activityProject.reviewModelID
            ?? "glm-5"
        let scheduleHourLocal = existing?.scheduleHourLocal
            ?? activityProject.scheduleHourLocal
            ?? 9
        let scheduleWeekdayLocal = existing?.scheduleWeekdayLocal
            ?? activityProject.scheduleWeekdayLocal
            ?? 2
        let aliases = existing?.aliases.isEmpty == false
            ? existing?.aliases ?? []
            : activityProject.aliases
        let summary = activityProject.summary.nonEmpty
            ?? activityProject.latestConversationSummary?.nonEmpty
            ?? activityProject.latestConversationTitle?.nonEmpty
            ?? existing?.summary
            ?? "Awaiting the next indexed OpenBurnBar checkpoint."

        return BurnBarReviewProjectSnapshot(
            id: existing?.id ?? "project-\(activityProject.projectSlug)",
            projectSlug: activityProject.projectSlug,
            displayName: activityProject.displayName,
            summary: summary,
            status: existing?.status == .paused ? .paused : (existing == nil ? .onboarding : (existing?.status ?? .healthy)),
            preferredCadence: cadence,
            aliases: aliases,
            automationMode: automationMode,
            reviewModelID: reviewModelID,
            scheduleHourLocal: scheduleHourLocal,
            scheduleWeekdayLocal: scheduleWeekdayLocal,
            freshness: existing?.freshness ?? .provisional,
            latestDailyReviewAt: existing?.latestDailyReviewAt,
            latestWeeklyReviewAt: existing?.latestWeeklyReviewAt,
            nextScheduledReviewAt: existing?.nextScheduledReviewAt,
            pendingQuestionCount: existing?.pendingQuestionCount ?? 0,
            openFollowupCount: existing?.openFollowupCount ?? 0,
            activeMissionCount: existing?.activeMissionCount ?? 0,
            activeMissionID: existing?.activeMissionID,
            needsOperatorAttention: existing?.needsOperatorAttention ?? false,
            ingestionSource: .appActivity,
            metadata: metadata
        )
    }

    private func projectRegistryEquivalent(
        _ lhs: BurnBarReviewProjectSnapshot,
        _ rhs: BurnBarReviewProjectSnapshot
    ) -> Bool {
        lhs.projectSlug == rhs.projectSlug
            && lhs.displayName == rhs.displayName
            && lhs.summary == rhs.summary
            && lhs.preferredCadence == rhs.preferredCadence
            && lhs.aliases == rhs.aliases
            && lhs.automationMode == rhs.automationMode
            && lhs.reviewModelID == rhs.reviewModelID
            && lhs.scheduleHourLocal == rhs.scheduleHourLocal
            && lhs.scheduleWeekdayLocal == rhs.scheduleWeekdayLocal
            && lhs.ingestionSource == rhs.ingestionSource
            && lhs.metadata == rhs.metadata
    }

    private func syncInferredQuestion(
        for activityProject: BurnBarControllerActivityProject,
        now: Date
    ) async throws {
        guard let prompt = activityProject.latestQuestionPrompt?.nonEmpty else {
            return
        }

        let fingerprint = [
            activityProject.latestConversationID ?? activityProject.projectSlug,
            prompt
        ].joined(separator: "|")
        let existingQuestions = try await store.questions(
            BurnBarQuestionsListRequest(
                projectSlug: activityProject.projectSlug,
                statuses: BurnBarPendingQuestionStatus.allCases,
                limit: 50
            )
        )
        if existingQuestions.contains(where: { question in
            guard let existingFingerprint = question.metadata["ingestion_fingerprint"]?.missionStringValue() else {
                return false
            }
            return existingFingerprint == fingerprint
                && question.status != .dismissed
                && question.status != .expired
        }) {
            return
        }

        var metadata: BurnBarMetadata = [
            "ingestion_fingerprint": .string(fingerprint),
            "ingestion_source": .string(BurnBarControllerProjectIngestionSource.appActivity.rawValue)
        ]
        if let latestConversationID = activityProject.latestConversationID?.nonEmpty {
            metadata["conversation_id"] = .string(latestConversationID)
        }

        _ = try await questionCreate(
            BurnBarQuestionCreateRequest(
                question: BurnBarPendingQuestionSnapshot(
                    id: BurnBarQuestionID(rawValue: "question-\(UUID().uuidString)"),
                    projectSlug: activityProject.projectSlug,
                    sessionID: activityProject.latestConversationSessionID,
                    title: activityProject.latestConversationTitle?.nonEmpty ?? "Answer the latest checkpoint question",
                    prompt: prompt,
                    stageLabel: inferredStageLabel(for: prompt),
                    status: .pending,
                    priority: questionPriority(for: prompt),
                    askedAt: activityProject.latestActivityAt ?? now,
                    dueAt: Calendar.current.date(byAdding: .hour, value: 2, to: activityProject.latestActivityAt ?? now),
                    answerPlaceholder: "Record the operator call OpenBurnBar should carry forward…",
                    contextSummary: activityProject.latestConversationSummary?.nonEmpty ?? activityProject.summary,
                    evidenceRefs: activityProject.latestConversationID.map { [$0] } ?? [],
                    suggestedOptions: inferredQuestionOptions(for: prompt),
                    deepLink: inferredQuestionDeepLink(for: activityProject),
                    tracker: BurnBarQuestionTrackerSnapshot(
                        isUnread: true,
                        surfacedAt: activityProject.latestActivityAt ?? now
                    ),
                    metadata: metadata
                )
            )
        )
    }

    private func evaluateEnterprisePolicyBlock(
        mission: BurnBarMissionSnapshot,
        packet: BurnBarMissionPacketSnapshot
    ) async throws -> BurnBarEnterprisePolicyBlock? {
        guard let project = try await store.project(slug: mission.projectSlug) else {
            return nil
        }

        let metadata = project.metadata
        if let hardCap = metadata["enterprise_budget_hard_cap_usd"]?.missionNumberValue(),
           let observedSpend = metadata["enterprise_budget_spend_usd"]?.missionNumberValue(),
           observedSpend > hardCap {
            return BurnBarEnterprisePolicyBlock(
                reasonCode: .budgetHardCapBlocked,
                detail: String(
                    format: "Observed spend (%.2f USD) exceeds hard cap (%.2f USD).",
                    observedSpend,
                    hardCap
                ),
                approvalMode: metadata["enterprise_approval_mode"]
                    .flatMap { $0.missionStringValue() }
                    .flatMap(BurnBarEnterpriseApprovalMode.init(rawValue:)),
                budgetHardCapUSD: hardCap,
                observedSpendUSD: observedSpend,
                blockedAt: Date()
            )
        }

        guard let approvalModeRaw = metadata["enterprise_approval_mode"]?.missionStringValue() else {
            return nil
        }
        guard let approvalMode = BurnBarEnterpriseApprovalMode(rawValue: approvalModeRaw) else {
            return BurnBarEnterprisePolicyBlock(
                reasonCode: .configurationInvalid,
                detail: "Unsupported enterprise approval mode '\(approvalModeRaw)'.",
                blockedAt: Date()
            )
        }

        switch approvalMode {
        case .manualAll:
            let hasExplicitApproval = packet.metadata["enterprise_explicit_approval_granted"]?.missionBoolValue() == true
            if hasExplicitApproval == false {
                return BurnBarEnterprisePolicyBlock(
                    reasonCode: .approvalRequiredByMode,
                    detail: "\(approvalMode.rawValue) mode requires explicit operator approval metadata.",
                    approvalMode: approvalMode,
                    blockedAt: Date()
                )
            }
        case .autoLowOnly:
            let riskLevel = packet.metadata["risk_level"]?.missionStringValue()?.lowercased()
            if riskLevel == "high" || riskLevel == "critical" {
                return BurnBarEnterprisePolicyBlock(
                    reasonCode: .approvalRequiredByMode,
                    detail: "\(approvalMode.rawValue) mode blocks \(riskLevel ?? "high") risk packets without explicit approval metadata.",
                    approvalMode: approvalMode,
                    blockedAt: Date()
                )
            }
        case .autoLowMedium:
            break
        }

        return nil
    }

    private func persistEnterprisePolicyBlock(
        _ block: BurnBarEnterprisePolicyBlock,
        mission: BurnBarMissionSnapshot,
        actor: String
    ) async throws {
        var snapshot = missionSnapshot(
            from: mission,
            status: .awaitingApproval,
            updatedAt: block.blockedAt,
            packets: mission.packets,
            results: mission.results,
            burnRecords: mission.burnRecords,
            takeoverHistory: mission.takeoverHistory
        )
        var metadata = snapshot.metadata
        var policyMetadata: [String: BurnBarJSONValue] = [
            "reason_code": .string(block.reasonCode.rawValue),
            "detail": .string(block.detail),
            "blocked_at": .string(block.blockedAt.ISO8601Format())
        ]
        if let approvalMode = block.approvalMode {
            policyMetadata["approval_mode"] = .string(approvalMode.rawValue)
        }
        if let hardCap = block.budgetHardCapUSD {
            policyMetadata["budget_hard_cap_usd"] = .number(hardCap)
        }
        if let observedSpend = block.observedSpendUSD {
            policyMetadata["observed_spend_usd"] = .number(observedSpend)
        }

        metadata["enterprise_policy_block"] = .object(policyMetadata)
        metadata["enterprise_policy_block_reason_code"] = .string(block.reasonCode.rawValue)
        metadata["enterprise_policy_blocked_at"] = .string(block.blockedAt.ISO8601Format())
        metadata["enterprise_policy_blocked_by"] = .string(actor)

        snapshot = BurnBarMissionSnapshot(
            id: snapshot.id,
            projectSlug: snapshot.projectSlug,
            title: snapshot.title,
            summary: snapshot.summary,
            status: snapshot.status,
            recommendation: snapshot.recommendation,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            approval: snapshot.approval,
            packets: snapshot.packets,
            results: snapshot.results,
            burnRecords: snapshot.burnRecords,
            takeoverHistory: snapshot.takeoverHistory,
            prLinkage: snapshot.prLinkage,
            metadata: metadata
        )
        _ = try await store.persistMissionSnapshot(
            snapshot,
            eventType: "mission_dispatch_blocked_enterprise_policy",
            summary: snapshot.title,
            detail: block.detail
        )
    }

    private func launchDueScheduledReviews(now: Date) async throws {
        let projects = try await store.projects(
            BurnBarControllerProjectsListRequest(includePaused: false, limit: 500)
        )

        for project in projects {
            guard project.automationMode == .scheduled,
                  let dueAt = project.nextScheduledReviewAt,
                  dueAt <= now,
                  shouldAttemptScheduledLaunch(for: project, now: now) else {
                continue
            }

            do {
                let scheduledReviewIntent = try await buildScheduledReviewIntent(
                    project: project,
                    dueAt: dueAt
                )
                _ = try await launchReviewRun(
                    projectSlug: project.projectSlug,
                    cadence: project.preferredCadence,
                    origin: .scheduled,
                    triggeredBy: "scheduler",
                    summary: "Scheduled \(project.preferredCadence.rawValue) review launched automatically.",
                    metadata: scheduledReviewIntent.metadata
                )
                try await clearScheduledLaunchFailure(for: project)
            } catch {
                logger.error(
                    "scheduled_review_launch_failed",
                    metadata: [
                        "project_slug": project.projectSlug,
                        "error": error.localizedDescription
                    ]
                )
                try await recordScheduledLaunchFailure(for: project, error: error, at: now)
            }
        }
    }

    private func syncMissionExecution(now: Date) async throws {
        guard let runSnapshotLookup else { return }
        var missions = try await store.missions(
            BurnBarMissionListRequest(statuses: BurnBarMissionStatus.allCases, limit: 200)
        )

        for mission in missions {
            var currentMission = mission
            for packet in currentMission.packets {
                guard let runID = packet.runID,
                      let snapshot = await runSnapshotLookup(runID) else {
                    continue
                }

                let desiredPacketStatus = missionPacketStatus(for: snapshot.phase)
                let isTerminalPhase = isTerminal(phase: snapshot.phase)
                // VAL-EXEC-001: Update packet status for terminal phases (always, to ensure
                // correct phase→status mapping regardless of prior state) and for non-terminal
                // phases only when the status has changed. The completedAt check is intentionally
                // excluded for non-terminal packets since nil completedAt is expected and should
                // not trigger a rewrite on every sync cycle.
                if isTerminalPhase || desiredPacketStatus != packet.status {
                    let updatedPacket = BurnBarMissionPacketSnapshot(
                        id: packet.id,
                        missionID: currentMission.id,
                        workerName: packet.workerName,
                        objective: packet.objective,
                        status: desiredPacketStatus,
                        runID: runID,
                        dispatchedAt: packet.dispatchedAt,
                        completedAt: isTerminal(phase: snapshot.phase) ? (packet.completedAt ?? now) : packet.completedAt,
                        metadata: packet.metadata.merging([
                            "run_phase": .string(snapshot.phase.rawValue),
                            "model_id": .string(snapshot.modelID)
                        ]) { _, new in new }
                    )
                    currentMission = try await store.persistMissionSnapshot(
                        missionSnapshot(
                            from: currentMission,
                            status: currentMission.status,
                            updatedAt: now,
                            packets: replacePacket(updatedPacket, in: currentMission.packets),
                            results: currentMission.results,
                            burnRecords: currentMission.burnRecords,
                            takeoverHistory: currentMission.takeoverHistory
                        ),
                        eventType: "mission_packet_synced",
                        summary: updatedPacket.workerName,
                        detail: snapshot.phase.rawValue
                    ).mission
                }

                if isTerminal(phase: snapshot.phase),
                   currentMission.results.contains(where: { $0.runID == runID }) == false {
                    let usage = latestUsageEvent(for: runID)
                    var resultMetadata = packet.metadata
                    resultMetadata["run_phase"] = .string(snapshot.phase.rawValue)
                    resultMetadata["model_id"] = .string(snapshot.modelID)
                    resultMetadata["provider_id"] = usage.map { .string($0.providerID) } ?? .string("unknown")
                    resultMetadata["input_tokens"] = .number(Double(usage?.inputTokens ?? 0))
                    resultMetadata["output_tokens"] = .number(Double(usage?.outputTokens ?? 0))
                    resultMetadata["cache_read_tokens"] = .number(Double(usage?.cacheReadTokens ?? 0))
                    let result = BurnBarMissionResultSnapshot(
                        id: BurnBarMissionResultID(rawValue: "result-\(runID.rawValue)"),
                        missionID: currentMission.id,
                        packetID: packet.id,
                        runID: runID,
                        status: missionResultStatus(for: snapshot.phase),
                        summary: missionResultSummary(for: packet, snapshot: snapshot),
                        detail: missionResultDetail(for: snapshot),
                        burnDelta: usage?.cost ?? 0,
                        createdAt: now,
                        evidenceRefs: [runID.rawValue],
                        metadata: resultMetadata
                    )
                    let recordResponse = try await store.recordMissionResult(
                        BurnBarMissionRecordResultRequest(
                            missionID: currentMission.id,
                            result: result
                        ),
                        existingMission: currentMission
                    )
                    currentMission = recordResponse.mission
                }
            }

            currentMission = try await synchronizeAutoTakeover(for: currentMission, now: now)
            if let index = missions.firstIndex(where: { $0.id == currentMission.id }) {
                missions[index] = currentMission
            }
        }
    }

    private func synchronizeAutoTakeover(
        for mission: BurnBarMissionSnapshot,
        now: Date
    ) async throws -> BurnBarMissionSnapshot {
        guard let runSnapshotLookup,
              let reviewRunLauncher else {
            return mission
        }

        var currentMission = mission
        let takeoverHistory = currentMission.takeoverHistory ?? []

        for packet in currentMission.packets {
            guard packet.metadata["source_packet_id"] == nil,
                  let sourceRunID = packet.runID else { continue }
            let existingTakeover = takeoverHistory.last { $0.sourceRunID == sourceRunID }

            if let existingTakeover, let takeoverRunID = existingTakeover.takeoverRunID,
               let takeoverSnapshot = await runSnapshotLookup(takeoverRunID) {
                let desiredStatus = autoTakeoverStatus(for: takeoverSnapshot.phase)
                if desiredStatus != existingTakeover.status {
                    let updatedRecord = BurnBarAutoTakeoverRecord(
                        id: existingTakeover.id,
                        projectSlug: existingTakeover.projectSlug,
                        missionID: existingTakeover.missionID,
                        sourceRunID: existingTakeover.sourceRunID,
                        takeoverRunID: existingTakeover.takeoverRunID,
                        status: desiredStatus,
                        reason: existingTakeover.reason,
                        createdAt: existingTakeover.createdAt,
                        updatedAt: now,
                        metadata: existingTakeover.metadata.merging([
                            "run_phase": .string(takeoverSnapshot.phase.rawValue),
                            "error_message": .string(takeoverSnapshot.errorMessage ?? "")
                        ]) { _, new in new }
                    )
                    currentMission = try await store.persistMissionSnapshot(
                        missionSnapshot(
                            from: currentMission,
                            status: currentMission.status,
                            updatedAt: now,
                            packets: currentMission.packets,
                            results: currentMission.results,
                            burnRecords: currentMission.burnRecords,
                            takeoverHistory: replaceTakeoverRecord(updatedRecord, in: currentMission.takeoverHistory)
                        ),
                        eventType: "mission_auto_takeover_synced",
                        summary: currentMission.title,
                        detail: desiredStatus.rawValue
                    ).mission
                }
                continue
            }

            guard let sourceSnapshot = await runSnapshotLookup(sourceRunID),
                  existingTakeover == nil,
                  shouldAutoTakeover(snapshot: sourceSnapshot, now: now) else {
                continue
            }

            let takeoverRun = try await reviewRunLauncher(
                buildAutoTakeoverPrompt(mission: currentMission, packet: packet, snapshot: sourceSnapshot),
                missionExecutionModelID(for: currentMission, packet: packet),
                BurnBarRunCreateMetadata(
                    packet.metadata.merging([
                        "autoTakeover": .bool(true),
                        "missionExecution": .bool(true),
                        "mission_id": .string(currentMission.id.rawValue),
                        "mission_packet_id": .string(packet.id.rawValue),
                        "source_run_id": .string(sourceRunID.rawValue)
                    ]) { _, new in new }
                )
            )

            let takeoverReason = autoTakeoverReason(for: sourceSnapshot, now: now)
            let takeoverPacket = BurnBarMissionPacketSnapshot(
                id: BurnBarMissionPacketID(rawValue: "takeover-packet-\(UUID().uuidString)"),
                missionID: currentMission.id,
                workerName: "auto-takeover",
                objective: "Take over \(packet.workerName): \(packet.objective)",
                status: .dispatched,
                runID: takeoverRun.runID,
                dispatchedAt: now,
                metadata: [
                    "auto_takeover": .bool(true),
                    "source_packet_id": .string(packet.id.rawValue),
                    "source_run_id": .string(sourceRunID.rawValue)
                ]
            )
            let takeoverRecord = BurnBarAutoTakeoverRecord(
                id: "takeover-\(UUID().uuidString)",
                projectSlug: currentMission.projectSlug,
                missionID: currentMission.id,
                sourceRunID: sourceRunID,
                takeoverRunID: takeoverRun.runID,
                status: .launched,
                reason: takeoverReason,
                createdAt: now,
                updatedAt: now,
                metadata: [
                    "source_packet_id": .string(packet.id.rawValue),
                    "takeover_packet_id": .string(takeoverPacket.id.rawValue)
                ]
            )

            currentMission = try await store.persistMissionSnapshot(
                missionSnapshot(
                    from: currentMission,
                    status: .dispatching,
                    updatedAt: now,
                    packets: mergePackets(currentMission.packets, takeoverPacket),
                    results: currentMission.results,
                    burnRecords: currentMission.burnRecords,
                    takeoverHistory: (currentMission.takeoverHistory ?? []) + [takeoverRecord]
                ),
                eventType: "mission_auto_takeover_launched",
                summary: currentMission.title,
                detail: takeoverReason
            ).mission
        }

        return currentMission
    }

    private struct BurnBarScheduledReviewIntentPayload {
        let intent: BurnBarScheduledReviewIntent
        let metadata: BurnBarMetadata
    }

    private func buildScheduledReviewIntent(
        project: BurnBarReviewProjectSnapshot,
        dueAt: Date
    ) async throws -> BurnBarScheduledReviewIntentPayload {
        let dueTimestamp = Int(dueAt.timeIntervalSince1970)
        let taskID = "scheduled-review-\(project.projectSlug)-\(project.preferredCadence.rawValue)-\(dueTimestamp)"
        let notificationIntentID = "intent-\(project.projectSlug)-\(project.preferredCadence.rawValue)-\(dueTimestamp)"
        let config = try await store.notificationConfig()
        let channels = enabledNotificationChannels(from: config)
        let dueAtISO = dueAt.ISO8601Format()
        let dedupeKey = [
            "scheduled-review",
            project.projectSlug,
            project.preferredCadence.rawValue,
            dueAtISO
        ].joined(separator: "|")
        let intent = BurnBarScheduledReviewIntent(
            taskID: taskID,
            projectSlug: project.projectSlug,
            dueAt: dueAt,
            notificationIntentID: notificationIntentID,
            notificationChannels: channels
        )

        let intentObject: [String: BurnBarJSONValue] = [
            "taskID": .string(intent.taskID),
            "projectSlug": .string(intent.projectSlug),
            "dueAt": .string(dueAtISO),
            "notificationIntentID": .string(intent.notificationIntentID),
            "notificationChannels": .array(intent.notificationChannels.map { .string($0.rawValue) })
        ]
        let metadata: BurnBarMetadata = [
            "scheduled_review_task_id": .string(intent.taskID),
            "scheduled_review_due_at": .string(dueAtISO),
            "notification_intent_id": .string(intent.notificationIntentID),
            "notification_intent_dedupe_key": .string(dedupeKey),
            "notification_intent_channels": .array(intent.notificationChannels.map { .string($0.rawValue) }),
            "scheduledReviewIntent": .object(intentObject)
        ]
        return BurnBarScheduledReviewIntentPayload(intent: intent, metadata: metadata)
    }

    private func enabledNotificationChannels(
        from config: BurnBarNotificationConfig
    ) -> [BurnBarNotificationChannel] {
        var channels: [BurnBarNotificationChannel] = []
        if config.local.isEnabled {
            channels.append(.local)
        }
        if config.telegram.isEnabled,
           config.telegram.botToken?.nonEmpty != nil,
           config.telegram.chatID?.nonEmpty != nil {
            channels.append(.telegram)
        }
        if config.calendar.isEnabled {
            channels.append(.calendar)
        }
        return channels
    }

    private func shouldAttemptScheduledLaunch(
        for project: BurnBarReviewProjectSnapshot,
        now: Date
    ) -> Bool {
        guard let attemptedAt = metadataDate("scheduler_last_launch_attempt_at", in: project.metadata) else {
            return true
        }

        let cooldown: TimeInterval = 4 * 60 * 60
        return now.timeIntervalSince(attemptedAt) >= cooldown
    }

    private func recordScheduledLaunchFailure(
        for project: BurnBarReviewProjectSnapshot,
        error: Error,
        at now: Date
    ) async throws {
        var metadata = project.metadata
        metadata["scheduler_last_launch_attempt_at"] = .string(now.ISO8601Format())
        metadata["scheduler_last_launch_error"] = .string(error.localizedDescription)
        _ = try await store.upsertProject(copy(project: project, metadata: metadata))
    }

    private func clearScheduledLaunchFailure(
        for project: BurnBarReviewProjectSnapshot
    ) async throws {
        guard project.metadata["scheduler_last_launch_attempt_at"] != nil
            || project.metadata["scheduler_last_launch_error"] != nil else {
            return
        }

        var metadata = project.metadata
        metadata.removeValue(forKey: "scheduler_last_launch_attempt_at")
        metadata.removeValue(forKey: "scheduler_last_launch_error")
        _ = try await store.upsertProject(copy(project: project, metadata: metadata))
    }

    private func launchReviewRun(
        projectSlug: String,
        cadence: BurnBarControllerReviewCadence,
        origin: BurnBarControllerReviewRunOrigin,
        triggeredBy: String?,
        summary: String,
        metadata: BurnBarMetadata = [:]
    ) async throws -> BurnBarControllerReviewRunRecordResponse {
        guard let project = try await store.project(slug: projectSlug) else {
            throw BurnBarMissionControlError.projectNotFound(projectSlug)
        }

        let launchedRun: BurnBarRunCreateResponse?
        if let reviewRunLauncher {
            launchedRun = try await reviewRunLauncher(
                buildReviewPrompt(for: project, cadence: cadence),
                project.reviewModelID ?? "glm-5",
                BurnBarRunCreateMetadata(
                    metadata.merging([
                        "controller_project_slug": .string(projectSlug),
                        "controller_review_cadence": .string(cadence.rawValue),
                        "controller_review_origin": .string(origin.rawValue)
                    ]) { _, new in new }
                )
            )
        } else {
            launchedRun = nil
        }

        let run = BurnBarReviewRunSnapshot(
            id: "review-\(UUID().uuidString)",
            projectSlug: projectSlug,
            cadence: cadence,
            recordedAt: Date(),
            summary: summary,
            questionCount: try await store.questions(BurnBarQuestionsListRequest(projectSlug: projectSlug, statuses: [.pending])).count,
            followupCount: try await store.followups(BurnBarFollowupsListRequest(projectSlug: projectSlug, statuses: [.open, .snoozed])).count,
            missionCount: try await store.missions(BurnBarMissionListRequest(projectSlug: projectSlug)).count,
            origin: origin,
            triggeredBy: triggeredBy,
            launchedRunID: launchedRun?.runID,
            metadata: metadata
        )
        let (recordedRun, _) = try await store.recordReviewRun(run)
        let summarySnapshot = try await store.controllerSummary(BurnBarControllerSummaryRequest(projectSlug: projectSlug))
        return BurnBarControllerReviewRunRecordResponse(run: recordedRun, summary: summarySnapshot.summary)
    }


}
