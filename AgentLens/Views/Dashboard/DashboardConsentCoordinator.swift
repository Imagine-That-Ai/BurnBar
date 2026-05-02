import SwiftUI

@Observable
@MainActor
final class DashboardConsentCoordinator {
    let settingsManager: SettingsManager
    let accountManager: AccountManager

    var showIndexingConsent = false
    var showCLIConsentSheet = false
    var showSessionLogCloudConsent = false

    init(settingsManager: SettingsManager, accountManager: AccountManager) {
        self.settingsManager = settingsManager
        self.accountManager = accountManager
    }

    var shouldShowIndexingConsent: Bool {
        !settingsManager.conversationIndexingConsentShown
    }

    var shouldShowCloudBackupConsent: Bool {
        accountManager.isSignedIn && !settingsManager.sessionLogCloudBackupConsentShown
    }

    func confirmIndexingConsent(enable: Bool, aggregator: UsageAggregator?) {
        settingsManager.conversationIndexingEnabled = enable
        settingsManager.conversationIndexingConsentShown = true
        if enable {
            Task { await aggregator?.refreshAll() }
        }
    }

    func onDashboardAppear(aggregator: UsageAggregator?) {
        if !settingsManager.conversationIndexingConsentShown {
            showIndexingConsent = true
        }
    }

    func onSignInChange(isSignedIn: Bool, chatController: ChatSessionController) {
        chatController.refreshRetrievalHealth(sharedFeaturesAvailable: isSignedIn)
        if isSignedIn && !settingsManager.sessionLogCloudBackupConsentShown {
            showSessionLogCloudConsent = true
        }
    }

    func openChatPanelIfConsented(chatController: ChatSessionController, open: () -> Void) {
        if !settingsManager.cliAssistantConsentShown {
            showCLIConsentSheet = true
            return
        }
        Task { await chatController.cliBridge.detect() }
        open()
    }
}
