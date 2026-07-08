import Foundation

extension OpenBurnBarOperatingComposer {
    static func buildControllerRuntime(
        cached: OpenBurnBarControllerRuntimeSnapshot?,
        daemonStatus: OpenBurnBarDaemonStatus,
        projectName: String?,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        mission: OpenBurnBarMissionSummary,
        direction: OpenBurnBarDirectionSummary,
        burn: OpenBurnBarBurnSummary,
        freshness: OpenBurnBarFreshnessSummary,
        settingsManager: SettingsManager,
        history: [OpenBurnBarOperatingHistoryEntry]
    ) -> OpenBurnBarControllerRuntimeSnapshot {
        let inferred = inferredControllerRuntime(
            daemonStatus: daemonStatus,
            projectName: projectName,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            mission: mission,
            direction: direction,
            burn: burn,
            freshness: freshness,
            settingsManager: settingsManager,
            history: history
        )

        guard let cached else { return inferred }

        let mergedQuestions = mergeQuestions(
            primary: cached.questions.filter { $0.sourceLabel != "Inferred from the latest local session" },
            fallback: inferred.questions
        )
        let mergedFollowups = mergeUniqueByID(primary: cached.followups, fallback: inferred.followups)
        let mergedMissions = mergeUniqueByID(primary: cached.missions, fallback: inferred.missions)
        let mergedNextActions = OpenBurnBarControllerNextActionPlanner.orderedActions(from: mergedMissions)
        let mergedEvents = mergeEvents(primary: cached.recentEvents, fallback: inferred.recentEvents)

        return OpenBurnBarControllerRuntimeSnapshot(
            source: cached.source,
            updatedAt: max(cached.updatedAt, inferred.updatedAt),
            summary: OpenBurnBarControllerSummary(
                headline: cached.summary.headline.nonEmpty ?? inferred.summary.headline,
                detail: cached.summary.detail.nonEmpty ?? inferred.summary.detail,
                pendingQuestions: mergedQuestions.filter { $0.state == .pending }.count,
                unresolvedFollowups: mergedFollowups.filter { $0.state == .open }.count,
                openMissions: mergedMissions.filter { $0.state != .completed }.count,
                replayLabel: cached.summary.replayLabel.nonEmpty ?? inferred.summary.replayLabel,
                notificationLabel: cached.summary.notificationLabel.nonEmpty ?? inferred.summary.notificationLabel
            ),
            questions: mergedQuestions,
            followups: mergedFollowups,
            missions: mergedMissions,
            nextActions: mergedNextActions,
            recentEvents: Array(mergedEvents.prefix(10))
        )
    }

    private static func inferredControllerRuntime(
        daemonStatus: OpenBurnBarDaemonStatus,
        projectName: String?,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        mission: OpenBurnBarMissionSummary,
        direction: OpenBurnBarDirectionSummary,
        burn: OpenBurnBarBurnSummary,
        freshness: OpenBurnBarFreshnessSummary,
        settingsManager: SettingsManager,
        history: [OpenBurnBarOperatingHistoryEntry]
    ) -> OpenBurnBarControllerRuntimeSnapshot {
        let now = Date()
        let project = projectName ?? mission.projectName.nonEmpty ?? "OpenBurnBar"

        let questions: [OpenBurnBarControllerQuestion] = []

        var followups: [OpenBurnBarControllerFollowup] = []
        if mission.approval == .pending, let reason = mission.approvalNote?.nonEmpty ?? mission.recommendationSummary.nonEmpty {
            followups.append(
                OpenBurnBarControllerFollowup(
                    projectName: project,
                    title: "Review mission approval",
                    summary: reason,
                    detail: "The current mission is still waiting on operator sign-off.",
                    kind: .missionWork,
                    dueAt: now.addingTimeInterval(60 * 60)
                )
            )
        }
        if settingsManager.conversationIndexingEnabled == false {
            followups.append(
                OpenBurnBarControllerFollowup(
                    projectName: project,
                    title: "Turn on transcript indexing",
                    summary: "Direction and evidence are still sparse without indexed local transcripts.",
                    detail: "Enable local indexing when you want grounded question tracking, evidence previews, and better drift detection.",
                    kind: .setup
                )
            )
        }
        if direction.status == .drifting || freshness.provisional {
            followups.append(
                OpenBurnBarControllerFollowup(
                    projectName: project,
                    title: "Resolve the latest direction call",
                    summary: direction.summary,
                    detail: direction.sparseReason ?? freshness.reasons.first,
                    kind: .completedAction,
                    dueAt: now.addingTimeInterval(2 * 60 * 60)
                )
            )
        }

        let missions = [
            OpenBurnBarControllerMissionRecord(
                id: mission.missionID.nonEmpty ?? UUID().uuidString,
                projectName: project,
                title: mission.title,
                summary: mission.subtitle,
                state: mission.state,
                approval: mission.approval,
                packetSummary: "OpenBurnBar is watching \(mission.summarizedSessionCount) summarized session\(mission.summarizedSessionCount == 1 ? "" : "s") for this mission.",
                latestResultSummary: mission.recommendationSummary,
                latestResultDetail: mission.approvalNote,
                latestResultRunID: nil,
                activeWorkerName: nil,
                activeRunID: nil,
                packetRunCount: 0,
                latestTakeoverState: nil,
                latestTakeoverReason: nil,
                latestTakeoverRunID: nil,
                takeoverCount: 0,
                burnCostUSD: burn.estimatedCostUSD,
                burnTokens: burn.totalTokens,
                updatedAt: freshness.updatedAt ?? now
            )
        ]
        let nextActions = OpenBurnBarControllerNextActionPlanner.orderedActions(from: missions)

        var events = history.map {
            OpenBurnBarControllerEvent(
                id: $0.id,
                projectName: projectName,
                category: .governance,
                title: $0.title,
                summary: $0.summary,
                detail: $0.detail,
                createdAt: $0.createdAt
            )
        }
        if case .healthy = daemonStatus {
            events.insert(
                OpenBurnBarControllerEvent(
                    projectName: projectName,
                    category: .controller,
                    title: "Controller runtime reachable",
                    summary: "AgentLens can pull daemon-backed controller state when it is available.",
                    detail: nil,
                    createdAt: now
                ),
                at: 0
            )
        }

        let daemonDetail: String = {
            switch daemonStatus {
            case .healthy:
                return "Daemon-backed control plane is healthy."
            case .checking:
                return "OpenBurnBar is checking the local daemon."
            case .notInstalled:
                return "Install the local daemon when you want long-lived notifications, Telegram, and replay workflows."
            case .unhealthy(let message):
                return "Daemon runtime needs repair: \(message)"
            }
        }()

        let summary = OpenBurnBarControllerSummary(
            headline: summaryHeadline(questionCount: questions.count, followupCount: followups.filter { $0.state == .open }.count),
            detail: daemonDetail,
            pendingQuestions: questions.filter { $0.state == .pending }.count,
            unresolvedFollowups: followups.filter { $0.state == .open }.count,
            openMissions: missions.filter { $0.state != .completed }.count,
            replayLabel: settingsManager.controllerSimulatorToolsEnabled ? "Replay tools visible" : "Replay tools hidden",
            notificationLabel: notificationLabel(from: settingsManager)
        )

        return OpenBurnBarControllerRuntimeSnapshot(
            source: .inferred,
            updatedAt: freshness.updatedAt ?? now,
            summary: summary,
            questions: questions,
            followups: followups,
            missions: missions,
            nextActions: nextActions,
            recentEvents: Array(events.prefix(10))
        )
    }

    private static func summaryHeadline(questionCount: Int, followupCount: Int) -> String {
        switch (questionCount, followupCount) {
        case (0, 0): return "Controller runtime is quiet."
        case let (q, 0) where q > 0: return "\(q) pending question\(q == 1 ? "" : "s") need an answer."
        case let (0, f) where f > 0: return "\(f) followup\(f == 1 ? "" : "s") are still open."
        case let (q, f): return "\(q) pending question\(q == 1 ? "" : "s") and \(f) followup\(f == 1 ? "" : "s") need attention."
        }
    }

    private static func notificationLabel(from settingsManager: SettingsManager) -> String {
        if settingsManager.controllerTelegramEnabled,
           settingsManager.controllerTelegramChatID.nonEmpty != nil {
            return "Telegram and local notifications armed"
        }
        if settingsManager.controllerLocalNotificationsEnabled {
            return "Local notifications armed"
        }
        return "Notifications optional"
    }

    private static func mergeQuestions(
        primary: [OpenBurnBarControllerQuestion],
        fallback: [OpenBurnBarControllerQuestion]
    ) -> [OpenBurnBarControllerQuestion] {
        var seenIDs = Set<String>()
        var seenSemanticKeys = Set<String>()
        return (primary + fallback).filter { question in
            guard seenIDs.insert(question.id).inserted else {
                return false
            }
            let semanticKey = questionSemanticKey(question)
            guard seenSemanticKeys.insert(semanticKey).inserted else {
                return false
            }
            return true
        }
    }

    private static func mergeUniqueByID<T: Identifiable>(
        primary: [T],
        fallback: [T]
    ) -> [T] where T.ID == String {
        var seen = Set<String>()
        return (primary + fallback).filter { seen.insert($0.id).inserted }
    }

    private static func mergeEvents(
        primary: [OpenBurnBarControllerEvent],
        fallback: [OpenBurnBarControllerEvent]
    ) -> [OpenBurnBarControllerEvent] {
        let merged = primary + fallback.filter { candidate in
            primary.contains(where: { $0.id == candidate.id }) == false
        }
        return merged.sorted { $0.createdAt > $1.createdAt }
    }

    private static func questionSemanticKey(_ question: OpenBurnBarControllerQuestion) -> String {
        if let sessionID = question.sessionID?.nonEmpty {
            return "session|\(sessionID)"
        }
        let normalizedProject = question.projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrompt = question.prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "project|\(normalizedProject)|\(normalizedPrompt)"
    }
}
