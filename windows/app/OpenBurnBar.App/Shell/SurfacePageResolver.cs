using System;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Maps a <see cref="NavDestination.Key"/> to the real <c>Page</c> type that renders it,
/// defaulting to <see cref="SurfaceStubPage"/> only for unknown keys. All
/// <see cref="NavCatalog"/> and <see cref="NavCatalog.Auxiliary"/> destinations are registered.
/// <see cref="AppShell"/> routes the content Frame through this resolver.
/// </summary>
public static class SurfacePageResolver
{
    /// <summary>The real page type for a destination key, or the stub when none is registered.</summary>
    public static Type Resolve(string key) => key switch
    {
        "budget" => typeof(OpenBurnBar.App.Budget.BudgetPage),
        "quota" => typeof(OpenBurnBar.App.Quota.QuotaWorkspacePage),
        "insights" => typeof(OpenBurnBar.App.Insights.InsightsPage),
        "sessionLogs" => typeof(OpenBurnBar.App.SessionLogs.SessionLogsHostPage),
        "dashboard" => typeof(OpenBurnBar.App.Dashboard.DashboardPage),
        "missionControl" => typeof(OpenBurnBar.App.MissionControl.MissionControlPage),
        "dataControlCenter" => typeof(OpenBurnBar.App.DataControlCenter.DataControlCenterPage),
        "chat" => typeof(OpenBurnBar.App.Chat.ChatHostPage),
        "switcher" => typeof(OpenBurnBar.App.Switcher.SwitcherHostPage),
        // Elder Wand is an Auxiliary (Command-Palette) destination, not a sidebar row — see
        // NavCatalog.Auxiliary + ElderWandPage.xaml for the macOS reachability-parity rationale.
        "memory" => typeof(OpenBurnBar.App.Memory.MemoryPage),
        "elderWand" => typeof(OpenBurnBar.App.ElderWand.ElderWandPage),
        "onboarding" => typeof(OpenBurnBar.App.Onboarding.OnboardingPage),
        "settings" => typeof(OpenBurnBar.App.Settings.Winui.SettingsPage),
        _ => typeof(SurfaceStubPage),
    };
}
