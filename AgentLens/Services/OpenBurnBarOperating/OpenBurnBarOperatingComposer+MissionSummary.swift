import Foundation

extension OpenBurnBarOperatingComposer {
    private static let missionChangedFileScanLimit = 64
    private static let missionChangedFilePreviewLimit = 3
    private static let missionChangedFilePathLimit = 96
    static func buildMissionSummary(
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
                changedFilesSummary: "No changed files are available until OpenBurnBar sees a mission checkpoint.",
                risksSummary: "Mission risk is unknown because no project checkpoint has been ingested yet.",
                remainingWorkSummary: "Run a local scan or index a project conversation to establish remaining work.",
                recommendationSummary: "Run a local scan or index a recent project conversation to make the mission legible.",
                nextRecommendation: "Run a local scan, then create or approve a mission to begin execution.",
                approvalNote: nil,
                readinessFailure: nil
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
        let availability: OpenBurnBarOperatingAvailability = projectConversations.count < 2 ? .sparse : .available
        let subtitle: String = {
            if availability == .sparse {
                let count = projectConversations.count
                return "Mission brief is sparse: OpenBurnBar only has \(count) indexed checkpoint\(count == 1 ? "" : "s") for \(focusProject)."
            }
            return missionSubtitle(
                title: title,
                latestConversation: latestConversation,
                projectConversations: projectConversations,
                projectUsages: projectUsages
            )
        }()
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
        let changedFilesSummary = missionChangedFilesSummary(
            state: state,
            latestConversation: latestConversation
        )
        let risksSummary = missionRisksSummary(
            state: state,
            approval: approval,
            insightBrief: insightBrief,
            retrievalHealth: retrievalHealth
        )
        let remainingWorkSummary = missionRemainingWorkSummary(
            state: state,
            approval: approval,
            insightBrief: insightBrief,
            latestConversation: latestConversation
        )
        let nextRecommendation = missionNextRecommendation(
            state: state,
            approval: approval
        )

        return OpenBurnBarMissionSummary(
            availability: availability,
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
            changedFilesSummary: changedFilesSummary,
            risksSummary: risksSummary,
            remainingWorkSummary: remainingWorkSummary,
            recommendationSummary: recommendation,
            nextRecommendation: nextRecommendation,
            approvalNote: approvalRecord?.note.nonEmpty,
            readinessFailure: nil
        )
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

    private static func missionChangedFilesSummary(
        state: OpenBurnBarMissionLifecycle,
        latestConversation: ConversationRecord?
    ) -> String {
        guard let latestConversation else {
            return "No changed files are available yet."
        }

        let hasHiddenFiles = latestConversation.keyFiles.count > missionChangedFileScanLimit
        let files = latestConversation.keyFiles
            .prefix(missionChangedFileScanLimit)
            .compactMap(abbreviatedMissionChangedFilePath)

        guard files.isEmpty == false else {
            if hasHiddenFiles {
                return "\(missionChangedFileScanLimit)+ changed-file references captured; preview is bounded until the next normalized checkpoint."
            }
            switch state {
            case .blocked:
                return "Changed files are unavailable while the mission is blocked."
            case .partial:
                return "Changed files have not been captured for the incomplete checkpoint yet."
            case .running:
                return "Changed files are still being collected while execution is active."
            case .completed:
                return "No changed-file list was captured in the latest closure checkpoint."
            case .planned:
                return "Changed files will appear after execution starts."
            }
        }

        let preview = files.prefix(missionChangedFilePreviewLimit).joined(separator: ", ")
        let remaining = files.count - min(files.count, missionChangedFilePreviewLimit)
        let suffix: String
        if hasHiddenFiles {
            suffix = " (+more)"
        } else {
            suffix = remaining > 0 ? " (+\(remaining) more)" : ""
        }
        let countPrefix = hasHiddenFiles ? "\(files.count)+" : "\(files.count)"
        return "\(countPrefix) file\(files.count == 1 && hasHiddenFiles == false ? "" : "s") touched: \(preview)\(suffix)"
    }

    private static func abbreviatedMissionChangedFilePath(_ rawValue: String) -> String? {
        let collapsed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        guard collapsed.isEmpty == false else {
            return nil
        }

        let components = collapsed
            .components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .filter { $0.isEmpty == false }
        let displayPath = components.count > 2
            ? ".../" + components.suffix(2).joined(separator: "/")
            : collapsed
        guard displayPath.count > missionChangedFilePathLimit else {
            return displayPath
        }

        let headCount = max(12, missionChangedFilePathLimit / 2 - 2)
        let tailCount = max(12, missionChangedFilePathLimit - headCount - 3)
        return "\(displayPath.prefix(headCount))...\(displayPath.suffix(tailCount))"
    }

    private static func missionRisksSummary(
        state: OpenBurnBarMissionLifecycle,
        approval: OpenBurnBarMissionApprovalState,
        insightBrief: InsightBriefSnapshot,
        retrievalHealth: RetrievalSystemHealthSnapshot
    ) -> String {
        let pendingApprovalSuffix = approval == .pending
            ? " Operator approval is still pending for this mission checkpoint."
            : ""

        switch state {
        case .blocked:
            return (retrievalHealthFailureSummary(retrievalHealth)
                ?? retrievalHealth.degradedModes.first?.message
                ?? "Execution is blocked until readiness or indexing issues are resolved.")
                + pendingApprovalSuffix
        case .partial:
            return (insightBrief.incompleteHint?.nonEmpty
                ?? "The latest checkpoint still has unresolved work.")
                + pendingApprovalSuffix
        case .running:
            return "Execution is active, so closure risk remains open until the run settles." + pendingApprovalSuffix
        case .completed:
            return "No active blocking risk is detected in the latest summarized checkpoint." + pendingApprovalSuffix
        case .planned:
            return "Execution has not started yet, so downstream risk is still unvalidated." + pendingApprovalSuffix
        }
    }

    private static func missionRemainingWorkSummary(
        state: OpenBurnBarMissionLifecycle,
        approval: OpenBurnBarMissionApprovalState,
        insightBrief: InsightBriefSnapshot,
        latestConversation: ConversationRecord?
    ) -> String {
        if approval == .pending {
            return "Approve this mission or record an override before dispatch can continue."
        }

        switch state {
        case .blocked:
            return "Resolve the blocking issue, then retry mission dispatch."
        case .partial:
            return insightBrief.incompleteHint?.nonEmpty
                ?? "Close open tasks from the latest checkpoint before marking complete."
        case .running:
            return "Wait for active execution to finish and publish a fresh closure checkpoint."
        case .completed:
            return "No remaining work was reported in the latest closure checkpoint."
        case .planned:
            return latestConversation == nil
                ? "Gather a project checkpoint so OpenBurnBar can form an actionable brief."
                : "Start execution to convert this plan into runnable work."
        }
    }

    private static func missionNextRecommendation(
        state: OpenBurnBarMissionLifecycle,
        approval: OpenBurnBarMissionApprovalState
    ) -> String {
        if approval == .pending {
            switch state {
            case .running:
                return "Approve mission to keep active execution moving."
            case .blocked:
                return "Resolve blocking issues, then approve mission to retry."
            case .partial:
                return "Approve mission and close remaining work before rerun."
            case .completed:
                return "Approve mission closure or request one final follow-up."
            case .planned:
                return "Approve mission to continue execution."
            }
        }

        switch state {
        case .running:
            return "Wait for active execution to finish, then refresh the brief."
        case .blocked:
            return "Resolve blocking issues before retrying the mission."
        case .partial:
            return "Close remaining work and rerun validation."
        case .completed:
            return "Review closure evidence and archive or hand off the mission."
        case .planned:
            return "Start mission execution from the current plan."
        }
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
}
