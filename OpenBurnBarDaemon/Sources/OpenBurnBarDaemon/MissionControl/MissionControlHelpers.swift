import OpenBurnBarCore
import Foundation

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

func intValue(_ value: BurnBarJSONValue?) -> Int {
    switch value {
    case .number(let number):
        return Int(number)
    case .string(let string):
        return Int(string) ?? 0
    default:
        return 0
    }
}

extension BurnBarMissionControlService {
    func normalizedQuestion(
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

    func deliverNewQuestionNotificationsIfNeeded(
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

    func inferredStageLabel(for prompt: String) -> String {
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

    func inferredQuestionOptions(for prompt: String) -> [BurnBarQuestionOptionSnapshot] {
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

    func inferredQuestionDeepLink(
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

    func buildReviewPrompt(
        for project: BurnBarReviewProjectSnapshot,
        cadence: BurnBarControllerReviewCadence
    ) -> String {
        let latestTitle = project.metadata["latest_conversation_title"]?.missionStringValue() ?? "No titled checkpoint yet"
        let latestSummary = project.metadata["latest_conversation_summary"]?.missionStringValue() ?? project.summary
        let sessions = project.metadata["session_count_last_7d"]?.missionNumberValue().map { Int($0) } ?? 0
        let totalCost = project.metadata["total_cost_last_7d"]?.missionNumberValue() ?? 0
        let totalTokens = project.metadata["total_tokens_last_7d"]?.missionNumberValue().map { Int($0) } ?? 0

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

    func copy(
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

    func defaultCadence(
        for project: BurnBarControllerActivityProject
    ) -> BurnBarControllerReviewCadence {
        if project.sessionCountLast7Days >= 5 || project.totalCostLast7Days >= 5 {
            return .daily
        }
        return .weekly
    }

    func questionPriority(for prompt: String) -> BurnBarPendingQuestionPriority {
        let lowered = prompt.lowercased()
        if lowered.contains("blocked")
            || lowered.contains("stuck")
            || lowered.contains("error")
            || lowered.contains("fail") {
            return .high
        }
        return .medium
    }

    func metadataDate(
        _ key: String,
        in metadata: BurnBarMetadata
    ) -> Date? {
        guard let rawValue = metadata[key]?.missionStringValue() else {
            return nil
        }
        return ISO8601DateFormatter().date(from: rawValue)
    }
}

extension BurnBarJSONValue {
    func missionBoolValue() -> Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    func missionStringValue() -> String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    func missionNumberValue() -> Double? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }
}

