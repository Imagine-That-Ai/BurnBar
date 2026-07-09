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
    static let settingsRoot = "settings.root"
    static let settingsSidebar = "settings.sidebar"
    static let settingsCommandBar = "settings.commandBar"
    static let computerUseSettingsRoot = "computerUse.settings.root"
    static let chatPanel = "chat.panel"
    static let chatPanelMinimized = "chat.panel.minimized"

    static func settingsRow(_ section: String) -> String {
        "settings.row.\(normalized(section))"
    }

    static func providersRow(_ providerID: String) -> String {
        "providers.row.\(normalized(providerID))"
    }

    static func dashboardViewMode(_ mode: String) -> String {
        "dashboard.viewMode.\(normalized(mode))"
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}
