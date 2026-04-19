import Foundation

// MARK: - Operating Layer Composition

@MainActor
enum OpenBurnBarOperatingComposer {
    static func build(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        daemonStatus: OpenBurnBarDaemonStatus,
        aggregator: UsageAggregator?,
        chatController: ChatSessionController?,
        actionRecords: [OpenBurnBarOperatingActionRecord],
        cachedControllerRuntime: OpenBurnBarControllerRuntimeSnapshot?
    ) -> OpenBurnBarOperatingSnapshot {
        let searchService = SearchService.makeConversationSearchService(
            dataStore: dataStore,
            settingsManager: settingsManager
        )
        let rollupService = WorkflowInsightRollupService(dataStore: dataStore)
        let insightBrief = InsightBriefSnapshot.build(
            from: dataStore,
            intelligenceService: searchService,
            rollupService: rollupService,
            refreshRollups: false
        )
        let retrievalHealth = RetrievalHealthService(dataStore: dataStore).snapshot(
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            sharedFeaturesAvailable: accountManager.isSignedIn
        )

        let recentConversations = searchService
            .recentConversations(limit: 120)
            .filter { $0.sourceType == .providerLog }
        let focus = selectProjectFocus(
            conversations: recentConversations,
            usages: dataStore.usages
        )

        let projectConversations = filterByPrimaryProject(recentConversations, focus.primaryProject) { $0.projectName }
        let decisions = decisionState(from: actionRecords)
        let history = historyEntries(
            from: actionRecords,
            focusProject: focus.primaryProject
        )
        let latestConversation = searchService.latestConversation(in: projectConversations)
        let projectUsages = filterByPrimaryProject(dataStore.usages, focus.primaryProject) { $0.projectName }
        let recentProjectUsages = projectUsages.filter { $0.startTime >= Date().addingTimeInterval(-7 * 24 * 60 * 60) }
        let activeUsages = recentProjectUsages.isEmpty ? projectUsages : recentProjectUsages

        let mission = buildMissionSummary(
            focusProject: focus.primaryProject,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            projectUsages: activeUsages,
            insightBrief: insightBrief,
            retrievalHealth: retrievalHealth,
            aggregator: aggregator,
            chatController: chatController,
            decisions: decisions
        )
        let direction = buildDirectionSummary(
            focus: focus,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            projectUsages: activeUsages,
            insightBrief: insightBrief,
            rollupFreshness: insightBrief.rollupFreshness,
            rollupStatusMessage: insightBrief.rollupStatusMessage,
            retrievalHealth: retrievalHealth,
            settingsManager: settingsManager,
            decisions: decisions
        )
        let burn = buildBurnSummary(
            focusProject: focus.primaryProject,
            projectUsages: activeUsages
        )
        let freshness = buildFreshnessSummary(
            focus: focus,
            dataStore: dataStore,
            settingsManager: settingsManager,
            aggregator: aggregator,
            rollupFreshness: insightBrief.rollupFreshness,
            rollupStatusMessage: insightBrief.rollupStatusMessage,
            retrievalHealth: retrievalHealth
        )
        let evidence = buildEvidenceSummary(
            focusProject: focus.primaryProject,
            projectConversations: projectConversations,
            latestConversation: latestConversation,
            settingsManager: settingsManager,
            insightBrief: insightBrief,
            direction: direction,
            freshness: freshness
        )
        let actions = buildActions(
            projectName: focus.primaryProject,
            mission: mission,
            direction: direction
        )
        let controllerRuntime = buildControllerRuntime(
            cached: cachedControllerRuntime,
            daemonStatus: daemonStatus,
            projectName: focus.primaryProject,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            mission: mission,
            direction: direction,
            burn: burn,
            freshness: freshness,
            settingsManager: settingsManager,
            history: history
        )

        let compactSummary = buildCompactSummary(
            projectName: focus.primaryProject,
            mission: mission,
            direction: direction,
            burn: burn
        )
        let pendingHighlight = controllerRuntime.compactHighlight
            ?? actions.first(where: { $0.available })?.reason

        return OpenBurnBarOperatingSnapshot(
            updatedAt: freshness.updatedAt ?? Date(),
            projectName: focus.primaryProject,
            secondaryProjectName: focus.secondaryProject,
            mission: mission,
            direction: direction,
            burn: burn,
            freshness: freshness,
            evidence: evidence,
            availableActions: actions,
            recentHistory: history,
            controllerRuntime: controllerRuntime,
            compactSummary: compactSummary,
            pendingHighlight: pendingHighlight
        )
    }

    private static func decisionState(
        from actionRecords: [OpenBurnBarOperatingActionRecord]
    ) -> OpenBurnBarOperatingDecisionState {
        var state = OpenBurnBarOperatingDecisionState()

        for record in actionRecords {
            switch record.actionKind {
            case .missionApproval:
                guard let missionFingerprint = record.missionFingerprint else { continue }
                if state.missionApprovalsByProject[record.projectName] == nil {
                    state.missionApprovalsByProject[record.projectName] = OpenBurnBarMissionApprovalRecord(
                        projectName: record.projectName,
                        missionFingerprint: missionFingerprint,
                        note: record.detail ?? "",
                        approvedAt: record.createdAt
                    )
                }
            case .directionOverride:
                if state.directionOverridesByProject[record.projectName] == nil {
                    state.directionOverridesByProject[record.projectName] = OpenBurnBarDirectionOverrideRecord(
                        projectName: record.projectName,
                        mode: record.overrideMode ?? .annotate,
                        forcedStatus: record.forcedDirectionStatus,
                        summary: record.summary,
                        rationale: record.detail ?? "",
                        createdAt: record.createdAt
                    )
                }
            case .missionCreation:
                // Mission creation is recorded in history but doesn't affect decision state
                break
            }
        }

        return state
    }

    private static func historyEntries(
        from actionRecords: [OpenBurnBarOperatingActionRecord],
        focusProject: String?
    ) -> [OpenBurnBarOperatingHistoryEntry] {
        let scoped = actionRecords.filter { record in
            guard let focusProject else { return true }
            return record.projectName == focusProject
        }
        return scoped.prefix(6).map { record in
            OpenBurnBarOperatingHistoryEntry(
                id: record.id,
                kind: record.actionKind,
                title: historyTitle(for: record),
                summary: record.summary,
                detail: record.detail,
                createdAt: record.createdAt
            )
        }
    }

    private static func buildControllerRuntime(
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

    private static func filterByPrimaryProject<T>(
        _ items: [T],
        _ primaryProject: String?,
        projectName: (T) -> String
    ) -> [T] {
        guard let primaryProject else { return [] }
        return items.filter { normalizeProjectName(projectName($0)) == primaryProject }
    }

    private static func questionSemanticKey(_ question: OpenBurnBarControllerQuestion) -> String {
        if let sessionID = question.sessionID?.nonEmpty {
            return "session|\(sessionID)"
        }
        let normalizedProject = question.projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrompt = question.prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "project|\(normalizedProject)|\(normalizedPrompt)"
    }

    private static func buildMissionSummary(
        focusProject: String?,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage],
        insightBrief: InsightBriefSnapshot,
        retrievalHealth: RetrievalSystemHealthSnapshot,
        aggregator: UsageAggregator?,
        chatController: ChatSessionController?,
        decisions: OpenBurnBarOperatingDecisionState
    ) -> OpenBurnBarMissionSummary {
        guard let focusProject else {
            return OpenBurnBarMissionSummary(
                availability: .missing,
                missionID: "",
                projectName: "",
                title: "No active mission yet",
                subtitle: "OpenBurnBar needs a recent local project conversation before it can name the current mission.",
                state: .planned,
                approval: .pending,
                sessionCount: 0,
                summarizedSessionCount: 0,
                burnRecordCount: 0,
                totalTokens: 0,
                estimatedCostUSD: 0,
                recommendationSummary: "Run a local scan or index a recent project conversation to make the mission legible.",
                approvalNote: nil
            )
        }

        let title = latestConversation?.summaryTitle
            ?? latestConversation?.inferredTaskTitle
            ?? insightBrief.heaviestTaskTitle
            ?? "Recent work in \(focusProject)"
        let state = inferMissionState(
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            projectUsages: projectUsages,
            insightBrief: insightBrief,
            retrievalHealth: retrievalHealth,
            isRefreshing: aggregator?.isRefreshing == true,
            isStreaming: chatController?.isStreaming == true,
        )
        let missionID = missionFingerprint(
            projectName: focusProject,
            conversation: latestConversation
        )
        let approvalRecord = decisions.missionApprovalsByProject[focusProject]
        let approval: OpenBurnBarMissionApprovalState = approvalRecord?.missionFingerprint == missionID ? .approved : .pending
        let subtitle = missionSubtitle(
            title: title,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            projectUsages: projectUsages
        )
        let recommendation = buildMissionRecommendation(
            state: state,
            latestConversation: latestConversation,
            insightBrief: insightBrief,
            focusProject: focusProject,
            approval: approval,
            projectConversations: projectConversations,
            projectUsages: projectUsages,
            retrievalHealth: retrievalHealth
        )

        return OpenBurnBarMissionSummary(
            availability: .available,
            missionID: missionID,
            projectName: focusProject,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Recent work in \(focusProject)",
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "OpenBurnBar has a lightweight read of the latest checkpoint.",
            state: state,
            approval: approval,
            sessionCount: projectConversations.count,
            summarizedSessionCount: projectConversations.filter { ($0.summary?.isEmpty == false) || ($0.summaryTitle?.isEmpty == false) }.count,
            burnRecordCount: projectUsages.count,
            totalTokens: projectUsages.reduce(0) { $0 + $1.totalTokens },
            estimatedCostUSD: projectUsages.reduce(0) { $0 + $1.cost },
            recommendationSummary: recommendation,
            approvalNote: approvalRecord?.note.nonEmpty
        )
    }

    private static func buildDirectionSummary(
        focus: ProjectFocus,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage],
        insightBrief: InsightBriefSnapshot,
        rollupFreshness: InsightRollupFreshness,
        rollupStatusMessage: String?,
        retrievalHealth: RetrievalSystemHealthSnapshot,
        settingsManager: SettingsManager,
        decisions: OpenBurnBarOperatingDecisionState
    ) -> OpenBurnBarDirectionSummary {
        guard let focusProject = focus.primaryProject else {
            return OpenBurnBarDirectionSummary(
                availability: .missing,
                projectName: "",
                title: "No direction signal yet",
                status: .notEnoughSignal,
                summary: "OpenBurnBar needs recent local work before it can tell whether execution still matches intent.",
                scopeLabel: "Workspace",
                freshness: .unknown,
                mode: .sparse,
                sparseReason: "No active project could be inferred from the local index.",
                nextActions: ["Run a scan or point OpenBurnBar at your agent log folders."],
                overrideSummary: nil
            )
        }

        let overrideRecord = decisions.directionOverridesByProject[focusProject]
        let freshness = freshnessForEvidence(
            rollupFreshness: rollupFreshness,
            latestConversation: latestConversation
        )

        if let overrideRecord {
            let forced = overrideRecord.forcedStatus ?? inferredOverrideDirectionStatus(
                focus: focus,
                latestConversation: latestConversation,
                projectConversations: projectConversations,
                projectUsages: projectUsages,
                insightBrief: insightBrief,
                retrievalHealth: retrievalHealth,
                indexingEnabled: settingsManager.conversationIndexingEnabled
            )
            let mode: OpenBurnBarDirectionMode = overrideRecord.mode == .annotate ? .overrideAnnotating : .overrideSuperseding
            return OpenBurnBarDirectionSummary(
                availability: .available,
                projectName: focusProject,
                title: "Operator override",
                status: forced,
                summary: overrideRecord.summary,
                scopeLabel: focus.scopeLabel,
                freshness: freshness,
                mode: mode,
                sparseReason: nil,
                nextActions: [overrideRecord.rationale],
                overrideSummary: overrideRecord.summary
            )
        }

        if settingsManager.conversationIndexingEnabled == false {
            return OpenBurnBarDirectionSummary(
                availability: .sparse,
                projectName: focusProject,
                title: "Direction is inferred from metadata",
                status: .notEnoughSignal,
                summary: "Direction is provisional because transcript indexing is off. OpenBurnBar can see project activity and burn, but not grounded evidence.",
                scopeLabel: focus.scopeLabel,
                freshness: freshness,
                mode: .sparse,
                sparseReason: "Turn on local indexing to let OpenBurnBar quote indexed sessions and explain drift with evidence.",
                nextActions: ["Enable conversation indexing in Settings.", "Run another local scan once indexing is on."],
                overrideSummary: overrideRecord?.summary
            )
        }

        if projectConversations.count < 5 {
            return OpenBurnBarDirectionSummary(
                availability: .sparse,
                projectName: focusProject,
                title: "Direction signal is still sparse",
                status: .notEnoughSignal,
                summary: "OpenBurnBar can name the active project, but there are not enough indexed checkpoints to judge alignment with confidence.",
                scopeLabel: focus.scopeLabel,
                freshness: freshness,
                mode: .sparse,
                sparseReason: "Only \(projectConversations.count) indexed conversation\(projectConversations.count == 1 ? "" : "s") were available for \(focusProject).",
                nextActions: [
                    "Let OpenBurnBar ingest \(max(5 - projectConversations.count, 1)) more conversation checkpoint\(max(5 - projectConversations.count, 1) == 1 ? "" : "s") for \(focusProject).",
                    "Add a direction override now if you already know the intended call."
                ],
                overrideSummary: overrideRecord?.summary
            )
        }

        let assessment = assessDirection(
            focus: focus,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            projectUsages: projectUsages,
            insightBrief: insightBrief,
            retrievalHealth: retrievalHealth
        )
        let status = assessment.status
        let summary = directionSummaryText(
            assessment: assessment,
            focusProject: focusProject,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            projectUsages: projectUsages,
            insightBrief: insightBrief,
            rollupStatusMessage: rollupStatusMessage,
            retrievalHealth: retrievalHealth
        )
        let nextActions = directionNextActions(
            assessment: assessment,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            projectUsages: projectUsages,
            insightBrief: insightBrief,
            retrievalHealth: retrievalHealth
        )

        return OpenBurnBarDirectionSummary(
            availability: .available,
            projectName: focusProject,
            title: "Current read on \(focusProject)",
            status: status,
            summary: summary,
            scopeLabel: focus.scopeLabel,
            freshness: freshness,
            mode: .inferred,
            sparseReason: nil,
            nextActions: nextActions,
            overrideSummary: nil
        )
    }

    private static func burnSummaryEmpty(
        availability: OpenBurnBarOperatingAvailability,
        projectName: String,
        windowLabel: String
    ) -> OpenBurnBarBurnSummary {
        OpenBurnBarBurnSummary(
            availability: availability,
            projectName: projectName,
            sessionCount: 0,
            burnRecordCount: 0,
            totalTokens: 0,
            estimatedCostUSD: 0,
            latestSource: nil,
            dominantModel: nil,
            windowLabel: windowLabel
        )
    }

    private static func buildBurnSummary(
        focusProject: String?,
        projectUsages: [TokenUsage]
    ) -> OpenBurnBarBurnSummary {
        guard let focusProject else {
            return burnSummaryEmpty(availability: .missing, projectName: "", windowLabel: "No burn signal yet")
        }

        guard projectUsages.isEmpty == false else {
            return burnSummaryEmpty(
                availability: .sparse,
                projectName: focusProject,
                windowLabel: "No recent usage rows have been attributed to this project yet."
            )
        }

        let latestUsage = projectUsages.sorted(by: { $0.endTime > $1.endTime }).first
        let dominantModel = Dictionary(grouping: projectUsages, by: \.model)
            .mapValues { entries in entries.reduce(0) { $0 + $1.cost } }
            .max(by: { $0.value < $1.value })?
            .key

        return OpenBurnBarBurnSummary(
            availability: .available,
            projectName: focusProject,
            sessionCount: Set(projectUsages.map { "\($0.provider.rawValue):\($0.sessionId)" }).count,
            burnRecordCount: projectUsages.count,
            totalTokens: projectUsages.reduce(0) { $0 + $1.totalTokens },
            estimatedCostUSD: projectUsages.reduce(0) { $0 + $1.cost },
            latestSource: latestUsage?.provider.displayName,
            dominantModel: dominantModel,
            windowLabel: projectUsages.count == 1 ? "Latest indexed session" : "Recent indexed work"
        )
    }

    private static func buildFreshnessSummary(
        focus: ProjectFocus,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        aggregator: UsageAggregator?,
        rollupFreshness: InsightRollupFreshness,
        rollupStatusMessage: String?,
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> OpenBurnBarFreshnessSummary {
        var reasons = retrievalHealth.degradedModes.map(\.message)

        if settingsManager.conversationIndexingEnabled == false {
            reasons.append("Direction and evidence are being inferred from scan metadata only.")
        }
        if let secondary = focus.secondaryProject {
            reasons.append("Recent work is split between \(focus.primaryProject ?? "multiple projects") and \(secondary), so OpenBurnBar is treating direction as provisional.")
        }
        switch rollupFreshness {
        case .fresh:
            break
        case .stale:
            reasons.append(rollupStatusMessage ?? "Workflow insights are stale.")
        case .rebuilding:
            reasons.append(rollupStatusMessage ?? "Workflow insights are rebuilding.")
        case .unavailable:
            reasons.append(rollupStatusMessage ?? "Workflow insights are unavailable.")
        }

        let updatedAt = maxDate([
            dataStore.lastRefresh,
            retrievalHealth.observedAt == .distantPast ? nil : retrievalHealth.observedAt
        ])

        if dataStore.lastRefresh == nil {
            return OpenBurnBarFreshnessSummary(
                status: .missing,
                provisional: true,
                updatedAt: updatedAt,
                reasons: ["OpenBurnBar has not completed its first local scan yet."]
            )
        }

        if aggregator?.isRefreshing == true {
            return OpenBurnBarFreshnessSummary(
                status: .live,
                provisional: true,
                updatedAt: updatedAt,
                reasons: ["OpenBurnBar is actively refreshing local logs right now."]
            )
        }

        let age = Date().timeIntervalSince(dataStore.lastRefresh ?? .distantPast)
        if reasons.isEmpty {
            let status: OpenBurnBarFreshnessKind = age > 30 * 60 ? .stale : .live
            let ageReason = age > 30 * 60 ? ["The last local scan is older than thirty minutes."] : []
            return OpenBurnBarFreshnessSummary(
                status: status,
                provisional: false,
                updatedAt: updatedAt,
                reasons: ageReason
            )
        }

        let status: OpenBurnBarFreshnessKind = age > 30 * 60 ? .stale : .provisional
        return OpenBurnBarFreshnessSummary(
            status: status,
            provisional: true,
            updatedAt: updatedAt,
            reasons: reasons
        )
    }

    private static func emptyEvidenceSummary(
        availability: OpenBurnBarOperatingAvailability,
        projectName: String,
        summary: String,
        sparseReason: String?,
        majorExclusions: [String] = []
    ) -> OpenBurnBarEvidenceSummary {
        OpenBurnBarEvidenceSummary(
            availability: availability,
            projectName: projectName,
            freshness: .unknown,
            summary: summary,
            sparseReason: sparseReason,
            entries: [],
            inclusionReasons: [],
            majorExclusions: majorExclusions,
            support: [],
            contradictions: []
        )
    }

    private static func buildEvidenceSummary(
        focusProject: String?,
        projectConversations: [ConversationRecord],
        latestConversation: ConversationRecord?,
        settingsManager: SettingsManager,
        insightBrief: InsightBriefSnapshot,
        direction: OpenBurnBarDirectionSummary,
        freshness: OpenBurnBarFreshnessSummary
    ) -> OpenBurnBarEvidenceSummary {
        guard let focusProject else {
            return emptyEvidenceSummary(
                availability: .missing,
                projectName: "",
                summary: "No evidence is available yet.",
                sparseReason: "OpenBurnBar has not resolved an active project."
            )
        }

        guard settingsManager.conversationIndexingEnabled else {
            return emptyEvidenceSummary(
                availability: .sparse,
                projectName: focusProject,
                summary: "Evidence is limited to metadata until transcript indexing is enabled.",
                sparseReason: "Turn on local indexing to see transcript-grounded evidence previews.",
                majorExclusions: ["Transcript excerpts are excluded because local indexing is currently off."]
            )
        }

        guard projectConversations.isEmpty == false else {
            return emptyEvidenceSummary(
                availability: .missing,
                projectName: focusProject,
                summary: "OpenBurnBar does not have indexed sessions for this project yet.",
                sparseReason: nil,
                majorExclusions: ["No indexed sessions were available for \(focusProject)."]
            )
        }

        let entries = Array(projectConversations.prefix(3).enumerated()).map { index, conversation in
            OpenBurnBarEvidenceEntry(
                id: conversation.id,
                sourceLabel: conversation.summaryTitle?.nonEmpty
                    ?? conversation.inferredTaskTitle.nonEmpty
                    ?? conversation.provider.displayName,
                summary: conversation.summary?.nonEmpty
                    ?? truncated(conversation.lastAssistantMessage, limit: 140),
                detail: [
                    conversation.provider.displayName,
                    conversation.endTime?.formatted(date: .abbreviated, time: .shortened)
                        ?? conversation.indexedAt.formatted(date: .abbreviated, time: .shortened),
                    truncated(conversation.lastAssistantMessage, limit: 160),
                ]
                .compactMap { $0?.nonEmpty }
                .joined(separator: " · "),
                includedReason: evidenceReason(index: index, latestConversation: latestConversation, conversation: conversation),
                freshness: freshnessForConversation(conversation)
            )
        }

        let support = buildSupportJudgments(
            focusProject: focusProject,
            direction: direction,
            insightBrief: insightBrief,
            entries: entries
        )
        let contradictions = buildContradictionJudgments(
            latestConversation: latestConversation,
            direction: direction,
            freshness: freshness,
            insightBrief: insightBrief
        )

        let majorExclusions: [String] = {
            var exclusions: [String] = []
            if projectConversations.count < 3 {
                exclusions.append("Only \(projectConversations.count) recent indexed session\(projectConversations.count == 1 ? "" : "s") were available for \(focusProject).")
            }
            if freshness.provisional {
                exclusions.append("Some supporting signals are provisional because the local index is still catching up.")
            }
            return exclusions
        }()

        return OpenBurnBarEvidenceSummary(
            availability: projectConversations.count < 2 ? .sparse : .available,
            projectName: focusProject,
            freshness: entries.contains(where: { $0.freshness == .stale }) ? .stale : .fresh,
            summary: "\(entries.count) recent indexed checkpoint\(entries.count == 1 ? "" : "s") ground OpenBurnBar's read of \(focusProject).",
            sparseReason: projectConversations.count < 2 ? "Only one grounded checkpoint is available right now." : nil,
            entries: entries,
            inclusionReasons: [
                "Most recent indexed sessions for \(focusProject).",
                "Latest assistant checkpoints with project-specific burn attached."
            ],
            majorExclusions: majorExclusions,
            support: support,
            contradictions: contradictions
        )
    }

    private static func buildActions(
        projectName: String?,
        mission: OpenBurnBarMissionSummary,
        direction: OpenBurnBarDirectionSummary
    ) -> [OpenBurnBarActionAvailability] {
        let missionApproval: OpenBurnBarActionAvailability = {
            guard mission.availability == .available, mission.missionID.isEmpty == false else {
                return OpenBurnBarActionAvailability(
                    kind: .missionApproval,
                    available: false,
                    reason: "OpenBurnBar has not resolved a local mission to approve yet.",
                    title: OpenBurnBarActionKind.missionApproval.label
                )
            }
            if mission.approval == .approved {
                return OpenBurnBarActionAvailability(
                    kind: .missionApproval,
                    available: false,
                    reason: "The current mission checkpoint is already approved.",
                    title: "Mission Approved"
                )
            }
            return OpenBurnBarActionAvailability(
                kind: .missionApproval,
                available: true,
                reason: "Operator sign-off is still pending for the current mission.",
                title: OpenBurnBarActionKind.missionApproval.label
            )
        }()

        let directionOverride: OpenBurnBarActionAvailability = {
            guard let projectName, direction.availability != .missing else {
                return OpenBurnBarActionAvailability(
                    kind: .directionOverride,
                    available: false,
                    reason: "OpenBurnBar needs an active project before you can steer direction.",
                    title: OpenBurnBarActionKind.directionOverride.label
                )
            }
            return OpenBurnBarActionAvailability(
                kind: .directionOverride,
                available: true,
                reason: "You can record an explicit direction call for \(projectName).",
                title: direction.mode == .overrideAnnotating || direction.mode == .overrideSuperseding
                    ? "Update Override"
                    : OpenBurnBarActionKind.directionOverride.label
            )
        }()

        return [missionApproval, directionOverride]
    }

    private static func buildCompactSummary(
        projectName: String?,
        mission: OpenBurnBarMissionSummary,
        direction: OpenBurnBarDirectionSummary,
        burn: OpenBurnBarBurnSummary
    ) -> String {
        let project = projectName ?? "workspace"
        if mission.availability == .missing {
            return "OpenBurnBar is waiting on a first live project checkpoint."
        }
        return "\(project): \(mission.title) • \(direction.status.label.lowercased()) • \(burn.estimatedCostUSD.formatAsCost())"
    }

    private static func directionSummaryText(
        assessment: DirectionAssessmentEvidence,
        focusProject: String,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage],
        insightBrief: InsightBriefSnapshot,
        rollupStatusMessage: String?,
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> String {
        let latestTitle = latestConversation?.summaryTitle?.nonEmpty
            ?? latestConversation?.inferredTaskTitle.nonEmpty
            ?? focusProject
        let lastActivity = latestActivityDate(
            latestConversation: latestConversation,
            projectUsages: projectUsages
        )
        let sessionCount = Set(projectUsages.map { "\($0.provider.rawValue):\($0.sessionId)" }).count
        let totalCost = projectUsages.reduce(0) { $0 + $1.cost }

        switch assessment.status {
        case .aligned:
            let activityClause = lastActivity.map { "Last activity was \(relativeTimeString(since: $0))." }
                ?? "Recent activity is concentrated on \(focusProject)."
            return "\(assessment.leadingSignal) \(activityClause) \(sessionCount) session\(sessionCount == 1 ? "" : "s") account for \(totalCost.formatAsCost()) of recent burn around “\(latestTitle)”."
        case .drifting:
            return "\(assessment.leadingSignal) Latest checkpoint “\(latestTitle)” is the current anchor, but the data still points to open work after \(sessionCount) session\(sessionCount == 1 ? "" : "s") and \(totalCost.formatAsCost())."
        case .ambiguous:
            return assessment.leadingSignal.nonEmpty
                ?? rollupStatusMessage?.nonEmpty
                ?? retrievalHealth.degradedModes.first?.message
                ?? "OpenBurnBar can see activity in \(focusProject), but the signal is mixed across recency, evidence freshness, or burn."
        case .notEnoughSignal:
            return "OpenBurnBar only has \(projectConversations.count) project conversation checkpoint\(projectConversations.count == 1 ? "" : "s") for \(focusProject), so the direction call is still provisional."
        }
    }

    private static func directionNextActions(
        assessment: DirectionAssessmentEvidence,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage],
        insightBrief: InsightBriefSnapshot,
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> [String] {
        let latestTitle = latestConversation?.summaryTitle?.nonEmpty
            ?? latestConversation?.inferredTaskTitle.nonEmpty
            ?? "the latest checkpoint"
        let lastActivity = latestActivityDate(
            latestConversation: latestConversation,
            projectUsages: projectUsages
        )

        switch assessment.status {
        case .aligned:
            return [
                "Keep executing from “\(latestTitle)” while the signal stays concentrated here.",
                "Approve the mission if this checkpoint should remain the carried-forward plan."
            ]
        case .drifting:
            return [
                insightBrief.incompleteHint?.nonEmpty
                    ?? "Resolve the open handoff in “\(latestTitle)”.",
                lastActivity.map { "Refresh the project with a new summarized checkpoint; the last activity was \($0.formatted(date: .omitted, time: .shortened))." }
                    ?? "Use a direction override if you already know the new call."
            ]
        case .ambiguous:
            return assessment.nextActions.nonEmptyArray
                ?? retrievalHealth.degradedModes.prefix(2).map(\.message).nonEmptyArray
                ?? ["Let OpenBurnBar finish refreshing the local index before you trust the direction call."]
        case .notEnoughSignal:
            return [
                latestConversation?.summaryTitle?.nonEmpty.map { "Summarize and continue “\($0)”." }
                    ?? "Let OpenBurnBar ingest another checkpoint for this project.",
                "Record an override if you already know the intended direction."
            ]
        }
    }

    private static func buildMissionRecommendation(
        state: OpenBurnBarMissionLifecycle,
        latestConversation: ConversationRecord?,
        insightBrief: InsightBriefSnapshot,
        focusProject: String,
        approval: OpenBurnBarMissionApprovalState,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage],
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> String {
        let latestTitle = latestConversation?.summaryTitle?.nonEmpty
            ?? latestConversation?.inferredTaskTitle.nonEmpty
            ?? focusProject
        let sessionCount = Set(projectUsages.map { "\($0.provider.rawValue):\($0.sessionId)" }).count
        let totalCost = projectUsages.reduce(0) { $0 + $1.cost }
        let lastActivity = latestActivityDate(
            latestConversation: latestConversation,
            projectUsages: projectUsages
        )

        if approval == .approved {
            return "Approved checkpoint “\(latestTitle)” is carrying \(sessionCount) recent session\(sessionCount == 1 ? "" : "s") and \(totalCost.formatAsCost()) for \(focusProject)."
        }
        switch state {
        case .blocked:
            return retrievalHealthFailureSummary(retrievalHealth)
                ?? "A retrieval or indexing failure is blocking a confident mission read for \(focusProject)."
        case .partial:
            return insightBrief.incompleteHint?.nonEmpty
                ?? "Latest checkpoint “\(latestTitle)” still looks open after \(sessionCount) session\(sessionCount == 1 ? "" : "s")."
        case .completed:
            return "Latest summarized checkpoint “\(latestTitle)” cooled \(lastActivity.map { relativeTimeString(since: $0) } ?? "recently") after \(sessionCount) session\(sessionCount == 1 ? "" : "s") and \(totalCost.formatAsCost())."
        case .running:
            return "Fresh activity \(lastActivity.map { relativeTimeString(since: $0) } ?? "just landed") keeps “\(latestTitle)” live across \(sessionCount) session\(sessionCount == 1 ? "" : "s")."
        case .planned:
            return "OpenBurnBar can name “\(latestTitle),” but \(projectConversations.count) conversation checkpoint\(projectConversations.count == 1 ? "" : "s") is still closer to plan than active execution."
        }
    }

    private static func historyTitle(for record: OpenBurnBarOperatingActionRecord) -> String {
        switch record.actionKind {
        case .missionApproval:
            return "Mission approved"
        case .missionCreation:
            return "Mission created"
        case .directionOverride:
            if record.overrideMode == .supersedeStatus {
                return "Direction overridden"
            }
            return "Direction annotated"
        }
    }

    private static func buildSupportJudgments(
        focusProject: String,
        direction: OpenBurnBarDirectionSummary,
        insightBrief: InsightBriefSnapshot,
        entries: [OpenBurnBarEvidenceEntry]
    ) -> [OpenBurnBarEvidenceJudgment] {
        var judgments: [OpenBurnBarEvidenceJudgment] = []
        if entries.isEmpty == false {
            judgments.append(
                OpenBurnBarEvidenceJudgment(
                    id: "support-recency",
                    summary: "Recent work still clusters on \(focusProject).",
                    detail: "OpenBurnBar is grounding direction against the newest indexed checkpoints instead of a stale aggregate."
                )
            )
        }
        if let modelShift = insightBrief.modelShiftHeadline?.nonEmpty {
            judgments.append(
                OpenBurnBarEvidenceJudgment(
                    id: "support-model-shift",
                    summary: modelShift,
                    detail: "OpenBurnBar kept the current model-shift rollup in view while judging direction."
                )
            )
        }
        if direction.status == .aligned {
            judgments.append(
                OpenBurnBarEvidenceJudgment(
                    id: "support-aligned",
                    summary: "The latest checkpoint still sounds coherent with the active project.",
                    detail: entries.first?.summary ?? direction.summary
                )
            )
        }
        return judgments
    }

    private static func buildContradictionJudgments(
        latestConversation: ConversationRecord?,
        direction: OpenBurnBarDirectionSummary,
        freshness: OpenBurnBarFreshnessSummary,
        insightBrief: InsightBriefSnapshot
    ) -> [OpenBurnBarEvidenceJudgment] {
        var judgments: [OpenBurnBarEvidenceJudgment] = []
        if let incompleteHint = insightBrief.incompleteHint?.nonEmpty {
            judgments.append(
                OpenBurnBarEvidenceJudgment(
                    id: "contradiction-open-loop",
                    summary: "The latest checkpoint still looks unfinished.",
                    detail: incompleteHint
                )
            )
        }
        if freshness.provisional, let reason = freshness.reasons.first {
            judgments.append(
                OpenBurnBarEvidenceJudgment(
                    id: "contradiction-freshness",
                    summary: "Some of the evidence is still provisional.",
                    detail: reason
                )
            )
        }
        if direction.status == .drifting {
            judgments.append(
                OpenBurnBarEvidenceJudgment(
                    id: "contradiction-drift",
                    summary: "OpenBurnBar thinks the current work needs steering.",
                    detail: latestConversation?.summary?.nonEmpty
                        ?? latestConversation?.lastAssistantMessage.nonEmpty
                        ?? direction.summary
                )
            )
        }
        return judgments
    }

    private static func inferMissionState(
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage],
        insightBrief: InsightBriefSnapshot,
        retrievalHealth: RetrievalSystemHealthSnapshot,
        isRefreshing: Bool,
        isStreaming: Bool
    ) -> OpenBurnBarMissionLifecycle {
        if isRefreshing || isStreaming {
            return .running
        }
        if missionReadIsBlockedByRetrievalFailure(retrievalHealth) {
            return .blocked
        }
        if insightBrief.incompleteHint?.nonEmpty != nil {
            return .partial
        }
        let lastConversationAt = latestConversationActivityDate(latestConversation)
        let lastUsageAt = projectUsages.map(\.endTime).max()
        let lastActivity = maxDate([lastConversationAt, lastUsageAt])
        if let lastActivity, Date().timeIntervalSince(lastActivity) <= 90 * 60 {
            return .running
        }
        if latestConversation?.summary?.nonEmpty != nil
            || latestConversation?.summaryTitle?.nonEmpty != nil {
            if let lastActivity, Date().timeIntervalSince(lastActivity) >= 3 * 60 * 60 {
                return .completed
            }
        }
        if lastConversationAt == nil || Date().timeIntervalSince(lastConversationAt ?? .distantPast) >= 24 * 60 * 60 {
            return .planned
        }
        if projectConversations.count >= 2 {
            return .running
        }
        return .planned
    }

    private static func assessDirection(
        focus: ProjectFocus,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage],
        insightBrief: InsightBriefSnapshot,
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> DirectionAssessmentEvidence {
        if projectConversations.count < 5 {
            return DirectionAssessmentEvidence(
                status: .notEnoughSignal,
                leadingSignal: "Only \(projectConversations.count) indexed conversation\(projectConversations.count == 1 ? "" : "s") are available for \(focus.primaryProject ?? "this project") so far.",
                nextActions: []
            )
        }

        var score = 0
        var strongestSignal = ""
        var strongestWeight = 0
        var nextActions: [String] = []

        func record(weight: Int, _ message: String) {
            score += weight
            guard abs(weight) > abs(strongestWeight) else { return }
            strongestWeight = weight
            strongestSignal = message
        }

        let dominance = focus.dominanceRatio
        if dominance >= 0.72 {
            record(weight: 3, "\(focus.primaryProject ?? "This project") owns \(Int((dominance * 100).rounded()))% of the recent project signal.")
        } else if dominance < 0.58 {
            record(weight: -1, "Project dominance is weak at \(Int((dominance * 100).rounded()))%, so the lead is not decisive yet.")
        }

        if let latestConversation, (latestConversation.summary?.nonEmpty != nil || latestConversation.summaryTitle?.nonEmpty != nil) {
            record(weight: 2, "Latest checkpoint “\(latestConversation.summaryTitle?.nonEmpty ?? latestConversation.inferredTaskTitle)” is summarized and grounded.")
        } else {
            record(weight: -1, "The latest checkpoint still lacks a structured summary.")
        }

        if let lastActivity = latestActivityDate(latestConversation: latestConversation, projectUsages: projectUsages) {
            let age = Date().timeIntervalSince(lastActivity)
            if age <= 90 * 60 {
                record(weight: 1, "Fresh project activity landed \(relativeTimeString(since: lastActivity)).")
            } else if age >= 24 * 60 * 60 {
                record(weight: -2, "The project has been quiet since \(relativeTimeString(since: lastActivity)).")
            }
        }

        if projectUsages.reduce(0) { $0 + $1.cost } >= 3 || Set(projectUsages.map(\.sessionId)).count >= 2 {
            record(weight: 1, "Recent burn is concentrated in active sessions for the lead project.")
        }

        if insightBrief.incompleteHint?.nonEmpty != nil {
            record(weight: -3, insightBrief.incompleteHint ?? "The latest checkpoint still ends with an unfinished handoff.")
        }

        var competitionSignal: String?
        if focus.secondaryProject != nil {
            let competitorCost = focus.secondaryMetrics?.recentBurnCost ?? 0
            let competitorActivity = focus.secondaryMetrics?.lastActivityDate.map { relativeTimeString(since: $0) } ?? "recently"
            let message = "\(focus.secondaryProject ?? "A second project") is still competing with \(competitorCost.formatAsCost()) of recent burn and activity \(competitorActivity)."
            competitionSignal = message
            record(weight: -2, message)
            nextActions.append("Decide whether \(focus.primaryProject ?? "the primary project") or \(focus.secondaryProject ?? "the secondary project") is the current priority.")
        }

        if retrievalHealth.degradedModes.contains(where: { $0.mode == .indexStale || $0.mode == .rebuildInProgress }) {
            record(weight: -2, retrievalHealth.degradedModes.first?.message ?? "The local index is rebuilding, so the direction read is provisional.")
            nextActions.append("Let the local index finish catching up before trusting the direction call.")
        }

        if focus.secondaryProject != nil || retrievalHealth.degradedModes.contains(where: { $0.mode == .indexStale || $0.mode == .rebuildInProgress }) {
            return DirectionAssessmentEvidence(
                status: score <= -3 && insightBrief.incompleteHint?.nonEmpty != nil ? .drifting : .ambiguous,
                leadingSignal: competitionSignal ?? strongestSignal,
                nextActions: nextActions
            )
        }

        let status: OpenBurnBarDirectionAssessment
        if score >= 4 {
            status = .aligned
        } else if score <= -2 {
            status = .drifting
        } else {
            status = .ambiguous
        }

        return DirectionAssessmentEvidence(
            status: status,
            leadingSignal: strongestSignal,
            nextActions: nextActions
        )
    }

    private static func selectProjectFocus(
        conversations: [ConversationRecord],
        usages: [TokenUsage]
    ) -> ProjectFocus {
        var metricsByProject: [String: ProjectSignalMetrics] = [:]
        for (index, conversation) in conversations.enumerated() {
            let project = normalizeProjectName(conversation.projectName)
            guard project.isEmpty == false else { continue }
            let activityDate = latestConversationActivityDate(conversation) ?? conversation.indexedAt
            var metrics = metricsByProject[project] ?? ProjectSignalMetrics(projectName: project)
            metrics.score += Double(max(18 - index, 2))
            metrics.conversationCount += 1
            metrics.lastConversationAt = maxDate([metrics.lastConversationAt, activityDate])
            metrics.lastActivityDate = maxDate([metrics.lastActivityDate, activityDate])
            if activityDate >= Date().addingTimeInterval(-24 * 60 * 60) {
                metrics.recentConversationCount += 1
            }
            if conversation.summary?.nonEmpty != nil || conversation.summaryTitle?.nonEmpty != nil {
                metrics.summarizedConversationCount += 1
            }
            metricsByProject[project] = metrics
        }
        let oneWeekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for usage in usages where usage.startTime >= oneWeekAgo {
            let project = normalizeProjectName(usage.projectName)
            guard project.isEmpty == false else { continue }
            let weight = max(1, min(usage.cost * 6, Double(usage.totalTokens) / 100_000))
            var metrics = metricsByProject[project] ?? ProjectSignalMetrics(projectName: project)
            metrics.score += weight
            metrics.recentBurnCost += usage.cost
            metrics.lastUsageAt = maxDate([metrics.lastUsageAt, usage.endTime])
            metrics.lastActivityDate = maxDate([metrics.lastActivityDate, usage.endTime])
            metricsByProject[project] = metrics
        }
        let sorted = metricsByProject.values.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        let primaryMetrics = sorted.first
        let secondaryMetrics = sorted.dropFirst().first
        let meaningfulCompetition = meaningfulSecondaryCompetition(
            primary: primaryMetrics,
            secondary: secondaryMetrics
        )
        return ProjectFocus(
            primaryMetrics: primaryMetrics,
            secondaryMetrics: meaningfulCompetition ? secondaryMetrics : nil,
            totalConversationCount: conversations.count
        )
    }

    private static func missionFingerprint(
        projectName: String,
        conversation: ConversationRecord?
    ) -> String {
        let title = stableMissionComponent(
            conversation?.summaryTitle?.nonEmpty
                ?? conversation?.inferredTaskTitle.nonEmpty
                ?? "untitled"
        )
        let parts = [
            stableMissionComponent(projectName),
            title,
            stableMissionSummarySignature(
                conversation: conversation,
                normalizedTitle: title
            )
        ]
        return parts.joined(separator: "|")
    }

    private static func freshnessForEvidence(
        rollupFreshness: InsightRollupFreshness,
        latestConversation: ConversationRecord?
    ) -> OpenBurnBarEvidenceFreshness {
        if rollupFreshness == .stale || rollupFreshness == .rebuilding {
            return .stale
        }
        guard let latestConversation else { return .unknown }
        return freshnessForConversation(latestConversation)
    }

    private static func freshnessForConversation(_ conversation: ConversationRecord) -> OpenBurnBarEvidenceFreshness {
        let age = Date().timeIntervalSince(conversation.indexedAt)
        if age < 24 * 60 * 60 {
            return .fresh
        }
        if age.isFinite {
            return .stale
        }
        return .unknown
    }

    private static func evidenceReason(
        index: Int,
        latestConversation: ConversationRecord?,
        conversation: ConversationRecord
    ) -> String {
        if conversation.id == latestConversation?.id {
            return "Latest indexed checkpoint"
        }
        if index == 1 {
            return "Corroborating recent session"
        }
        return "Recent project context"
    }

    private static func normalizeProjectName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func latestConversationActivityDate(_ conversation: ConversationRecord?) -> Date? {
        maxDate([
            conversation?.endTime,
            conversation?.startTime,
            conversation?.indexedAt
        ])
    }

    private static func latestActivityDate(
        latestConversation: ConversationRecord?,
        projectUsages: [TokenUsage]
    ) -> Date? {
        maxDate([
            latestConversationActivityDate(latestConversation),
            projectUsages.map(\.endTime).max()
        ])
    }

    private static func relativeTimeString(since date: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 {
            return "just now"
        }
        if seconds < 60 * 60 {
            let minutes = seconds / 60
            return "\(minutes)m ago"
        }
        if seconds < 24 * 60 * 60 {
            let hours = seconds / (60 * 60)
            return "\(hours)h ago"
        }
        let days = seconds / (24 * 60 * 60)
        return "\(days)d ago"
    }

    private static func inferredOverrideDirectionStatus(
        focus: ProjectFocus,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage],
        insightBrief: InsightBriefSnapshot,
        retrievalHealth: RetrievalSystemHealthSnapshot,
        indexingEnabled: Bool
    ) -> OpenBurnBarDirectionAssessment {
        guard indexingEnabled, projectConversations.count >= 5 else {
            return .notEnoughSignal
        }
        return assessDirection(
            focus: focus,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
            projectUsages: projectUsages,
            insightBrief: insightBrief,
            retrievalHealth: retrievalHealth
        ).status
    }

    private static func missionReadIsBlockedByRetrievalFailure(_ retrievalHealth: RetrievalSystemHealthSnapshot) -> Bool {
        retrievalHealth.parserImport.status == .failed
            || retrievalHealth.projectionQueue.status == .failed
    }

    private static func retrievalHealthFailureSummary(_ retrievalHealth: RetrievalSystemHealthSnapshot) -> String? {
        retrievalHealth.parserImport.errorMessage
            ?? retrievalHealth.projectionQueue.errorMessage
    }

    private static func stableMissionComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func stableMissionSummarySignature(
        conversation: ConversationRecord?,
        normalizedTitle: String
    ) -> String {
        let source = conversation?.summary?.nonEmpty
            ?? conversation?.lastAssistantMessage.nonEmpty
            ?? conversation?.inferredTaskTitle.nonEmpty
            ?? "no-summary"
        let scrubbed = stableMissionComponent(source)
            .replacingOccurrences(of: "\\b[0-9]+(?:[.:/-][0-9]+)*\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\b[a-f0-9]{7,}\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleTokens = Set(normalizedTitle.split(separator: " ").map(String.init))
        let stopWords: Set<String> = [
            "after", "and", "before", "from", "into", "only", "that", "the", "this",
            "with", "while", "were", "when", "where", "which", "will", "still", "just",
            "about", "have", "has", "had", "been", "being", "your", "their", "there",
            "refresh", "refreshed", "timestamp", "timestamps"
        ]

        var tokens: [String] = []
        var seen = Set<String>()
        for word in scrubbed.split(separator: " ").map(String.init) {
            guard word.count >= 4 else { continue }
            guard stopWords.contains(word) == false else { continue }
            guard titleTokens.contains(word) == false else { continue }
            guard seen.insert(word).inserted else { continue }
            tokens.append(word)
            if tokens.count == 10 {
                break
            }
        }

        return tokens.isEmpty ? "no-summary" : tokens.joined(separator: " ")
    }

    private static func missionSubtitle(
        title: String,
        latestConversation: ConversationRecord?,
        projectConversations: [ConversationRecord],
        projectUsages: [TokenUsage]
    ) -> String {
        let lastActivity = latestActivityDate(
            latestConversation: latestConversation,
            projectUsages: projectUsages
        )
        let sessionCount = Set(projectUsages.map { "\($0.provider.rawValue):\($0.sessionId)" }).count
        let totalCost = projectUsages.reduce(0) { $0 + $1.cost }
        if let summary = latestConversation?.summary?.nonEmpty {
            return "\(summary) Last activity \(lastActivity.map { relativeTimeString(since: $0) } ?? "recently"), \(sessionCount) session\(sessionCount == 1 ? "" : "s"), \(totalCost.formatAsCost())."
        }
        return "Latest checkpoint “\(title)” covers \(projectConversations.count) conversation\(projectConversations.count == 1 ? "" : "s") with \(sessionCount) billed session\(sessionCount == 1 ? "" : "s") and \(totalCost.formatAsCost())."
    }

    private static func meaningfulSecondaryCompetition(
        primary: ProjectSignalMetrics?,
        secondary: ProjectSignalMetrics?
    ) -> Bool {
        guard let primary, let secondary else { return false }
        guard secondary.score >= primary.score * 0.75 else { return false }
        guard secondary.recentBurnCost >= max(1.5, primary.recentBurnCost * 0.35) else { return false }
        guard let secondaryActivity = secondary.lastActivityDate,
              Date().timeIntervalSince(secondaryActivity) <= 24 * 60 * 60 else {
            return false
        }
        return secondary.recentConversationCount >= 1 || secondary.recentBurnCost >= 3
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func maxDate(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.max()
    }
}

private struct DirectionAssessmentEvidence {
    let status: OpenBurnBarDirectionAssessment
    let leadingSignal: String
    let nextActions: [String]
}

private struct ProjectSignalMetrics: Equatable {
    let projectName: String
    var score: Double = 0
    var conversationCount: Int = 0
    var recentConversationCount: Int = 0
    var summarizedConversationCount: Int = 0
    var recentBurnCost: Double = 0
    var lastConversationAt: Date?
    var lastUsageAt: Date?
    var lastActivityDate: Date?

    var key: String { projectName }
    var value: Double { score }
}

private struct ProjectFocus: Equatable {
    let primaryMetrics: ProjectSignalMetrics?
    let secondaryMetrics: ProjectSignalMetrics?
    let totalConversationCount: Int

    var primaryProject: String? { primaryMetrics?.projectName }
    var secondaryProject: String? { secondaryMetrics?.projectName }
    var dominanceRatio: Double {
        guard let primaryScore = primaryMetrics?.score, primaryScore > 0 else { return 0 }
        let secondaryScore = secondaryMetrics?.score ?? 0
        return primaryScore / max(primaryScore + secondaryScore, 1)
    }

    var scopeLabel: String {
        if secondaryProject != nil {
            return "Cross-project"
        }
        return primaryProject ?? "Workspace"
    }
}

extension Array where Element == String {
    fileprivate var nonEmptyArray: [String]? {
        isEmpty ? nil : self
    }
}
