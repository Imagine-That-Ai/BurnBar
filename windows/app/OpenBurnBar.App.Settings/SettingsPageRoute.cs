// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsItem.swift (enum SettingsPageRoute).
//
// Concrete destinations inside the Settings hierarchy. Each case maps 1:1 to a
// sub-screen the SettingsRouter can push. Legacy aliases are kept so existing deep
// links resolve; the router maps each onto the appropriate agents* route.

namespace OpenBurnBar.App.Settings;

/// <summary>Concrete destinations inside the Settings hierarchy (Swift <c>SettingsPageRoute</c>).</summary>
public enum SettingsPageRoute
{
    // Home
    HomeRoot,

    // General
    GeneralRoot,
    OperatorModel,
    Appearance,
    DefaultView,
    DataRefresh,
    Indexing,
    SessionSummaries,

    // Updates
    UpdatesRoot,

    // Daemon
    DaemonRoot,
    DaemonLifecycle,
    HttpGateway,
    ControllerRuntime,

    // Account
    AccountRoot,

    // Cloud
    CloudRoot,

    // Agents (the unified Connections + Account Switcher + AI Environments tab).
    AgentsRoot,
    AgentsAccounts,
    AgentsCLIs,
    AgentsRuntimes,
    AgentsModels,
    AgentsAdvanced,

    // Model Proxy (local gateway + routing + model catalog)
    ModelProxyRoot,

    // Legacy aliases kept so existing deep links resolve. The router maps each of
    // these onto the appropriate agents* route at navigation time.
    ConnectionsRoot,
    ProvidersRoot,
    RoutingPoolsRoot,
    SwitcherRoot,
    HermesRoot,
    HermesChatEngines,
    HermesGateway,
    HermesPiAgent,
    HermesRelay,
    HermesPiRelay,

    // Alerts
    AlertsRoot,

    // Notifications
    NotificationsRoot,

    // Devices & Sync
    DevicesAndSyncRoot,

    // Text Expansion
    TextExpansionRoot,

    // Media & Sharing
    MediaRoot,

    // Data & Privacy
    DataControlCenterRoot,

    // Computer Use
    ComputerUseRoot,

    // Pets
    PetsRoot,

    // The Elder Wand (analysis-model fusion configurator)
    AnalysisConfigurator,

    // The Elder Wand — standing fusion spend / impact screen
    FusionImpact,
}
