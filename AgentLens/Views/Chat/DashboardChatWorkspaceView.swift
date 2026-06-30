import SwiftUI
import OpenBurnBarCore
import UniformTypeIdentifiers

/// Full-canvas chat experience, modeled after Claude.ai and ChatGPT.
///
/// Layout:
///   ┌─ Toolbar ─────────────────────────────────────────────────────────┐
///   │ Backend  Model   New chat  ⋯  Pop out  Restore window  Close      │
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

    /// The pane-tiling workspace for the right-side viewer. Built lazily on first appear
    /// from the persisted layout (or a single primary pane bound to `controller`).
    @State private var workspace: PaneWorkspaceModel?

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
                showsEnginePickers: !(workspace?.isTiled ?? false),
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

                Group {
                    if let workspace {
                        PaneWorkspaceView(
                            workspace: workspace,
                            settingsManager: settingsManager,
                            onJumpToConversation: onOpenConversationJump
                        )
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
            Text("This starts a new chat. Previous Burn Bar chats stay in History.")
        }
        .hermesRuntimeGate(
            controller: controller,
            settingsManager: settingsManager,
            dataStore: dataStore
        )
    }

    /// Apply an action to every pane's controller (or just the app-wide controller before
    /// the workspace is built), so global setting changes reach all panes.
    private func forEachController(_ body: (ChatSessionController) -> Void) {
        if let workspace {
            workspace.leaves.forEach { body($0.controller) }
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
                                isActive: thread.id == activeController.activeThreadID,
                                isOpenInPane: workspace?.boundThreadIDs.contains(thread.id) ?? false,
                                accent: activeController.chatBackend == .hermes
                                    ? DesignSystem.Colors.hermesAureate
                                    : DesignSystem.Colors.whimsy,
                                onSelect: { activeController.openHistoryThread(thread.id) }
                            )
                            .draggable(thread.id)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.md)
    }
}
