import Foundation

// MARK: - Settings Manifest (iOS)

/// Hand-authored index of every searchable control inside the iOS Settings
/// hub and its sub-pages (Cloud, Providers, Hermes, Pi).
///
/// Adding a new searchable row:
/// 1. Add an entry below.
/// 2. Reference a stable `SettingsAnchor.<id>` (extend `SettingsAnchor` if
///    needed).
/// 3. On the destination view, attach `.id(SettingsAnchor.<id>)` to the row.
/// 4. For focusable controls, register the `focusID` against a
///    `@FocusState` in the destination.
enum SettingsManifest {

    static let all: [SettingsItem] = [

        // MARK: Appearance

        SettingsItem(
            id: "hub.appearance.theme",
            section: .appearance,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.theme,
            title: "Theme",
            subtitle: "System, Light, or Dark appearance",
            keywords: ["dark", "light", "appearance", "mode", "color"]
        ),
        SettingsItem(
            id: "hub.appearance.usageDisplay",
            section: .appearance,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.usageDisplay,
            title: "Default display",
            subtitle: "Show USD or token totals",
            keywords: ["currency", "tokens", "usd", "default"]
        ),

        // MARK: UI Mode

        SettingsItem(
            id: "hub.uiMode",
            section: .uiMode,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.uiMode,
            title: "UI Mode",
            subtitle: "Standard or focused interface",
            keywords: ["interface", "layout", "compact", "standard"]
        ),

        // MARK: Budget

        SettingsItem(
            id: "hub.budget.dailyBudget",
            section: .budget,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.dailyBudget,
            title: "Daily budget",
            subtitle: "Spending ceiling for today",
            keywords: ["spend", "budget", "ceiling", "limit", "usd"]
        ),
        SettingsItem(
            id: "hub.budget.costAlerts",
            section: .budget,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.costAlerts,
            title: "Cost alerts",
            subtitle: "Notify when spend crosses a threshold",
            keywords: ["alert", "threshold", "cost", "notification"]
        ),
        SettingsItem(
            id: "hub.budget.tokenAlerts",
            section: .budget,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.tokenAlerts,
            title: "Token alerts",
            subtitle: "Notify when token volume crosses a threshold",
            keywords: ["alert", "token", "threshold", "notification"]
        ),

        // MARK: Notifications

        SettingsItem(
            id: "hub.notifications.dailyDigest",
            section: .notifications,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.dailyDigest,
            title: "Daily digest",
            subtitle: "Receive a daily summary of spend and tokens",
            keywords: ["digest", "daily", "summary", "morning"]
        ),
        SettingsItem(
            id: "hub.notifications.sessionPings",
            section: .notifications,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.sessionPings,
            title: "Session pings",
            subtitle: "Notify when new sessions are detected",
            keywords: ["ping", "session", "notification"]
        ),
        SettingsItem(
            id: "hub.notifications.system",
            section: .notifications,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.openSystemNotifications,
            title: "Open system Notifications",
            subtitle: "Manage permissions in the iOS Settings app",
            keywords: ["system", "permissions", "notifications"]
        ),

        // MARK: Cloud

        SettingsItem(
            id: "hub.cloud",
            section: .cloud,
            pageRoute: .cloud,
            anchorID: SettingsAnchor.cloudRow,
            title: "OpenBurnBar Cloud",
            subtitle: "Quota, backups, Hermes — anywhere",
            keywords: ["cloud", "subscription", "premium", "sync", "backup"]
        ),
        SettingsItem(
            id: "cloud.membership",
            section: .cloud,
            pageRoute: .cloud,
            anchorID: SettingsAnchor.cloudMembership,
            title: "Membership",
            subtitle: "Active subscription status",
            keywords: ["membership", "plan", "active"]
        ),
        SettingsItem(
            id: "cloud.plan",
            section: .cloud,
            pageRoute: .cloud,
            anchorID: SettingsAnchor.cloudPlan,
            title: "Plan",
            subtitle: "Upgrade or change your plan",
            keywords: ["plan", "tier", "upgrade"]
        ),
        SettingsItem(
            id: "cloud.restore",
            section: .cloud,
            pageRoute: .cloud,
            anchorID: SettingsAnchor.cloudRestore,
            title: "Restore Purchases",
            subtitle: "Recover a prior subscription on this device",
            keywords: ["restore", "purchases", "appstore"]
        ),

        // MARK: Account

        SettingsItem(
            id: "hub.account",
            section: .account,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.accountRow,
            title: "Signed in",
            subtitle: "Identity for OpenBurnBar Cloud",
            keywords: ["sign", "login", "email", "account"]
        ),
        SettingsItem(
            id: "hub.account.delete",
            section: .account,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.deleteAccount,
            title: "Delete account",
            subtitle: "Permanently remove your OpenBurnBar cloud data",
            keywords: ["delete", "remove", "wipe", "gdpr"]
        ),

        // MARK: Providers

        SettingsItem(
            id: "hub.providers",
            section: .providers,
            pageRoute: .providerConnections,
            anchorID: SettingsAnchor.providersRow,
            title: "Provider connections",
            subtitle: "Connect Claude, OpenCode, Factory, OpenAI, Kimi, and more",
            keywords: ["providers", "claude", "opencode", "open code", "factory", "openai", "connections"]
        ),
        SettingsItem(
            id: "providers.add",
            section: .providers,
            pageRoute: .providerConnections,
            anchorID: SettingsAnchor.providerAdd,
            title: "Add Provider",
            subtitle: "Connect a new provider account",
            keywords: ["add", "new", "provider", "account", "opencode", "open code", "opencode go"]
        ),
        SettingsItem(
            id: "providers.openCode",
            section: .providers,
            pageRoute: .providerConnections,
            anchorID: SettingsAnchor.providerOpenCode,
            title: "OpenCode",
            subtitle: "Connect OpenCode and review its local quota/auth path",
            keywords: ["opencode", "open code", "opencode go", "cli", "quota", "auth", "provider"]
        ),
        SettingsItem(
            id: "providers.cliAuth",
            section: .providers,
            pageRoute: .providerConnections,
            anchorID: SettingsAnchor.providerCLIAuth,
            title: "CLI Authentication",
            subtitle: "OAuth and API key management for local CLIs",
            keywords: ["cli", "oauth", "api key", "auth", "opencode", "open code"]
        ),

        // MARK: AI environments — Hermes

        SettingsItem(
            id: "hub.hermes",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: SettingsAnchor.hermesRow,
            title: "Hermes",
            subtitle: "Hermes endpoints, models, gateway, pretext",
            keywords: ["hermes", "chat", "ai", "assistant"]
        ),
        SettingsItem(
            id: "hermes.connections",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: SettingsAnchor.hermesConnections,
            title: "Hermes Connections",
            subtitle: "Connected Hermes endpoints and tokens",
            keywords: ["connection", "endpoint", "url", "token"]
        ),
        SettingsItem(
            id: "hermes.models",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: SettingsAnchor.hermesModels,
            title: "Hermes Models",
            subtitle: "Default models exposed by Hermes",
            keywords: ["model", "llm", "claude", "gpt"]
        ),
        SettingsItem(
            id: "hermes.display.tps",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: SettingsAnchor.hermesDisplayTPS,
            title: "TPS overlay",
            subtitle: "Display tokens-per-second under streaming responses",
            keywords: ["tps", "tokens", "speed", "overlay"]
        ),
        SettingsItem(
            id: "hermes.pretext",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: SettingsAnchor.hermesPretext,
            title: "Pretext",
            subtitle: "System prompt prefix injected into every Hermes turn",
            keywords: ["pretext", "system prompt", "context", "prefix"]
        ),
        SettingsItem(
            id: "hermes.gateway.url",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: SettingsAnchor.hermesGatewayURL,
            focusID: SettingsFocus.hermesGatewayURL,
            title: "Hermes Gateway URL",
            subtitle: "Base URL of the Hermes webapi gateway",
            keywords: ["gateway", "url", "endpoint", "webapi"]
        ),
        SettingsItem(
            id: "hermes.gateway.token",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: SettingsAnchor.hermesGatewayToken,
            focusID: SettingsFocus.hermesGatewayToken,
            title: "Hermes Gateway Token",
            subtitle: "Bearer token used to authenticate to the gateway",
            keywords: ["bearer", "token", "secret", "gateway"]
        ),

        // MARK: AI environments — Pi

        SettingsItem(
            id: "hub.pi",
            section: .hermesAI,
            pageRoute: .pi,
            anchorID: SettingsAnchor.piRow,
            title: "Pi",
            subtitle: "Raspberry Pi runtimes",
            keywords: ["pi", "raspberry", "host", "edge"]
        ),
        SettingsItem(
            id: "pi.hosts",
            section: .hermesAI,
            pageRoute: .pi,
            anchorID: SettingsAnchor.piHosts,
            title: "Pi Hosts",
            subtitle: "Connected Raspberry Pi runtimes",
            keywords: ["host", "raspberry", "edge"]
        ),
        SettingsItem(
            id: "pi.models",
            section: .hermesAI,
            pageRoute: .pi,
            anchorID: SettingsAnchor.piModels,
            title: "Pi Models",
            subtitle: "Models exposed by Pi runtimes",
            keywords: ["model", "pi", "raspberry"]
        ),

        // MARK: About

        SettingsItem(
            id: "hub.about.version",
            section: .about,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.aboutVersion,
            title: "Version",
            subtitle: "OpenBurnBar app build and marketing version",
            keywords: ["version", "build", "release"]
        ),
        SettingsItem(
            id: "hub.about.privacy",
            section: .about,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.aboutPrivacy,
            title: "Privacy policy",
            subtitle: "How OpenBurnBar handles your data",
            keywords: ["privacy", "policy", "gdpr"]
        ),
        SettingsItem(
            id: "hub.about.terms",
            section: .about,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.aboutTerms,
            title: "Terms of service",
            subtitle: "Legal terms governing use of OpenBurnBar",
            keywords: ["terms", "legal", "service", "agreement"]
        ),
    ]

    /// Reverse-index from anchor id to page route, used by destination views
    /// to know whether they should consume the pending anchor.
    static let anchorIndex: [String: SettingsPageRoute] = {
        var index: [String: SettingsPageRoute] = [:]
        for item in all { index[item.anchorID] = item.pageRoute }
        return index
    }()
}
