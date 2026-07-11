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
        cachedControllerRuntime: OpenBurnBarControllerRuntimeSnapshot?,
        cachedRetrievalHealth: RetrievalSystemHealthSnapshot
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
        let retrievalHealth = cachedRetrievalHealth

        let recentProviderConversations = fetchRecentConversationsSynchronously(from: dataStore, limit: 120)
            .filter { $0.sourceType == .providerLog }
        let focus = selectProjectFocus(
            conversations: recentProviderConversations,
            usages: dataStore.usages
        )

        let projectConversations = filterByPrimaryProject(recentProviderConversations, focus.primaryProject) { $0.projectName }
        let decisions = decisionState(from: actionRecords)
        let history = historyEntries(
            from: actionRecords,
            focusProject: focus.primaryProject
        )
        let latestConversation = projectConversations.max {
            (latestConversationActivityDate($0) ?? .distantPast) < (latestConversationActivityDate($1) ?? .distantPast)
        }
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

    private static func fetchRecentConversationsSynchronously(from dataStore: DataStore, limit: Int) -> [ConversationRecord] {
        let bounded = max(1, min(limit, 1_000))
        do {
            return try dataStore.fetchConversationsSynchronously(limit: bounded)
        } catch {
            AppLogger.search.silentFailure("operating_composer_recent_conversations_fetch_failed", error: error)
            return []
        }
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

        let missionCreation = OpenBurnBarActionAvailability(
            kind: .missionCreation,
            available: true,
            reason: projectName?.nonEmpty.map { "Create a mission for \($0) from this brief." }
                ?? "Create a mission to start tracking work from this surface.",
            title: OpenBurnBarActionKind.missionCreation.label
        )

        return [missionApproval, directionOverride, missionCreation]
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
}
