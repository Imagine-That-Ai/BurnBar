// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsSearchResultsView.swift
// (pageDisplayName + breadcrumb). These are the pure text helpers the results list
// uses to render a "Tab › Page" breadcrumb under each match; kept in the portable
// library so they carry unit coverage and the WinUI results page just binds them.

namespace OpenBurnBar.App.Settings;

/// <summary>Presentation-name helpers for Settings routes (Swift results-view breadcrumb logic).</summary>
public static class SettingsRouteDisplay
{
    /// <summary>Human label for a route inside a breadcrumb; roots render as empty.</summary>
    public static string PageDisplayName(SettingsPageRoute route) => route switch
    {
        SettingsPageRoute.HomeRoot or SettingsPageRoute.GeneralRoot or SettingsPageRoute.UpdatesRoot
            or SettingsPageRoute.DaemonRoot or SettingsPageRoute.AccountRoot or SettingsPageRoute.CloudRoot
            or SettingsPageRoute.ConnectionsRoot or SettingsPageRoute.ProvidersRoot
            or SettingsPageRoute.RoutingPoolsRoot or SettingsPageRoute.AlertsRoot
            or SettingsPageRoute.NotificationsRoot or SettingsPageRoute.DevicesAndSyncRoot
            or SettingsPageRoute.SwitcherRoot or SettingsPageRoute.HermesRoot or SettingsPageRoute.AgentsRoot
            or SettingsPageRoute.TextExpansionRoot or SettingsPageRoute.MediaRoot
            or SettingsPageRoute.DataControlCenterRoot or SettingsPageRoute.ComputerUseRoot
            or SettingsPageRoute.PetsRoot => string.Empty,
        SettingsPageRoute.ModelProxyRoot => "Model Proxy",
        SettingsPageRoute.AgentsAccounts => "Accounts",
        SettingsPageRoute.AgentsCLIs => "CLIs",
        SettingsPageRoute.AgentsRuntimes => "Runtimes",
        SettingsPageRoute.AgentsModels => "Models",
        SettingsPageRoute.AgentsAdvanced => "Advanced",
        SettingsPageRoute.OperatorModel => "Operator Model",
        SettingsPageRoute.Appearance => "Appearance",
        SettingsPageRoute.DefaultView => "Dashboard Defaults",
        SettingsPageRoute.DataRefresh => "Data Refresh",
        SettingsPageRoute.Indexing => "Indexing & Search",
        SettingsPageRoute.SessionSummaries => "Session Summaries",
        SettingsPageRoute.DaemonLifecycle => "Lifecycle",
        SettingsPageRoute.HttpGateway => "HTTP Gateway",
        SettingsPageRoute.ControllerRuntime => "Controller Runtime",
        SettingsPageRoute.HermesChatEngines => "Chat Engines",
        SettingsPageRoute.HermesGateway => "Hermes Gateway",
        SettingsPageRoute.HermesPiAgent => "Pi Agent Instances",
        SettingsPageRoute.HermesRelay => "Hermes Remote Relay",
        SettingsPageRoute.HermesPiRelay => "Pi Remote Relay",
        SettingsPageRoute.AnalysisConfigurator => "Analysis Models",
        SettingsPageRoute.FusionImpact => "Fusion Impact",
        _ => string.Empty,
    };

    /// <summary>Breadcrumb of the form "Tab" or "Tab › Page" for a result row (Swift <c>breadcrumb(for:)</c>).</summary>
    public static string Breadcrumb(SettingsItem item)
    {
        var pageLabel = PageDisplayName(item.PageRoute);
        var tabTitle = SettingsTabMetadata.Title(item.Tab);
        return string.IsNullOrEmpty(pageLabel) ? tabTitle : $"{tabTitle} › {pageLabel}";
    }
}
