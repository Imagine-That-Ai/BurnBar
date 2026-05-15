import Foundation
import OpenBurnBarCore

// MARK: - Settings Manifest (macOS)

/// Hand-authored index of every searchable control inside macOS Settings.
///
/// Each entry binds a user-facing label and its synonym set to a `pageRoute`
/// (detail screen) and `anchorID` (scroll target) so `SettingsRouter` can
/// land the user on the exact row, not just the section.
///
/// To add a new searchable item:
/// 1. Add an entry below.
/// 2. Add a matching `SettingsAnchor.<id>` if one doesn't exist.
/// 3. On the destination view, attach `.id(SettingsAnchor.<id>)` to the row.
/// 4. For focus-able controls, register the `focusID` against a
///    `@FocusState` in the destination.
enum SettingsManifest {

    static let all: [SettingsItem] = baseItems + providerItems

    private static let baseItems: [SettingsItem] = [

        // MARK: General → Operator model & setup

        SettingsItem(
            id: "general.operator.wizard",
            tab: .general,
            pageRoute: .operatorModel,
            anchorID: SettingsAnchor.operatorWizard,
            title: "Setup Wizard",
            subtitle: "Run the guided onboarding wizard",
            keywords: ["onboarding", "agents", "detect", "wizard", "setup"],
            helpText: "Detects installed agents, enables indexing, and configures cloud features."
        ),

        // MARK: General → Appearance

        SettingsItem(
            id: "general.appearance.theme",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceTheme,
            title: "Theme",
            subtitle: "System, Light, or Dark appearance",
            keywords: ["dark", "light", "appearance", "mode", "color"],
            helpText: "Choose whether OpenBurnBar follows macOS or pins to Light or Dark."
        ),
        SettingsItem(
            id: "general.appearance.menuBar",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceMenuBar,
            title: "Menu Bar Visibility",
            subtitle: "Show the OpenBurnBar icon in the menu bar",
            keywords: ["menubar", "icon", "tray", "hide"]
        ),
        SettingsItem(
            id: "general.appearance.launchAtLogin",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceLaunchAtLogin,
            title: "Launch at Login",
            subtitle: "Start OpenBurnBar automatically when you sign in",
            keywords: ["autostart", "boot", "startup", "login items"]
        ),

        // MARK: General → Dashboard defaults

        SettingsItem(
            id: "general.defaults.timeRange",
            tab: .general,
            pageRoute: .defaultView,
            anchorID: SettingsAnchor.defaultsTimeRange,
            title: "Default Time Range",
            subtitle: "Window used by charts and totals",
            keywords: ["day", "week", "month", "range", "window", "default"]
        ),
        SettingsItem(
            id: "general.defaults.usageMode",
            tab: .general,
            pageRoute: .defaultView,
            anchorID: SettingsAnchor.defaultsUsageMode,
            title: "Usage Display",
            subtitle: "Show USD spend or token totals (M / B)",
            keywords: ["currency", "tokens", "usd", "dollars", "units"]
        ),

        // MARK: General → Refresh

        SettingsItem(
            id: "general.refresh.interval",
            tab: .general,
            pageRoute: .dataRefresh,
            anchorID: SettingsAnchor.refreshInterval,
            title: "Refresh Interval",
            subtitle: "How often OpenBurnBar scans for new sessions",
            keywords: ["polling", "interval", "scan", "rate", "frequency"]
        ),

        // MARK: General → Indexing

        SettingsItem(
            id: "general.indexing.enabled",
            tab: .general,
            pageRoute: .indexing,
            anchorID: SettingsAnchor.indexingToggle,
            title: "Indexing & Search",
            subtitle: "Local conversation indexing and embeddings",
            keywords: ["search", "index", "embeddings", "rag", "rerank"],
            helpText: "Indexed transcripts never leave this Mac unless cloud backup is enabled."
        ),

        // MARK: General → Session summaries

        SettingsItem(
            id: "general.summaries.auto",
            tab: .general,
            pageRoute: .sessionSummaries,
            anchorID: SettingsAnchor.summariesAuto,
            title: "Auto-Generate Session Summaries",
            subtitle: "Write a recap after every scan",
            keywords: ["recap", "summary", "session", "auto"]
        ),

        // MARK: Daemon → Lifecycle

        SettingsItem(
            id: "daemon.lifecycle.status",
            tab: .daemon,
            pageRoute: .daemonLifecycle,
            anchorID: SettingsAnchor.daemonStatus,
            title: "Daemon Lifecycle",
            subtitle: "Install, repair, and watch the local daemon",
            keywords: ["daemon", "service", "install", "repair", "health"]
        ),

        // MARK: Daemon → HTTP gateway

        SettingsItem(
            id: "daemon.gateway.enabled",
            tab: .daemon,
            pageRoute: .httpGateway,
            anchorID: SettingsAnchor.gatewayEnabled,
            title: "HTTP Gateway",
            subtitle: "Expose an OpenAI-compatible API on a local port",
            keywords: ["api", "openai", "gateway", "endpoint", "vibeproxy"]
        ),
        SettingsItem(
            id: "daemon.gateway.host",
            tab: .daemon,
            pageRoute: .httpGateway,
            anchorID: SettingsAnchor.gatewayHost,
            focusID: SettingsFocus.gatewayHost,
            title: "Gateway Host",
            subtitle: "Bind address for the gateway server",
            keywords: ["host", "bind", "address", "127.0.0.1", "localhost"]
        ),
        SettingsItem(
            id: "daemon.gateway.port",
            tab: .daemon,
            pageRoute: .httpGateway,
            anchorID: SettingsAnchor.gatewayPort,
            focusID: SettingsFocus.gatewayPort,
            title: "Gateway Port",
            subtitle: "TCP port the gateway listens on",
            keywords: ["port", "tcp", "8317", "vibeproxy"]
        ),
        SettingsItem(
            id: "daemon.gateway.token",
            tab: .daemon,
            pageRoute: .httpGateway,
            anchorID: SettingsAnchor.gatewayAuthToken,
            focusID: SettingsFocus.gatewayAuthToken,
            title: "Gateway Auth Token",
            subtitle: "Required for non-loopback bindings",
            keywords: ["token", "auth", "bearer", "secret"]
        ),

        // MARK: Daemon → Controller runtime

        SettingsItem(
            id: "daemon.controller.enabled",
            tab: .daemon,
            pageRoute: .controllerRuntime,
            anchorID: SettingsAnchor.controllerEnabled,
            title: "Controller Runtime",
            subtitle: "Mirror daemon missions and replay state",
            keywords: ["controller", "runtime", "missions", "operator", "replay"]
        ),
        SettingsItem(
            id: "daemon.controller.refresh",
            tab: .daemon,
            pageRoute: .controllerRuntime,
            anchorID: SettingsAnchor.controllerRefresh,
            title: "Controller Refresh Cadence",
            subtitle: "How often to mirror runtime state",
            keywords: ["refresh", "cadence", "polling", "mirror"]
        ),
        SettingsItem(
            id: "daemon.controller.simulator",
            tab: .daemon,
            pageRoute: .controllerRuntime,
            anchorID: SettingsAnchor.controllerSimulator,
            title: "Simulator Tools",
            subtitle: "Expose replay and simulator controls",
            keywords: ["simulator", "replay", "operator", "preview"]
        ),

        // MARK: Account

        SettingsItem(
            id: "account.signIn",
            tab: .account,
            pageRoute: .accountRoot,
            anchorID: SettingsAnchor.accountSignIn,
            title: "Sign In",
            subtitle: "Sign in with Apple, Google, or email",
            keywords: ["login", "apple", "google", "email", "signin"]
        ),
        SettingsItem(
            id: "account.subscription",
            tab: .account,
            pageRoute: .accountRoot,
            anchorID: SettingsAnchor.accountSubscription,
            title: "Subscription",
            subtitle: "OpenBurnBar Cloud plan and billing",
            keywords: ["plan", "subscription", "billing", "premium", "upgrade"]
        ),
        SettingsItem(
            id: "account.delete",
            tab: .account,
            pageRoute: .accountRoot,
            anchorID: SettingsAnchor.accountDelete,
            title: "Delete Account",
            subtitle: "Permanently remove your cloud account",
            keywords: ["delete", "remove", "wipe", "gdpr"]
        ),

        // MARK: Cloud

        SettingsItem(
            id: "cloud.overview",
            tab: .cloud,
            pageRoute: .cloudRoot,
            anchorID: SettingsAnchor.cloudOverview,
            title: "OpenBurnBar Cloud",
            subtitle: "Hosted refresh, backup, remote MCP clients, and member status",
            keywords: ["cloud", "member", "pro", "hosted", "backup", "remote mcp", "subscription", "billing", "relay"]
        ),

        // MARK: Providers

        SettingsItem(
            id: "providers.add",
            tab: .providers,
            pageRoute: .providersRoot,
            anchorID: SettingsAnchor.providersAdd,
            title: "Add Provider Account",
            subtitle: "Connect Claude, OpenCode, Factory, OpenAI, Kimi, and more",
            keywords: ["add", "account", "provider", "claude", "opencode", "open code", "opencode go", "factory", "openai", "anthropic"],
            logoProviders: [.claudeCode, .openCode, .factory, .openAI]
        ),
        SettingsItem(
            id: "providers.cli",
            tab: .providers,
            pageRoute: .providersRoot,
            anchorID: SettingsAnchor.providersCLI,
            title: "CLI Authentication",
            subtitle: "OAuth and API key management for local CLIs",
            keywords: ["cli", "oauth", "api key", "anthropic", "openai", "opencode", "open code", "auth"],
            logoProviders: [.claudeCode, .codex, .openCode]
        ),
        SettingsItem(
            id: "providers.logSources",
            tab: .providers,
            pageRoute: .providersRoot,
            anchorID: SettingsAnchor.providersLogSources,
            title: "Log Sources",
            subtitle: "Enable or disable individual on-disk log scans",
            keywords: ["logs", "sources", "scan", "claude code", "factory droid", "codex", "opencode", "open code"],
            logoProviders: [.claudeCode, .codex, .openCode, .factory]
        ),

        // MARK: Routing pools

        SettingsItem(
            id: "routingPools.overview",
            tab: .routingPools,
            pageRoute: .routingPoolsRoot,
            anchorID: SettingsAnchor.routingPoolsOverview,
            title: "Routing Pools",
            subtitle: "Wire Claude Code, OpenCode, and OpenAI-compatible clients through routed provider pools",
            keywords: ["routing", "fire hydrant", "pools", "failover", "claude code", "codex", "opencode", "open code", "gateway"],
            logoProviders: [.claudeCode, .codex, .openCode, .openAI]
        ),

        // MARK: Alerts

        SettingsItem(
            id: "alerts.dailySpend",
            tab: .alerts,
            pageRoute: .alertsRoot,
            anchorID: SettingsAnchor.alertsDailySpend,
            focusID: SettingsFocus.alertsDailySpend,
            title: "Daily Spend Threshold",
            subtitle: "Notify when today's USD crosses this number",
            keywords: ["spend", "budget", "threshold", "limit", "alert", "usd"]
        ),
        SettingsItem(
            id: "alerts.digest",
            tab: .alerts,
            pageRoute: .alertsRoot,
            anchorID: SettingsAnchor.alertsDigest,
            title: "Daily Digest",
            subtitle: "Receive a daily summary of spend and tokens",
            keywords: ["digest", "daily", "summary", "morning"]
        ),

        // MARK: Notifications

        SettingsItem(
            id: "notifications.local",
            tab: .notifications,
            pageRoute: .notificationsRoot,
            anchorID: SettingsAnchor.notificationsLocal,
            title: "Local Notifications",
            subtitle: "Banner alerts on this Mac",
            keywords: ["banner", "notification", "alert", "local", "ping"]
        ),
        SettingsItem(
            id: "notifications.telegram",
            tab: .notifications,
            pageRoute: .notificationsRoot,
            anchorID: SettingsAnchor.notificationsTelegram,
            title: "Telegram",
            subtitle: "Bot token and chat ID for Telegram alerts",
            keywords: ["telegram", "bot", "chat id", "messenger"]
        ),
        SettingsItem(
            id: "notifications.calendar",
            tab: .notifications,
            pageRoute: .notificationsRoot,
            anchorID: SettingsAnchor.notificationsCalendar,
            title: "Calendar",
            subtitle: "Mirror digests to a calendar of your choice",
            keywords: ["calendar", "ical", "google calendar", "event"]
        ),

        // MARK: Devices & Sync

        SettingsItem(
            id: "devices.cloudSync",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.cloudSyncToggle,
            title: "Cloud Sync",
            subtitle: "Sync usage and conversations to OpenBurnBar Cloud",
            keywords: ["sync", "cloud", "firebase", "backup", "ios", "android"]
        ),
        SettingsItem(
            id: "devices.trusted",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.trustedDevices,
            title: "Trusted Devices",
            subtitle: "Manage which devices can read your data",
            keywords: ["devices", "trusted", "pairing", "phone", "tablet"]
        ),
        SettingsItem(
            id: "devices.smartDisplays",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.smartDisplays,
            title: "Smart Displays",
            subtitle: "Cast cost glances to Nest Hub, Pixel Tablet, and Pixel Clock",
            keywords: ["nest", "hub", "pixel", "clock", "display", "cast"]
        ),

        // MARK: Account Switcher

        SettingsItem(
            id: "switcher.browser",
            tab: .switcher,
            pageRoute: .switcherRoot,
            anchorID: SettingsAnchor.switcherBrowser,
            title: "Browser Profiles",
            subtitle: "Launch isolated browser profiles per provider",
            keywords: ["browser", "profile", "chrome", "safari", "firefox"]
        ),
        SettingsItem(
            id: "switcher.cli",
            tab: .switcher,
            pageRoute: .switcherRoot,
            anchorID: SettingsAnchor.switcherCLI,
            title: "CLI Profiles",
            subtitle: "Swap CLI credentials between Claude / Factory accounts",
            keywords: ["cli", "profile", "credentials", "swap"],
            logoProviders: [.claudeCode, .codex, .openCode, .factory]
        ),

        // MARK: Hermes / AI environments

        SettingsItem(
            id: "hermes.connections",
            tab: .hermes,
            pageRoute: .hermesChatEngines,
            anchorID: SettingsAnchor.hermesConnections,
            title: "Chat Engines",
            subtitle: "Choose which chat engines appear in OpenBurnBar",
            keywords: ["hermes", "pi", "connection", "engine", "chat", "codex", "claude", "openclaw"],
            logoProviders: [.hermes, .piAgent, .openClaw, .claudeCode, .codex]
        ),
        SettingsItem(
            id: "hermes.models",
            tab: .hermes,
            pageRoute: .hermesChatEngines,
            anchorID: SettingsAnchor.hermesModels,
            title: "Hermes Models",
            subtitle: "Default models exposed by Hermes",
            keywords: ["model", "hermes", "claude", "gpt", "llm"],
            logoProviders: [.hermes, .claudeCode, .openAI, .geminiCLI]
        ),
        SettingsItem(
            id: "hermes.gateway.url",
            tab: .hermes,
            pageRoute: .hermesGateway,
            anchorID: SettingsAnchor.hermesGatewayURL,
            focusID: SettingsFocus.hermesGatewayURL,
            title: "Hermes Gateway URL",
            subtitle: "Base URL of the Hermes webapi gateway",
            keywords: ["gateway", "url", "endpoint", "webapi"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.gateway.token",
            tab: .hermes,
            pageRoute: .hermesGateway,
            anchorID: SettingsAnchor.hermesGatewayToken,
            focusID: SettingsFocus.hermesGatewayToken,
            title: "Hermes Gateway Token",
            subtitle: "Bearer token used to authenticate to the gateway",
            keywords: ["bearer", "token", "secret", "gateway"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.pi.hosts",
            tab: .hermes,
            pageRoute: .hermesPiAgent,
            anchorID: SettingsAnchor.hermesPiHosts,
            title: "Pi Agent Base URL",
            subtitle: "Gateway endpoint for local Pi runtimes",
            keywords: ["pi", "raspberry", "host", "edge", "gateway", "url"],
            logoProviders: [.piAgent]
        ),
        SettingsItem(
            id: "hermes.relay",
            tab: .hermes,
            pageRoute: .hermesRelay,
            anchorID: SettingsAnchor.hermesRelay,
            title: "Hermes Remote Relay",
            subtitle: "Reach Hermes from the cloud relay endpoint",
            keywords: ["hermes", "relay", "remote", "tunnel", "cloud"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.pi.relay",
            tab: .hermes,
            pageRoute: .hermesPiRelay,
            anchorID: SettingsAnchor.hermesPiRelay,
            title: "Pi Remote Relay",
            subtitle: "Reach Pi from the cloud relay endpoint",
            keywords: ["pi", "raspberry", "relay", "remote", "tunnel", "cloud"],
            logoProviders: [.piAgent]
        ),
    ]

    /// Map of anchor IDs back to the page route that owns them — used by
    /// destination views to know whether they should consume the pending
    /// anchor.
    static let anchorIndex: [String: SettingsPageRoute] = {
        var index: [String: SettingsPageRoute] = [:]
        for item in all { index[item.anchorID] = item.pageRoute }
        return index
    }()

    /// Anchors that are wired to concrete rows/controls in the macOS Settings
    /// UI. Coverage tests compare this against `all` so search cannot index a
    /// setting that has no scroll target.
    static let visibleAnchorIDs: Set<String> = Set([
        SettingsAnchor.operatorWizard,
        SettingsAnchor.appearanceTheme,
        SettingsAnchor.appearanceMenuBar,
        SettingsAnchor.appearanceLaunchAtLogin,
        SettingsAnchor.defaultsTimeRange,
        SettingsAnchor.defaultsUsageMode,
        SettingsAnchor.refreshInterval,
        SettingsAnchor.indexingToggle,
        SettingsAnchor.summariesAuto,
        SettingsAnchor.daemonStatus,
        SettingsAnchor.gatewayEnabled,
        SettingsAnchor.gatewayHost,
        SettingsAnchor.gatewayPort,
        SettingsAnchor.gatewayAuthToken,
        SettingsAnchor.controllerEnabled,
        SettingsAnchor.controllerRefresh,
        SettingsAnchor.controllerSimulator,
        SettingsAnchor.accountSignIn,
        SettingsAnchor.accountSubscription,
        SettingsAnchor.accountDelete,
        SettingsAnchor.cloudOverview,
        SettingsAnchor.providersAdd,
        SettingsAnchor.providersCLI,
        SettingsAnchor.providersLogSources,
        SettingsAnchor.routingPoolsOverview,
        SettingsAnchor.alertsDailySpend,
        SettingsAnchor.alertsDigest,
        SettingsAnchor.notificationsLocal,
        SettingsAnchor.notificationsTelegram,
        SettingsAnchor.notificationsCalendar,
        SettingsAnchor.cloudSyncToggle,
        SettingsAnchor.trustedDevices,
        SettingsAnchor.smartDisplays,
        SettingsAnchor.switcherBrowser,
        SettingsAnchor.switcherCLI,
        SettingsAnchor.hermesConnections,
        SettingsAnchor.hermesModels,
        SettingsAnchor.hermesGatewayURL,
        SettingsAnchor.hermesGatewayToken,
        SettingsAnchor.hermesPiHosts,
        SettingsAnchor.hermesRelay,
        SettingsAnchor.hermesPiRelay,
    ]).union(providerItems.map(\.anchorID))

    private static let providerItems: [SettingsItem] = {
        AgentProvider.allCases
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { provider in
                SettingsItem(
                    id: providerItemID(for: provider),
                    tab: .providers,
                    pageRoute: .providersRoot,
                    anchorID: providerAnchor(for: provider),
                    title: provider.displayName,
                    subtitle: "\(provider.displayName) provider setup, logs, accounts, and quota signals",
                    keywords: providerKeywords(for: provider),
                    logoProviders: [provider]
                )
            }
    }()

    private static func providerItemID(for provider: AgentProvider) -> String {
        provider == .openCode ? "providers.openCode" : "providers.\(provider.persistedToken)"
    }

    private static func providerAnchor(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode:
            return SettingsAnchor.providerCLI(SwitcherCLIProfileType.claude.rawValue)
        case .codex:
            return SettingsAnchor.providerCLI(SwitcherCLIProfileType.codex.rawValue)
        case .openCode:
            return SettingsAnchor.providersOpenCode
        default:
            return SettingsAnchor.providerLogSource(provider.persistedToken)
        }
    }

    private static func providerKeywords(for provider: AgentProvider) -> [String] {
        var keywords: [String] = [
            provider.persistedToken,
            provider.providerID.rawValue,
            "provider",
            "account",
            "quota",
            "logs",
            "routing",
            "failover"
        ]

        switch provider {
        case .claudeCode:
            keywords += ["claude", "anthropic", "claude code", "claude cli", "sonnet", "opus"]
        case .codex:
            keywords += ["openai codex", "codex cli", "chatgpt", "openai"]
        case .openCode:
            keywords += ["opencode", "open code", "opencode go", "open code go", "cli"]
        case .openAI:
            keywords += ["open ai", "openai", "gpt", "chatgpt"]
        case .geminiCLI:
            keywords += ["gemini", "google", "google ai", "gemini cli"]
        case .kiloCode:
            keywords += ["kilo", "kilo code", "kilocode"]
        case .rooCode:
            keywords += ["roo", "roo code", "roocode"]
        case .forgeDev:
            keywords += ["forge", "forge dev", "forgedev"]
        case .openClaw:
            keywords += ["open claw", "openclaw"]
        case .piAgent:
            keywords += ["pi", "raspberry", "pi agent"]
        case .kimi:
            keywords += ["moonshot", "kimi k2"]
        case .zai:
            keywords += ["z.ai", "z-ai", "zai"]
        case .minimax:
            keywords += ["mini max", "minimax"]
        case .copilot:
            keywords += ["github", "github copilot"]
        default:
            break
        }

        return Array(Set(keywords)).sorted()
    }
}
