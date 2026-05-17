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
            keywords: ["api", "openai", "gateway", "endpoint", "hydrant"]
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
            keywords: ["port", "tcp", "8317", "hydrant"]
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

        // MARK: Agents (unified Connections + Account Switcher + AI Environments tab)

        SettingsItem(
            id: "agents.accounts",
            tab: .agents,
            pageRoute: .agentsAccounts,
            anchorID: SettingsAnchor.agentsAccounts,
            title: "Add Account",
            subtitle: "Bring API keys for OpenAI, Anthropic, and other providers — add many keys per provider for automatic failover",
            keywords: [
                "agent", "agents",
                "connect", "connections", "account", "accounts", "add", "key", "api key",
                "openai", "anthropic", "claude", "claude code", "opencode", "open code",
                "factory", "kimi", "moonshot", "minimax", "zai", "z.ai", "deepseek", "ollama",
                "provider", "providers", "plan", "plans"
            ],
            logoProviders: [.claudeCode, .openAI, .openCode, .factory]
        ),
        SettingsItem(
            id: "agents.clis",
            tab: .agents,
            pageRoute: .agentsCLIs,
            anchorID: SettingsAnchor.agentsCLIs,
            title: "Connect a CLI",
            subtitle: "Wire Claude Code, Codex, OpenCode, Forge, or Droid to your local gateway and switch between CLI profiles",
            keywords: [
                "agent", "agents",
                "cli", "app", "apps", "connect", "wire", "wiring", "claude code", "codex",
                "opencode", "open code", "forge", "droid", "factory",
                // Legacy "routing pool" / "hydrant" vocabulary still resolves here.
                "routing", "routing pool", "routing pools", "pool", "pools",
                "fire hydrant", "hydrant", "gateway", "failover", "fallback",
                "oauth", "api key", "auth",
                // Account Switcher vocabulary forwarded here.
                "switcher", "profile", "profiles", "reserve", "primary",
                "swap", "credentials", "isolated"
            ],
            logoProviders: [.claudeCode, .codex, .openCode, .factory]
        ),
        SettingsItem(
            id: "agents.runtimes",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.agentsRuntimes,
            title: "Runtimes & Relays",
            subtitle: "Local Hermes, Pi, and OpenClaw runtimes plus their iPhone/iPad relays",
            keywords: [
                "agent", "agents",
                "runtime", "runtimes", "hermes", "pi", "pi agent", "openclaw", "open claw",
                "gateway", "engine", "engines", "relay", "remote", "tunnel", "webapi",
                "ai environment", "ai environments", "chat engine"
            ],
            logoProviders: [.hermes, .piAgent, .openClaw]
        ),
        SettingsItem(
            id: "agents.advanced",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.agentsAdvanced,
            title: "Advanced Routing, Gateway, Browsers & Setup",
            subtitle: "Routing strategy, local gateway, browser profiles, chat engines, Hermes models, inventory, setup wizard",
            keywords: [
                "agent", "agents",
                "advanced", "router", "router mode", "routing strategy", "intelligent",
                "provider family", "gateway", "host", "port", "token", "bearer",
                "loopback", "log sources", "logs", "smart hubs", "quota",
                "browser", "chrome", "safari", "profile",
                "chat engine", "engine", "engines", "model", "models", "hermes model",
                "inventory", "import", "setup", "setup wizard", "wizard"
            ],
            logoProviders: [.claudeCode, .openAI, .hermes]
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

        // MARK: Account Switcher — now lives inside Agents → CLIs / Advanced.

        SettingsItem(
            id: "switcher.browser",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.switcherBrowser,
            title: "Browser Profiles",
            subtitle: "Launch isolated browser profiles per provider (now under Agents → Advanced)",
            keywords: ["browser", "profile", "chrome", "safari", "firefox", "switcher"]
        ),
        SettingsItem(
            id: "switcher.cli",
            tab: .agents,
            pageRoute: .agentsCLIs,
            anchorID: SettingsAnchor.switcherCLI,
            title: "CLI Profiles",
            subtitle: "Swap CLI credentials between Claude / Codex / OpenCode accounts (now under Agents → CLIs)",
            keywords: ["cli", "profile", "credentials", "swap", "switcher"],
            logoProviders: [.claudeCode, .codex, .openCode, .factory]
        ),

        // MARK: Hermes / AI environments — now live inside Agents → Runtimes / Advanced.

        SettingsItem(
            id: "hermes.connections",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.hermesConnections,
            title: "Chat Engines",
            subtitle: "Choose which chat engines appear in OpenBurnBar (now under Agents → Advanced)",
            keywords: ["hermes", "pi", "connection", "engine", "chat", "codex", "claude", "openclaw"],
            logoProviders: [.hermes, .piAgent, .openClaw, .claudeCode, .codex]
        ),
        SettingsItem(
            id: "hermes.models",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.hermesModels,
            title: "Hermes Models",
            subtitle: "Default models exposed by Hermes (now under Agents → Advanced)",
            keywords: ["model", "hermes", "claude", "gpt", "llm"],
            logoProviders: [.hermes, .claudeCode, .openAI, .geminiCLI]
        ),
        SettingsItem(
            id: "hermes.gateway.url",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesGatewayURL,
            focusID: SettingsFocus.hermesGatewayURL,
            title: "Hermes Gateway URL",
            subtitle: "Base URL of the Hermes webapi gateway (now under Agents → Runtimes)",
            keywords: ["gateway", "url", "endpoint", "webapi", "hermes"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.gateway.token",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesGatewayToken,
            focusID: SettingsFocus.hermesGatewayToken,
            title: "Hermes Gateway Token",
            subtitle: "Bearer token used to authenticate to the gateway (now under Agents → Runtimes)",
            keywords: ["bearer", "token", "secret", "gateway", "hermes"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.pi.hosts",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesPiHosts,
            title: "Pi Agent Base URL",
            subtitle: "Gateway endpoint for local Pi runtimes (now under Agents → Runtimes)",
            keywords: ["pi", "raspberry", "host", "edge", "gateway", "url"],
            logoProviders: [.piAgent]
        ),
        SettingsItem(
            id: "hermes.relay",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesRelay,
            title: "Hermes Remote Relay",
            subtitle: "Reach Hermes from the cloud relay endpoint (now under Agents → Runtimes)",
            keywords: ["hermes", "relay", "remote", "tunnel", "cloud"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.pi.relay",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesPiRelay,
            title: "Pi Remote Relay",
            subtitle: "Reach Pi from the cloud relay endpoint (now under Agents → Runtimes)",
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
        SettingsAnchor.agentsAccounts,
        SettingsAnchor.agentsCLIs,
        SettingsAnchor.agentsRuntimes,
        SettingsAnchor.agentsAdvanced,
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
                    tab: .agents,
                    pageRoute: .agentsAccounts,
                    anchorID: providerAnchor(for: provider),
                    title: provider.displayName,
                    subtitle: "\(provider.displayName) accounts, keys, and quota signals",
                    keywords: providerKeywords(for: provider),
                    logoProviders: [provider]
                )
            }
    }()

    private static func providerItemID(for provider: AgentProvider) -> String {
        provider == .openCode ? "providers.openCode" : "providers.\(provider.persistedToken)"
    }

    /// Per-provider scroll anchor. The Connections page itself only renders
    /// three anchored sections, so these per-provider IDs scroll the user to
    /// the top of the Accounts section in practice — they exist so each
    /// provider has its own unique manifest entry for search.
    private static func providerAnchor(for provider: AgentProvider) -> String {
        "agents.account.\(provider.persistedToken)"
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
