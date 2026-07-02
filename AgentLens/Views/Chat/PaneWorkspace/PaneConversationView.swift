import Foundation
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct PaneThreadDropPayload: Codable, Transferable {
    let threadID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .openBurnBarChatThread)
    }
}

extension UTType {
    static let openBurnBarChatThread = UTType(exportedAs: "ai.burnbar.chat-thread")
}

/// One full conversation rendered as a tiling pane: a per-pane header (engine + model
/// pickers, split + close affordances), the message stream or welcome state, and the
/// composer — all bound to ONE `ChatSessionController`. When the workspace holds a single
/// pane (`showsChrome == false`) the header / focus ring / activation are hidden, so the
/// single-pane Chat screen looks and behaves exactly as before.
struct PaneConversationView: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var workspace: PaneWorkspaceModel
    var leafID: UUID
    var onJumpToConversation: (ConversationJumpTarget) -> Void = { _ in }

    @State private var brief = InsightBriefSnapshot()
    @State private var showCLIAssistantConsent = false
    @State private var atomRouter = HermesAtomRouter()
    @State private var isDropTargeted = false

    private let canvasMaxWidth: CGFloat = 760

    private var isActive: Bool { workspace.activeLeafID == leafID }
    private var showsChrome: Bool { workspace.isTiled }
    private var accent: Color {
        controller.chatBackend == .hermes ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.whimsy
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsChrome { paneHeader }
            conversationBody
            Divider().opacity(0.35)
            composer
        }
        .background { dropHighlight }
        .overlay { paneRing }
        .environment(settingsManager)
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
        .sheet(isPresented: $showCLIAssistantConsent) {
            CLIAssistantConsentSheet(settingsManager: settingsManager) {
                showCLIAssistantConsent = false
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if showsChrome { workspace.setActive(leafID) }
        })
        .dropDestination(for: PaneThreadDropPayload.self) { items, _ in
            guard let threadID = items.first?.threadID else { return false }
            Task { await workspace.bindExistingThread(threadID, toLeaf: leafID) }
            return true
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
        .task { atomRouter.onPerform = { _ in } }
        .onChange(of: controller.activeThreadID) { _, _ in
            workspace.persist()
            // The shared left rail is bound to the primary controller's history, so a
            // non-primary pane that creates or switches its thread must refresh it.
            if !controller.persistsViewState {
                workspace.primaryController.refreshHistory()
            }
        }
        .onChange(of: controller.messages.count) { _, _ in
            // Keep the rail's preview / message-count fresh after a non-primary pane sends.
            if !controller.persistsViewState {
                workspace.primaryController.refreshHistory()
            }
        }
        .onChange(of: controller.dataStore.usagesVersion) { _, _ in
            Task { @MainActor in
                brief = await controller.buildInsightBriefSnapshotAsync(refreshRollups: false)
            }
        }
        .onAppear {
            if controller.persistsViewState {
                // Primary pane reuses the app-wide controller: resolve the global thread
                // slot + load ONCE. On later recreations (a split/close re-parents this
                // view) hydrate the current thread instead, so we neither re-resolve the
                // slot nor race a re-home.
                if workspace.primaryDidInitialLoad {
                    Task { await controller.hydratePaneThread() }
                } else {
                    workspace.primaryDidInitialLoad = true
                    controller.loadPersistedMessages()
                }
            } else {
                Task { await controller.hydratePaneThread() }
            }
            controller.refreshHistory()
            Task { @MainActor in
                brief = await controller.buildInsightBriefSnapshotAsync(refreshRollups: false)
            }
        }
    }

    // MARK: - Pane chrome

    @ViewBuilder
    private var paneHeader: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ChatEngineBackendStrip(controller: controller, settingsManager: settingsManager)
            ChatEngineModelMenu(controller: controller)
                .layoutPriority(1)
            Spacer(minLength: DesignSystem.Spacing.sm)
            Button {
                workspace.setActive(leafID)
                workspace.splitActive(axis: .horizontal)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Split right (⌘D)")
            .accessibilityLabel("Split pane right")
            Button {
                workspace.setActive(leafID)
                workspace.splitActive(axis: .vertical)
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("Split down (⌘⇧D)")
            .accessibilityLabel("Split pane down")
            Button {
                workspace.setActive(leafID)
                workspace.closeActive()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close pane (⌘W)")
            .accessibilityLabel("Close pane")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isActive ? accent : DesignSystem.Colors.textSecondary)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs + 2)
        .background(DesignSystem.Colors.surface.opacity(isActive ? 0.55 : 0.3))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(accent.opacity(0.10))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var paneRing: some View {
        if showsChrome || isDropTargeted {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? accent.opacity(0.9) : (isActive ? accent.opacity(0.6) : Color.clear),
                    lineWidth: isDropTargeted ? 2 : (isActive ? 1.5 : 0)
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: - Conversation

    @ViewBuilder
    private var conversationBody: some View {
        Group {
            if controller.messages.isEmpty,
               controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                welcomeState
            } else {
                ChatMessagesStream(
                    controller: controller,
                    settingsManager: settingsManager,
                    maxContentWidth: canvasMaxWidth,
                    horizontalPadding: DesignSystem.Spacing.xl,
                    verticalPadding: DesignSystem.Spacing.xl,
                    onJumpToConversation: onJumpToConversation
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var composer: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ChatInputRow(
                controller: controller,
                chatBackend: controller.chatBackend,
                cliAssistantAllowed: settingsManager.cliAssistantAllowed,
                onRequestCLIAssistantConsent: { showCLIAssistantConsent = true },
                onSubmit: { Task { await controller.send() } }
            )
            .frame(maxWidth: canvasMaxWidth)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Welcome state (per pane)

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
        case .droid: return "Talk to Droid with your indexed history as grounding."
        case .forge: return "Talk to Forge with your indexed history as grounding."
        case .antigravity: return "Talk to Antigravity with your indexed history as grounding."
        case .cursorAgent: return "Talk to Cursor Agent with your indexed history as grounding."
        case .openClaude: return "Talk to OpenClaude with your indexed history as grounding."
        case .junie: return "Talk to Junie with your indexed history as grounding."
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
                    columns: [GridItem(.adaptive(minimum: 240), spacing: DesignSystem.Spacing.md)],
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
