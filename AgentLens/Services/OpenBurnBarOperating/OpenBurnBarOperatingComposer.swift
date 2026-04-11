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
            aggregator: aggregator,
            chatController: chatController,
            decisions: decisions
        )
        let direction = buildDirectionSummary(
            focus: focus,
            latestConversation: latestConversation,
            projectConversations: projectConversations,
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

        let latestText = joinedMissionText(from: latestConversation, insightBrief: insightBrief)
        let title = latestConversation?.summaryTitle
            ?? latestConversation?.inferredTaskTitle
            ?? insightBrief.heaviestTaskTitle
            ?? "Recent work in \(focusProject)"
        let subtitle = latestConversation?.summary
            ?? insightBrief.whereLeftOff
            ?? latestConversation?.lastAssistantMessage
            ?? "OpenBurnBar is watching the most recent indexed checkpoint for \(focusProject)."
        let state = inferMissionState(
            latestText: latestText,
            isRefreshing: aggregator?.isRefreshing == true,
            isStreaming: chatController?.isStreaming == true,
            conversationCount: projectConversations.count
        )
        let missionID = missionFingerprint(
            projectName: focusProject,
            conversation: latestConversation,
            conversationCount: projectConversations.count
        )
        let approvalRecord = decisions.missionApprovalsByProject[focusProject]
        let approval: OpenBurnBarMissionApprovalState = approvalRecord?.missionFingerprint == missionID ? .approved : .pending
        let recommendation = buildMissionRecommendation(
            state: state,
            latestConversation: latestConversation,
            insightBrief: insightBrief,
            focusProject: focusProject,
            approval: approval
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

        if projectConversations.count < 2 {
            return OpenBurnBarDirectionSummary(
                availability: .sparse,
                projectName: focusProject,
                title: "Direction signal is still sparse",
                status: .notEnoughSignal,
                summary: "OpenBurnBar can name the active project, but there are not enough indexed checkpoints to judge alignment with confidence.",
                scopeLabel: focus.scopeLabel,
                freshness: freshness,
                mode: .sparse,
                sparseReason: "Only \(projectConversations.count) indexed session\(projectConversations.count == 1 ? "" : "s") exists for \(focusProject).",
                nextActions: ["Let OpenBurnBar ingest a couple more sessions.", "Add a note or direction override if you already know the call."],
                overrideSummary: overrideRecord?.summary
            )
        }

        if let overrideRecord {
            let forced = overrideRecord.forcedStatus ?? inferDirectionStatus(
                focus: focus,
                latestConversation: latestConversation,
                insightBrief: insightBrief,
                retrievalHealth: retrievalHealth
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

        let status = inferDirectionStatus(
            focus: focus,
            latestConversation: latestConversation,
            insightBrief: insightBrief,
            retrievalHealth: retrievalHealth
        )
        let summary = directionSummaryText(
            status: status,
            focusProject: focusProject,
            latestConversation: latestConversation,
            insightBrief: insightBrief,
            rollupStatusMessage: rollupStatusMessage,
            retrievalHealth: retrievalHealth
        )
        let nextActions = directionNextActions(
            status: status,
            latestConversation: latestConversation,
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
        status: OpenBurnBarDirectionAssessment,
        focusProject: String,
        latestConversation: ConversationRecord?,
        insightBrief: InsightBriefSnapshot,
        rollupStatusMessage: String?,
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> String {
        switch status {
        case .aligned:
            return latestConversation?.summary?.nonEmpty
                ?? "Recent indexed checkpoints still cluster around \(focusProject), and OpenBurnBar does not see a strong contradiction yet."
        case .drifting:
            return insightBrief.incompleteHint?.nonEmpty
                ?? "The latest checkpoint ends with open follow-ups, so OpenBurnBar thinks the work needs steering before it drifts further."
        case .ambiguous:
            return rollupStatusMessage?.nonEmpty
                ?? retrievalHealth.degradedModes.first?.message
                ?? "OpenBurnBar can see activity in \(focusProject), but the signal is mixed across recency, evidence freshness, or burn."
        case .notEnoughSignal:
            return "OpenBurnBar does not have enough grounded evidence yet to call alignment for \(focusProject)."
        }
    }

    private static func directionNextActions(
        status: OpenBurnBarDirectionAssessment,
        latestConversation: ConversationRecord?,
        insightBrief: InsightBriefSnapshot,
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> [String] {
        switch status {
        case .aligned:
            return [
                "Keep importing sessions so OpenBurnBar can catch the next inflection point.",
                "Approve the mission when the current checkpoint looks right."
            ]
        case .drifting:
            return [
                insightBrief.incompleteHint?.nonEmpty
                    ?? "Write down the next step OpenBurnBar should optimize for.",
                "Use a direction override if you want to force the call instead of waiting on more evidence."
            ]
        case .ambiguous:
            return retrievalHealth.degradedModes.prefix(2).map(\.message).nonEmptyArray
                ?? ["Let OpenBurnBar finish refreshing the local index before you trust the direction call."]
        case .notEnoughSignal:
            return [
                latestConversation?.summaryTitle?.nonEmpty.map { "Summarize and continue \($0)." }
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
        approval: OpenBurnBarMissionApprovalState
    ) -> String {
        if approval == .approved {
            return "OpenBurnBar is carrying this checkpoint as the operator-approved mission for \(focusProject)."
        }
        switch state {
        case .blocked:
            return "The latest checkpoint reads blocked. OpenBurnBar is waiting for an explicit unblock or a new plan."
        case .partial:
            return insightBrief.incompleteHint?.nonEmpty
                ?? "The mission still looks open-loop. OpenBurnBar expects a next-step decision."
        case .completed:
            return "The latest checkpoint looks finished. Approve it if this is the mission you want OpenBurnBar to carry forward."
        case .running:
            return latestConversation?.summary?.nonEmpty
                ?? "OpenBurnBar sees active execution against the current mission."
        case .planned:
            return "OpenBurnBar can name the current work, but it still needs more concrete execution before the mission feels locked."
        }
    }

    private static func historyTitle(for record: OpenBurnBarOperatingActionRecord) -> String {
        switch record.actionKind {
        case .missionApproval:
            return "Mission approved"
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
        latestText: String,
        isRefreshing: Bool,
        isStreaming: Bool,
        conversationCount: Int
    ) -> OpenBurnBarMissionLifecycle {
        let lowered = latestText.lowercased()
        if isRefreshing || isStreaming {
            return .running
        }
        if containsAny(lowered, needles: ["blocked", "stuck", "unable", "permission denied", "failed", "error"]) {
            return .blocked
        }
        if containsAny(lowered, needles: ["shipped", "done", "completed", "resolved", "finished", "merged"]) {
            return .completed
        }
        if lowered.hasSuffix("?")
            || containsAny(lowered, needles: ["next step", "next steps", "follow up", "todo", "to-do", "need to"]) {
            return .partial
        }
        if conversationCount >= 2 {
            return .running
        }
        return .planned
    }

    private static func inferDirectionStatus(
        focus: ProjectFocus,
        latestConversation: ConversationRecord?,
        insightBrief: InsightBriefSnapshot,
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> OpenBurnBarDirectionAssessment {
        if focus.secondaryProject != nil {
            return .ambiguous
        }
        if retrievalHealth.degradedModes.contains(where: { $0.mode == .indexStale || $0.mode == .rebuildInProgress }) {
            return .ambiguous
        }
        if insightBrief.incompleteHint?.nonEmpty != nil {
            return .drifting
        }
        let lowered = [
            latestConversation?.summary,
            latestConversation?.lastAssistantMessage,
            insightBrief.whereLeftOff
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: "\n")
        if containsAny(lowered, needles: ["blocked", "stuck", "redo", "rethink", "unclear"]) {
            return .drifting
        }
        return .aligned
    }

    private static func selectProjectFocus(
        conversations: [ConversationRecord],
        usages: [TokenUsage]
    ) -> ProjectFocus {
        var scores: [String: Double] = [:]
        for (index, conversation) in conversations.prefix(12).enumerated() {
            let project = normalizeProjectName(conversation.projectName)
            guard project.isEmpty == false else { continue }
            scores[project, default: 0] += Double(max(12 - index, 1))
        }
        let oneWeekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for usage in usages where usage.startTime >= oneWeekAgo {
            let project = normalizeProjectName(usage.projectName)
            guard project.isEmpty == false else { continue }
            let weight = max(1, min(usage.cost * 8, Double(usage.totalTokens) / 50_000))
            scores[project, default: 0] += weight
        }
        let sorted = scores.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        let primary = sorted.first?.key
        let secondary: String?
        if sorted.count >= 2, let top = sorted.first, let next = sorted.dropFirst().first, next.value >= top.value * 0.8 {
            secondary = next.key
        } else {
            secondary = nil
        }
        return ProjectFocus(primaryProject: primary, secondaryProject: secondary)
    }

    private static func joinedMissionText(
        from latestConversation: ConversationRecord?,
        insightBrief: InsightBriefSnapshot
    ) -> String {
        [
            latestConversation?.summary,
            latestConversation?.summaryTitle,
            latestConversation?.lastAssistantMessage,
            insightBrief.whereLeftOff,
            insightBrief.incompleteHint,
        ]
        .compactMap { $0?.nonEmpty }
        .joined(separator: "\n")
    }

    private static func missionFingerprint(
        projectName: String,
        conversation: ConversationRecord?,
        conversationCount: Int
    ) -> String {
        let parts = [
            projectName,
            conversation?.id ?? "none",
            conversation?.indexedAt.ISO8601Format() ?? "never",
            "\(conversationCount)",
            conversation?.summaryUpdatedAt?.ISO8601Format() ?? "",
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

    private static func containsAny(_ text: String, needles: [String]) -> Bool {
        needles.contains(where: text.contains)
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

private struct ProjectFocus: Equatable {
    let primaryProject: String?
    let secondaryProject: String?

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
