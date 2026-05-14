import Foundation
import OpenBurnBarCore

// MARK: - Settings Search Item

/// A single indexable control inside the Settings hierarchy.
///
/// Hand-authored entries live in `SettingsManifest`. Each item points to a
/// `tab` (which sidebar selection owns it), a `pageRoute` (which detail screen
/// drills to it), an `anchorID` (a stable string passed to `View.id(_:)` so
/// `ScrollViewReader` can scroll it into view), and an optional `focusID`
/// (used by detail screens to set a `@FocusState` on a text field or stepper
/// once the page appears).
///
/// Keywords are the synonym net — what users type when they don't know the
/// exact label. `helpText` is opt-in long-form context indexed at lowest
/// weight. Title carries the most weight; see `SettingsSearchEngine`.
struct SettingsItem: Hashable, Identifiable {
    /// Stable, unique identifier — typed-string form so manifest authors can
    /// keep entries readable (`"general.appearance.theme"`).
    let id: String

    /// Sidebar tab that owns this item.
    let tab: SettingsTab

    /// Page-level route identifier. The detail view inspects
    /// `SettingsRouter.pendingAnchor` and decides whether to scroll to the
    /// matching `anchorID`. Multiple items can share a `pageRoute`.
    let pageRoute: SettingsPageRoute

    /// Anchor target used by the destination `ScrollViewReader`. Authors are
    /// expected to attach `.id(SettingsAnchor.<anchorID>)` to the row.
    let anchorID: String

    /// Optional focus target for text fields, steppers, secure fields, etc.
    /// Destination views match this against their `@FocusState` enum.
    let focusID: String?

    /// Primary label as seen in the UI.
    let title: String

    /// Optional descriptive line shown under `title` in the matching row.
    let subtitle: String?

    /// Synonyms / alternates users might type.
    let keywords: [String]

    /// Long-form help indexed at the lowest weight.
    let helpText: String?

    /// Provider logos that should visually identify this setting in search
    /// results. Empty means the row falls back to its section/system icon.
    let logoProviders: [AgentProvider]

    init(
        id: String,
        tab: SettingsTab,
        pageRoute: SettingsPageRoute,
        anchorID: String,
        focusID: String? = nil,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        helpText: String? = nil,
        logoProviders: [AgentProvider] = []
    ) {
        self.id = id
        self.tab = tab
        self.pageRoute = pageRoute
        self.anchorID = anchorID
        self.focusID = focusID
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.helpText = helpText
        self.logoProviders = logoProviders
    }
}

// MARK: - Page Routes

/// Concrete destinations inside the macOS Settings hierarchy. Each case maps
/// 1:1 to a sub-screen that can be pushed via `NavigationStack`.
enum SettingsPageRoute: Hashable, Codable {
    // General
    case generalRoot
    case operatorModel
    case appearance
    case defaultView
    case dataRefresh
    case indexing
    case sessionSummaries

    // Daemon
    case daemonRoot
    case daemonLifecycle
    case httpGateway
    case controllerRuntime

    // Account
    case accountRoot

    // Providers
    case providersRoot

    // Routing pools
    case routingPoolsRoot

    // Alerts
    case alertsRoot

    // Notifications
    case notificationsRoot

    // Devices & Sync
    case devicesAndSyncRoot

    // Account Switcher
    case switcherRoot

    // Hermes / AI Environments
    case hermesRoot
    case hermesChatEngines
    case hermesGateway
    case hermesPiAgent
    case hermesRelay
    case hermesPiRelay
}

// MARK: - Anchor IDs

/// Centralized anchor and focus identifiers so manifest entries and detail
/// views agree on a single source of truth.
enum SettingsAnchor {
    // General → Appearance
    static let appearanceTheme = "general.appearance.theme"
    static let appearanceMenuBar = "general.appearance.menuBar"
    static let appearanceLaunchAtLogin = "general.appearance.launchAtLogin"

    // General → Defaults
    static let defaultsTimeRange = "general.defaults.timeRange"
    static let defaultsUsageMode = "general.defaults.usageDisplayMode"

    // General → Refresh
    static let refreshInterval = "general.refresh.interval"

    // General → Indexing
    static let indexingToggle = "general.indexing.enabled"

    // General → Summaries
    static let summariesAuto = "general.summaries.auto"

    // General → Operator
    static let operatorWizard = "general.operator.wizard"

    // Daemon → Lifecycle
    static let daemonStatus = "daemon.lifecycle.status"

    // Daemon → HTTP Gateway
    static let gatewayEnabled = "daemon.gateway.enabled"
    static let gatewayHost = "daemon.gateway.host"
    static let gatewayPort = "daemon.gateway.port"
    static let gatewayAuthToken = "daemon.gateway.authToken"

    // Daemon → Controller runtime
    static let controllerEnabled = "daemon.controller.enabled"
    static let controllerRefresh = "daemon.controller.refreshCadence"
    static let controllerSimulator = "daemon.controller.simulator"

    // Account
    static let accountSignIn = "account.signIn"
    static let accountSubscription = "account.subscription"
    static let accountDelete = "account.delete"

    // Providers
    static let providersAdd = "providers.add"
    static let providersCLI = "providers.cliAuth"
    static let providersLogSources = "providers.logSources"
    static let providersOpenCode = "providers.cli.opencode"

    static func providerLogSource(_ persistedToken: String) -> String {
        "providers.logSource.\(persistedToken)"
    }

    static func providerCLI(_ cliToken: String) -> String {
        "providers.cli.\(cliToken)"
    }

    // Routing pools
    static let routingPoolsOverview = "routingPools.overview"

    // Alerts
    static let alertsDailySpend = "alerts.dailySpend"
    static let alertsDigest = "alerts.digest"

    // Notifications
    static let notificationsLocal = "notifications.local"
    static let notificationsTelegram = "notifications.telegram"
    static let notificationsCalendar = "notifications.calendar"

    // Devices & Sync
    static let cloudSyncToggle = "devices.cloudSync"
    static let trustedDevices = "devices.trusted"
    static let smartDisplays = "devices.smartDisplays"

    // Switcher
    static let switcherBrowser = "switcher.browser"
    static let switcherCLI = "switcher.cli"

    // Hermes
    static let hermesConnections = "hermes.connections"
    static let hermesModels = "hermes.models"
    static let hermesGatewayURL = "hermes.gateway.url"
    static let hermesGatewayToken = "hermes.gateway.token"
    static let hermesPiHosts = "hermes.pi.hosts"
    static let hermesRelay = "hermes.relay"
    static let hermesPiRelay = "hermes.pi.relay"
}

// MARK: - Focus IDs

enum SettingsFocus {
    static let gatewayHost = "daemon.gateway.host"
    static let gatewayPort = "daemon.gateway.port"
    static let gatewayAuthToken = "daemon.gateway.authToken"
    static let hermesGatewayURL = "hermes.gateway.url"
    static let hermesGatewayToken = "hermes.gateway.token"
    static let alertsDailySpend = "alerts.dailySpend"
}
