import OpenBurnBarCore
import Foundation

public actor BurnBarMissionControlService {
    private let store: BurnBarMissionControlStore
    private let logger: BurnBarDaemonLogger
    private let transport: BurnBarMissionControlTransport
    private let activitySnapshotURL: URL?
    private let reviewRunLauncher: BurnBarMissionControlReviewRunLauncher?
    private let runSnapshotLookup: BurnBarMissionControlRunSnapshotLookup?
    private let usageLedgerURL: URL
    /// VAL-DAEMON-011: Execution readiness gate for pre-dispatch checks.
    /// When nil, dispatch proceeds without readiness checks (legacy behavior for tests).
    private let executionReadinessGate: BurnBarExecutionReadinessGate?

    /// Terminal mission statuses that block dispatch — must match MissionControlStore.terminalStatuses.
    private static let terminalMissionStatuses: Set<BurnBarMissionStatus> = [
        .completed, .failed, .cancelled
    ]
    private var notificationLoopTask: Task<Void, Never>?
    private var lastIngestedActivityDigest: String?

    public init(
        store: BurnBarMissionControlStore = BurnBarMissionControlStore(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "mission-control-service"),
        activitySnapshotURL: URL? = BurnBarDaemonPaths.defaultControllerActivitySnapshotURL,
        reviewRunLauncher: BurnBarMissionControlReviewRunLauncher? = nil,
        runSnapshotLookup: BurnBarMissionControlRunSnapshotLookup? = nil,
        usageLedgerURL: URL = BurnBarDaemonPaths.defaultUsageLedgerURL,
        executionReadinessGate: BurnBarExecutionReadinessGate? = nil
    ) {
        self.store = store
        self.logger = logger
        self.transport = .live()
        self.activitySnapshotURL = activitySnapshotURL
        self.reviewRunLauncher = reviewRunLauncher
        self.runSnapshotLookup = runSnapshotLookup
        self.usageLedgerURL = usageLedgerURL
        self.executionReadinessGate = executionReadinessGate
    }

    init(
        store: BurnBarMissionControlStore = BurnBarMissionControlStore(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "mission-control-service"),
        transport: BurnBarMissionControlTransport,
        activitySnapshotURL: URL? = nil,
        reviewRunLauncher: BurnBarMissionControlReviewRunLauncher? = nil,
        runSnapshotLookup: BurnBarMissionControlRunSnapshotLookup? = nil,
        usageLedgerURL: URL = BurnBarDaemonPaths.defaultUsageLedgerURL,
        executionReadinessGate: BurnBarExecutionReadinessGate? = nil
    ) {
        self.store = store
        self.logger = logger
        self.transport = transport
        self.activitySnapshotURL = activitySnapshotURL
        self.reviewRunLauncher = reviewRunLauncher
        self.runSnapshotLookup = runSnapshotLookup
        self.usageLedgerURL = usageLedgerURL
        self.executionReadinessGate = executionReadinessGate
    }

    public func startBackgroundLoops() {
        guard notificationLoopTask == nil else { return }
        notificationLoopTask = Task.detached(priority: .background) { [service = self, logger] in
            while !Task.isCancelled {
                do {
                    try await service.processTransportCycle(now: Date())
                } catch {
                    logger.error(
                        "mission_control_notification_loop_failed",
                        metadata: ["error": error.localizedDescription]
                    )
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    public func stopBackgroundLoops() {
        notificationLoopTask?.cancel()
        notificationLoopTask = nil
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
            let metadata = request.packet.metadata.merging([
                "missionExecution": .bool(true),
                "mission_id": .string(mission.id.rawValue),
                "mission_packet_id": .string(request.packet.id.rawValue),
                "project_slug": .string(mission.projectSlug)
            ]) { _, new in new }
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
        try await ingestControllerActivityIfNeeded(now: now)
        try await launchDueScheduledReviews(now: now)
        try await syncMissionExecution(now: now)
        let dueFollowups = try await store.evaluateDueNotifications(now: now)
        try await deliverDueFollowups(dueFollowups)
        try await pollTelegramCommands()
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
            guard let existingFingerprint = question.metadata["ingestion_fingerprint"]?.stringValue() else {
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
                _ = try await launchReviewRun(
                    projectSlug: project.projectSlug,
                    cadence: project.preferredCadence,
                    origin: .scheduled,
                    triggeredBy: "scheduler",
                    summary: "Scheduled \(project.preferredCadence.rawValue) review launched automatically."
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
                        metadata: [
                            "run_phase": .string(snapshot.phase.rawValue),
                            "model_id": .string(snapshot.modelID),
                            "provider_id": usage.map { .string($0.providerID) } ?? .string("unknown"),
                            "input_tokens": .number(Double(usage?.inputTokens ?? 0)),
                            "output_tokens": .number(Double(usage?.outputTokens ?? 0)),
                            "cache_read_tokens": .number(Double(usage?.cacheReadTokens ?? 0))
                        ]
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
                packet.metadata.merging([
                    "autoTakeover": .bool(true),
                    "missionExecution": .bool(true),
                    "mission_id": .string(currentMission.id.rawValue),
                    "mission_packet_id": .string(packet.id.rawValue),
                    "source_run_id": .string(sourceRunID.rawValue)
                ]) { _, new in new }
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

    private func missionPacketStatus(for phase: BurnBarRunPhase) -> BurnBarMissionPacketStatus {
        switch phase {
        case .idle, .planning:
            return .dispatched
        case .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    private func isTerminal(phase: BurnBarRunPhase) -> Bool {
        switch phase {
        case .completed, .failed, .cancelled:
            return true
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return false
        }
    }

    private func latestUsageEvent(for runID: BurnBarRunID) -> BurnBarUsageEvent? {
        guard FileManager.default.fileExists(atPath: usageLedgerURL.path),
              let content = try? String(contentsOf: usageLedgerURL, encoding: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        let lines = content.split(whereSeparator: \.isNewline)
        var matches: [BurnBarUsageEvent] = []
        matches.reserveCapacity(lines.count)

        for line in lines {
            guard line.isEmpty == false,
                  let record = try? decoder.decode(BurnBarUsageRecord.self, from: Data(line.utf8)),
                  record.event.runID == runID else {
                continue
            }
            matches.append(record.event)
        }

        return matches.sorted { $0.recordedAt > $1.recordedAt }.first
    }

    private func missionResultStatus(for phase: BurnBarRunPhase) -> BurnBarMissionResultStatus {
        switch phase {
        case .completed:
            return .succeeded
        case .failed, .cancelled:
            return .failed
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return .partial
        }
    }

    private func missionResultSummary(
        for packet: BurnBarMissionPacketSnapshot,
        snapshot: BurnBarRunStateSnapshot
    ) -> String {
        switch snapshot.phase {
        case .completed:
            return "\(packet.workerName) completed its mission packet."
        case .failed:
            return "\(packet.workerName) failed its mission packet."
        case .cancelled:
            return "\(packet.workerName) was cancelled before finishing."
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return "\(packet.workerName) reported a partial mission result."
        }
    }

    private func missionResultDetail(for snapshot: BurnBarRunStateSnapshot) -> String? {
        switch snapshot.phase {
        case .completed:
            return "Run \(snapshot.runID.rawValue) completed on \(snapshot.modelID)."
        case .failed:
            return snapshot.errorMessage?.nonEmpty ?? "Run \(snapshot.runID.rawValue) failed."
        case .cancelled:
            return snapshot.errorMessage?.nonEmpty ?? "Run \(snapshot.runID.rawValue) was cancelled."
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return snapshot.errorMessage?.nonEmpty
        }
    }

    private func autoTakeoverStatus(for phase: BurnBarRunPhase) -> BurnBarAutoTakeoverStatus {
        switch phase {
        case .completed:
            return .completed
        case .failed, .cancelled:
            return .failed
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return .launched
        }
    }

    private func shouldAutoTakeover(
        snapshot: BurnBarRunStateSnapshot,
        now: Date
    ) -> Bool {
        switch snapshot.phase {
        case .failed, .cancelled:
            return true
        case .awaitingApproval, .completed:
            return false
        case .idle, .planning, .executingTool, .waitingOnCompanion, .modelStreaming:
            return now.timeIntervalSince(snapshot.updatedAt) >= autoTakeoverStallThreshold(for: snapshot.phase)
        }
    }

    private func buildAutoTakeoverPrompt(
        mission: BurnBarMissionSnapshot,
        packet: BurnBarMissionPacketSnapshot,
        snapshot: BurnBarRunStateSnapshot
    ) -> String {
        let recoveryReason = autoTakeoverReason(for: snapshot, now: Date())
        return """
        OpenBurnBar auto-takeover for mission \(mission.title) in project \(mission.projectSlug).

        Original packet:
        - Worker: \(packet.workerName)
        - Objective: \(packet.objective)
        - Source run: \(snapshot.runID.rawValue)
        - Source phase: \(snapshot.phase.rawValue)
        - Last updated: \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
        - Recovery reason: \(snapshot.errorMessage?.nonEmpty ?? recoveryReason)

        Take over the work, recover the objective if possible, and return a concise operator-facing outcome with:
        1. what you completed
        2. what remains blocked
        3. the next recommended operator action
        """
    }

    private func autoTakeoverReason(
        for snapshot: BurnBarRunStateSnapshot,
        now: Date
    ) -> String {
        switch snapshot.phase {
        case .failed:
            return snapshot.errorMessage?.nonEmpty ?? "Source run failed."
        case .cancelled:
            return snapshot.errorMessage?.nonEmpty ?? "Source run was cancelled."
        case .idle, .planning, .executingTool, .waitingOnCompanion, .modelStreaming:
            let minutes = max(1, Int(now.timeIntervalSince(snapshot.updatedAt) / 60))
            return "Source run stalled in \(snapshot.phase.rawValue) for \(minutes)m."
        case .awaitingApproval:
            return "Source run is waiting on operator approval."
        case .completed:
            return "Source run already completed."
        }
    }

    private func missionExecutionModelID(
        for mission: BurnBarMissionSnapshot,
        packet: BurnBarMissionPacketSnapshot
    ) -> String {
        packet.metadata.stringValue(forKey: "model_id")
            ?? mission.metadata.stringValue(forKey: "model_id")
            ?? "glm-5"
    }

    private func buildMissionPacketPrompt(
        mission: BurnBarMissionSnapshot,
        packet: BurnBarMissionPacketSnapshot
    ) -> String {
        let approvalLine = mission.approval.approved
            ? "Approved by \(mission.approval.approvedBy ?? "operator")."
            : "Still awaiting explicit approval."
        let priorResults = mission.results
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(3)
            .map { "- \($0.summary)" }
            .joined(separator: "\n")
        let priorResultsBlock = priorResults.isEmpty ? "- None yet." : priorResults

        return """
        OpenBurnBar mission execution for project \(mission.projectSlug).

        Mission:
        - Title: \(mission.title)
        - Summary: \(mission.summary)
        - Recommendation: \(mission.recommendation.rawValue)
        - Approval: \(approvalLine)

        Packet:
        - Worker: \(packet.workerName)
        - Objective: \(packet.objective)

        Recent mission results:
        \(priorResultsBlock)

        Execute the packet objective directly. Return a concise completion note that states what changed, what evidence you used, and any remaining blockers.
        """
    }

    private func missionSnapshot(
        from mission: BurnBarMissionSnapshot,
        status: BurnBarMissionStatus,
        updatedAt: Date,
        packets: [BurnBarMissionPacketSnapshot],
        results: [BurnBarMissionResultSnapshot],
        burnRecords: [BurnBarMissionBurnRecord],
        takeoverHistory: [BurnBarAutoTakeoverRecord]?
    ) -> BurnBarMissionSnapshot {
        var metadata = mission.metadata
        let totalTokens = results.reduce(0) { partial, result in
            partial
                + intValue(result.metadata["input_tokens"])
                + intValue(result.metadata["output_tokens"])
                + intValue(result.metadata["cache_read_tokens"])
        }
        metadata["total_tokens"] = .number(Double(totalTokens))
        metadata["packet_count"] = .number(Double(packets.count))
        metadata["result_count"] = .number(Double(results.count))
        metadata["burn_record_count"] = .number(Double(burnRecords.count))
        if let latestPacket = packets.sorted(by: { ($0.dispatchedAt ?? .distantPast) > ($1.dispatchedAt ?? .distantPast) }).first,
           let runID = latestPacket.runID?.rawValue {
            metadata["latest_run_id"] = .string(runID)
        } else {
            metadata.removeValue(forKey: "latest_run_id")
        }
        if let latestTakeover = takeoverHistory?.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            metadata["latest_takeover_status"] = .string(latestTakeover.status.rawValue)
            if let runID = latestTakeover.takeoverRunID?.rawValue {
                metadata["latest_takeover_run_id"] = .string(runID)
            }
        } else {
            metadata.removeValue(forKey: "latest_takeover_status")
            metadata.removeValue(forKey: "latest_takeover_run_id")
        }

        return BurnBarMissionSnapshot(
            id: mission.id,
            projectSlug: mission.projectSlug,
            title: mission.title,
            summary: mission.summary,
            status: resolvedMissionStatus(
                preferredStatus: status,
                approval: mission.approval,
                packets: packets,
                results: results
            ),
            recommendation: mission.recommendation,
            createdAt: mission.createdAt,
            updatedAt: updatedAt,
            approval: mission.approval,
            packets: packets,
            results: results,
            burnRecords: burnRecords,
            takeoverHistory: takeoverHistory,
            metadata: metadata
        )
    }

    private func resolvedMissionStatus(
        preferredStatus: BurnBarMissionStatus,
        approval: BurnBarMissionApprovalSnapshot,
        packets: [BurnBarMissionPacketSnapshot],
        results: [BurnBarMissionResultSnapshot]
    ) -> BurnBarMissionStatus {
        if preferredStatus == .cancelled {
            return .cancelled
        }
        if approval.approved == false {
            return packets.isEmpty && results.isEmpty ? preferredStatus : .awaitingApproval
        }
        if packets.isEmpty {
            return results.isEmpty ? preferredStatus : statusFromTerminalResults(results)
        }

        if packets.contains(where: { $0.status == .running }) {
            return .inProgress
        }
        if packets.contains(where: { $0.status == .queued || $0.status == .dispatched }) {
            return .dispatching
        }

        let allPacketsTerminal = packets.allSatisfy { packet in
            [.completed, .failed, .cancelled].contains(packet.status)
        }
        guard allPacketsTerminal else {
            return preferredStatus
        }
        guard results.isEmpty == false else {
            return preferredStatus
        }

        return statusFromTerminalResults(results)
    }

    private func statusFromTerminalResults(
        _ results: [BurnBarMissionResultSnapshot]
    ) -> BurnBarMissionStatus {
        let statuses = Set(results.map(\.status))
        if statuses.isSubset(of: [.succeeded, .replayed]) {
            return .completed
        }
        if statuses == [.failed] {
            return .failed
        }
        return .partiallyCompleted
    }

    private func mergePackets(
        _ existing: [BurnBarMissionPacketSnapshot],
        _ appended: BurnBarMissionPacketSnapshot
    ) -> [BurnBarMissionPacketSnapshot] {
        var merged: [String: BurnBarMissionPacketSnapshot] = [:]
        for packet in existing {
            merged[packet.id.rawValue] = packet
        }
        merged[appended.id.rawValue] = appended
        return merged.values.sorted {
            ($0.dispatchedAt ?? .distantPast) < ($1.dispatchedAt ?? .distantPast)
        }
    }

    private func replacePacket(
        _ packet: BurnBarMissionPacketSnapshot,
        in packets: [BurnBarMissionPacketSnapshot]
    ) -> [BurnBarMissionPacketSnapshot] {
        var replaced = false
        let updated = packets.map { existing -> BurnBarMissionPacketSnapshot in
            guard existing.id == packet.id else { return existing }
            replaced = true
            return packet
        }
        return mergePackets(replaced ? updated : packets, packet)
    }

    private func replaceTakeoverRecord(
        _ record: BurnBarAutoTakeoverRecord,
        in history: [BurnBarAutoTakeoverRecord]?
    ) -> [BurnBarAutoTakeoverRecord] {
        let existing = history ?? []
        var replaced = false
        let updated = existing.map { current -> BurnBarAutoTakeoverRecord in
            guard current.id == record.id else { return current }
            replaced = true
            return record
        }
        let merged = replaced ? updated : (existing + [record])
        return merged.sorted { $0.createdAt < $1.createdAt }
    }

    private func autoTakeoverStallThreshold(for phase: BurnBarRunPhase) -> TimeInterval {
        switch phase {
        case .idle, .planning:
            return 5 * 60
        case .executingTool, .waitingOnCompanion, .modelStreaming:
            return 15 * 60
        case .awaitingApproval, .completed, .failed, .cancelled:
            return .infinity
        }
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
                metadata.merging([
                    "controller_project_slug": .string(projectSlug),
                    "controller_review_cadence": .string(cadence.rawValue),
                    "controller_review_origin": .string(origin.rawValue)
                ]) { _, new in new }
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

    private func normalizedQuestion(
        _ question: BurnBarPendingQuestionSnapshot
    ) -> BurnBarPendingQuestionSnapshot {
        let normalizedStage = question.stageLabel?.nonEmpty ?? inferredStageLabel(for: question.prompt)
        let normalizedOptions = question.suggestedOptions.isEmpty
            ? inferredQuestionOptions(for: question.prompt)
            : question.suggestedOptions
        let normalizedDeepLink = question.deepLink
            ?? question.sessionID.map {
                BurnBarQuestionDeepLinkSnapshot(
                    kind: .sessionLog,
                    targetID: $0.rawValue,
                    title: "Open related session log",
                    subtitle: question.title
                )
            }
            ?? BurnBarQuestionDeepLinkSnapshot(
                kind: .project,
                targetID: question.projectSlug,
                title: "Open project in dashboard",
                subtitle: question.projectSlug
            )
        let tracker = question.tracker ?? BurnBarQuestionTrackerSnapshot(
            isUnread: question.status == .pending,
            surfacedAt: question.askedAt
        )

        return BurnBarPendingQuestionSnapshot(
            id: question.id,
            projectSlug: question.projectSlug,
            sessionID: question.sessionID,
            title: question.title,
            prompt: question.prompt,
            stageLabel: normalizedStage,
            status: question.status,
            priority: question.priority,
            askedAt: question.askedAt,
            dueAt: question.dueAt,
            latestAnswer: question.latestAnswer,
            answerPlaceholder: question.answerPlaceholder?.nonEmpty ?? "Record the operator call OpenBurnBar should carry forward…",
            contextSummary: question.contextSummary,
            evidenceRefs: question.evidenceRefs,
            suggestedOptions: normalizedOptions,
            deepLink: normalizedDeepLink,
            tracker: tracker,
            metadata: question.metadata
        )
    }

    private func deliverNewQuestionNotificationsIfNeeded(
        _ question: BurnBarPendingQuestionSnapshot
    ) async throws {
        guard question.status == .pending else { return }
        let tracker = question.tracker ?? BurnBarQuestionTrackerSnapshot(isUnread: true, surfacedAt: question.askedAt)
        guard tracker.notificationCount == 0 else { return }

        let config = try await store.notificationConfig()
        let title = question.stageLabel?.nonEmpty.map { "\($0): \(question.title)" } ?? question.title
        let body = question.prompt
        var deliveredChannels: [BurnBarNotificationChannel] = []

        if config.local.isEnabled {
            do {
                try await transport.deliverLocalNotification("New OpenBurnBar question", "\(title)\n\(body)")
                deliveredChannels.append(.local)
                try await store.recordTransportError(channel: .local, error: nil)
            } catch {
                try await store.recordTransportError(channel: .local, error: error.localizedDescription)
            }
        }

        if config.telegram.isEnabled,
           let botToken = config.telegram.botToken?.nonEmpty,
           let chatID = config.telegram.chatID?.nonEmpty {
            do {
                let routeHint = question.deepLink?.title.nonEmpty.map { "\n\($0)" } ?? ""
                try await transport.sendTelegramMessage(
                    botToken,
                    chatID,
                    "[\(question.projectSlug.capitalized)] New question\n\(title)\n\(body)\(routeHint)"
                )
                deliveredChannels.append(.telegram)
                try await store.recordTransportError(channel: .telegram, error: nil)
            } catch {
                try await store.recordTransportError(channel: .telegram, error: error.localizedDescription)
            }
        }

        for channel in deliveredChannels {
            _ = try await store.recordQuestionNotification(questionID: question.id, channel: channel)
        }
    }

    private func inferredStageLabel(for prompt: String) -> String {
        let lowered = prompt.lowercased()
        if lowered.hasPrefix("should ")
            || lowered.contains("keep ")
            || lowered.contains("ship ")
            || lowered.contains("continue ") {
            return "Operator Decision"
        }
        if lowered.contains("why")
            || lowered.contains("what happened")
            || lowered.contains("investigate") {
            return "Clarify Signal"
        }
        if lowered.contains("when")
            || lowered.contains("follow up") {
            return "Plan Followup"
        }
        return "Need Operator Input"
    }

    private func inferredQuestionOptions(for prompt: String) -> [BurnBarQuestionOptionSnapshot] {
        let lowered = prompt.lowercased()
        if lowered.hasPrefix("should ")
            || lowered.contains("keep ")
            || lowered.contains("ship ")
            || lowered.contains("continue ") {
            return [
                BurnBarQuestionOptionSnapshot(
                    id: "proceed",
                    title: "Proceed",
                    detail: "Keep the current direction moving.",
                    answer: "Proceed with the current plan."
                ),
                BurnBarQuestionOptionSnapshot(
                    id: "pause_and_reset",
                    title: "Pause + Reset",
                    detail: "Change direction before continuing.",
                    answer: "Pause the current plan and reset direction before continuing."
                )
            ]
        }
        return []
    }

    private func inferredQuestionDeepLink(
        for activityProject: BurnBarControllerActivityProject
    ) -> BurnBarQuestionDeepLinkSnapshot? {
        if let sessionID = activityProject.latestConversationSessionID?.rawValue {
            return BurnBarQuestionDeepLinkSnapshot(
                kind: .sessionLog,
                targetID: sessionID,
                title: "Open related session log",
                subtitle: activityProject.latestConversationTitle
            )
        }
        return BurnBarQuestionDeepLinkSnapshot(
            kind: .project,
            targetID: activityProject.projectSlug,
            title: "Open project in dashboard",
            subtitle: activityProject.displayName
        )
    }

    private func buildReviewPrompt(
        for project: BurnBarReviewProjectSnapshot,
        cadence: BurnBarControllerReviewCadence
    ) -> String {
        let latestTitle = project.metadata["latest_conversation_title"]?.stringValue() ?? "No titled checkpoint yet"
        let latestSummary = project.metadata["latest_conversation_summary"]?.stringValue() ?? project.summary
        let sessions = project.metadata["session_count_last_7d"]?.numberValue().map { Int($0) } ?? 0
        let totalCost = project.metadata["total_cost_last_7d"]?.numberValue() ?? 0
        let totalTokens = project.metadata["total_tokens_last_7d"]?.numberValue().map { Int($0) } ?? 0

        return """
        OpenBurnBar \(cadence.rawValue) review for project \(project.displayName) (\(project.projectSlug)).

        Latest checkpoint:
        - Title: \(latestTitle)
        - Summary: \(latestSummary)

        Recent activity:
        - Sessions in the last 7 days: \(sessions)
        - Burn in the last 7 days: \(String(format: "%.2f", totalCost)) USD
        - Tokens in the last 7 days: \(totalTokens)

        Produce a concise operator review covering current state, the biggest risk, any open questions, and the next recommended step.
        """
    }

    private func copy(
        project: BurnBarReviewProjectSnapshot,
        metadata: BurnBarMetadata
    ) -> BurnBarReviewProjectSnapshot {
        BurnBarReviewProjectSnapshot(
            id: project.id,
            projectSlug: project.projectSlug,
            displayName: project.displayName,
            summary: project.summary,
            status: project.status,
            preferredCadence: project.preferredCadence,
            aliases: project.aliases,
            automationMode: project.automationMode,
            reviewModelID: project.reviewModelID,
            scheduleHourLocal: project.scheduleHourLocal,
            scheduleWeekdayLocal: project.scheduleWeekdayLocal,
            freshness: project.freshness,
            latestDailyReviewAt: project.latestDailyReviewAt,
            latestWeeklyReviewAt: project.latestWeeklyReviewAt,
            nextScheduledReviewAt: project.nextScheduledReviewAt,
            pendingQuestionCount: project.pendingQuestionCount,
            openFollowupCount: project.openFollowupCount,
            activeMissionCount: project.activeMissionCount,
            activeMissionID: project.activeMissionID,
            needsOperatorAttention: project.needsOperatorAttention,
            ingestionSource: project.ingestionSource,
            metadata: metadata
        )
    }

    private func defaultCadence(
        for project: BurnBarControllerActivityProject
    ) -> BurnBarControllerReviewCadence {
        if project.sessionCountLast7Days >= 5 || project.totalCostLast7Days >= 5 {
            return .daily
        }
        return .weekly
    }

    private func questionPriority(for prompt: String) -> BurnBarPendingQuestionPriority {
        let lowered = prompt.lowercased()
        if lowered.contains("blocked")
            || lowered.contains("stuck")
            || lowered.contains("error")
            || lowered.contains("fail") {
            return .high
        }
        return .medium
    }

    private func metadataDate(
        _ key: String,
        in metadata: BurnBarMetadata
    ) -> Date? {
        guard let rawValue = metadata[key]?.stringValue() else {
            return nil
        }
        return ISO8601DateFormatter().date(from: rawValue)
    }

    private func deliverDueFollowups(_ followups: [BurnBarFollowupSnapshot]) async throws {
        guard followups.isEmpty == false else { return }
        let config = try await store.notificationConfig()

        if config.local.isEnabled {
            do {
                for followup in followups {
                    try await transport.deliverLocalNotification(
                        "OpenBurnBar followup due",
                        "\(followup.title)\n\(followup.summary)"
                    )
                }
                try await store.recordTransportError(channel: .local, error: nil)
            } catch {
                try await store.recordTransportError(channel: .local, error: error.localizedDescription)
                throw error
            }
        }

        guard config.telegram.isEnabled,
              let botToken = config.telegram.botToken?.nonEmpty,
              let chatID = config.telegram.chatID?.nonEmpty else {
            return
        }

        do {
            for followup in followups {
                let project = followup.projectSlug.capitalized
                let message = "[\(project)] Followup due\n\(followup.title)\n\(followup.summary)"
                try await transport.sendTelegramMessage(botToken, chatID, message)
            }
            try await store.recordTransportError(channel: .telegram, error: nil)
        } catch {
            try await store.recordTransportError(channel: .telegram, error: error.localizedDescription)
            throw error
        }
    }

    private func pollTelegramCommands() async throws {
        let config = try await store.notificationConfig()
        guard config.telegram.isEnabled,
              let botToken = config.telegram.botToken?.nonEmpty,
              let configuredChatID = config.telegram.chatID?.nonEmpty else {
            return
        }

        do {
            let updates = try await transport.fetchTelegramUpdates(botToken, try await store.telegramUpdateOffset())
            guard updates.isEmpty == false else { return }

            for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
                try await store.setTelegramUpdateOffset(update.updateID + 1)
                guard update.chatID == configuredChatID,
                      let request = parseTelegramCommand(text: update.text, actor: "telegram") else {
                    continue
                }
                let response = try await notificationCommand(request)
                try await transport.sendTelegramMessage(botToken, configuredChatID, response.message)
            }
            try await store.recordTransportError(channel: .telegram, error: nil)
        } catch {
            try await store.recordTransportError(channel: .telegram, error: error.localizedDescription)
            throw error
        }
    }

    private func parseTelegramCommand(text: String, actor: String) -> BurnBarNotificationCommandRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let parts = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let rawCommand = parts.first else { return nil }

        let normalized = rawCommand
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        let command: BurnBarTelegramCommand?
        switch normalized {
        case "daily": command = .runDaily
        case "weekly": command = .runWeekly
        default: command = BurnBarTelegramCommand(rawValue: normalized)
        }

        guard let command else { return nil }
        return BurnBarNotificationCommandRequest(
            command: command,
            arguments: Array(parts.dropFirst()),
            actor: actor
        )
    }

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

private extension BurnBarJSONValue {
    func boolValue() -> Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    func stringValue() -> String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    func numberValue() -> Double? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }
}

private extension Dictionary where Key == String, Value == BurnBarJSONValue {
    func stringValue(forKey key: String) -> String? {
        self[key]?.stringValue()
    }
}

