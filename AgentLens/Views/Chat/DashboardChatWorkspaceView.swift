import SwiftUI
import OpenBurnBarCore

/// Full-canvas chat experience, modeled after Claude.ai and ChatGPT — a cmux-style
/// tiling workspace.
///
/// Layout:
///   ┌─ Toolbar ─────────────────────────────────────────────────────────┐
///   │ Backend  Model   New chat  ⋯  Pop out  Restore window  Close      │
///   ├───────────────────────────────────────────────────────────────────┤
///   │ Thread rail (260pt) │  PaneWorkspaceView (tiling conversation)     │
///   │  + New chat         │   ⌘D split right · ⌘⇧D split down · ⌘W close │
///   │  search             │   drag a thread chip onto a pane to load it, │
///   │  thread rows (drag) │   or onto an edge to open it in a new pane   │
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

    /// The cmux-style tiling tree. Built lazily in `.onAppear` — NOT in `init`, which
    /// would re-run the controller-building `restore()` on every parent re-render. The
    /// passed-in `controller` is the app-wide primary controller reused by the primary
    /// pane, so the single-pane experience and every other surface holding it are
    /// unchanged.
    @State private var workspace: PaneWorkspaceModel?
    @State private var showClearChatPrompt = false
    @Environment(\.dashboardLiveBackdropActive) private var dashboardLiveBackdropActive

    private let railWidth: CGFloat = 260

    /// The focused pane's controller — the toolbar + rail selection target. Falls back to
    /// the app-wide controller before the workspace is built.
    private var activeController: ChatSessionController {
        workspace?.activeController ?? controller
    }

    private var isTiled: Bool { (workspace?.paneCount ?? 1) > 1 }

    private var railAccent: Color {
        activeController.chatBackend == .hermes
            ? DesignSystem.Colors.hermesAureate
            : DesignSystem.Colors.whimsy
    }

    var body: some View {
        VStack(spacing: 0) {
            DashboardChatWorkspaceToolbar(
                controller: activeController,
                settingsManager: settingsManager,
                mode: mode,
                showsEnginePickers: !isTiled,
                onNewChat: { activeController.clearChat() },
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

                conversationArea
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
        .task {
            PretextEngine.shared.start()
        }
        .onAppear {
            if workspace == nil {
                workspace = PaneWorkspaceModel.restore(
                    primaryController: controller,
                    dataStore: dataStore,
                    settingsManager: settingsManager
                )
            }
            controller.refreshHistory()
        }
        .onChange(of: dataStore.usagesVersion) { _, _ in
            controller.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
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
                activeController.clearChat()
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

    // MARK: - Conversation area (cmux-style tiling)

    @ViewBuilder
    private var conversationArea: some View {
        if let workspace {
            PaneWorkspaceView(
                workspace: workspace,
                settingsManager: settingsManager,
                onJumpToConversation: onOpenConversationJump
            )
        } else {
            // First frame before `.onAppear` builds the workspace — the backdrop shows
            // through; the pane (with its own welcome + composer) lands immediately after.
            Color.clear
        }
    }

    // MARK: - Thread rail

    @ViewBuilder
    private var threadRail: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Button {
                activeController.clearChat()
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New chat")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(railAccent)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(railAccent.opacity(0.4), lineWidth: 0.75)
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
                            threadRow(thread)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.md)
    }

    /// One draggable thread chip. Dragging it onto a pane loads the thread there; dropping
    /// on a pane edge opens it in a new split pane (handled by `PaneDropDelegate`).
    @ViewBuilder
    private func threadRow(_ thread: ChatThreadSummary) -> some View {
        ChatHistoryRow(
            thread: thread,
            isActive: thread.id == activeController.activeThreadID,
            accent: railAccent,
            isOpenInPane: workspace?.boundThreadIDs.contains(thread.id) ?? false,
            onSelect: { activeController.openHistoryThread(thread.id) }
        )
        .onDrag {
            NSItemProvider(object: thread.id as NSString)
        } preview: {
            threadDragPreview(thread)
        }
    }

    @ViewBuilder
    private func threadDragPreview(_ thread: ChatThreadSummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 11, weight: .semibold))
            Text(thread.title)
                .font(DesignSystem.Typography.caption)
                .lineLimit(1)
        }
        .foregroundStyle(railAccent)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .frame(maxWidth: 240)
    }
}
