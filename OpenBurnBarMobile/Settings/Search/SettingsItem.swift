import Foundation
import OpenBurnBarCore

// MARK: - Settings Search Item (iOS)

/// A single indexable control inside the iOS/iPadOS Settings hierarchy.
///
/// Mirrors the shape of the macOS `SettingsItem` so the search engine can
/// stay structurally identical across platforms while each platform owns
/// its own manifest and routing.
struct SettingsItem: Hashable, Identifiable {
    /// Stable typed-string identifier (e.g. `"appearance.theme"`).
    let id: String

    /// Sidebar / Form section that owns this item.
    let section: SettingsSection

    /// Deep-link route used to push the destination view onto the
    /// `NavigationStack`. `.hubRoot` means the row already lives on the
    /// Settings root form.
    let pageRoute: SettingsPageRoute

    /// Stable id attached to the row via `.id(_:)` so `ScrollViewReader`
    /// (or the SwiftUI scroll proxy in a `Form`) can scroll the row into
    /// view on arrival.
    let anchorID: String

    /// Optional focus target a destination view uses to latch a
    /// `@FocusState` onto a text field / stepper.
    let focusID: String?

    /// Primary user-facing label.
    let title: String

    /// Optional descriptive line.
    let subtitle: String?

    /// Synonyms / alternate phrasings.
    let keywords: [String]

    /// Long-form indexed at the lowest weight.
    let helpText: String?

    /// Provider logos shown in search results when the setting maps to a
    /// provider, provider family, or AI environment.
    let logoProviders: [AgentProvider]

    init(
        id: String,
        section: SettingsSection,
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
        self.section = section
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

// MARK: - Sections

/// Top-level sections in the iOS Settings hub. Mirrors the section groups in
/// `SettingsHubView`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case uiMode
    case budget
    case notifications
    case cloud
    case account
    case providers
    case hermesAI
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .uiMode: return "UI Mode"
        case .budget: return "Budget"
        case .notifications: return "Notifications"
        case .cloud: return "Cloud"
        case .account: return "Account"
        case .providers: return "Providers"
        case .hermesAI: return "AI Environments"
        case .about: return "About"
        }
    }
}

// MARK: - Page Routes

/// Concrete destinations the iOS `SettingsRouter` knows how to push onto a
/// `NavigationStack`.
enum SettingsPageRoute: Hashable, Codable {
    /// The row lives on the Settings root Form.
    case hubRoot
    /// `CloudStoreView` (subscription / plan / capabilities).
    case cloud
    /// `ProviderConnectionsView` (add account, per-provider rows).
    case providerConnections
    /// `HermesSettingsView` (Hermes endpoints, models, gateway, pretext).
    case hermes
    /// `PiSettingsView` (Raspberry Pi runtimes).
    case pi
    /// `ChatTilesSettingsView` — which chat tiles appear in the runtime pill +
    /// which Hermes sub-providers appear in the model picker.
    case chatTiles
}

// MARK: - Anchor IDs

/// Stable scroll/focus anchor ids reused by `SettingsRouter` and the
/// destination views.
enum SettingsAnchor {
    // Hub / root
    static let theme = "hub.appearance.theme"
    static let usageDisplay = "hub.appearance.usageDisplay"
    static let uiMode = "hub.uiMode"
    static let dailyBudget = "hub.budget.dailyBudget"
    static let costAlerts = "hub.budget.costAlerts"
    static let tokenAlerts = "hub.budget.tokenAlerts"
    static let dailyDigest = "hub.notifications.dailyDigest"
    static let sessionPings = "hub.notifications.sessionPings"
    static let openSystemNotifications = "hub.notifications.system"
    static let cloudRow = "hub.cloud.row"
    static let accountRow = "hub.account.row"
    static let deleteAccount = "hub.account.deleteAccount"
    static let providersRow = "hub.providers.row"
    static let hermesRow = "hub.hermes.row"
    static let piRow = "hub.pi.row"
    static let aboutVersion = "hub.about.version"
    static let aboutPrivacy = "hub.about.privacy"
    static let aboutTerms = "hub.about.terms"

    // Cloud
    static let cloudMembership = "cloud.membership"
    static let cloudPlan = "cloud.plan"
    static let cloudRestore = "cloud.restore"

    // Provider connections
    static let providerAdd = "providers.add"
    static let providerCLIAuth = "providers.cliAuth"
    static let providerOpenCode = "providers.provider.opencode"

    static func provider(_ persistedToken: String) -> String {
        "providers.provider.\(persistedToken)"
    }

    // Hermes
    static let hermesConnections = "hermes.connections"
    static let hermesModels = "hermes.models"
    static let hermesDisplayTPS = "hermes.display.tps"
    static let hermesPretext = "hermes.pretext"
    static let hermesGatewayURL = "hermes.gateway.url"
    static let hermesGatewayToken = "hermes.gateway.token"

    // Pi
    static let piHosts = "pi.hosts"
    static let piModels = "pi.models"
}

// MARK: - Focus IDs

enum SettingsFocus {
    static let hermesGatewayURL = "hermes.gateway.url"
    static let hermesGatewayToken = "hermes.gateway.token"
}
