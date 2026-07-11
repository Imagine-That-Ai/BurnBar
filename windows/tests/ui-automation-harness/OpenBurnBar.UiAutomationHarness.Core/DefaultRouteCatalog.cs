using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.UiAutomationHarness.Core;

public static class DefaultRouteCatalog
{
    private static readonly UiHarnessRoute[] Routes =
    {
        new("dashboard", "Dashboard", "RouteRoot.dashboard", "windows/app/OpenBurnBar.App/Dashboard/DashboardPage.xaml"),
        new("quota", "Quota", "RouteRoot.quota", "windows/app/OpenBurnBar.App/Quota/QuotaWorkspacePage.xaml"),
        new("insights", "Insights", "RouteRoot.insights", "windows/app/OpenBurnBar.App/Insights/InsightsPage.xaml"),
        new("sessionLogs", "Session Logs", "RouteRoot.sessionLogs", "windows/app/OpenBurnBar.App/SessionLogs/SessionLogsHostPage.xaml"),
        new("memory", "Memory", "RouteRoot.memory", "windows/app/OpenBurnBar.App/Memory/MemoryPage.xaml"),
        new("missionControl", "Mission Control", "RouteRoot.missionControl", "windows/app/OpenBurnBar.App/MissionControl/MissionControlPage.xaml"),
        new("budget", "Budget", "RouteRoot.budget", "windows/app/OpenBurnBar.App/Budget/BudgetPage.xaml"),
        new("dataControlCenter", "Data Control Center", "RouteRoot.dataControlCenter", "windows/app/OpenBurnBar.App/DataControlCenter/DataControlCenterPage.xaml"),
        new("chat", "Chat", "RouteRoot.chat", "windows/app/OpenBurnBar.App/Chat/ChatHostPage.xaml"),
        new("switcher", "Switcher", "RouteRoot.switcher", "windows/app/OpenBurnBar.App/Switcher/SwitcherHostPage.xaml"),
        new("onboarding", "Onboarding", "RouteRoot.onboarding", "windows/app/OpenBurnBar.App/Onboarding/OnboardingPage.xaml"),
        new("settings", "Settings", "RouteRoot.settings", "windows/app/OpenBurnBar.App/Settings/SettingsPage.xaml"),
        new("elderWand", "Elder Wand", "RouteRoot.elderWand", "windows/app/OpenBurnBar.App/ElderWand/ElderWandPage.xaml"),
    };

    public static IReadOnlyList<UiHarnessRoute> All => Routes;

    public static IReadOnlyList<UiHarnessRoute> Select(IEnumerable<string>? routeKeys)
    {
        if (routeKeys is null)
        {
            return Routes;
        }

        var requested = routeKeys
            .Where(key => !string.IsNullOrWhiteSpace(key))
            .Select(key => key.Trim())
            .ToArray();
        if (requested.Length == 0)
        {
            return Routes;
        }

        var byKey = Routes.ToDictionary(route => route.Key, StringComparer.OrdinalIgnoreCase);
        var selected = new List<UiHarnessRoute>();
        foreach (string key in requested)
        {
            if (!byKey.TryGetValue(key, out UiHarnessRoute? route))
            {
                throw new ArgumentException($"Unknown route '{key}'. Known routes: {string.Join(", ", Routes.Select(r => r.Key))}");
            }

            selected.Add(route);
        }

        return selected;
    }
}
