import SwiftUI

@Observable
@MainActor
final class DashboardConsentCoordinator {
    let settingsManager: SettingsManager
    let accountManager: AccountManager

    var showIndexingConsent = false
    var showCLIConsentSheet = false
    var showSessionLogCloudConsent = false
    var showMemoryConsent = false
    var showUsageMemoryConsent = false

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

    /// First-run memory consent is eligible when it has never been presented.
    /// Sequencing (only one consent sheet at a time) is enforced at the trigger
    /// site so it never stacks on top of the indexing prompt.
    var shouldShowMemoryConsent: Bool {
        !settingsManager.memoryConsentShown
    }

    /// First-run usage-memory consent is THIRD in the one-at-a-time chain: it is
    /// eligible only after both the conversation-indexing prompt and the
    /// chat-memory consent have been settled (shown, whatever the decision), so
    /// the permission moments arrive one per visit instead of stacking.
    var shouldShowUsageMemoryConsent: Bool {
        !settingsManager.usageMemoryConsentShown
            && settingsManager.memoryConsentShown
            && settingsManager.conversationIndexingConsentShown
    }

    func confirmIndexingConsent(enable: Bool, aggregator: UsageAggregator?) {
        settingsManager.conversationIndexingEnabled = enable
        settingsManager.conversationIndexingConsentShown = true
        if enable {
            Task { await aggregator?.refreshAll() }
        }
    }

    /// Records the first-run memory consent decision. Granting flips
    /// `memoryConsentGranted` (whose setter also marks the prompt shown);
    /// declining only marks it shown so the loop stays dormant.
    func confirmMemoryConsent(grant: Bool) {
        settingsManager.memoryConsentGranted = grant
        if !grant {
            settingsManager.memoryConsentShown = true
        }
    }

    /// Records the first-run usage-memory consent decision. Granting flips
    /// `usageMemoryConsentGranted` (whose setter also marks the prompt shown);
    /// declining only marks it shown so the usage loop stays dormant.
    func confirmUsageMemoryConsent(grant: Bool) {
        settingsManager.usageMemoryConsentGranted = grant
        if !grant {
            settingsManager.usageMemoryConsentShown = true
        }
    }

    func onDashboardAppear(aggregator: UsageAggregator?) {
        if !settingsManager.conversationIndexingConsentShown {
            showIndexingConsent = true
        } else if shouldShowMemoryConsent {
            // Only surface memory consent once the indexing prompt is settled,
            // so the two first-run sheets never stack.
            showMemoryConsent = true
        } else if shouldShowUsageMemoryConsent {
            // Usage-memory consent is third: it waits for both prior prompts
            // to settle, keeping the chain strictly one sheet at a time.
            showUsageMemoryConsent = true
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
