// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsItem.swift
// (enum SettingsAnchor + enum SettingsFocus).
//
// Centralized anchor and focus identifiers so manifest entries and destination
// pages agree on a single source of truth. On macOS an anchor string is passed to
// SwiftUI's `.id(_:)` so a ScrollViewReader can scroll it into view; on Windows the
// same string keys a FrameworkElement registered on the destination Page, which
// BringIntoView-scrolls + pulse-highlights it (see SettingsAnchorScroller).

namespace OpenBurnBar.App.Settings;

/// <summary>Stable anchor identifiers shared by the manifest and destination pages.</summary>
public static class SettingsAnchor
{
    // General → Appearance
    public const string AppearanceTheme = "general.appearance.theme";
    public const string AppearanceSkin = "general.appearance.skin";
    public const string AppearanceGlassTransparency = "general.appearance.glassTransparency";
    public const string AppearanceMenuBar = "general.appearance.menuBar";
    public const string AppearanceLaunchAtLogin = "general.appearance.launchAtLogin";
    public const string UsePremiumSotaUx = "general.appearance.usePremiumSOTAUX";
    public const string UseWebsiteBackground = "general.appearance.useWebsiteBackground";
    public const string UseConstellationBackground = "general.appearance.useConstellationBackground";
    public const string UseKernelBackdrop = "general.appearance.useKernelBackdrop";
    public const string BackdropKernel = "general.appearance.backdropKernel";
    public const string DesktopWallpaperEnabled = "general.appearance.desktopWallpaperEnabled";
    public const string DesktopWallpaperBackground = "general.appearance.desktopWallpaperBackground";
    public const string DesktopWallpaperSpeed = "general.appearance.desktopWallpaperSpeed";
    public const string DesktopWallpaperProviderGlyphs = "general.appearance.desktopWallpaperProviderGlyphs";
    public const string DesktopWallpaperClickCycle = "general.appearance.desktopWallpaperClickCycle";

    // General → Defaults
    public const string DefaultsTimeRange = "general.defaults.timeRange";
    public const string DefaultsUsageMode = "general.defaults.usageDisplayMode";

    // General → Refresh
    public const string RefreshInterval = "general.refresh.interval";

    // General → Indexing
    public const string IndexingToggle = "general.indexing.enabled";

    // General → Summaries
    public const string SummariesAuto = "general.summaries.auto";

    // General → Operator
    public const string OperatorWizard = "general.operator.wizard";

    // Updates
    public const string UpdatesOverview = "updates.overview";
    public const string UpdatesAutomaticChecks = "updates.automaticChecks";
    public const string UpdatesReleaseNotes = "updates.releaseNotes";

    // Daemon → Lifecycle
    public const string DaemonStatus = "daemon.lifecycle.status";

    // Daemon → HTTP Gateway
    public const string GatewayEnabled = "daemon.gateway.enabled";
    public const string GatewayHost = "daemon.gateway.host";
    public const string GatewayPort = "daemon.gateway.port";
    public const string GatewayAuthToken = "daemon.gateway.authToken";
    public const string GatewayAllowUnauthenticatedLoopback = "daemon.gateway.allowUnauthenticatedLoopback";

    // Daemon → Controller runtime
    public const string ControllerEnabled = "daemon.controller.enabled";
    public const string ControllerRefresh = "daemon.controller.refreshCadence";
    public const string ControllerSimulator = "daemon.controller.simulator";

    // Account
    public const string AccountSignIn = "account.signIn";
    public const string AccountSubscription = "account.subscription";
    public const string AccountDelete = "account.delete";

    // Cloud
    public const string CloudOverview = "cloud.overview";

    // Agents (the unified Connections + Account Switcher + AI Environments tab).
    public const string AgentsAccounts = "agents.accounts";
    public const string AgentsCLIs = "agents.clis";
    public const string AgentsRuntimes = "agents.runtimes";
    public const string AgentsModels = "agents.models";
    public const string AgentsAdvanced = "agents.advanced";
    public const string AgentsQuotaDisplay = "agents.quotaDisplay";

    // Legacy anchors — every one aliases to an agents anchor so back-compat search
    // and deep links keep working.
    public const string ConnectionsAccounts = AgentsAccounts;
    public const string ConnectionsApps = AgentsCLIs;
    public const string ConnectionsAdvanced = AgentsAdvanced;
    public const string ProvidersAdd = AgentsAccounts;
    public const string ProvidersCLI = AgentsCLIs;
    public const string ProvidersLogSources = AgentsAdvanced;
    public const string ProvidersOpenCode = AgentsCLIs;
    public const string RoutingPoolsOverview = AgentsCLIs;

    public static string ProviderLogSource(string persistedToken) => $"providers.logSource.{persistedToken}";

    public static string ProviderCLI(string cliToken) => $"providers.cli.{cliToken}";

    // Alerts
    public const string AlertsDailySpend = "alerts.dailySpend";
    public const string AlertsDigest = "alerts.digest";

    // Notifications
    public const string NotificationsLocal = "notifications.local";
    public const string NotificationsTelegram = "notifications.telegram";
    public const string NotificationsCalendar = "notifications.calendar";

    // Devices & Sync
    public const string CloudSyncToggle = "devices.cloudSync";
    public const string TrustedDevices = "devices.trusted";
    public const string SmartDisplays = "devices.smartDisplays";

    // Text Expansion
    public const string TextExpansionRuntime = "textExpansion.runtime";
    public const string TextExpansionSnippets = "textExpansion.snippets";

    // Media & Sharing
    public const string MediaPermissions = "media.permissions";

    // Data & Privacy
    public const string DataControlCenterInventory = "data.controlCenter.inventory";

    // Computer Use
    public const string ComputerUseReadiness = "computerUse.readiness";
    public const string ComputerUsePermissionsSetup = "computerUse.permissionsSetup";

    // Pets
    public const string PetsCompanion = "pets.companion";

    // The Elder Wand (analysis-model fusion configurator)
    public const string AnalysisConfigurator = "agents.analysisConfigurator";

    // The Elder Wand — standing fusion spend / impact screen
    public const string FusionImpact = "agents.fusionImpact";
    public const string FusionImpactPeriod = "agents.fusionImpact.period";

    // Model Proxy
    public const string ModelProxyOverview = "modelProxy.overview";
    public const string ModelProxyEndpoint = "modelProxy.endpoint";
    public const string ModelProxyRouting = "modelProxy.routing";

    // Home
    public const string HomeOverview = "home.overview";

    // Switcher
    public const string SwitcherBrowser = "switcher.browser";
    public const string SwitcherCLI = "switcher.cli";

    // Hermes
    public const string HermesConnections = "hermes.connections";
    public const string HermesModels = "hermes.models";
    public const string HermesGatewayURL = "hermes.gateway.url";
    public const string HermesGatewayToken = "hermes.gateway.token";
    public const string HermesPiHosts = "hermes.pi.hosts";
    public const string HermesRelay = "hermes.relay";
    public const string HermesPiRelay = "hermes.pi.relay";
}

/// <summary>Focus targets destination pages latch onto (Swift <c>SettingsFocus</c>).</summary>
public static class SettingsFocus
{
    public const string GatewayHost = "daemon.gateway.host";
    public const string GatewayPort = "daemon.gateway.port";
    public const string GatewayAuthToken = "daemon.gateway.authToken";
    public const string HermesGatewayURL = "hermes.gateway.url";
    public const string HermesGatewayToken = "hermes.gateway.token";
    public const string AlertsDailySpend = "alerts.dailySpend";
}
