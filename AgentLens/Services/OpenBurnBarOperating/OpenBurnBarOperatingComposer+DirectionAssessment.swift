import Foundation

extension OpenBurnBarOperatingComposer {
    static func buildDirectionSummary(
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

        if let latestConversation, latestConversation.summary?.nonEmpty != nil || latestConversation.summaryTitle?.nonEmpty != nil {
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

        if projectUsages.reduce(0, { $0 + $1.cost }) >= 3 || Set(projectUsages.map(\.sessionId)).count >= 2 {
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
}

private struct DirectionAssessmentEvidence {
    let status: OpenBurnBarDirectionAssessment
    let leadingSignal: String
    let nextActions: [String]
}

extension Array where Element == String {
    var nonEmptyArray: [String]? {
        isEmpty ? nil : self
    }
}
