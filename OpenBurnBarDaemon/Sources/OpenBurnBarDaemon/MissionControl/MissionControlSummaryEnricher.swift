import OpenBurnBarCore
import Foundation

/// Builds controller summaries and enriched project snapshots from mission control projection state.
struct MissionControlSummaryEnricher {
    let projection: BurnBarMissionControlProjectionFile?
    let cachedEvents: [BurnBarControllerEvent]?

    func enrichedProjects() -> [BurnBarReviewProjectSnapshot] {
        let baseProjects = projection.map { Array($0.projects.values) } ?? []
        return baseProjects
            .map { base in
                let pendingQuestions = projection?.questions.values.filter {
                    $0.projectSlug == base.projectSlug && $0.status == .pending
                }.count ?? 0
                let openFollowups = projection?.followups.values.filter {
                    $0.projectSlug == base.projectSlug && $0.status == .open
                }.count ?? 0
                let activeMissions = projection?.missions.values.filter {
                    $0.projectSlug == base.projectSlug
                        && ![BurnBarMissionStatus.completed, .failed, .cancelled].contains($0.status)
                } ?? []
                let latestDaily = projection?.reviewRuns.values
                    .filter { $0.projectSlug == base.projectSlug && $0.cadence == .daily }
                    .sorted { $0.recordedAt > $1.recordedAt }
                    .first?.recordedAt
                let latestWeekly = projection?.reviewRuns.values
                    .filter { $0.projectSlug == base.projectSlug && $0.cadence == .weekly }
                    .sorted { $0.recordedAt > $1.recordedAt }
                    .first?.recordedAt
                let freshness = freshnessState(latestReviewAt: [latestDaily, latestWeekly].compactMap { $0 }.max())
                let nextScheduledReviewAt = nextScheduledReviewAt(
                    for: base,
                    latestDailyReviewAt: latestDaily,
                    latestWeeklyReviewAt: latestWeekly
                )
                let status: BurnBarReviewProjectStatus
                if base.status == .paused {
                    status = .paused
                } else if freshness == .stale {
                    status = .stale
                } else if pendingQuestions > 0 || openFollowups > 0 || activeMissions.count > 0 {
                    status = .needsAttention
                } else {
                    status = base.status == .onboarding ? .onboarding : .healthy
                }
                return BurnBarReviewProjectSnapshot(
                    id: base.id,
                    projectSlug: base.projectSlug,
                    displayName: base.displayName,
                    summary: base.summary,
                    status: status,
                    preferredCadence: base.preferredCadence,
                    aliases: base.aliases,
                    automationMode: base.automationMode,
                    reviewModelID: base.reviewModelID,
                    scheduleHourLocal: base.scheduleHourLocal,
                    scheduleWeekdayLocal: base.scheduleWeekdayLocal,
                    freshness: freshness,
                    latestDailyReviewAt: latestDaily,
                    latestWeeklyReviewAt: latestWeekly,
                    nextScheduledReviewAt: nextScheduledReviewAt,
                    pendingQuestionCount: pendingQuestions,
                    openFollowupCount: openFollowups,
                    activeMissionCount: activeMissions.count,
                    activeMissionID: activeMissions.sorted { $0.updatedAt > $1.updatedAt }.first?.id,
                    needsOperatorAttention: pendingQuestions > 0 || openFollowups > 0 || activeMissions.count > 0,
                    ingestionSource: base.ingestionSource,
                    metadata: base.metadata
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func makeSummary(for request: BurnBarControllerSummaryRequest) -> BurnBarControllerSummary {
        let projects = enrichedProjects().filter { request.projectSlug == nil || $0.projectSlug == request.projectSlug }
        let pendingQuestions = projection?.questions.values.filter {
            (request.projectSlug == nil || $0.projectSlug == request.projectSlug) && $0.status == .pending
        }.count ?? 0
        let openFollowups = projection?.followups.values.filter {
            (request.projectSlug == nil || $0.projectSlug == request.projectSlug) && $0.status == .open
        }.count ?? 0
        let activeMissions = projection?.missions.values.filter {
            (request.projectSlug == nil || $0.projectSlug == request.projectSlug)
                && ![BurnBarMissionStatus.completed, .failed, .cancelled].contains($0.status)
        }.count ?? 0
        let latestReviewAt = projects
            .flatMap { [$0.latestDailyReviewAt, $0.latestWeeklyReviewAt] }
            .compactMap { $0 }
            .max()
        let freshness = freshnessState(latestReviewAt: latestReviewAt)
        let recentEvents = request.includeRecentEvents
            ? (cachedEvents ?? [])
                .filter { request.projectSlug == nil || $0.projectSlug == request.projectSlug }
                .sorted(by: { lhs, rhs in
                    if lhs.sequence == rhs.sequence {
                        return lhs.recordedAt > rhs.recordedAt
                    }
                    return lhs.sequence > rhs.sequence
                })
                .prefix(20)
                .map { $0 }
            : []
        let projectionStatus = request.includeProjectionStatus
            ? projectionStatusArray(sortedBySequence: projection?.lastSequence ?? 0, recordedAt: projection?.rebuiltAt ?? Date())
            : []

        return BurnBarControllerSummary(
            updatedAt: projection?.rebuiltAt ?? Date(),
            activeProjectSlug: request.projectSlug ?? projects.first?.projectSlug,
            counts: BurnBarControllerCounts(
                projectCount: projects.count,
                pendingQuestionCount: pendingQuestions,
                openFollowupCount: openFollowups,
                activeMissionCount: activeMissions,
                staleProjectCount: projects.filter { $0.status == .stale }.count
            ),
            nextSuggestedCadence: nextSuggestedCadence(from: projects),
            latestReviewAt: latestReviewAt,
            freshness: freshness,
            projectionStatus: projectionStatus,
            recentEvents: recentEvents
        )
    }

    func makeNotificationHealth() -> BurnBarNotificationHealthSnapshot {
        let config = projection?.notificationConfig ?? BurnBarMissionControlProjectionFile.defaultNotificationConfig()
        let now = Date()
        let localError = projection?.transportErrors[BurnBarNotificationChannel.local.rawValue]
        let telegramError = projection?.transportErrors[BurnBarNotificationChannel.telegram.rawValue]
        let calendarError = projection?.transportErrors[BurnBarNotificationChannel.calendar.rawValue]

        let local = BurnBarNotificationChannelHealth(
            channel: .local,
            status: config.local.isEnabled ? (localError == nil ? .healthy : .degraded) : .disabled,
            detail: config.local.isEnabled
                ? (localError ?? "Local notifications can nudge due followups.")
                : "Local notifications are turned off.",
            checkedAt: now
        )
        let telegramConfigured = ((config.telegram.botToken?.isEmpty == false) || config.telegram.botTokenConfigured)
            && config.telegram.chatID?.isEmpty == false
        let telegram = BurnBarNotificationChannelHealth(
            channel: .telegram,
            status: config.telegram.isEnabled
                ? (telegramConfigured ? (telegramError == nil ? .healthy : .degraded) : .unauthorized)
                : .disabled,
            detail: config.telegram.isEnabled
                ? (telegramConfigured ? (telegramError ?? "Telegram bot is configured.") : "Telegram needs a bot token and chat ID.")
                : "Telegram delivery is turned off.",
            checkedAt: now
        )
        let calendar = BurnBarNotificationChannelHealth(
            channel: .calendar,
            status: config.calendar.isEnabled ? (calendarError == nil ? .healthy : .degraded) : .disabled,
            detail: config.calendar.isEnabled
                ? (calendarError ?? "Calendar holds can be created from followups.")
                : "Calendar integration is off.",
            checkedAt: now
        )

        return BurnBarNotificationHealthSnapshot(
            checkedAt: now,
            channels: [local, telegram, calendar]
        )
    }

    func projectionStatusArray(
        sortedBySequence eventSequence: Int,
        recordedAt: Date
    ) -> [BurnBarProjectionStatusSnapshot] {
        let statuses = projection?.projectionStatus.isEmpty == false
            ? projection?.projectionStatus ?? [:]
            : BurnBarMissionControlProjectionFile.defaultProjectionStatus(
                eventSequence: eventSequence,
                recordedAt: recordedAt
            )
        return statuses.values.sorted { $0.projectionName < $1.projectionName }
    }

    private func freshnessState(latestReviewAt: Date?) -> BurnBarControllerFreshnessState {
        guard let latestReviewAt else {
            return (projection?.projects.isEmpty ?? true) ? .missing : .provisional
        }

        let age = Date().timeIntervalSince(latestReviewAt)
        if age < Double(12 * 60 * 60) {
            return .fresh
        }
        if age < Double(48 * 60 * 60) {
            return .aging
        }
        return .stale
    }

    private func nextSuggestedCadence(from projects: [BurnBarReviewProjectSnapshot]) -> BurnBarControllerReviewCadence? {
        if projects.isEmpty {
            return nil
        }
        if projects.contains(where: { $0.preferredCadence == .daily && ($0.latestDailyReviewAt ?? .distantPast) < Date().addingTimeInterval(-24 * 60 * 60) }) {
            return .daily
        }
        if projects.contains(where: { $0.preferredCadence == .weekly && ($0.latestWeeklyReviewAt ?? .distantPast) < Date().addingTimeInterval(-7 * 24 * 60 * 60) }) {
            return .weekly
        }
        return projects.first?.preferredCadence
    }

    private func nextScheduledReviewAt(
        for project: BurnBarReviewProjectSnapshot,
        latestDailyReviewAt: Date?,
        latestWeeklyReviewAt: Date?
    ) -> Date? {
        guard project.automationMode == .scheduled else {
            return nil
        }

        let calendar = Calendar.current
        let hour = project.scheduleHourLocal ?? 9
        let reference = project.preferredCadence == .daily ? latestDailyReviewAt : latestWeeklyReviewAt
        let base = reference ?? Date()

        switch project.preferredCadence {
        case .daily, .adHoc:
            let startOfDay = calendar.startOfDay(for: base)
            let scheduledToday = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startOfDay) ?? startOfDay
            if reference == nil {
                return scheduledToday
            }
            return calendar.date(byAdding: .day, value: 1, to: scheduledToday)
        case .weekly:
            let weekday = project.scheduleWeekdayLocal ?? 2
            let nextDate = calendar.nextDate(
                after: base.addingTimeInterval(60),
                matching: DateComponents(hour: hour, minute: 0, weekday: weekday),
                matchingPolicy: .nextTime,
                direction: .forward
            )
            return nextDate
        }
    }

    static func defaultSimulatorEvents(
        for request: BurnBarSimulatorRunRequest,
        now: Date
    ) throws -> [BurnBarControllerEvent] {
        let project = BurnBarReviewProjectSnapshot(
            id: "project-\(request.projectSlug)",
            projectSlug: request.projectSlug,
            displayName: request.projectSlug.capitalized,
            summary: "Simulated controller project for \(request.scenarioName).",
            status: .needsAttention,
            preferredCadence: .daily,
            freshness: .provisional,
            pendingQuestionCount: 1,
            openFollowupCount: 1,
            activeMissionCount: 1,
            needsOperatorAttention: true,
            metadata: request.metadata
        )
        let question = BurnBarPendingQuestionSnapshot(
            id: BurnBarQuestionID(rawValue: "question-\(request.seed)"),
            projectSlug: request.projectSlug,
            title: "What should happen next?",
            prompt: "Scenario \(request.scenarioName) generated a pending operator question.",
            status: .pending,
            priority: .medium,
            askedAt: now,
            dueAt: now.addingTimeInterval(3600),
            contextSummary: "Generated from the deterministic simulator.",
            metadata: request.metadata
        )
        let mission = BurnBarMissionSnapshot(
            id: BurnBarMissionID(rawValue: "mission-\(request.seed)"),
            projectSlug: request.projectSlug,
            title: "Simulated mission",
            summary: "Exercise replay, followups, and operator review state.",
            status: .awaitingApproval,
            recommendation: .review,
            createdAt: now,
            updatedAt: now,
            approval: BurnBarMissionApprovalSnapshot(approved: false),
            metadata: request.metadata
        )

        let payloads: [(BurnBarControllerEventFamily, String, String, String?, BurnBarJSONValue)] = [
            (.controller, "project_upserted", project.displayName, project.summary, try BurnBarJSONValue.fromEncodable(project)),
            (.question, "question_created", question.title, question.prompt, try BurnBarJSONValue.fromEncodable(question)),
            (.mission, "mission_created", mission.title, mission.summary, try BurnBarJSONValue.fromEncodable(mission))
        ]

        return payloads.enumerated().map { index, item in
            BurnBarControllerEvent(
                id: BurnBarControllerEventID(rawValue: "sim-event-\(request.seed)-\(index)"),
                family: item.0,
                eventType: item.1,
                projectSlug: request.projectSlug,
                recordedAt: now.addingTimeInterval(Double(index)),
                sequence: index + 1,
                summary: item.2,
                detail: item.3,
                metadata: ["payload": item.4],
                isReplay: false
            )
        }
    }
}
