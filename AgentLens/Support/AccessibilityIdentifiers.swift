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
    static let localDBoxRoot = "agents.localDBox.root"
    static let localDBoxEnable = "agents.localDBox.enable"
    static let localDBoxAutoStart = "agents.localDBox.autoStart"
    static let localDBoxRefresh = "agents.localDBox.refresh"
    static let localDBoxComposer = "agents.localDBox.composer"
    static let localDBoxSend = "agents.localDBox.send"
    static let localDBoxEmpty = "agents.localDBox.empty"

    static func localDBoxAgent(_ id: String) -> String {
        "agents.localDBox.agent.\(normalized(id))"
    }
    static let chatPanel = "chat.panel"
    static let chatPanelMinimized = "chat.panel.minimized"
    static let chartsPage = "charts.page"
    static let chartsAIToggle = "charts.aiToggle"
    static let dashboardDeckChartButton = "dashboard.deckChartButton"

    // Control Deck
    static let controlDeck = "controlDeck.page"
    static let controlDeckEditMenu = "controlDeck.editMenu"

    static func controlDeckTile(_ kind: String) -> String {
        "controlDeck.tile.\(normalized(kind))"
    }

    static func controlDeckToggle(_ kind: String) -> String {
        "controlDeck.tile.toggle.\(normalized(kind))"
    }

    // Dashboard Home
    static let dashboardHomeRoot = "dashboardHome.root"
    static let dashboardHomeRail = "dashboardHome.rail"
    static let dashboardHomeRailToggle = "dashboardHome.railToggle"
    static let dashboardHomeInboxSwitcher = "dashboardHome.inboxSwitcher"
    static let dashboardHomeQuotaSwitcher = "dashboardHome.quotaSwitcher"
    static let dashboardHomeFleetSwitcher = "dashboardHome.fleetSwitcher"

    static func dashboardHomeRailPanel(_ panel: String) -> String {
        "dashboardHome.rail.panel.\(normalized(panel))"
    }

    static let inboxRoot = "inbox.root"
    static let inboxDetail = "inbox.detail"
    static let dashboardDeckInboxButton = "dashboard.deckInboxButton"

    static func inboxFilterChip(_ filter: String) -> String {
        "inbox.filter.\(normalized(filter))"
    }

    static func inboxRow(_ itemID: String) -> String {
        "inbox.row.\(normalized(itemID))"
    }

    static func settingsRow(_ section: String) -> String {
        "settings.row.\(normalized(section))"
    }

    static func providersRow(_ providerID: String) -> String {
        "providers.row.\(normalized(providerID))"
    }

    // Inbox management (pin / tag / category / order / select / delete)
    static let inboxOrderingMenu = "inbox.orderingMenu"
    static let inboxActionsMenu = "inbox.actionsMenu"
    static let inboxSelectionBar = "inbox.selectionBar"
    static let inboxUndoBanner = "inbox.undoBanner"

    static func inboxCategoryChip(_ category: String) -> String {
        "inbox.category.\(normalized(category))"
    }

    static func inboxSectionHeader(_ section: String) -> String {
        "inbox.section.\(normalized(section))"
    }

    // Inbox reading register — the one-tap "say that differently" chips.
    static func inboxRewriteChip(_ directive: String) -> String {
        "inbox.rewrite.\(normalized(directive))"
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}
