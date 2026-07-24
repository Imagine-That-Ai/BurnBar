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
    static let settingsRoot = "settings.root"
    static let settingsSidebar = "settings.sidebar"
    static let settingsCommandBar = "settings.commandBar"
    static let computerUseSettingsRoot = "computerUse.settings.root"
    static let chatPanel = "chat.panel"
    static let chatPanelMinimized = "chat.panel.minimized"
    static let chartsPage = "charts.page"
    static let chartsAIToggle = "charts.aiToggle"
    static let calendarPage = "calendar.page"
    static let calendarMonthGrid = "calendar.monthGrid"
    static let dashboardDeckChartButton = "dashboard.deckChartButton"

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
