import SwiftUI

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: TokenUsage
    let theme: ProviderTheme
    var dataStore: DataStore
    var onOpenSessionLog: ((ConversationJumpTarget) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var conversation: ConversationRecord?
    @State private var summaryText: String?
    @State private var summarizing = false
    @State private var summarizeError: String?
    @StateObject private var cliBridge = CLIBridge()
    @State private var showContextPackSheet = false
    @State private var contextPackAnchorId: String?
    @State private var contextPackAnchorProject: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider().background(DesignSystem.Colors.border)

            statsView

            Divider().background(DesignSystem.Colors.border)

            bottomRow

            if SettingsManager.shared.conversationIndexingEnabled, conversation != nil {
                Divider().background(DesignSystem.Colors.border)
                summarizeSection

                if let conv = conversation, let onOpenSessionLog {
                    Divider().background(DesignSystem.Colors.border)
                    viewSessionLogButton(conversation: conv, onOpen: onOpenSessionLog)
                }

                if conversation != nil {
                    Divider().background(DesignSystem.Colors.border)
                    SessionDetailContextPackRow(
                        session: session,
                        conversation: conversation,
                        dataStore: dataStore
                    ) { anchorId, anchorProject in
                        contextPackAnchorId = anchorId
                        contextPackAnchorProject = anchorProject
                        showContextPackSheet = true
                    }
                }
            }

            Divider().background(DesignSystem.Colors.border)

            timestampsView
        }
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.background)
        .frame(width: 480, height: SettingsManager.shared.conversationIndexingEnabled && conversation != nil ? 560 : 460)
        .task(id: ConversationRecord.stableId(provider: session.provider, sessionId: session.sessionId)) {
            await cliBridge.detect()
            let id = ConversationRecord.stableId(provider: session.provider, sessionId: session.sessionId)
            conversation = try? dataStore.fetchConversation(id: id)
            summaryText = conversation?.summary
        }
        .sheet(isPresented: $showContextPackSheet) {
            ContextPackSheet(
                dataStore: dataStore,
                anchorSessionId: contextPackAnchorId,
                anchorProject: contextPackAnchorProject,
                dateRange: nil
            )
        }
    }

    // MARK: - View Session Log

    private func viewSessionLogButton(conversation: ConversationRecord, onOpen: @escaping (ConversationJumpTarget) -> Void) -> some View {
        let snippet = conversation.summary?.nonEmpty
            ?? conversation.summaryTitle?.nonEmpty
            ?? conversation.lastAssistantMessage
        let target = ConversationJumpTarget(
            conversation: conversation,
            snippet: snippet,
            startOffset: 0,
            endOffset: snippet.count,
            source: .retrieval
        )
        return Button {
            dismiss()
            onOpen(target)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                Text("View Full Session Log")
                    .font(DesignSystem.Typography.caption)
            }
            .foregroundStyle(theme.primaryColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summarize

    private var summarizeSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Session summary")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    Task { await runSummarize() }
                } label: {
                    if summarizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(conversation?.summary == nil ? "Summarize with CLI" : "Regenerate")
                            .font(DesignSystem.Typography.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.whimsy)
                .disabled(summarizing || conversation?.fullText.isEmpty != false || cliBridge.detectedBackend == nil)
            }

            if let err = summarizeError {
                Text(err)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }

            if let s = summaryText, !s.isEmpty {
                Text(s)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if conversation?.fullText.isEmpty != false {
                Text("No indexed transcript for this session yet. Run a scan after enabling indexing.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    private func runSummarize() async {
        guard let conv = conversation, !conv.fullText.isEmpty else { return }
        summarizing = true
        summarizeError = nil
        await cliBridge.detect()
        guard cliBridge.detectedBackend != nil else {
            summarizing = false
            summarizeError = "No claude or codex CLI found."
            return
        }

        let userPrompt = ContextBuilder.summarizeSessionPrompt(fullText: conv.fullText)
        var acc = ""
        do {
            let stream = cliBridge.chat(
                systemPrompt: "You are a precise technical editor. Follow the user's format instructions exactly.",
                userMessage: userPrompt
            )
            for try await event in stream {
                if case .text(let chunk) = event {
                    acc += chunk
                    summaryText = acc
                }
            }
            try dataStore.updateConversationSummary(
                id: conv.id,
                title: conv.summaryTitle,
                summary: acc,
                provider: "cli-manual",
                model: "local-cli"
            )
            conversation = try? dataStore.fetchConversation(id: conv.id)
        } catch {
            summarizeError = error.localizedDescription
        }
        summarizing = false
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(theme.primaryColor.opacity(0.15))
                    .frame(width: 44, height: 44)

                ProviderLogoView(provider: session.provider, size: 28, useFallbackColor: false)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.projectName)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Text(session.model)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            Button("Done") { dismiss() }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.surface)
                .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        }
    }

    // MARK: - Stats

    private var statsView: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            StatTile(
                title: "Input",
                value: session.inputTokens.formatAsTokens(),
                color: theme.chartColors[0],
                transitionValue: session.inputTokens
            )
            StatTile(
                title: "Output",
                value: session.outputTokens.formatAsTokens(),
                color: theme.chartColors[1],
                transitionValue: session.outputTokens
            )
            StatTile(
                title: "Cache W",
                value: session.cacheCreationTokens.formatAsTokens(),
                color: theme.chartColors[2],
                transitionValue: session.cacheCreationTokens
            )
            StatTile(
                title: "Cache R",
                value: session.cacheReadTokens.formatAsTokens(),
                color: theme.chartColors[3],
                transitionValue: session.cacheReadTokens
            )
        }
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    // MARK: - Bottom Row

    private var bottomRow: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total Cost")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(session.cost.formatAsCost())
                    .font(DesignSystem.Typography.monoLarge)
                    .foregroundStyle(theme.gradient)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: session.cost)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Duration")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(session.formattedDuration)
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text("Total Tokens")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(session.totalTokens.formatAsTokens())
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: session.totalTokens)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    // MARK: - Timestamps

    private var timestampsView: some View {
        HStack(spacing: DesignSystem.Spacing.xl) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Started")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(formatDateTime(session.startTime))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Ended")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(formatDateTime(session.endTime))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()
        }
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Stat Tile

private struct StatTile: View {
    let title: String
    let value: String
    let color: Color
    var transitionValue: Int = 0

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(value)
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: transitionValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
    }
}

#Preview {
    let store = (try? DataStore()) ?? {
        preconditionFailure("Preview requires a valid DataStore - ensure app support directory is writable")
    }()
    return SessionDetailView(
        session: TokenUsage(
            provider: .factory,
            sessionId: "preview",
            projectName: "ImagineThatAiApp",
            model: "claude-4-sonnet",
            inputTokens: 45000,
            outputTokens: 12000,
            cacheCreationTokens: 5000,
            cacheReadTokens: 8000,
            startTime: Date(),
            endTime: Date()
        ),
        theme: .theme(for: .factory),
        dataStore: store
    )
}
