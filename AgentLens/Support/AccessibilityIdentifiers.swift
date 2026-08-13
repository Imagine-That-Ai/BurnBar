import Foundation

enum OBBAccessibilityID {
    static let menuBarStatusItem = "menuBar.statusItem"
    static let popoverRoot = "popover.root"
    static let popoverDashboardButton = "popover.dashboardButton"
    static let popoverSettingsButton = "popover.settingsButton"
    static let dashboardRoot = "dashboard.root"
    static let dashboardLayoutSwitcher = "dashboard.layoutSwitcher"
    static let dashboardViewModeSwitcher = "dashboard.viewModeSwitcher"
    static let dashboardOverflowButton = "dashboard.overflowButton"
    static let dashboardSettingsButton = "dashboard.settingsButton"
    static let dashboardRefreshButton = "dashboard.refreshButton"
    static let dashboardBackButton = "dashboard.backButton"
    static let dashboardForwardButton = "dashboard.forwardButton"
    static let dashboardSidebarToggleButton = "dashboard.sidebarToggleButton"
    static let settingsRoot = "settings.root"
    static let settingsSidebar = "settings.sidebar"
    static let settingsCommandBar = "settings.commandBar"
    static let computerUseSettingsRoot = "computerUse.settings.root"
    static let chatPanel = "chat.panel"
    static let chatPanelMinimized = "chat.panel.minimized"
    static let chartsPage = "charts.page"
    static let chartsAIToggle = "charts.aiToggle"
    static let dashboardDeckChartButton = "dashboard.deckChartButton"
    static let safariLearningRoot = "safariLearning.root"
    static let safariLearningProfileToggle = "safariLearning.profileToggle"
    static let safariLearningDeleteProfile = "safariLearning.deleteProfile"
    static let safariLearningSearch = "safariLearning.search"
    static let safariLearningRefresh = "safariLearning.refresh"
    static let safariLearningEditor = "safariLearning.editor"
    static let safariLearningEditorTitle = "safariLearning.editor.title"
    static let safariLearningEditorContent = "safariLearning.editor.content"
    static let safariLearningEditorSave = "safariLearning.editor.save"

    static let inboxRoot = "inbox.root"
    static let inboxDetail = "inbox.detail"
    static let dashboardDeckInboxButton = "dashboard.deckInboxButton"

    static func inboxFilterChip(_ filter: String) -> String {
        "inbox.filter.\(normalized(filter))"
    }

    static func inboxRow(_ itemID: String) -> String {
        "inbox.row.\(normalized(itemID))"
    }

    static func safariLearningFilter(_ filter: String) -> String {
        "safariLearning.filter.\(normalized(filter))"
    }

    static func safariLearningRow(_ proposalID: String) -> String {
        "safariLearning.row.\(normalized(proposalID))"
    }

    static func settingsRow(_ section: String) -> String {
        "settings.row.\(normalized(section))"
    }

    static func providersRow(_ providerID: String) -> String {
        "providers.row.\(normalized(providerID))"
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}
