import SwiftUI

// MARK: - Chat Panel

struct ChatPanel: View {
    @Bindable var controller: ChatSessionController
    var dataStore: DataStoreCoordinator
    var settingsManager: SettingsManager
    var sharedFeaturesAvailable: Bool
    /// Overlay geometry for clamping drag offset (same space as `GeometryReader` wrapping the chat stack).
    var containerSize: CGSize
    var edgePadding: CGFloat = 20
    var onOpenConversationJump: (ConversationJumpTarget) -> Void = { _ in }
    var onClose: () -> Void

    @State private var brief = InsightBriefSnapshot()
    @State private var showClearChatPrompt = false

    var body: some View {
        Group {
            if controller.isMinimized {
                ChatMinimizedPill(
                    controller: controller,
                    containerSize: containerSize,
                    edgePadding: edgePadding,
                    onExpand: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            controller.isMinimized = false
                        }
                    }
                )
            } else {
                ChatExpandedPanel(
                    controller: controller,
                    dataStore: dataStore,
                    settingsManager: settingsManager,
                    brief: brief,
                    containerSize: containerSize,
                    edgePadding: edgePadding,
                    onOpenConversationJump: onOpenConversationJump,
                    onNewChat: { controller.clearChat() },
                    onMinimize: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            controller.isMinimized = true
                        }
                    },
                    onClose: onClose,
                    onShowClearChatPrompt: { showClearChatPrompt = true }
                )
            }
        }
        .onAppear {
            brief = controller.buildInsightBriefSnapshot(refreshRollups: false)
            controller.loadPersistedMessages()
            controller.reclampPanelOffset(container: containerSize, padding: edgePadding)
            Task { await refreshBackendAvailability() }
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
        .onChange(of: settingsManager.enabledChatBackendIDsCSV) { _, _ in
            controller.syncChatBackendWithEnabledBackends()
            Task { await refreshBackendAvailability() }
        }
        .onChange(of: containerSize) { _, new in
            controller.reclampPanelOffset(container: new, padding: edgePadding)
        }
        .confirmationDialog("Clear current chat?", isPresented: $showClearChatPrompt) {
            Button("Clear Current Chat", role: .destructive) {
                controller.clearChat()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This starts a new chat. Previous Burn Bar chats stay in History.")
        }
    }

    private func refreshBackendAvailability() async {
        let enabled = settingsManager.enabledChatBackends
        if enabled.contains(.hermes) {
            await controller.probeHermesAvailability()
        } else {
            controller.hermesAvailable = false
        }
        if enabled.contains(.openclaw) {
            await controller.probeOpenClawAvailability()
        } else {
            controller.openClawAvailable = false
        }
    }
}
