using System;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Maps a <see cref="NavDestination.Key"/> to the real <c>Page</c> type that renders it.
/// Unknown keys and intentional IA-1 deferred routes (<c>database</c>, <c>projects</c>)
/// resolve to <see cref="SurfaceStubPage"/> (honest disclosure, not fake Real). Logical
/// names live in <see cref="SurfaceRouteMap"/> so shell unit tests can pin registration
/// without WinUI.
/// </summary>
public static class SurfacePageResolver
{
    /// <summary>The real page type for a destination key, or the stub when deferred/unknown.</summary>
    public static Type Resolve(string key) => SurfaceRouteMap.LogicalPageType(key) switch
    {
        "BudgetPage" => typeof(OpenBurnBar.App.Budget.BudgetPage),
        "QuotaWorkspacePage" => typeof(OpenBurnBar.App.Quota.QuotaWorkspacePage),
        "InsightsPage" => typeof(OpenBurnBar.App.Insights.InsightsPage),
        "SessionLogsHostPage" => typeof(OpenBurnBar.App.SessionLogs.SessionLogsHostPage),
        "DashboardPage" => typeof(OpenBurnBar.App.Dashboard.DashboardPage),
        "MissionControlPage" => typeof(OpenBurnBar.App.MissionControl.MissionControlPage),
        "DataControlCenterPage" => typeof(OpenBurnBar.App.DataControlCenter.DataControlCenterPage),
        "ChatHostPage" => typeof(OpenBurnBar.App.Chat.ChatHostPage),
        "SwitcherHostPage" => typeof(OpenBurnBar.App.Switcher.SwitcherHostPage),
        "MemoryPage" => typeof(OpenBurnBar.App.Memory.MemoryPage),
        // Elder Wand is Auxiliary (palette), not a sidebar row.
        "ElderWandPage" => typeof(OpenBurnBar.App.ElderWand.ElderWandPage),
        "OnboardingPage" => typeof(OpenBurnBar.App.Onboarding.OnboardingPage),
        "SettingsPage" => typeof(OpenBurnBar.App.Settings.Winui.SettingsPage),
        // IA-1 deferred disclosure + unknown keys.
        SurfaceRouteMap.DeferredStubPage => typeof(SurfaceStubPage),
        _ => typeof(SurfaceStubPage),
    };
}
