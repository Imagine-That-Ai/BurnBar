import SwiftUI
import OpenBurnBarCore

/// Full-canvas chat experience, modeled after Claude.ai and ChatGPT.
///
/// Layout:
///   ┌─ Toolbar ─────────────────────────────────────────────────────────┐
///   │ Backend  Model   New chat  ⋯  Pop out  Restore window  Close      │
///   ├─ HSplitView ──────────────────────────────────────────────────────┤
///   │ Thread rail (260pt) │  Centered conversation (max 760pt)          │
///   │  + New chat         │   Welcome state or `ChatMessagesStream`     │
///   │  search             │                                              │
///   │  thread rows        │   Centered composer                          │
///   └───────────────────────────────────────────────────────────────────┘
///
/// Two modes:
///   - `.embedded`  — rendered inside the dashboard `mainRoute == .chat`
///   - `.popOut`    — hosted inside a standalone `NSWindow`
struct DashboardChatWorkspaceView: View {
    enum Mode: Equatable {
        case embedded
        case popOut
    }

    @Bindable var controller: ChatSessionController
    var dataStore: DataStore
    var settingsManager: SettingsManager
    var sharedFeaturesAvailable: Bool
    var mode: Mode = .embedded
    var onOpenConversationJump: (ConversationJumpTarget) -> Void = { _ in }
    var onPopOut: (() -> Void)?
    var onRestoreFloating: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var brief = InsightBriefSnapshot()
    @State private var showClearChatPrompt = false
    @State private var atomRouter = HermesAtomRouter()

    private let canvasMaxWidth: CGFloat = 760
    private let railWidth: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            DashboardChatWorkspaceToolbar(
                controller: controller,
                settingsManager: settingsManager,
                mode: mode,
                onNewChat: { controller.clearChat() },
                onShowClearChatPrompt: { showClearChatPrompt = true },
                onPopOut: onPopOut,
                onRestoreFloating: onRestoreFloating,
                onClose: onClose
            )

            HStack(spacing: 0) {
                threadRail
                    .frame(width: railWidth)
                    .background(DesignSystem.Colors.surface.opacity(0.45))
                    .overlay(alignment: .trailing) {
                        Divider().opacity(0.4)
                    }

                conversationColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignSystem.Colors.background)
        .environment(\.hermesAtomNavigator, atomRouter)
        .popover(item: Binding(
            get: { atomRouter.pending },
            set: { atomRouter.pending = $0 }
        )) { pending in
            HermesAtomDetailPopover(
                atom: pending.atom,
                label: pending.label,
                onOpen: {
                    atomRouter.confirm(pending)
                    atomRouter.pending = nil
                }
            )
        }
        .task {
            PretextEngine.shared.start()
            atomRouter.onPerform = { _ in }
        }
        .onAppear {
            brief = controller.buildInsightBriefSnapshot(refreshRollups: false)
            controller.loadPersistedMessages()
            controller.refreshHistory()
        }
        .onChange(of: dataStore.lastRefresh) { _, _ in
            Task { @MainActor in
                brief = controller.buildInsightBriefSnapshot(refreshRollups: false)
                controller.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
            }
        }
        .onChange(of: sharedFeaturesAvailable) { _, available in
            controller.refreshRetrievalHealth(sharedFeaturesAvailable: available)
        }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in
            controller.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        }
        .onChange(of: settingsManager.preferredIndexEmbeddingVersionID) { _, _ in
            controller.reconfigureSearchService()
        }
        .confirmationDialog("Clear current chat?", isPresented: $showClearChatPrompt) {
            Button("Clear Current Chat", role: .destructive) {
                controller.clearChat()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This starts a new chat. Previous Burn Bar chats stay in History.")
        }
        .hermesRuntimeGate(
            controller: controller,
            settingsManager: settingsManager,
            dataStore: dataStore
        )
    }

    // MARK: - Thread rail

    @ViewBuilder
    private var threadRail: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Button {
                controller.clearChat()
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New chat")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(controller.chatBackend == .hermes
                    ? DesignSystem.Colors.hermesAureate
                    : DesignSystem.Colors.whimsy)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(
                            controller.chatBackend == .hermes
                                ? DesignSystem.Colors.hermesAureate.opacity(0.4)
                                : DesignSystem.Colors.whimsy.opacity(0.4),
                            lineWidth: 0.75
                        )
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: [.command])

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                TextField("Search chats", text: $controller.historyQuery)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .onSubmit { controller.refreshHistory() }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs + 2)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            )
            .onChange(of: controller.historyQuery) { _, _ in
                controller.refreshHistory()
            }

            if controller.historyThreads.isEmpty {
                Text("No chats yet")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignSystem.Spacing.lg)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        ForEach(controller.historyThreads) { thread in
                            ChatHistoryRow(
                                thread: thread,
                                isActive: thread.id == controller.activeThreadID,
                                accent: controller.chatBackend == .hermes
                                    ? DesignSystem.Colors.hermesAureate
                                    : DesignSystem.Colors.whimsy,
                                onSelect: { controller.openHistoryThread(thread.id) }
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.md)
    }

    // MARK: - Conversation column

    @ViewBuilder
    private var conversationColumn: some View {
        VStack(spacing: 0) {
            if controller.messages.isEmpty,
               controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                welcomeState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatMessagesStream(
                    controller: controller,
                    settingsManager: settingsManager,
                    maxContentWidth: canvasMaxWidth,
                    horizontalPadding: DesignSystem.Spacing.xl,
                    verticalPadding: DesignSystem.Spacing.xl,
                    onJumpToConversation: onOpenConversationJump
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().opacity(0.35)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ChatInputRow(
                    controller: controller,
                    chatBackend: controller.chatBackend,
                    onSubmit: { Task { await controller.send() } }
                )
                .frame(maxWidth: canvasMaxWidth)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Welcome state

    @ViewBuilder
    private var welcomeState: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    Spacer().frame(height: DesignSystem.Spacing.xxxl)
                    welcomeGreeting
                    suggestionChips
                    Spacer().frame(height: DesignSystem.Spacing.xl)
                }
                .frame(maxWidth: canvasMaxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
        }
    }

    @ViewBuilder
    private var welcomeGreeting: some View {
        let isHermes = controller.chatBackend == .hermes
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            if isHermes {
                Text("How can I help today?")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.mercuryGradient)
            } else {
                Text("How can I help today?")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Text(welcomeSubtitle)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var welcomeSubtitle: String {
        switch controller.chatBackend {
        case .hermes: return "Ask Hermes about your sessions, projects, or anything else."
        case .openclaw: return "Talk to OpenClaw with your indexed history as grounding."
        case .codex: return "Talk to Codex with your indexed history as grounding."
        case .claude: return "Talk to Claude Code with your indexed history as grounding."
        case .piAgent: return "Talk to Pi with your indexed history as grounding."
        }
    }

    @ViewBuilder
    private var suggestionChips: some View {
        let chips = suggestionData
        if chips.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Suggestions")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                suggestionCard(
                    title: "Where did I spend the most this week?",
                    detail: "Aggregate cost by project across all providers."
                ) {
                    controller.inputText = "Where did I spend the most this week?"
                }
                suggestionCard(
                    title: "Summarize my recent sessions",
                    detail: "What have I been working on lately?"
                ) {
                    controller.inputText = "Summarize my recent sessions"
                }
            }
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Suggestions")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: DesignSystem.Spacing.md), GridItem(.flexible(), spacing: DesignSystem.Spacing.md)],
                    alignment: .leading,
                    spacing: DesignSystem.Spacing.md
                ) {
                    ForEach(chips, id: \.id) { chip in
                        suggestionCard(title: chip.title, detail: chip.detail) {
                            controller.inputText = chip.prompt
                        }
                    }
                }
            }
        }
    }

    private struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let prompt: String
    }

    private var suggestionData: [Suggestion] {
        var result: [Suggestion] = []
        if let w = brief.whereLeftOff {
            result.append(Suggestion(
                title: "Where you left off",
                detail: w,
                prompt: "Tell me more about my work on \(brief.whereLeftOffProject ?? "this project")"
            ))
        }
        if let title = brief.heaviestTaskTitle,
           let cost = brief.heaviestTaskCost,
           let proj = brief.heaviestTaskProject {
            result.append(Suggestion(
                title: "Heaviest task this week",
                detail: "\(cost.formatAsCost()) on \(proj) — \(title)",
                prompt: "What did I spend on \(title) this week?"
            ))
        }
        if let m = brief.modelShiftHeadline {
            result.append(Suggestion(
                title: "Model shift",
                detail: m,
                prompt: "Tell me more about my new model usage"
            ))
        }
        if let inc = brief.incompleteHint {
            result.append(Suggestion(
                title: "Continue where you left off",
                detail: inc,
                prompt: "Help me continue where I left off"
            ))
        }
        return result
    }

    @ViewBuilder
    private func suggestionCard(title: String, detail: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
