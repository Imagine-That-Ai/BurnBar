// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsManifest.swift (baseItems, part 2/3).
//
// EXACT Swift order continues: Daemon (lifecycle / HTTP gateway / controller),
// Account, Cloud, the six Agents landing rows, Alerts, Notifications, Devices & Sync.

using System.Collections.Generic;

namespace OpenBurnBar.App.Settings;

public static partial class SettingsManifest
{
    private static IReadOnlyList<SettingsItem> MiddleGroupItems { get; } = new[]
    {
        // MARK: Daemon → Lifecycle
        new SettingsItem(
            id: "daemon.lifecycle.status",
            tab: SettingsTab.Daemon,
            pageRoute: SettingsPageRoute.DaemonLifecycle,
            anchorId: SettingsAnchor.DaemonStatus,
            title: "Daemon Lifecycle",
            subtitle: "Install, repair, and watch the local daemon",
            keywords: new[] { "daemon", "service", "install", "repair", "health" }),

        // MARK: Daemon → HTTP gateway
        new SettingsItem(
            id: "daemon.gateway.enabled",
            tab: SettingsTab.Daemon,
            pageRoute: SettingsPageRoute.HttpGateway,
            anchorId: SettingsAnchor.GatewayEnabled,
            title: "HTTP Gateway",
            subtitle: "Expose an OpenAI-compatible API on a local port",
            keywords: new[] { "api", "openai", "gateway", "endpoint", "hydrant" }),
        new SettingsItem(
            id: "daemon.gateway.host",
            tab: SettingsTab.Daemon,
            pageRoute: SettingsPageRoute.HttpGateway,
            anchorId: SettingsAnchor.GatewayHost,
            focusId: SettingsFocus.GatewayHost,
            title: "Gateway Host",
            subtitle: "Bind address for the gateway server",
            keywords: new[] { "host", "bind", "address", "127.0.0.1", "localhost" }),
        new SettingsItem(
            id: "daemon.gateway.port",
            tab: SettingsTab.Daemon,
            pageRoute: SettingsPageRoute.HttpGateway,
            anchorId: SettingsAnchor.GatewayPort,
            focusId: SettingsFocus.GatewayPort,
            title: "Gateway Port",
            subtitle: "TCP port the gateway listens on",
            keywords: new[] { "port", "tcp", "8317", "hydrant" }),
        new SettingsItem(
            id: "daemon.gateway.token",
            tab: SettingsTab.Daemon,
            pageRoute: SettingsPageRoute.HttpGateway,
            anchorId: SettingsAnchor.GatewayAuthToken,
            focusId: SettingsFocus.GatewayAuthToken,
            title: "Gateway Auth Token",
            subtitle: "Required for non-loopback bindings",
            keywords: new[] { "token", "auth", "bearer", "secret" }),

        // MARK: Daemon → Controller runtime
        new SettingsItem(
            id: "daemon.controller.enabled",
            tab: SettingsTab.Daemon,
            pageRoute: SettingsPageRoute.ControllerRuntime,
            anchorId: SettingsAnchor.ControllerEnabled,
            title: "Controller Runtime",
            subtitle: "Mirror daemon missions and replay state",
            keywords: new[] { "controller", "runtime", "missions", "operator", "replay" }),
        new SettingsItem(
            id: "daemon.controller.refresh",
            tab: SettingsTab.Daemon,
            pageRoute: SettingsPageRoute.ControllerRuntime,
            anchorId: SettingsAnchor.ControllerRefresh,
            title: "Controller Refresh Cadence",
            subtitle: "How often to mirror runtime state",
            keywords: new[] { "refresh", "cadence", "polling", "mirror" }),
        new SettingsItem(
            id: "daemon.controller.simulator",
            tab: SettingsTab.Daemon,
            pageRoute: SettingsPageRoute.ControllerRuntime,
            anchorId: SettingsAnchor.ControllerSimulator,
            title: "Simulator Tools",
            subtitle: "Expose replay and simulator controls",
            keywords: new[] { "simulator", "replay", "operator", "preview" }),

        // MARK: Account
        new SettingsItem(
            id: "account.signIn",
            tab: SettingsTab.Account,
            pageRoute: SettingsPageRoute.AccountRoot,
            anchorId: SettingsAnchor.AccountSignIn,
            title: "Sign In",
            subtitle: "Sign in with Apple, Google, or email",
            keywords: new[] { "login", "apple", "google", "email", "signin" }),
        new SettingsItem(
            id: "account.subscription",
            tab: SettingsTab.Account,
            pageRoute: SettingsPageRoute.AccountRoot,
            anchorId: SettingsAnchor.AccountSubscription,
            title: "Subscription",
            subtitle: "OpenBurnBar Cloud plan and billing",
            keywords: new[] { "plan", "subscription", "billing", "premium", "upgrade" }),
        new SettingsItem(
            id: "account.delete",
            tab: SettingsTab.Account,
            pageRoute: SettingsPageRoute.AccountRoot,
            anchorId: SettingsAnchor.AccountDelete,
            title: "Delete Account",
            subtitle: "Permanently remove your cloud account",
            keywords: new[] { "delete", "remove", "wipe", "gdpr" }),

        // MARK: Cloud
        new SettingsItem(
            id: "cloud.overview",
            tab: SettingsTab.Cloud,
            pageRoute: SettingsPageRoute.CloudRoot,
            anchorId: SettingsAnchor.CloudOverview,
            title: "OpenBurnBar Cloud",
            subtitle: "Hosted refresh, backup, remote MCP clients, and member status",
            keywords: new[] { "cloud", "member", "pro", "hosted", "backup", "remote mcp", "subscription", "billing", "relay" }),

        // MARK: Agents (unified Connections + Account Switcher + AI Environments tab)
        new SettingsItem(
            id: "agents.accounts",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsAccounts,
            anchorId: SettingsAnchor.AgentsAccounts,
            title: "Add Account",
            subtitle: "Bring API keys for OpenAI, Anthropic, and other providers — add many keys per provider for automatic failover",
            keywords: new[]
            {
                "agent", "agents",
                "connect", "connections", "account", "accounts", "add", "key", "api key",
                "openai", "anthropic", "claude", "claude code", "opencode", "open code",
                "factory", "kimi", "moonshot", "minimax", "zai", "z.ai", "deepseek", "ollama",
                "provider", "providers", "plan", "plans",
            },
            logoProviders: new[] { AgentProvider.ClaudeCode, AgentProvider.OpenAI, AgentProvider.OpenCode, AgentProvider.Factory }),
        new SettingsItem(
            id: "agents.clis",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsCLIs,
            anchorId: SettingsAnchor.AgentsCLIs,
            title: "Connect a CLI",
            subtitle: "Wire Claude Code, Codex, OpenCode, Forge, or Droid to your local gateway and switch between CLI profiles",
            keywords: new[]
            {
                "agent", "agents",
                "cli", "app", "apps", "connect", "wire", "wiring", "claude code", "codex",
                "opencode", "open code", "forge", "droid", "factory",
                "routing", "routing pool", "routing pools", "pool", "pools",
                "fire hydrant", "hydrant", "gateway", "failover", "fallback",
                "oauth", "api key", "auth",
                "switcher", "profile", "profiles", "reserve", "primary",
                "swap", "credentials", "isolated",
            },
            logoProviders: new[] { AgentProvider.ClaudeCode, AgentProvider.Codex, AgentProvider.OpenCode, AgentProvider.Factory }),
        new SettingsItem(
            id: "agents.runtimes",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsRuntimes,
            anchorId: SettingsAnchor.AgentsRuntimes,
            title: "Runtimes & Relays",
            subtitle: "Local Hermes, Pi, and OpenClaw runtimes plus their iPhone/iPad relays",
            keywords: new[]
            {
                "agent", "agents",
                "runtime", "runtimes", "hermes", "pi", "pi agent", "openclaw", "open claw",
                "gateway", "engine", "engines", "relay", "remote", "tunnel", "webapi",
                "ai environment", "ai environments", "chat engine",
            },
            logoProviders: new[] { AgentProvider.Hermes, AgentProvider.PiAgent, AgentProvider.OpenClaw }),
        new SettingsItem(
            id: "agents.models",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsModels,
            anchorId: SettingsAnchor.AgentsModels,
            title: "Models & Providers",
            subtitle: "Every model the local gateway can serve right now — grouped by provider and account, with route-readiness and quota state",
            keywords: new[]
            {
                "agent", "agents",
                "model", "models", "model catalog", "catalog", "directory",
                "provider", "providers", "advertised", "exposed", "proxy",
                "gateway", "v1/models", "endpoint", "routes", "routing",
                "claude", "gpt", "sonnet", "opus", "kimi", "minimax", "deepseek",
                "openai", "anthropic", "browse", "list", "view", "see",
            },
            logoProviders: new[] { AgentProvider.ClaudeCode, AgentProvider.OpenAI, AgentProvider.OpenCode, AgentProvider.Kimi }),
        new SettingsItem(
            id: "agents.advanced",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsAdvanced,
            anchorId: SettingsAnchor.AgentsAdvanced,
            title: "Advanced Routing, Gateway, Browsers & Setup",
            subtitle: "Exact model failover, provider-family routing, local gateway, browser profiles, chat engines, Hermes models, inventory, setup wizard",
            keywords: new[]
            {
                "agent", "agents",
                "advanced", "router", "router mode", "routing strategy",
                "exact model failover", "same model", "same-model", "never swap model",
                "provider family", "gateway", "host", "port", "token", "bearer",
                "loopback", "log sources", "logs", "smart hubs", "quota",
                "browser", "chrome", "safari", "profile",
                "chat engine", "engine", "engines", "model", "models", "hermes model",
                "inventory", "import", "setup", "setup wizard", "wizard",
            },
            logoProviders: new[] { AgentProvider.ClaudeCode, AgentProvider.OpenAI, AgentProvider.Hermes }),
        new SettingsItem(
            id: "agents.quotaDisplay",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsAdvanced,
            anchorId: SettingsAnchor.AgentsQuotaDisplay,
            title: "Quota Popover",
            subtitle: "Choose which provider quotas appear in the menu-bar drop-down",
            keywords: new[]
            {
                "agent", "agents", "quota", "quotas", "popover", "drop down", "dropdown",
                "menu bar", "menubar", "visible", "hide", "show", "provider", "providers",
                "codex", "claude", "opencode", "factory", "cursor", "grok",
            },
            logoProviders: new[] { AgentProvider.Codex, AgentProvider.ClaudeCode, AgentProvider.OpenCode, AgentProvider.Factory }),

        // MARK: Alerts
        new SettingsItem(
            id: "alerts.dailySpend",
            tab: SettingsTab.Alerts,
            pageRoute: SettingsPageRoute.AlertsRoot,
            anchorId: SettingsAnchor.AlertsDailySpend,
            focusId: SettingsFocus.AlertsDailySpend,
            title: "Daily Spend Threshold",
            subtitle: "Notify when today's USD crosses this number",
            keywords: new[] { "spend", "budget", "threshold", "limit", "alert", "usd" }),
        new SettingsItem(
            id: "alerts.digest",
            tab: SettingsTab.Alerts,
            pageRoute: SettingsPageRoute.AlertsRoot,
            anchorId: SettingsAnchor.AlertsDigest,
            title: "Daily Digest",
            subtitle: "Receive a daily summary of spend and tokens",
            keywords: new[] { "digest", "daily", "summary", "morning" }),

        // MARK: Notifications
        new SettingsItem(
            id: "notifications.local",
            tab: SettingsTab.Notifications,
            pageRoute: SettingsPageRoute.NotificationsRoot,
            anchorId: SettingsAnchor.NotificationsLocal,
            title: "Local Notifications",
            subtitle: "Banner alerts on this Mac",
            keywords: new[] { "banner", "notification", "alert", "local", "ping" }),
        new SettingsItem(
            id: "notifications.telegram",
            tab: SettingsTab.Notifications,
            pageRoute: SettingsPageRoute.NotificationsRoot,
            anchorId: SettingsAnchor.NotificationsTelegram,
            title: "Telegram",
            subtitle: "Bot token and chat ID for Telegram alerts",
            keywords: new[] { "telegram", "bot", "chat id", "messenger" }),
        new SettingsItem(
            id: "notifications.calendar",
            tab: SettingsTab.Notifications,
            pageRoute: SettingsPageRoute.NotificationsRoot,
            anchorId: SettingsAnchor.NotificationsCalendar,
            title: "Calendar",
            subtitle: "Mirror digests to a calendar of your choice",
            keywords: new[] { "calendar", "ical", "google calendar", "event" }),

        // MARK: Devices & Sync
        new SettingsItem(
            id: "devices.cloudSync",
            tab: SettingsTab.DevicesAndSync,
            pageRoute: SettingsPageRoute.DevicesAndSyncRoot,
            anchorId: SettingsAnchor.CloudSyncToggle,
            title: "Cloud Sync",
            subtitle: "Sync usage and conversations to OpenBurnBar Cloud",
            keywords: new[] { "sync", "cloud", "firebase", "backup", "ios", "android" }),
        new SettingsItem(
            id: "devices.trusted",
            tab: SettingsTab.DevicesAndSync,
            pageRoute: SettingsPageRoute.DevicesAndSyncRoot,
            anchorId: SettingsAnchor.TrustedDevices,
            title: "Trusted Devices",
            subtitle: "Manage which devices can read your data",
            keywords: new[] { "devices", "trusted", "pairing", "phone", "tablet" }),
        new SettingsItem(
            id: "devices.smartDisplays",
            tab: SettingsTab.DevicesAndSync,
            pageRoute: SettingsPageRoute.DevicesAndSyncRoot,
            anchorId: SettingsAnchor.SmartDisplays,
            title: "Smart Displays",
            subtitle: "Cast cost glances to Nest Hub, Pixel Tablet, and Pixel Clock",
            keywords: new[] { "nest", "hub", "pixel", "clock", "display", "cast" }),
    };
}
