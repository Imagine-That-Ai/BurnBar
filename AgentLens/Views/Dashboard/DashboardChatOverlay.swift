import SwiftUI

struct DashboardChatOverlay: View {
    let chatController: ChatSessionController
    let dataStore: DataStoreCoordinator
    let settingsManager: SettingsManager
    let accountManager: AccountManager
    let containerSize: CGSize
    let sharedFeaturesAvailable: Bool
    @Binding var isOpen: Bool
    let hasNewInsights: Bool
    /// When true, the dashboard is rendering the maximized chat workspace; the
    /// floating overlay and FAB are hidden to avoid a duplicate surface.
    var isChatRoute: Bool = false
    let onRequestOpen: () -> Void
    let onOpenConversationJump: (ConversationJumpTarget) -> Void
    var onMaximize: (() -> Void)? = nil
    var onPopOut: (() -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if !isChatRoute {
                if isOpen {
                    ChatPanel(
                        controller: chatController,
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        sharedFeaturesAvailable: sharedFeaturesAvailable,
                        containerSize: containerSize,
                        edgePadding: 20,
                        onOpenConversationJump: onOpenConversationJump,
                        onMaximize: onMaximize,
                        onPopOut: onPopOut,
                        onClose: onClose
                    )
                    .offset(x: chatController.panelFloatOffset.width, y: chatController.panelFloatOffset.height)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                if !isOpen {
                    ChatFAB(hasNewInsights: hasNewInsights) {
                        onRequestOpen()
                    }
                }
            }
        }
        .fixedSize()
        .padding(EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
    }

    #if DEBUG
    func testTriggerOpen() {
        isOpen = true
    }

    func testTriggerClose() {
        isOpen = false
    }
    #endif
}
