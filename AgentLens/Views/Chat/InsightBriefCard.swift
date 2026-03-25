import SwiftUI

// MARK: - Insight Brief Models

struct InsightBriefSnapshot {
    var whereLeftOff: String?
    var whereLeftOffProject: String?
    var heaviestTaskTitle: String?
    var heaviestTaskCost: Double?
    var heaviestTaskProject: String?
    var modelShiftHeadline: String?
    var incompleteHint: String?
    var rollupFreshness: InsightRollupFreshness = .fresh
    var rollupStatusMessage: String?

    /// True when the inline ribbon in `ChatPanel` would show at least one row.
    var hasInlineContent: Bool {
        whereLeftOff != nil
            || (heaviestTaskTitle != nil && heaviestTaskCost != nil && heaviestTaskProject != nil)
            || modelShiftHeadline != nil
            || incompleteHint != nil
            || rollupFreshness != .fresh
    }

    var rollupStatusLine: String? {
        guard rollupFreshness != .fresh else { return nil }
        if let rollupStatusMessage, rollupStatusMessage.isEmpty == false {
            return rollupStatusMessage
        }
        switch rollupFreshness {
        case .fresh:
            return nil
        case .stale:
            return "Workflow insights are stale."
        case .rebuilding:
            return "Workflow insights are rebuilding."
        case .unavailable:
            return "Workflow insights are unavailable."
        }
    }

    @MainActor
    static func build(
        from dataStore: DataStore,
        intelligenceService: SearchService? = nil,
        rollupService: WorkflowInsightRollupService? = nil
    ) -> InsightBriefSnapshot {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let weekUsages = dataStore.usages.filter { $0.startTime >= weekAgo }
        let retrieval = intelligenceService ?? SearchService.makeConversationSearchService(dataStore: dataStore)
        let rollups = rollupService ?? WorkflowInsightRollupService(dataStore: dataStore)
        let rollupSnapshot = rollups.snapshot(refreshIfStale: true)
        let conversations = retrieval.recentConversations(limit: 200)
        let latestConv = retrieval.latestConversation(in: conversations)

        let whereLeftOff = latestConv?.lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let whereProject = latestConv?.projectName

        let heaviestUsage = weekUsages.max(by: { $0.totalTokens < $1.totalTokens })
        let heaviestTitle = conversations.first(where: {
            $0.sessionId == heaviestUsage?.sessionId && $0.provider == heaviestUsage?.provider
        })?.inferredTaskTitle ?? heaviestUsage?.projectName

        let heaviestCost = heaviestUsage.map { u in
            weekUsages.filter { $0.projectName == u.projectName }.reduce(0.0) { $0 + $1.cost }
        }

        let modelShift = rollupSnapshot.insights.first { $0.type == .modelShift }

        let incomplete = latestConv.flatMap { conv -> String? in
            let t = conv.lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let lower = t.lowercased()
            if t.hasSuffix("?") || lower.contains("next steps") {
                return "Your last reply looks unfinished — pick up from: \(conv.inferredTaskTitle)"
            }
            return nil
        }

        return InsightBriefSnapshot(
            whereLeftOff: whereLeftOff?.isEmpty == false ? whereLeftOff : nil,
            whereLeftOffProject: whereProject,
            heaviestTaskTitle: heaviestTitle,
            heaviestTaskCost: heaviestCost,
            heaviestTaskProject: heaviestUsage?.projectName,
            modelShiftHeadline: modelShift?.headline,
            incompleteHint: incomplete,
            rollupFreshness: rollupSnapshot.freshness,
            rollupStatusMessage: rollupSnapshot.statusMessage
        )
    }
}

// MARK: - Insight Brief Card

struct InsightBriefCard: View {
    let title: String
    let bodyText: String
    let icon: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textCase(.uppercase)

                    Text(bodyText)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(accent.opacity(0.25), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
