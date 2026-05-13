import Foundation

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

    static let all: [SettingsItem] = [

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

        // MARK: Providers

        SettingsItem(
            id: "providers.add",
            tab: .providers,
            pageRoute: .providersRoot,
            anchorID: SettingsAnchor.providersAdd,
            title: "Add Provider Account",
            subtitle: "Connect Claude, Factory, OpenAI, Kimi, and more",
            keywords: ["add", "account", "provider", "claude", "factory", "openai", "anthropic"]
        ),
        SettingsItem(
            id: "providers.cli",
            tab: .providers,
            pageRoute: .providersRoot,
            anchorID: SettingsAnchor.providersCLI,
            title: "CLI Authentication",
            subtitle: "OAuth and API key management for local CLIs",
            keywords: ["cli", "oauth", "api key", "anthropic", "openai", "auth"]
        ),
        SettingsItem(
            id: "providers.logSources",
            tab: .providers,
            pageRoute: .providersRoot,
            anchorID: SettingsAnchor.providersLogSources,
            title: "Log Sources",
            subtitle: "Enable or disable individual on-disk log scans",
            keywords: ["logs", "sources", "scan", "claude code", "factory droid", "codex"]
        ),

        // MARK: Routing pools

        SettingsItem(
            id: "routingPools.overview",
            tab: .routingPools,
            pageRoute: .routingPoolsRoot,
            anchorID: SettingsAnchor.routingPoolsOverview,
            title: "Routing Pools",
            subtitle: "Wire Claude Code and OpenAI-compatible clients through routed provider pools",
            keywords: ["routing", "fire hydrant", "pools", "failover", "claude code", "codex", "gateway"]
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
            id: "alerts.perProvider",
            tab: .alerts,
            pageRoute: .alertsRoot,
            anchorID: SettingsAnchor.alertsPerProvider,
            title: "Per-Provider Thresholds",
            subtitle: "Set spend ceilings for each provider",
            keywords: ["provider", "threshold", "ceiling", "anthropic", "openai"]
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
            keywords: ["cli", "profile", "credentials", "swap"]
        ),

        // MARK: Hermes / AI environments

        SettingsItem(
            id: "hermes.connections",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: SettingsAnchor.hermesConnections,
            title: "Hermes Connections",
            subtitle: "Connected Hermes endpoints and tokens",
            keywords: ["hermes", "connection", "endpoint", "token"]
        ),
        SettingsItem(
            id: "hermes.models",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: SettingsAnchor.hermesModels,
            title: "Hermes Models",
            subtitle: "Default models exposed by Hermes",
            keywords: ["model", "hermes", "claude", "gpt", "llm"]
        ),
        SettingsItem(
            id: "hermes.tps",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: SettingsAnchor.hermesTPS,
            title: "TPS Overlay",
            subtitle: "Display tokens-per-second under streaming responses",
            keywords: ["tps", "tokens", "speed", "overlay"]
        ),
        SettingsItem(
            id: "hermes.pretext",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: SettingsAnchor.hermesPretext,
            title: "Pretext",
            subtitle: "System prompt prefix injected into every Hermes turn",
            keywords: ["pretext", "system prompt", "context", "prefix"]
        ),
        SettingsItem(
            id: "hermes.gateway.url",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: SettingsAnchor.hermesGatewayURL,
            focusID: SettingsFocus.hermesGatewayURL,
            title: "Hermes Gateway URL",
            subtitle: "Base URL of the Hermes webapi gateway",
            keywords: ["gateway", "url", "endpoint", "webapi"]
        ),
        SettingsItem(
            id: "hermes.gateway.token",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: SettingsAnchor.hermesGatewayToken,
            focusID: SettingsFocus.hermesGatewayToken,
            title: "Hermes Gateway Token",
            subtitle: "Bearer token used to authenticate to the gateway",
            keywords: ["bearer", "token", "secret", "gateway"]
        ),
        SettingsItem(
            id: "hermes.pi.hosts",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: SettingsAnchor.hermesPiHosts,
            title: "Pi Hosts",
            subtitle: "Connected Raspberry Pi runtimes",
            keywords: ["pi", "raspberry", "host", "edge"]
        ),
        SettingsItem(
            id: "hermes.relay",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: SettingsAnchor.hermesRelay,
            title: "Remote Relay",
            subtitle: "Reach Hermes from the cloud relay endpoint",
            keywords: ["relay", "remote", "tunnel", "cloud"]
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
}
