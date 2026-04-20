import OpenBurnBarCore
import Foundation

public actor BurnBarMissionControlStore {
    private let eventsFileURL: URL
    private let projectionFileURL: URL
    private let logger: BurnBarDaemonLogger
    private let journal: MissionControlJournalRepository
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var projection: BurnBarMissionControlProjectionFile?
    private var cachedEvents: [BurnBarControllerEvent]?
    private var seenEventIDs: Set<String> = []

    private var summaryEnricher: MissionControlSummaryEnricher {
        MissionControlSummaryEnricher(projection: projection, cachedEvents: cachedEvents)
    }

    public init(
        eventsFileURL: URL = BurnBarDaemonPaths.defaultControllerEventJournalURL,
        projectionFileURL: URL = BurnBarDaemonPaths.defaultControllerProjectionURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "mission-control-store")
    ) {
        self.eventsFileURL = eventsFileURL
        self.projectionFileURL = projectionFileURL
        self.logger = logger
        self.journal = MissionControlJournalRepository(
            eventsFileURL: eventsFileURL,
            projectionFileURL: projectionFileURL,
            logger: logger
        )
        encoder.outputFormatting = [.sortedKeys]
    }

    public func controllerSummary(_ request: BurnBarControllerSummaryRequest) throws -> BurnBarControllerSummaryResponse {
        try ensureLoaded()
        return BurnBarControllerSummaryResponse(summary: summaryEnricher.makeSummary(for: request))
    }

    public func project(slug: String) throws -> BurnBarReviewProjectSnapshot? {
        try ensureLoaded()
        return summaryEnricher.enrichedProjects()
            .first(where: { $0.projectSlug == slug })
    }

    public func projects(_ request: BurnBarControllerProjectsListRequest) throws -> [BurnBarReviewProjectSnapshot] {
        try ensureLoaded()
        return summaryEnricher.enrichedProjects()
            .filter { request.includePaused || $0.status != .paused }
            .prefix(request.limit)
            .map { $0 }
    }

    public func upsertProject(_ project: BurnBarReviewProjectSnapshot) throws -> (BurnBarReviewProjectSnapshot, BurnBarControllerEvent) {
        let event = try appendEvent(
            family: .controller,
            eventType: "project_upserted",
            projectSlug: project.projectSlug,
            summary: project.displayName,
            detail: project.summary,
            payload: try BurnBarJSONValue.fromEncodable(project)
        )
        return (try projectValue(project.projectSlug), event)
    }

    public func recordReviewRun(_ run: BurnBarReviewRunSnapshot) throws -> (BurnBarReviewRunSnapshot, BurnBarControllerEvent) {
        let event = try appendEvent(
            family: .controller,
            eventType: "review_run_recorded",
            projectSlug: run.projectSlug,
            summary: run.summary,
            detail: "\(run.cadence.rawValue) review",
            payload: try BurnBarJSONValue.fromEncodable(run)
        )
        return (try reviewRunValue(run.id), event)
    }

    public func question(id: BurnBarQuestionID) throws -> BurnBarPendingQuestionSnapshot? {
        try ensureLoaded()
        return projection?.questions[id.rawValue]
    }

    public func questions(_ request: BurnBarQuestionsListRequest) throws -> [BurnBarPendingQuestionSnapshot] {
        try ensureLoaded()
        return projection?.questions.values
            .filter { item in
                (request.projectSlug == nil || item.projectSlug == request.projectSlug)
                    && request.statuses.contains(item.status)
            }
            .sorted { $0.askedAt > $1.askedAt }
            .prefix(request.limit)
            .map { $0 } ?? []
    }

    public func createQuestion(_ question: BurnBarPendingQuestionSnapshot) throws -> (BurnBarPendingQuestionSnapshot, BurnBarControllerEvent) {
        let event = try appendEvent(
            family: .question,
            eventType: "question_created",
            projectSlug: question.projectSlug,
            summary: question.title,
            detail: question.prompt,
            payload: try BurnBarJSONValue.fromEncodable(question)
        )

        if followupForQuestion(question.id) == nil {
            let followup = BurnBarFollowupSnapshot(
                id: BurnBarFollowupID(rawValue: "followup-\(question.id.rawValue)"),
                projectSlug: question.projectSlug,
                questionID: question.id,
                title: question.title,
                summary: question.contextSummary ?? question.prompt,
                stageLabel: question.stageLabel,
                status: .open,
                kind: .pendingQuestion,
                createdAt: question.askedAt,
                nextNudgeAt: question.dueAt ?? Calendar.current.date(byAdding: .hour, value: 2, to: question.askedAt),
                deepLink: question.deepLink,
                metadata: question.metadata
            )
            _ = try appendEvent(
                family: .followup,
                eventType: "followup_created",
                projectSlug: followup.projectSlug,
                summary: followup.title,
                detail: followup.summary,
                payload: try BurnBarJSONValue.fromEncodable(followup)
            )
        }

        return (try questionValue(question.id), event)
    }

    public func answerQuestion(_ request: BurnBarQuestionAnswerRequest) throws -> BurnBarQuestionAnswerResponse {
        guard let existing = try question(id: request.questionID) else {
            throw BurnBarMissionControlError.questionNotFound(request.questionID)
        }

        let answeredAt = Date()
        let answer = BurnBarAnswerRecord(
            answeredAt: answeredAt,
            answeredBy: request.answeredBy,
            answer: request.answer,
            selectedOptionID: request.selectedOptionID,
            metadata: request.metadata
        )
        let updatedTracker = existing.tracker.map {
            BurnBarQuestionTrackerSnapshot(
                isUnread: false,
                surfacedAt: $0.surfacedAt ?? existing.askedAt,
                firstNotifiedAt: $0.firstNotifiedAt,
                lastNotifiedAt: $0.lastNotifiedAt,
                notificationCount: $0.notificationCount,
                metadata: $0.metadata
            )
        }
        let updated = BurnBarPendingQuestionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            sessionID: existing.sessionID,
            title: existing.title,
            prompt: existing.prompt,
            stageLabel: existing.stageLabel,
            status: .answered,
            priority: existing.priority,
            askedAt: existing.askedAt,
            dueAt: existing.dueAt,
            latestAnswer: answer,
            answerPlaceholder: existing.answerPlaceholder,
            contextSummary: existing.contextSummary,
            evidenceRefs: existing.evidenceRefs,
            suggestedOptions: existing.suggestedOptions,
            deepLink: existing.deepLink,
            tracker: updatedTracker,
            metadata: existing.metadata.merging(request.metadata) { _, new in new }
        )

        let event = try appendEvent(
            family: .question,
            eventType: "question_answered",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: request.answer,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        var resolvedFollowup: BurnBarFollowupSnapshot?
        if request.markFollowupDone, let followup = followupForQuestion(request.questionID) {
            resolvedFollowup = try markFollowupDone(
                BurnBarFollowupDoneRequest(
                    followupID: followup.id,
                    actor: request.answeredBy,
                    note: "Resolved when question \(request.questionID.rawValue) was answered."
                )
            ).followup
        }

        return BurnBarQuestionAnswerResponse(
            question: try questionValue(request.questionID),
            followup: resolvedFollowup,
            emittedEvent: event
        )
    }

    public func recordQuestionNotification(
        questionID: BurnBarQuestionID,
        channel: BurnBarNotificationChannel,
        notifiedAt: Date = Date()
    ) throws -> (BurnBarPendingQuestionSnapshot, BurnBarControllerEvent) {
        guard let existing = try question(id: questionID) else {
            throw BurnBarMissionControlError.questionNotFound(questionID)
        }

        let currentTracker = existing.tracker ?? BurnBarQuestionTrackerSnapshot(
            isUnread: true,
            surfacedAt: existing.askedAt
        )
        let updatedTracker = BurnBarQuestionTrackerSnapshot(
            isUnread: true,
            surfacedAt: currentTracker.surfacedAt ?? existing.askedAt,
            firstNotifiedAt: currentTracker.firstNotifiedAt ?? notifiedAt,
            lastNotifiedAt: notifiedAt,
            notificationCount: currentTracker.notificationCount + 1,
            metadata: currentTracker.metadata.merging([
                "last_channel": .string(channel.rawValue)
            ]) { _, new in new }
        )
        let updated = BurnBarPendingQuestionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            sessionID: existing.sessionID,
            title: existing.title,
            prompt: existing.prompt,
            stageLabel: existing.stageLabel,
            status: existing.status,
            priority: existing.priority,
            askedAt: existing.askedAt,
            dueAt: existing.dueAt,
            latestAnswer: existing.latestAnswer,
            answerPlaceholder: existing.answerPlaceholder,
            contextSummary: existing.contextSummary,
            evidenceRefs: existing.evidenceRefs,
            suggestedOptions: existing.suggestedOptions,
            deepLink: existing.deepLink,
            tracker: updatedTracker,
            metadata: existing.metadata
        )

        let event = try appendEvent(
            family: .question,
            eventType: "question_notified",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: "Delivered over \(channel.rawValue).",
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )
        return (try questionValue(questionID), event)
    }

    public func followups(_ request: BurnBarFollowupsListRequest) throws -> [BurnBarFollowupSnapshot] {
        try ensureLoaded()
        return projection?.followups.values
            .filter { item in
                (request.projectSlug == nil || item.projectSlug == request.projectSlug)
                    && request.statuses.contains(item.status)
            }
            .sorted { ($0.nextNudgeAt ?? $0.createdAt) < ($1.nextNudgeAt ?? $1.createdAt) }
            .prefix(request.limit)
            .map { $0 } ?? []
    }

    public func createFollowup(_ request: BurnBarFollowupCreateRequest) throws -> BurnBarFollowupMutationResponse {
        let event = try appendEvent(
            family: .followup,
            eventType: "followup_created",
            projectSlug: request.followup.projectSlug,
            summary: request.followup.title,
            detail: request.followup.summary,
            payload: try BurnBarJSONValue.fromEncodable(request.followup)
        )
        return BurnBarFollowupMutationResponse(
            followup: try followupValue(request.followup.id),
            emittedEvent: event
        )
    }

    public func markFollowupDone(_ request: BurnBarFollowupDoneRequest) throws -> BurnBarFollowupMutationResponse {
        guard let existing = followup(id: request.followupID) else {
            throw BurnBarMissionControlError.followupNotFound(request.followupID)
        }

        let updated = BurnBarFollowupSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            questionID: existing.questionID,
            title: existing.title,
            summary: request.note?.nonEmpty ?? existing.summary,
            stageLabel: existing.stageLabel,
            status: .done,
            kind: existing.kind,
            createdAt: existing.createdAt,
            nextNudgeAt: existing.nextNudgeAt,
            snoozeUntil: nil,
            calendarEntry: existing.calendarEntry,
            deepLink: existing.deepLink,
            metadata: existing.metadata.merging(["completed_by": .string(request.actor)]) { _, new in new }
        )

        let event = try appendEvent(
            family: .followup,
            eventType: "followup_done",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: updated.summary,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarFollowupMutationResponse(
            followup: try followupValue(updated.id),
            emittedEvent: event
        )
    }

    public func snoozeFollowup(_ request: BurnBarFollowupSnoozeRequest) throws -> BurnBarFollowupMutationResponse {
        guard let existing = followup(id: request.followupID) else {
            throw BurnBarMissionControlError.followupNotFound(request.followupID)
        }

        let updated = BurnBarFollowupSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            questionID: existing.questionID,
            title: existing.title,
            summary: request.note?.nonEmpty ?? existing.summary,
            stageLabel: existing.stageLabel,
            status: .snoozed,
            kind: existing.kind,
            createdAt: existing.createdAt,
            nextNudgeAt: existing.nextNudgeAt,
            snoozeUntil: request.snoozeUntil,
            calendarEntry: existing.calendarEntry,
            deepLink: existing.deepLink,
            metadata: existing.metadata.merging(["snoozed_by": .string(request.actor)]) { _, new in new }
        )

        let event = try appendEvent(
            family: .followup,
            eventType: "followup_snoozed",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: "Snoozed until \(request.snoozeUntil.formatted(date: .abbreviated, time: .shortened)).",
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarFollowupMutationResponse(
            followup: try followupValue(updated.id),
            emittedEvent: event
        )
    }

    public func scheduleFollowupCalendar(_ request: BurnBarFollowupCalendarRequest) throws -> BurnBarFollowupMutationResponse {
        guard let existing = followup(id: request.followupID) else {
            throw BurnBarMissionControlError.followupNotFound(request.followupID)
        }

        let calendarEntry: BurnBarCalendarEntrySnapshot?
        switch request.action {
        case .create, .update:
            calendarEntry = request.entry
        case .remove:
            calendarEntry = nil
        }

        let updated = BurnBarFollowupSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            questionID: existing.questionID,
            title: existing.title,
            summary: existing.summary,
            stageLabel: existing.stageLabel,
            status: existing.status == .done ? .done : .open,
            kind: existing.kind,
            createdAt: existing.createdAt,
            nextNudgeAt: existing.nextNudgeAt,
            snoozeUntil: existing.snoozeUntil,
            calendarEntry: calendarEntry,
            deepLink: existing.deepLink,
            metadata: existing.metadata.merging(["calendar_actor": .string(request.actor)]) { _, new in new }
        )

        let event = try appendEvent(
            family: .followup,
            eventType: "followup_calendar_\(request.action.rawValue)",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: request.entry.title,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarFollowupMutationResponse(
            followup: try followupValue(updated.id),
            emittedEvent: event
        )
    }

    public func mission(id: BurnBarMissionID) throws -> BurnBarMissionSnapshot? {
        try ensureLoaded()
        return projection?.missions[id.rawValue]
    }

    public func missions(_ request: BurnBarMissionListRequest) throws -> [BurnBarMissionSnapshot] {
        try ensureLoaded()
        return projection?.missions.values
            .filter { item in
                (request.projectSlug == nil || item.projectSlug == request.projectSlug)
                    && request.statuses.contains(item.status)
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                // Tie-break: missionID ascending (lexicographic)
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .prefix(request.limit)
            .map { $0 } ?? []
    }

    public func createMission(_ request: BurnBarMissionCreateRequest) throws -> BurnBarMissionMutationResponse {
        let now = Date()
        let mission = BurnBarMissionSnapshot(
            id: BurnBarMissionID(rawValue: "mission-\(UUID().uuidString)"),
            projectSlug: request.projectSlug,
            title: request.title,
            summary: request.summary,
            status: .awaitingApproval,
            recommendation: request.recommendation,
            createdAt: now,
            updatedAt: now,
            approval: BurnBarMissionApprovalSnapshot(
                approved: false,
                approvedAt: nil,
                approvedBy: nil,
                note: nil
            ),
            takeoverHistory: nil,
            metadata: request.metadata.merging(["created_by": .string(request.createdBy)]) { _, new in new }
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_created",
            projectSlug: mission.projectSlug,
            summary: mission.title,
            detail: mission.summary,
            payload: try BurnBarJSONValue.fromEncodable(mission)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(mission.id),
            emittedEvent: event
        )
    }

    public func approveMission(_ request: BurnBarMissionApproveRequest) throws -> BurnBarMissionMutationResponse {
        guard let existing = try mission(id: request.missionID) else {
            throw BurnBarMissionControlError.missionNotFound(request.missionID)
        }

        let now = Date()
        let updated = BurnBarMissionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            title: existing.title,
            summary: existing.summary,
            status: existing.status == .cancelled ? .cancelled : .approved,
            recommendation: existing.recommendation,
            createdAt: existing.createdAt,
            updatedAt: now,
            approval: BurnBarMissionApprovalSnapshot(
                approved: true,
                approvedAt: now,
                approvedBy: request.actor,
                note: request.note
            ),
            packets: existing.packets,
            results: existing.results,
            burnRecords: existing.burnRecords,
            takeoverHistory: existing.takeoverHistory,
            metadata: existing.metadata
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_approved",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: request.note,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(updated.id),
            emittedEvent: event
        )
    }

    /// Terminal mission statuses that block dispatch.
    private static let terminalStatuses: Set<BurnBarMissionStatus> = [
        .completed, .failed, .cancelled
    ]

    public func missionCancel(_ request: BurnBarMissionCancelRequest) throws -> BurnBarMissionMutationResponse {
        guard let existing = try mission(id: request.missionID) else {
            throw BurnBarMissionControlError.missionNotFound(request.missionID)
        }

        let now = Date()
        let updated = BurnBarMissionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            title: existing.title,
            summary: existing.summary,
            status: .cancelled,
            recommendation: existing.recommendation,
            createdAt: existing.createdAt,
            updatedAt: now,
            approval: existing.approval,
            packets: existing.packets,
            results: existing.results,
            burnRecords: existing.burnRecords,
            takeoverHistory: existing.takeoverHistory,
            metadata: existing.metadata.merging(["cancelled_by": .string(request.actor)]) { _, new in new }
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_cancelled",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: request.note,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(updated.id),
            emittedEvent: event
        )
    }

    public func dispatchMissionPacket(_ request: BurnBarMissionDispatchPacketRequest) throws -> BurnBarMissionMutationResponse {
        guard let existing = try mission(id: request.missionID) else {
            throw BurnBarMissionControlError.missionNotFound(request.missionID)
        }

        // VAL-DAEMON-009: Dispatch is approval-gated and terminal-safe
        // Block dispatch if mission is not approved
        guard existing.approval.approved else {
            throw BurnBarMissionControlError.missionNotApproved(request.missionID)
        }

        // Block dispatch if mission is in a terminal state
        guard !Self.terminalStatuses.contains(existing.status) else {
            throw BurnBarMissionControlError.missionTerminal(request.missionID, existing.status)
        }

        let packet = BurnBarMissionPacketSnapshot(
            id: request.packet.id,
            missionID: existing.id,
            workerName: request.packet.workerName,
            objective: request.packet.objective,
            status: request.packet.status,
            runID: request.packet.runID,
            dispatchedAt: request.packet.dispatchedAt ?? Date(),
            completedAt: request.packet.completedAt,
            metadata: request.packet.metadata.merging(["actor": .string(request.actor)]) { _, new in new }
        )
        let packets = MissionControlMissionStateMerger.mergePackets(existing.packets, packet)
        let updated = BurnBarMissionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            title: existing.title,
            summary: existing.summary,
            status: packet.status == .completed ? .inProgress : .dispatching,
            recommendation: existing.recommendation,
            createdAt: existing.createdAt,
            updatedAt: packet.dispatchedAt ?? Date(),
            approval: existing.approval,
            packets: packets,
            results: existing.results,
            burnRecords: existing.burnRecords,
            takeoverHistory: existing.takeoverHistory,
            metadata: existing.metadata
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_packet_dispatched",
            projectSlug: updated.projectSlug,
            summary: packet.workerName,
            detail: packet.objective,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(updated.id),
            emittedEvent: event
        )
    }

    public func recordMissionResult(_ request: BurnBarMissionRecordResultRequest, existingMission: BurnBarMissionSnapshot? = nil) throws -> BurnBarMissionMutationResponse {
        let existing: BurnBarMissionSnapshot
        if let provided = existingMission {
            existing = provided
        } else {
            guard let fetched = try mission(id: request.missionID) else {
                throw BurnBarMissionControlError.missionNotFound(request.missionID)
            }
            existing = fetched
        }

        let result = BurnBarMissionResultSnapshot(
            id: request.result.id,
            missionID: existing.id,
            packetID: request.result.packetID,
            runID: request.result.runID,
            status: request.result.status,
            summary: request.result.summary,
            detail: request.result.detail,
            burnDelta: request.result.burnDelta,
            createdAt: request.result.createdAt,
            evidenceRefs: request.result.evidenceRefs,
            metadata: request.result.metadata
        )
        let burnRecord = BurnBarMissionBurnRecord(
            id: "burn-\(result.id.rawValue)",
            label: result.summary,
            amount: result.burnDelta,
            unit: "points",
            recordedAt: result.createdAt
        )
        let mergedResults = MissionControlMissionStateMerger.mergeResults(existing.results, result)
        let mergedBurnRecords = MissionControlMissionStateMerger.mergeBurnRecords(existing.burnRecords, burnRecord)
        var metadata = existing.metadata
        let totalTokens = mergedResults.reduce(0) { partial, result in
            partial
                + intValue(result.metadata["input_tokens"])
                + intValue(result.metadata["output_tokens"])
                + intValue(result.metadata["cache_read_tokens"])
        }
        metadata["total_tokens"] = .number(Double(totalTokens))
        metadata["result_count"] = .number(Double(mergedResults.count))
        metadata["burn_record_count"] = .number(Double(mergedBurnRecords.count))
        let updated = BurnBarMissionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            title: existing.title,
            summary: existing.summary,
            status: MissionControlMissionStateMerger.missionStatus(for: result.status),
            recommendation: existing.recommendation,
            createdAt: existing.createdAt,
            updatedAt: result.createdAt,
            approval: existing.approval,
            packets: existing.packets,
            results: mergedResults,
            burnRecords: mergedBurnRecords,
            takeoverHistory: existing.takeoverHistory,
            metadata: metadata
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_result_recorded",
            projectSlug: updated.projectSlug,
            summary: result.summary,
            detail: result.detail,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(updated.id),
            emittedEvent: event
        )
    }

    public func persistMissionSnapshot(
        _ mission: BurnBarMissionSnapshot,
        eventType: String,
        summary: String,
        detail: String? = nil
    ) throws -> BurnBarMissionMutationResponse {
        let event = try appendEvent(
            family: .mission,
            eventType: eventType,
            projectSlug: mission.projectSlug,
            summary: summary,
            detail: detail,
            payload: try BurnBarJSONValue.fromEncodable(mission)
        )
        return BurnBarMissionMutationResponse(
            mission: try missionValue(mission.id),
            emittedEvent: event
        )
    }

    public func notificationConfig() throws -> BurnBarNotificationConfig {
        try ensureLoaded()
        return projection?.notificationConfig ?? BurnBarMissionControlProjectionFile.defaultNotificationConfig()
    }

    public func telegramUpdateOffset() throws -> Int? {
        try ensureLoaded()
        return projection?.telegramUpdateOffset
    }

    public func setTelegramUpdateOffset(_ offset: Int?) throws {
        try ensureLoaded()
        projection?.telegramUpdateOffset = offset
        try writeProjection()
    }

    public func recordTransportError(channel: BurnBarNotificationChannel, error: String?) throws {
        try ensureLoaded()
        if let error, error.isEmpty == false {
            projection?.transportErrors[channel.rawValue] = error
        } else {
            projection?.transportErrors.removeValue(forKey: channel.rawValue)
        }
        try writeProjection()
    }

    public func transportError(for channel: BurnBarNotificationChannel) throws -> String? {
        try ensureLoaded()
        return projection?.transportErrors[channel.rawValue]
    }

    /// Persists a notification command audit event. Interactive routing for commands is implemented in
    /// `MissionControlService.notificationCommand` (async; launches review runs, records via this hook).
    public func recordNotificationCommand(
        _ request: BurnBarNotificationCommandRequest,
        responseSummary: String,
        projectSlug: String
    ) throws {
        _ = try appendEvent(
            family: .notification,
            eventType: "notification_command_\(request.command.rawValue)",
            projectSlug: projectSlug,
            summary: responseSummary,
            detail: nil,
            payload: try BurnBarJSONValue.fromEncodable(request)
        )
    }

    public func updateNotificationConfig(_ request: BurnBarNotificationConfigUpdateRequest) throws -> BurnBarNotificationConfigResponse {
        let event = try appendEvent(
            family: .notification,
            eventType: "notification_config_updated",
            projectSlug: "openburnbar",
            summary: "Notification configuration updated",
            detail: nil,
            payload: try BurnBarJSONValue.fromEncodable(request.config)
        )
        _ = event
        return BurnBarNotificationConfigResponse(config: try notificationConfig())
    }

    public func notificationHealth() throws -> BurnBarNotificationHealthResponse {
        try ensureLoaded()
        return BurnBarNotificationHealthResponse(health: summaryEnricher.makeNotificationHealth())
    }

    public func recordSimulatorRun(_ request: BurnBarSimulatorRunRequest) throws -> BurnBarSimulatorRunResponse {
        let now = Date()
        let emittedEvents = request.injectedEvents.isEmpty
            ? try MissionControlSummaryEnricher.defaultSimulatorEvents(for: request, now: now)
            : request.injectedEvents
        let status = summaryEnricher.projectionStatusArray(sortedBySequence: projection?.lastSequence ?? 0, recordedAt: now)
        let run = BurnBarSimulatorRunSnapshot(
            id: BurnBarSimulatorRunID(rawValue: "simulator-\(UUID().uuidString)"),
            projectSlug: request.projectSlug,
            scenarioName: request.scenarioName,
            status: .queued,
            seed: request.seed,
            startedAt: now,
            completedAt: nil,
            emittedEvents: emittedEvents,
            projectionStatus: status,
            summary: "Prepared \(emittedEvents.count) replayable controller event\(emittedEvents.count == 1 ? "" : "s")."
        )

        _ = try appendEvent(
            family: .simulator,
            eventType: "simulator_run_recorded",
            projectSlug: run.projectSlug,
            summary: run.scenarioName,
            detail: run.summary,
            payload: try BurnBarJSONValue.fromEncodable(run)
        )

        return BurnBarSimulatorRunResponse(run: try simulatorRunValue(run.id))
    }

    public func simulatorRuns(_ request: BurnBarSimulatorListRequest) throws -> BurnBarSimulatorListResponse {
        try ensureLoaded()
        let runs = projection?.simulatorRuns.values
            .filter { request.projectSlug == nil || $0.projectSlug == request.projectSlug }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(request.limit)
            .map { $0 } ?? []
        return BurnBarSimulatorListResponse(runs: runs)
    }

    public func replaySimulator(_ request: BurnBarSimulatorReplayRequest) throws -> BurnBarSimulatorRunResponse {
        guard let existing = simulatorRun(id: request.runID) else {
            throw BurnBarMissionControlError.simulatorRunNotFound(request.runID)
        }

        for event in existing.emittedEvents {
            let payload = event.metadata["payload"]
            _ = try appendEvent(
                family: event.family,
                eventType: event.eventType,
                projectSlug: event.projectSlug,
                summary: event.summary,
                detail: event.detail,
                payload: payload,
                isReplay: true
            )
        }

        let completedAt = Date()
        let updated = BurnBarSimulatorRunSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            scenarioName: existing.scenarioName,
            status: .completed,
            seed: existing.seed,
            startedAt: existing.startedAt,
            completedAt: completedAt,
            emittedEvents: request.includeEvents ? existing.emittedEvents : [],
            projectionStatus: summaryEnricher.projectionStatusArray(sortedBySequence: projection?.lastSequence ?? 0, recordedAt: completedAt),
            summary: "Replayed \(existing.emittedEvents.count) controller event\(existing.emittedEvents.count == 1 ? "" : "s")."
        )

        _ = try appendEvent(
            family: .simulator,
            eventType: "simulator_replayed",
            projectSlug: updated.projectSlug,
            summary: updated.scenarioName,
            detail: updated.summary,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarSimulatorRunResponse(run: try simulatorRunValue(updated.id))
    }

    public func rebuildProjection(_ request: BurnBarProjectionRebuildRequest) throws -> BurnBarProjectionRebuildResponse {
        let events = try loadEvents()
        projection = BurnBarMissionControlProjectionFile.empty(now: Date())
        seenEventIDs = []
        for event in events.sorted(by: MissionControlMissionStateMerger.eventSort) {
            try MissionControlProjectionReducer.apply(event: event, projection: &projection, seenEventIDs: &seenEventIDs)
        }
        try writeProjection()

        _ = try appendEvent(
            family: .projection,
            eventType: "projection_rebuilt",
            projectSlug: request.projectionNames.first ?? "openburnbar",
            summary: "Projection rebuild completed",
            detail: request.projectionNames.joined(separator: ", "),
            payload: BurnBarJSONValue.array(request.projectionNames.map(BurnBarJSONValue.string))
        )

        let names = request.projectionNames.isEmpty
            ? summaryEnricher.projectionStatusArray(sortedBySequence: projection?.lastSequence ?? 0, recordedAt: Date())
            : summaryEnricher.projectionStatusArray(sortedBySequence: projection?.lastSequence ?? 0, recordedAt: Date())
                .filter { request.projectionNames.contains($0.projectionName) }
        return BurnBarProjectionRebuildResponse(status: names)
    }

    public func evaluateDueNotifications(now: Date) throws -> [BurnBarFollowupSnapshot] {
        try ensureLoaded()

        let config = projection?.notificationConfig ?? BurnBarMissionControlProjectionFile.defaultNotificationConfig()
        let open = try followups(BurnBarFollowupsListRequest(statuses: [.open, .snoozed], limit: 500))
        for followup in open {
            if followup.status == .snoozed, let snoozeUntil = followup.snoozeUntil, snoozeUntil <= now {
                let reopened = MissionControlNotificationEvaluator.reopenedFollowupAfterSnoozeExpired(
                    followup: followup,
                    snoozeUntil: snoozeUntil
                )
                _ = try appendEvent(
                    family: .followup,
                    eventType: "followup_reopened",
                    projectSlug: reopened.projectSlug,
                    summary: reopened.title,
                    detail: "Snooze expired.",
                    payload: try BurnBarJSONValue.fromEncodable(reopened)
                )
            }
        }

        let ready = try followups(BurnBarFollowupsListRequest(statuses: [.open], limit: 500))
        var nudgedFollowups: [BurnBarFollowupSnapshot] = []
        for followup in ready {
            guard let nextNudgeAt = followup.nextNudgeAt ?? followup.calendarEntry?.startAt ?? followup.createdAt as Date? else {
                continue
            }
            if nextNudgeAt > now {
                continue
            }

            let rescheduled = MissionControlNotificationEvaluator.nudgedFollowupRescheduled(
                followup: followup,
                config: config,
                now: now
            )
            _ = try appendEvent(
                family: .followup,
                eventType: "followup_nudged",
                projectSlug: rescheduled.projectSlug,
                summary: rescheduled.title,
                detail: "Nudged by OpenBurnBar runtime.",
                payload: try BurnBarJSONValue.fromEncodable(rescheduled)
            )
            _ = try appendEvent(
                family: .notification,
                eventType: "notification_local_due",
                projectSlug: rescheduled.projectSlug,
                summary: rescheduled.title,
                detail: rescheduled.summary,
                payload: try BurnBarJSONValue.fromEncodable(rescheduled)
            )
            nudgedFollowups.append(rescheduled)
        }
        _ = config
        return nudgedFollowups
    }

    private func ensureLoaded() throws {
        if projection != nil {
            return
        }

        if let decoded = try journal.loadProjectionFromDiskIfPresent(decoder: decoder) {
            projection = decoded
        } else {
            projection = BurnBarMissionControlProjectionFile.empty()
        }

        let events = try loadEvents()
        projection = BurnBarMissionControlProjectionFile.empty(now: projection?.rebuiltAt ?? Date())
        seenEventIDs = []
        for event in events.sorted(by: MissionControlMissionStateMerger.eventSort) {
            try MissionControlProjectionReducer.apply(event: event, projection: &projection, seenEventIDs: &seenEventIDs)
        }
        try writeProjection()
    }

    private func loadEvents() throws -> [BurnBarControllerEvent] {
        if let cachedEvents {
            return cachedEvents
        }
        let events = try journal.readEventsFromDisk(decoder: decoder)
        cachedEvents = events
        return events
    }

    private func projectValue(_ slug: String) throws -> BurnBarReviewProjectSnapshot {
        guard let project = try project(slug: slug) else {
            throw BurnBarMissionControlError.projectNotFound(slug)
        }
        return project
    }

    private func reviewRunValue(_ id: String) throws -> BurnBarReviewRunSnapshot {
        try ensureLoaded()
        guard let run = projection?.reviewRuns[id] else {
            throw BurnBarMissionControlError.projectNotFound(id)
        }
        return run
    }

    private func questionValue(_ id: BurnBarQuestionID) throws -> BurnBarPendingQuestionSnapshot {
        guard let question = try question(id: id) else {
            throw BurnBarMissionControlError.questionNotFound(id)
        }
        return question
    }

    private func followup(id: BurnBarFollowupID) -> BurnBarFollowupSnapshot? {
        projection?.followups[id.rawValue]
    }

    private func followupValue(_ id: BurnBarFollowupID) throws -> BurnBarFollowupSnapshot {
        guard let followup = followup(id: id) else {
            throw BurnBarMissionControlError.followupNotFound(id)
        }
        return followup
    }

    private func followupForQuestion(_ questionID: BurnBarQuestionID) -> BurnBarFollowupSnapshot? {
        projection?.followups.values.first { $0.questionID == questionID && $0.status != .done }
    }

    private func missionValue(_ id: BurnBarMissionID) throws -> BurnBarMissionSnapshot {
        guard let mission = try mission(id: id) else {
            throw BurnBarMissionControlError.missionNotFound(id)
        }
        return mission
    }

    private func simulatorRun(id: BurnBarSimulatorRunID) -> BurnBarSimulatorRunSnapshot? {
        projection?.simulatorRuns[id.rawValue]
    }

    private func simulatorRunValue(_ id: BurnBarSimulatorRunID) throws -> BurnBarSimulatorRunSnapshot {
        guard let run = simulatorRun(id: id) else {
            throw BurnBarMissionControlError.simulatorRunNotFound(id)
        }
        return run
    }

    private func appendEvent(
        family: BurnBarControllerEventFamily,
        eventType: String,
        projectSlug: String,
        summary: String,
        detail: String?,
        payload: BurnBarJSONValue?,
        isReplay: Bool = false
    ) throws -> BurnBarControllerEvent {
        try ensureLoaded()
        let sequence = (projection?.lastSequence ?? 0) + 1
        var metadata: BurnBarMetadata = [:]
        if let payload {
            metadata["payload"] = payload
        }

        let event = BurnBarControllerEvent(
            id: BurnBarControllerEventID(rawValue: "controller-event-\(UUID().uuidString)"),
            family: family,
            eventType: eventType,
            projectSlug: projectSlug,
            recordedAt: Date(),
            sequence: sequence,
            summary: summary,
            detail: detail,
            metadata: metadata,
            isReplay: isReplay
        )

        try append(event)
        return event
    }

    private func append(_ event: BurnBarControllerEvent) throws {
        try journal.appendEventToDisk(event, encoder: encoder)
        try MissionControlProjectionReducer.apply(event: event, projection: &projection, seenEventIDs: &seenEventIDs)
        if cachedEvents == nil {
            cachedEvents = [event]
        } else {
            cachedEvents?.append(event)
        }
        try writeProjection()
    }

    private func writeProjection() throws {
        guard let projection else { return }
        try journal.writeProjectionFile(projection, encoder: encoder)
    }

    // MARK: - Test Helpers

    /// Directly injects missions into the store's in-memory projection for testing
    /// tie-break behavior with forced equal timestamps.
    ///
    /// This bypasses the event journal entirely and directly modifies the projection,
    /// which is appropriate for unit testing the comparator logic.
    ///
    /// Note: After calling this, do NOT call ensureLoaded() or any method that would
    /// rebuild the projection, as that would discard the injected data.
    func injectMissionsForTieBreakTesting(_ missions: [BurnBarMissionSnapshot]) throws {
        if projection == nil {
            projection = BurnBarMissionControlProjectionFile.empty(now: Date())
        }
        for mission in missions {
            projection?.missions[mission.id.rawValue] = mission
        }
    }

    /// Returns the current list of missions from the projection without requiring a reload,
    /// with the same sorting applied as the public missions() method.
    ///
    /// This is useful for tests to verify ordering after injecting test missions.
    func missionsSnapshot() throws -> [BurnBarMissionSnapshot] {
        return projection?.missions.values
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                // Tie-break: missionID ascending (lexicographic)
                return lhs.id.rawValue < rhs.id.rawValue
            } ?? []
    }
}
