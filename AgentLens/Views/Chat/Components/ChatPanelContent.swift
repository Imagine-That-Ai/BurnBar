import SwiftUI

/// Floating `ChatPanel` body wrapper. Delegates the actual message rendering
/// to `ChatMessagesStream` so the maximized workspace and pop-out window
/// share the same component.
struct ChatPanelContent: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var onJumpToConversation: (ConversationJumpTarget) -> Void

    var body: some View {
        ChatMessagesStream(
            controller: controller,
            settingsManager: settingsManager,
            maxContentWidth: .infinity,
            horizontalPadding: DesignSystem.Spacing.md,
            verticalPadding: DesignSystem.Spacing.md,
            onJumpToConversation: onJumpToConversation
        )
    }
}
