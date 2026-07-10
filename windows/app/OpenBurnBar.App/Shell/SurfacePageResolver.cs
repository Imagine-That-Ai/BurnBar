using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Maps a <see cref="NavDestination.Key"/> to the real <c>Page</c> type that renders it.
/// Unknown keys resolve to <see cref="SurfaceStubPage"/>. Logical names live in
/// <see cref="SurfaceRouteMap"/> so shell unit tests can pin registration without WinUI.
/// Static construction fails if a product logical name lacks a typeof arm.
/// </summary>
public static class SurfacePageResolver
{
    private static readonly IReadOnlyDictionary<string, Type> LogicalToType =
        new ReadOnlyDictionary<string, Type>(new Dictionary<string, Type>(StringComparer.Ordinal)
        {
            ["BudgetPage"] = typeof(OpenBurnBar.App.Budget.BudgetPage),
            ["QuotaWorkspacePage"] = typeof(OpenBurnBar.App.Quota.QuotaWorkspacePage),
            ["InsightsPage"] = typeof(OpenBurnBar.App.Insights.InsightsPage),
            ["SessionLogsHostPage"] = typeof(OpenBurnBar.App.SessionLogs.SessionLogsHostPage),
            ["DashboardPage"] = typeof(OpenBurnBar.App.Dashboard.DashboardPage),
            ["MissionControlPage"] = typeof(OpenBurnBar.App.MissionControl.MissionControlPage),
            ["DataControlCenterPage"] = typeof(OpenBurnBar.App.DataControlCenter.DataControlCenterPage),
            ["ChatHostPage"] = typeof(OpenBurnBar.App.Chat.ChatHostPage),
            ["SwitcherHostPage"] = typeof(OpenBurnBar.App.Switcher.SwitcherHostPage),
            ["MemoryPage"] = typeof(OpenBurnBar.App.Memory.MemoryPage),
            // Elder Wand is Auxiliary (palette), not a sidebar row.
            ["ElderWandPage"] = typeof(OpenBurnBar.App.ElderWand.ElderWandPage),
            ["OnboardingPage"] = typeof(OpenBurnBar.App.Onboarding.OnboardingPage),
            ["SettingsPage"] = typeof(OpenBurnBar.App.Settings.Winui.SettingsPage),
            ["DatabasePage"] = typeof(OpenBurnBar.App.Database.DatabasePage),
            ["ProjectsPage"] = typeof(OpenBurnBar.App.Projects.ProjectsPage),
            [SurfaceRouteMap.DeferredStubPage] = typeof(SurfaceStubPage),
        });

    static SurfacePageResolver()
    {
        // Fail closed on dual-map desync: every SurfaceRouteMap product logical name must bind.
        SurfaceRouteMap.AssertWinUiBindingsCoverProductLogicalNames(LogicalToType.Keys.ToArray());
    }

    /// <summary>Logical page names that have a WinUI <see cref="Type"/> binding (incl. stub).</summary>
    public static IReadOnlyCollection<string> BoundLogicalPageNames => LogicalToType.Keys.ToArray();

    /// <summary>The real page type for a destination key, or the stub when deferred/unknown.</summary>
    public static Type Resolve(string key)
    {
        string logical = SurfaceRouteMap.LogicalPageType(key);
        if (LogicalToType.TryGetValue(logical, out Type? pageType))
        {
            return pageType;
        }

        // Should be unreachable when static ctor completeness holds; keep fail-closed stub.
        return typeof(SurfaceStubPage);
    }
}
