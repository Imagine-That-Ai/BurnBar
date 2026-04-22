import Foundation
import OpenBurnBarCore

extension DataStore {
    nonisolated func appendOperatingActionRecord(_ record: OpenBurnBarOperatingActionRecord) throws {
        try controlPlaneStore.appendOperatingActionRecord(record)
    }

    nonisolated func fetchOperatingActionRecords(
        projectName: String? = nil,
        actionKinds: [OpenBurnBarActionKind]? = nil,
        limit: Int = 100
    ) throws -> [OpenBurnBarOperatingActionRecord] {
        try controlPlaneStore.fetchOperatingActionRecords(
            projectName: projectName,
            actionKinds: actionKinds,
            limit: limit
        )
    }

    nonisolated func countOperatingActionRecords(
        projectName: String? = nil,
        actionKinds: [OpenBurnBarActionKind]? = nil
    ) throws -> Int {
        try controlPlaneStore.countOperatingActionRecords(projectName: projectName, actionKinds: actionKinds)
    }

    nonisolated func saveControllerRuntimeMirror(
        _ snapshot: OpenBurnBarControllerRuntimeSnapshot,
        cacheKey: String = "latest"
    ) throws {
        try controlPlaneStore.saveControllerRuntimeMirror(snapshot, cacheKey: cacheKey)
    }

    nonisolated func fetchControllerRuntimeMirror(
        cacheKey: String = "latest"
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try controlPlaneStore.fetchControllerRuntimeMirror(cacheKey: cacheKey)
    }

    nonisolated func localAuthoritySnapshot() throws -> OpenBurnBarLocalAuthoritySnapshot {
        try controlPlaneStore.localAuthoritySnapshot()
    }

    nonisolated func mutateControllerRuntimeMirror(
        cacheKey: String = "latest",
        _ mutate: (inout OpenBurnBarControllerRuntimeSnapshot) -> Void
    ) throws {
        try controlPlaneStore.mutateControllerRuntimeMirror(cacheKey: cacheKey, mutate)
    }

    @discardableResult
    nonisolated func answerControllerQuestion(
        id: String,
        answer: String,
        selectedOptionID: String? = nil,
        cacheKey: String = "latest",
        answeredAt: Date = Date()
    ) throws -> Bool {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAnswer.isEmpty == false else { return false }

        var updated = false
        try mutateControllerRuntimeMirror(cacheKey: cacheKey) { snapshot in
            guard let index = snapshot.questions.firstIndex(where: { $0.id == id }) else { return }
            let question = snapshot.questions[index]
            guard question.state == .pending else { return }

            snapshot.questions[index] = OpenBurnBarControllerQuestion(
                id: question.id,
                projectName: question.projectName,
                sessionID: question.sessionID,
                title: question.title,
                prompt: question.prompt,
                stageLabel: question.stageLabel,
                evidenceHint: question.evidenceHint,
                state: .answered,
                priority: question.priority,
                sourceLabel: question.sourceLabel,
                createdAt: question.createdAt,
                answeredAt: answeredAt,
                answer: trimmedAnswer,
                selectedOptionID: selectedOptionID,
                answerPlaceholder: question.answerPlaceholder,
                suggestedOptions: question.suggestedOptions,
                deepLink: question.deepLink,
                isUnread: false,
                notificationCount: question.notificationCount
            )

            snapshot.recentEvents.insert(
                OpenBurnBarControllerEvent(
                    projectName: question.projectName,
                    category: .question,
                    title: "Question answered",
                    summary: question.title,
                    detail: trimmedAnswer,
                    createdAt: answeredAt
                ),
                at: 0
            )
            snapshot.recentEvents = Array(snapshot.recentEvents.prefix(10))
            snapshot.updatedAt = answeredAt
            snapshot.summary = snapshot.summary.recounted(
                pendingQuestions: snapshot.questions.filter { $0.state == .pending }.count,
                unresolvedFollowups: snapshot.followups.filter { $0.state == .open }.count,
                openMissions: snapshot.missions.filter { $0.state != .completed }.count
            )
            updated = true
        }

        return updated
    }

    @discardableResult
    nonisolated func completeControllerFollowup(
        id: String,
        cacheKey: String = "latest",
        completedAt: Date = Date()
    ) throws -> Bool {
        var updated = false
        try mutateControllerRuntimeMirror(cacheKey: cacheKey) { snapshot in
            guard let index = snapshot.followups.firstIndex(where: { $0.id == id }) else { return }
            let followup = snapshot.followups[index]
            guard followup.state != .done else { return }

            snapshot.followups[index] = followup.updating(state: .done, updatedAt: completedAt)
            snapshot.recentEvents.insert(
                OpenBurnBarControllerEvent(
                    projectName: followup.projectName,
                    category: .followup,
                    title: "Followup completed",
                    summary: followup.title,
                    detail: followup.summary,
                    createdAt: completedAt
                ),
                at: 0
            )
            snapshot.recentEvents = Array(snapshot.recentEvents.prefix(10))
            snapshot.updatedAt = completedAt
            snapshot.summary = snapshot.summary.recounted(
                pendingQuestions: snapshot.questions.filter { $0.state == .pending }.count,
                unresolvedFollowups: snapshot.followups.filter { $0.state == .open }.count,
                openMissions: snapshot.missions.filter { $0.state != .completed }.count
            )
            updated = true
        }

        return updated
    }

    @discardableResult
    nonisolated func snoozeControllerFollowup(
        id: String,
        until: Date,
        cacheKey: String = "latest",
        updatedAt: Date = Date()
    ) throws -> Bool {
        var updated = false
        try mutateControllerRuntimeMirror(cacheKey: cacheKey) { snapshot in
            guard let index = snapshot.followups.firstIndex(where: { $0.id == id }) else { return }
            let followup = snapshot.followups[index]

            snapshot.followups[index] = followup.updating(
                state: .snoozed,
                snoozedUntil: until,
                updatedAt: updatedAt
            )
            snapshot.recentEvents.insert(
                OpenBurnBarControllerEvent(
                    projectName: followup.projectName,
                    category: .followup,
                    title: "Followup snoozed",
                    summary: followup.title,
                    detail: "Snoozed until \(until.formatted(date: .abbreviated, time: .shortened)).",
                    createdAt: updatedAt
                ),
                at: 0
            )
            snapshot.recentEvents = Array(snapshot.recentEvents.prefix(10))
            snapshot.updatedAt = updatedAt
            snapshot.summary = snapshot.summary.recounted(
                pendingQuestions: snapshot.questions.filter { $0.state == .pending }.count,
                unresolvedFollowups: snapshot.followups.filter { $0.state == .open }.count,
                openMissions: snapshot.missions.filter { $0.state != .completed }.count
            )
            updated = true
        }

        return updated
    }

    @discardableResult
    nonisolated func scheduleControllerFollowupCalendar(
        id: String,
        title: String?,
        start: Date,
        durationMinutes: Int,
        cacheKey: String = "latest",
        updatedAt: Date = Date()
    ) throws -> Bool {
        var updated = false
        try mutateControllerRuntimeMirror(cacheKey: cacheKey) { snapshot in
            guard let index = snapshot.followups.firstIndex(where: { $0.id == id }) else { return }
            let followup = snapshot.followups[index]

            let resolvedTitle: String
            if let title {
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                resolvedTitle = trimmedTitle.isEmpty ? followup.title : trimmedTitle
            } else {
                resolvedTitle = followup.title
            }

            let end = start.addingTimeInterval(Double(max(durationMinutes, 15)) * 60)
            snapshot.followups[index] = followup.updating(
                calendarTitle: resolvedTitle,
                calendarStart: start,
                calendarEnd: end,
                updatedAt: updatedAt
            )
            snapshot.recentEvents.insert(
                OpenBurnBarControllerEvent(
                    projectName: followup.projectName,
                    category: .notification,
                    title: "Calendar hold created",
                    summary: resolvedTitle,
                    detail: "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))",
                    createdAt: updatedAt
                ),
                at: 0
            )
            snapshot.recentEvents = Array(snapshot.recentEvents.prefix(10))
            snapshot.updatedAt = updatedAt
            updated = true
        }

        return updated
    }
}
