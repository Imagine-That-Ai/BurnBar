import OpenBurnBarEngine
import Foundation

/// Builds controller summaries and enriched project snapshots from mission control projection state.
struct MissionControlSummaryEnricher {
    let projection: BurnBarMissionControlProjectionFile?
    let cachedEvents: [BurnBarControllerEvent]?

    private struct ProjectAggregate {
        var pendingQuestionCount = 0
        var openFollowupCount = 0
        var activeMissionCount = 0
        var activeMissionID: BurnBarMissionID?
        var activeMissionUpdatedAt: Date?
        var latestDailyReviewAt: Date?
        var latestWeeklyReviewAt: Date?
    }

    private static let terminalMissionStatuses: Set<BurnBarMissionStatus> = [
        .completed,
        .failed,
        .cancelled
    ]

    func enrichedProjects() -> [BurnBarReviewProjectSnapshot] {
        let baseProjects = projection.map { Array($0.projects.values) } ?? []
        let aggregates = projectAggregates()
        return baseProjects
            .map { enrichedProject($0, aggregate: aggregates[$0.projectSlug] ?? ProjectAggregate()) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func enrichedProject(slug: String) -> BurnBarReviewProjectSnapshot? {
        guard let base = projection?.projects[slug] else {
            return nil
        }
        return enrichedProject(
            base,
            aggregate: projectAggregates()[slug] ?? ProjectAggregate()
        )
    }

    func makeSummary(for request: BurnBarControllerSummaryRequest) -> BurnBarControllerSummary {
        let projects = enrichedProjects().filter { request.projectSlug == nil || $0.projectSlug == request.projectSlug }
        let missionSnapshots = projection?.missions.values.filter {
            request.projectSlug == nil || $0.projectSlug == request.projectSlug
        } ?? []
        let pendingQuestions = projection?.questions.values.filter {
            (request.projectSlug == nil || $0.projectSlug == request.projectSlug) && $0.status == .pending
        }.count ?? 0
        let openFollowups = projection?.followups.values.filter {
            (request.projectSlug == nil || $0.projectSlug == request.projectSlug) && $0.status == .open
        }.count ?? 0
        let activeMissions = missionSnapshots.filter {
            ![BurnBarMissionStatus.completed, .failed, .cancelled].contains($0.status)
        }.count
        let latestReviewAt = projects
            .flatMap { [$0.latestDailyReviewAt, $0.latestWeeklyReviewAt] }
            .compactMap { $0 }
            .max()
        let freshness = freshnessState(latestReviewAt: latestReviewAt)
        let recentEvents = request.includeRecentEvents
            ? Array((cachedEvents ?? [])
                .filter { request.projectSlug == nil || $0.projectSlug == request.projectSlug }
                .sorted(by: { lhs, rhs in
                    if lhs.sequence == rhs.sequence {
                        return lhs.recordedAt > rhs.recordedAt
                    }
                    return lhs.sequence > rhs.sequence
                })
                .prefix(20))
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
            recentEvents: recentEvents,
            nextActions: BurnBarControllerNextActionPlanner.orderedActions(
                from: missionSnapshots,
                maxCount: BurnBarControllerNextActionPlanner.defaultMaximumActionCount
            )
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

    /// Builds every derived per-project count/date in one pass over each
    /// projection collection. The previous implementation filtered all
    /// questions, followups, missions, and review runs separately for every
    /// project, repeatedly copying large mission snapshots.
    private func projectAggregates() -> [String: ProjectAggregate] {
        guard let projection else {
            return [:]
        }

        var aggregates: [String: ProjectAggregate] = [:]
        aggregates.reserveCapacity(projection.projects.count)

        for question in projection.questions.values where question.status == .pending {
            aggregates[question.projectSlug, default: ProjectAggregate()].pendingQuestionCount += 1
        }
        for followup in projection.followups.values where followup.status == .open {
            aggregates[followup.projectSlug, default: ProjectAggregate()].openFollowupCount += 1
        }
        for mission in projection.missions.values where !Self.terminalMissionStatuses.contains(mission.status) {
            var aggregate = aggregates[mission.projectSlug, default: ProjectAggregate()]
            aggregate.activeMissionCount += 1
            if let activeMissionUpdatedAt = aggregate.activeMissionUpdatedAt {
                if mission.updatedAt > activeMissionUpdatedAt {
                    aggregate.activeMissionID = mission.id
                    aggregate.activeMissionUpdatedAt = mission.updatedAt
                }
            } else {
                aggregate.activeMissionID = mission.id
                aggregate.activeMissionUpdatedAt = mission.updatedAt
            }
            aggregates[mission.projectSlug] = aggregate
        }
        for review in projection.reviewRuns.values {
            var aggregate = aggregates[review.projectSlug, default: ProjectAggregate()]
            switch review.cadence {
            case .daily:
                aggregate.latestDailyReviewAt = max(aggregate.latestDailyReviewAt ?? .distantPast, review.recordedAt)
            case .weekly:
                aggregate.latestWeeklyReviewAt = max(aggregate.latestWeeklyReviewAt ?? .distantPast, review.recordedAt)
            case .adHoc:
                break
            }
            aggregates[review.projectSlug] = aggregate
        }
        return aggregates
    }

    private func enrichedProject(
        _ base: BurnBarReviewProjectSnapshot,
        aggregate: ProjectAggregate
    ) -> BurnBarReviewProjectSnapshot {
        let latestDaily = aggregate.latestDailyReviewAt
        let latestWeekly = aggregate.latestWeeklyReviewAt
        let freshness = freshnessState(latestReviewAt: [latestDaily, latestWeekly].compactMap { $0 }.max())
        let nextScheduledReviewAt = nextScheduledReviewAt(
            for: base,
            latestDailyReviewAt: latestDaily,
            latestWeeklyReviewAt: latestWeekly
        )
        let needsOperatorAttention = aggregate.pendingQuestionCount > 0
            || aggregate.openFollowupCount > 0
            || aggregate.activeMissionCount > 0
        let status: BurnBarReviewProjectStatus
        if base.status == .paused {
            status = .paused
        } else if freshness == .stale {
            status = .stale
        } else if needsOperatorAttention {
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
            pendingQuestionCount: aggregate.pendingQuestionCount,
            openFollowupCount: aggregate.openFollowupCount,
            activeMissionCount: aggregate.activeMissionCount,
            activeMissionID: aggregate.activeMissionID,
            needsOperatorAttention: needsOperatorAttention,
            ingestionSource: base.ingestionSource,
            metadata: base.metadata
        )
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

        struct SimulatorEventPayload {
            let family: BurnBarControllerEventFamily
            let eventType: String
            let summary: String
            let detail: String?
            let payload: BurnBarJSONValue
        }

        let payloads: [SimulatorEventPayload] = [
            .init(family: .controller, eventType: "project_upserted", summary: project.displayName, detail: project.summary, payload: try BurnBarJSONValue.fromEncodable(project)),
            .init(family: .question, eventType: "question_created", summary: question.title, detail: question.prompt, payload: try BurnBarJSONValue.fromEncodable(question)),
            .init(family: .mission, eventType: "mission_created", summary: mission.title, detail: mission.summary, payload: try BurnBarJSONValue.fromEncodable(mission))
        ]

        return payloads.enumerated().map { index, item in
            BurnBarControllerEvent(
                id: BurnBarControllerEventID(rawValue: "sim-event-\(request.seed)-\(index)"),
                family: item.family,
                eventType: item.eventType,
                projectSlug: request.projectSlug,
                recordedAt: now.addingTimeInterval(Double(index)),
                sequence: index + 1,
                summary: item.summary,
                detail: item.detail,
                metadata: ["payload": item.payload],
                isReplay: false
            )
        }
    }
}
