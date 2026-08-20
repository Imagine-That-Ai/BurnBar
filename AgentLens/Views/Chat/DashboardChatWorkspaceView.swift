import SwiftUI
import OpenBurnBarCore
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// Full-canvas chat experience, modeled after Claude.ai and ChatGPT.
///
/// Layout:
///   ┌─ Toolbar ─────────────────────────────────────────────────────────┐
///   │ ● ◆ Codex · gpt-5-codex ⌄ │ ghosts │ New chat ⋯ Pop out … Close   │
///   ├───────────────────────────────────────────────────────────────────┤
///   │ Thread rail (260pt) │  Pane workspace (cmux-style tiling)          │
///   │  + New chat         │   One full-size pane by default; ⌘D / ⌘⇧D    │
///   │  search             │   split, drag a thread row onto any pane.    │
///   │  thread rows        │                                              │
///   └───────────────────────────────────────────────────────────────────┘
///
/// The right viewer is a `PaneWorkspaceView` tiling tree. With a single pane it is
/// pixel-identical to the previous single-conversation column; splitting reveals per-pane
/// chrome. The `controller` injected here is the app-wide controller and becomes the
/// workspace's primary leaf, so every other surface that holds it is unaffected.
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

    @State private var showClearChatPrompt = false

    /// The thread rail starts hidden so the chat route opens as one vertical
    /// reading column rather than a side-by-side landscape split. History is a
    /// keystroke away (⌃⌘L) and the choice persists once made.
    @AppStorage(Self.railVisibleStorageKey) private var threadRailVisible = false

    static let railVisibleStorageKey = "dashboardChat.threadRailVisible"

    /// The pane-tiling workspace for the right-side viewer. Built lazily on first appear
    /// from the persisted layout (or a single primary pane bound to `controller`).
    @State private var workspace: PaneWorkspaceModel?
    @State private var alertCenter = ChatPaneAlertCenter()

    private let railWidth: CGFloat = 260

    /// The focused pane's controller (falls back to the app-wide controller before the
    /// workspace is built). Drives the toolbar, the rail selection, and retrieval refreshes.
    private var activeController: ChatSessionController { workspace?.activeController ?? controller }

    var body: some View {
        VStack(spacing: 0) {
            DashboardChatWorkspaceToolbar(
                controller: activeController,
                settingsManager: settingsManager,
                mode: mode,
                // The old `showsEnginePickers: !isTiled` gate is gone: splitting
                // a pane must never make the top of the window anonymous.
                workspace: workspace,
                threadRailVisible: $threadRailVisible,
                onNewChat: { activeController.clearChat() },
                onShowClearChatPrompt: { showClearChatPrompt = true },
                onPopOut: onPopOut,
                onRestoreFloating: onRestoreFloating,
                onClose: onClose
            )

            HStack(spacing: 0) {
                if threadRailVisible {
                    threadRail
                        .frame(width: railWidth)
                        .background(.ultraThinMaterial)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.10))
                                .frame(width: 1)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Group {
                    if let workspace {
                        VStack(spacing: 0) {
                            ConversationTabStrip(workspace: workspace)
                            PaneWorkspaceView(
                                workspace: workspace,
                                settingsManager: settingsManager,
                                onJumpToConversation: onOpenConversationJump
                            )
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(settingsManager.useWebsiteBackground ? Color.clear : DesignSystem.Colors.background)
        .task {
            PretextEngine.shared.start()
        }
        .onAppear {
            let paneWorkspace = workspace ?? PaneWorkspaceModel.shared(
                primaryController: controller,
                dataStore: dataStore,
                settingsManager: settingsManager,
                alertCenter: alertCenter
            )
            workspace = paneWorkspace
            ChatPaneAlertCenter.paneCompletionTapHandler = { paneID, tabID in
                #if canImport(AppKit)
                NSApp.activate(ignoringOtherApps: true)
                #endif
                paneWorkspace.focusPane(paneID, inTab: tabID)
            }
            controller.refreshHistory()
        }
        .onChange(of: dataStore.usagesVersion) { _, _ in
            forEachController { $0.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable) }
            controller.refreshHistory()
        }
        .onChange(of: sharedFeaturesAvailable) { _, available in
            forEachController { $0.refreshRetrievalHealth(sharedFeaturesAvailable: available) }
        }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in
            forEachController { $0.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable) }
        }
        .onChange(of: settingsManager.preferredIndexEmbeddingVersionID) { _, _ in
            forEachController { $0.reconfigureSearchService() }
        }
        .confirmationDialog("Clear current chat?", isPresented: $showClearChatPrompt) {
            Button("Clear Current Chat", role: .destructive) {
                activeController.clearChat()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This starts a new chat. Previous BurnBar chats stay in History.")
        }
        .hermesRuntimeGate(
            controller: activeController,
            settingsManager: settingsManager,
            dataStore: dataStore
        )
    }

    /// Apply an action to every pane's controller (or just the app-wide controller before
    /// the workspace is built), so global setting changes reach all panes.
    private func forEachController(_ body: (ChatSessionController) -> Void) {
        if let workspace {
            workspace.allLeaves.forEach { body($0.controller) }
        } else {
            body(controller)
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
                .foregroundStyle(activeController.chatBackend == .hermes
                    ? DesignSystem.Colors.hermesAureate
                    : DesignSystem.Colors.whimsy)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(
                            activeController.chatBackend == .hermes
                                ? DesignSystem.Colors.hermesAureate.opacity(0.4)
                                : DesignSystem.Colors.whimsy.opacity(0.4),
                            lineWidth: 0.75
                        )
                )
            }
            .buttonStyle(.plain)

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
                                isActive: thread.id == activeController.activeThreadID,
                                paneBadge: railBadge(for: thread.id),
                                accent: activeController.chatBackend == .hermes
                                    ? DesignSystem.Colors.hermesAureate
                                    : DesignSystem.Colors.whimsy,
                                onSelect: { openThreadInActivePane(thread.id) }
                            )
                            .draggable(PaneThreadDropPayload(threadID: thread.id))
                            .contextMenu {
                                Button("Open in Active Pane") { openThreadInActivePane(thread.id) }
                                Button("Open in New Tab") { workspace?.newTab(bindingThreadID: thread.id) }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.md)
    }

    private func openThreadInActivePane(_ threadID: String) {
        if let workspace {
            workspace.bind(threadID: threadID, toLeaf: workspace.activeLeafID)
        } else {
            activeController.openHistoryThread(threadID)
        }
    }

    private func railBadge(for threadID: String) -> ChatHistoryRow.PaneRailBadge {
        if workspace?.unseenThreadIDs.contains(threadID) == true { return .unseen }
        if workspace?.boundThreadIDs.contains(threadID) == true { return .openInPane }
        return .none
    }
}
