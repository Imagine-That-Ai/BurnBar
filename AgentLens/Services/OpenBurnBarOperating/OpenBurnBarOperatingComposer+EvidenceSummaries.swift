import Foundation

extension OpenBurnBarOperatingComposer {
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

    static func buildBurnSummary(
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

        let latestUsage = projectUsages.min(by: { $0.endTime > $1.endTime })
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

    static func buildFreshnessSummary(
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

    static func buildEvidenceSummary(
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
                    truncated(conversation.lastAssistantMessage, limit: 160)
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
    static func freshnessForEvidence(
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
    private static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
